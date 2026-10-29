#+build linux
package main

import "core:c"
import libc "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import posix "core:sys/posix"

// Prompt decoding is separate from redraw: command substitutions execute once
// when the prompt is prepared, rather than again on every cursor movement.
native_shell_prompt :: proc(shell:^Native_Shell,continuation:bool,source:string="",use_source:bool=false)->string {
    result_allocator:=context.allocator
    arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
    context.allocator=mem.dynamic_arena_allocator(&arena);context.temp_allocator=context.allocator
    name:="PS1";fallback:=`\w \$ `
    if continuation {name="PS2";fallback="> "}
    prompt,exists:=shell.variables[name];if !exists {prompt=fallback};if use_source {prompt=source}
    output:=make([dynamic]u8);append(&output,'"')
    literal :: proc(output:^[dynamic]u8,text:string) {
        for byte in transmute([]u8)text {if byte=='$'||byte=='`'||byte=='"'||byte=='\\' {append(output,'\\')};append(output,byte)}
    }
    cwd:=native_shell_logical_directory(shell)
    home:=shell.variables["HOME"];display:=cwd
    if home!=""&&(cwd==home||strings.has_prefix(cwd,strings.concatenate([]string{home,"/"},context.temp_allocator))) {display=strings.concatenate([]string{"~",cwd[len(home):]},context.temp_allocator)}
    for i:=0;i<len(prompt);i+=1 {
        ch:=prompt[i]
        if ch=='!'&&shell.compat.options["posix"] {if i+1<len(prompt)&&prompt[i+1]=='!' {append(&output,'!');i+=1} else {literal(&output,fmt.tprintf("%d",native_shell_editor.history_base+len(native_shell_editor.history)))};continue}
        if ch!='\\'||i+1==len(prompt) {if ch=='"'||ch=='\\' {append(&output,'\\')};append(&output,ch);continue}
        i+=1;ch=prompt[i]
        switch ch {
        case 'a':append(&output,7)
        case 'e':append(&output,27)
        case 'n':append(&output,'\n')
        case 'r':append(&output,'\r')
        case '[':append(&output,1)
        case ']':append(&output,2)
        case '$':if posix.geteuid()==0 {append(&output,'#')} else {append(&output,'$')}
        case '\\':append(&output,'\\','\\')
        case 'w':literal(&output,native_shell_editor_safe(display))
        case 'W':
            tail:=display;if slash:=strings.last_index_byte(tail,'/');slash>=0&&slash+1<len(tail) {tail=tail[slash+1:]}
            literal(&output,native_shell_editor_safe(tail))
        case 'u':
            user:=shell.variables["USER"];if user=="" {user=shell.variables["LOGNAME"]};if user=="" {user=fmt.tprintf("%d",posix.getuid())};literal(&output,user)
        case 'h','H':
            host:[256]c.char
            if posix.gethostname(raw_data(host[:]),len(host)-1)==.OK {text:=string(cstring(raw_data(host[:])));if ch=='h' {if dot:=strings.index_byte(text,'.');dot>=0 {text=text[:dot]}};literal(&output,text)}
        case 's':literal(&output,"terminal+")
        case 'v','V':
            version,_:=native_shell_value_get(shell,"BASH_VERSION");if version=="" {version="5.3"}
            end:=len(version);for byte,at in version {if !(byte>='0'&&byte<='9'||byte=='.') {end=at;break}};version=version[:end]
            if ch=='v' {first:=strings.index_byte(version,'.');if first>=0 {if second:=strings.index_byte(version[first+1:],'.');second>=0 {version=version[:first+1+second]}}}
            literal(&output,version)
        case '!':literal(&output,fmt.tprintf("%d",len(native_shell_editor.history)+1))
        case '#':literal(&output,fmt.tprintf("%d",native_shell_editor.command_number+1))
        case 'j':count:=0;for &job in shell.jobs {if !native_shell_job_done(&job) {count+=1}};literal(&output,fmt.tprintf("%d",count))
        case 'l':
            tty:=posix.ttyname(0);if tty!=nil {text:=string(tty);if slash:=strings.last_index_byte(text,'/');slash>=0 {text=text[slash+1:]};literal(&output,text)}
        case 'd','t','T','@','A','D':
            format:="%a %b %d"
            switch ch {case 't':format="%H:%M:%S";case 'T':format="%I:%M:%S";case '@':format="%I:%M %p";case 'A':format="%H:%M";case 'D':
                if i+1<len(prompt)&&prompt[i+1]=='{' {start:=i+2;end:=start;for end<len(prompt)&&prompt[end]!='}' {end+=1};if end<len(prompt) {format=prompt[start:end];i=end}}
            }
            now:=posix.time(nil);local:posix.tm
            if posix.localtime_r(&now,&local)!=nil {bytes:[512]c.char;pattern:=strings.clone_to_cstring(format,context.temp_allocator);count:=posix.strftime(raw_data(bytes[:]),len(bytes),pattern,&local);literal(&output,string(bytes[:int(count)]))}
        case '0'..='7':
            value:=int(ch-'0');count:=1
            for count<3&&i+1<len(prompt)&&prompt[i+1]>='0'&&prompt[i+1]<='7' {i+=1;value=value*8+int(prompt[i]-'0');count+=1}
            append(&output,u8(value&255))
        case:append(&output,'\\','\\',ch)
        }
    }
    append(&output,'"')
    if shell.compat!=nil&&(shell.compat.shopts["promptvars"]||shell.compat.options["posix"]) {
        status:=shell.status
        expanded,error:=native_shell_expand_assignment(shell,string(output[:]))
        shell.status=status
        if error=="" {return strings.clone(expanded,result_allocator)}
    }
    // Quote removal is still needed for escapes inserted by literal().
    result:=make([dynamic]u8)
    for i:=1;i<len(output)-1;i+=1 {if output[i]=='\\'&&i+1<len(output)-1 {i+=1};append(&result,output[i])}
    return strings.clone(string(result[:]),result_allocator)
}

native_shell_prompt_value :: proc(shell:^Native_Shell,value:string)->string {return native_shell_prompt(shell,false,value,true)}

native_shell_prompt_cells :: proc(prompt:string)->int {
    count:=0;hidden:=false
    for i:=0;i<len(prompt); {
        byte:=prompt[i]
        if byte==1 {hidden=true;i+=1;continue};if byte==2 {hidden=false;i+=1;continue}
        if byte==27&&i+1<len(prompt) {
            if prompt[i+1]=='[' {i+=2;for i<len(prompt) {last:=prompt[i];i+=1;if last>=0x40&&last<=0x7e {break}};continue}
            if prompt[i+1]==']' {i+=2;for i<len(prompt)&&prompt[i]!=7 {if prompt[i]==27&&i+1<len(prompt)&&prompt[i+1]=='\\' {i+=1;break};i+=1};if i<len(prompt) {i+=1};continue}
        }
        ch,n:=utf8.decode_rune(prompt[i:]);i+=max(1,n)
        if !hidden {count+=native_shell_editor_rune_width(ch)}
    }
    return count
}
native_shell_prompt_visible :: proc(prompt:string)->string {
    bytes:=make([dynamic]u8);for byte in transmute([]u8)prompt {if byte!=1&&byte!=2 {append(&bytes,byte)}};return string(bytes[:])
}

Native_Shell_Completion :: struct {function,words,command,prefix,suffix,filter,glob:string,actions:[dynamic]string,nospace,filenames,default_files,bashdefault,nosort,noquote,dirnames,plusdirs,fullquote:bool}
Native_Shell_Keybinding :: struct {action:string,command,macro:bool,key:u8}
native_shell_completions:map[string]Native_Shell_Completion
native_shell_keybindings:map[string]Native_Shell_Keybinding
native_shell_editing_mode:="emacs"

native_shell_editor_builtin_name :: proc(name:string)->bool {return name=="bind"||name=="complete"||name=="compgen"||name=="compopt"||name=="fc"}
native_shell_editor_builtin :: proc(shell:^Native_Shell,args:[]string)->(int,bool) {
    if len(args)==0 {return 0,false}
    native_shell_editor.shell=shell
    switch args[0] {
    case "fc":return native_shell_fc_builtin(shell,args),true
    case "bind":return native_shell_bind_builtin(shell,args),true
    case "complete":return native_shell_complete_builtin(shell,args),true
    case "compgen":
        normalized:=make([dynamic]string);append(&normalized,args[0]);append(&normalized,..native_shell_completion_arguments(args[1:]));arguments:=normalized[:]
        options:=make([dynamic]string);destination:=""
        for i:=1;i<len(arguments);i+=1 {
            if arguments[i]=="--" {append(&options,..arguments[i:]);break}
            if arguments[i]=="-V" {if i+1==len(arguments) {fmt.eprintln("compgen: -V requires an array name");return 2,true};i+=1;destination=arguments[i];if !native_shell_name(destination) {fmt.eprintln("compgen: invalid array name");return 2,true}} else {
                value:=arguments[i];append(&options,value)
                if value=="-W"||value=="-F"||value=="-C"||value=="-A"||value=="-G"||value=="-P"||value=="-S"||value=="-X"||value=="-o" {if i+1<len(arguments) {i+=1;append(&options,arguments[i])}}
            }
        }
        for i:=0;i<len(options);i+=1 {option:=options[i];if option=="--" {break};if option=="-D"||option=="-E"||option=="-I" {fmt.eprintf("compgen: %s: invalid option\n",option);return 2,true};if option=="-W"||option=="-F"||option=="-C"||option=="-A"||option=="-G"||option=="-P"||option=="-S"||option=="-X"||option=="-o" {i+=1}}
        spec,word,error:=native_shell_completion_parse(options[:])
        if error!="" {fmt.eprintln("compgen:",error);return 2,true}
        if spec.function!="" {fmt.eprintln("compgen: warning: -F option may not work as you expect")}
        if spec.command!="" {fmt.eprintln("compgen: warning: -C option may not work as you expect")}
        candidates:=native_shell_completion_candidates(shell,spec,word,"","",false)
        if destination!="" {
            resolved,resolve_error:=native_shell_read_array_name(shell,destination);if resolve_error!="" {fmt.eprintln("compgen:",resolve_error);return 1,true};destination=resolved
            if shell.compat.attributes[destination]&NATIVE_SHELL_READONLY!=0 {fmt.eprintln("compgen: readonly array");return 1,true}
            if array:=shell.compat.arrays[destination];array!=nil&&array.associative_mode {fmt.eprintln("compgen: not an indexed array");return 1,true}
            native_shell_array_remove(shell,destination);native_shell_array_ensure(shell,destination)
            native_shell_attribute_set(shell,destination,shell.compat.attributes[destination]|NATIVE_SHELL_INDEXED)
            for value,i in candidates {if assignment_error:=native_shell_value_set(shell,fmt.tprintf("%s[%d]",destination,i),value);assignment_error!="" {fmt.eprintln("compgen:",assignment_error);return 1,true}}
        } else {for value in candidates {fmt.println(value)}}
        if len(candidates)==0 {return 1,true};return 0,true
    case "compopt":return native_shell_compopt_builtin(shell,args),true
    }
    return 0,false
}

// Readline configuration is owned by the shell, rather than a command arena.
native_shell_readline_variables:map[string]string
native_shell_readline_configured:bool
native_shell_readline_keymap:="emacs-standard"

native_shell_editor_setting :: proc(name:string)->string {
    if name=="editing-mode" {return native_shell_editing_mode}
    if name=="keymap" {return native_shell_readline_keymap}
    if value,found:=native_shell_readline_variables[name];found {return value}
    switch name {
    case "editing-mode":return native_shell_editing_mode
    case "keymap":return native_shell_readline_keymap
    case "bell-style":return "audible"
    case "enable-bracketed-paste","mark-directories","mark-symlinked-directories","match-hidden-files","page-completions","input-meta","output-meta","meta-flag":return "on"
    case "completion-query-items":return "100"
    case "keyseq-timeout":return "500"
    case "completion-display-width":return "-1"
    }
    return "off"
}
native_shell_editor_setting_on :: proc(name:string)->bool {return native_shell_editor_setting(name)=="on"}

native_shell_editor_set_setting :: proc(shell:^Native_Shell,name,source:string)->bool {
    value:=source
    switch name {
    case "editing-mode":
        if value!="vi"&&value!="emacs" {return false};native_shell_editing_mode="vi" if value=="vi" else "emacs"
        native_shell_readline_keymap="vi-insertion" if value=="vi" else "emacs-standard"
        native_shell_bool_set(shell,&shell.compat.options,"vi",value=="vi");native_shell_bool_set(shell,&shell.compat.options,"emacs",value=="emacs")
    case "keymap":
        switch value {case "emacs","emacs-standard":native_shell_readline_keymap="emacs-standard";case "emacs-meta":native_shell_readline_keymap="emacs-meta";case "emacs-ctlx":native_shell_readline_keymap="emacs-ctlx";case "vi","vi-move","vi-command":native_shell_readline_keymap="vi-command";case "vi-insert","vi-insertion":native_shell_readline_keymap="vi-insertion";case:return false}
    case "bell-style":if value!="none"&&value!="visible"&&value!="audible" {return false}
    case "completion-query-items","keyseq-timeout","completion-display-width":number,valid:=strconv.parse_int(value);if !valid||number< -1 {return false}
    case "completion-ignore-case","completion-map-case","disable-completion","enable-bracketed-paste","mark-directories","mark-symlinked-directories","match-hidden-files","show-all-if-ambiguous","show-all-if-unmodified","skip-completed-text","history-preserve-point","page-completions","input-meta","output-meta","meta-flag","convert-meta":
        if value=="1" {value="on"};if value=="0" {value="off"};if value!="on"&&value!="off" {return false}
    case:return false
    }
    if native_shell_readline_variables==nil {native_shell_readline_variables=make(map[string]string,shell.allocator)}
    if name=="meta-flag" {native_shell_owned_text_set(&native_shell_readline_variables,"input-meta",value,shell.allocator)}
    native_shell_owned_text_set(&native_shell_readline_variables,name,value,shell.allocator)
    return true
}

native_shell_bind_key :: proc(keymap,key:string)->string {return strings.concatenate([]string{keymap,"\x1f",key})}
native_shell_bind_store :: proc(shell:^Native_Shell,keymap,key:string,binding:Native_Shell_Keybinding) {
    if native_shell_keybindings==nil {native_shell_keybindings=make(map[string]Native_Shell_Keybinding,shell.allocator)}
    owned:=native_shell_bind_key(keymap,key)
    if old,exists:=native_shell_keybindings[owned];exists {
        delete(old.action,shell.allocator)
        for found,_ in native_shell_keybindings {if found==owned {native_shell_keybindings[found]=Native_Shell_Keybinding{action=strings.clone(binding.action,shell.allocator),command=binding.command,macro=binding.macro};break}}
    } else {native_shell_keybindings[strings.clone(owned,shell.allocator)]=Native_Shell_Keybinding{action=strings.clone(binding.action,shell.allocator),command=binding.command,macro=binding.macro}}
}
native_shell_bind_initialize :: proc(shell:^Native_Shell) {
    if native_shell_keybindings!=nil {return}
    native_shell_keybindings=make(map[string]Native_Shell_Keybinding,shell.allocator)
    defaults:=[][2]string{{"\x01","beginning-of-line"},{"\x02","backward-char"},{"\x04","delete-char"},{"\x05","end-of-line"},{"\x06","forward-char"},{"\x08","backward-delete-char"},{"\x09","complete"},{"\x0a","accept-line"},{"\x0b","kill-line"},{"\x0c","clear-screen"},{"\x0d","accept-line"},{"\x0e","next-history"},{"\x10","previous-history"},{"\x12","reverse-search-history"},{"\x14","transpose-chars"},{"\x15","unix-line-discard"},{"\x17","unix-word-rubout"},{"\x19","yank"},{"\x1f","undo"},{"\x7f","backward-delete-char"},{"\x1bb","backward-word"},{"\x1bf","forward-word"},{"\x1bd","kill-word"},{"\x1bu","upcase-word"},{"\x1bl","downcase-word"},{"\x1bc","capitalize-word"},{"\x1by","yank-pop"},{"\x1b.","yank-last-arg"},{"\x1b_","yank-last-arg"},{"\x1b<","beginning-of-history"},{"\x1b>","end-of-history"},{"\x1b\x7f","backward-kill-word"},{"\x18\x18","exchange-point-and-mark"},{"\x00","set-mark"},{"\x18\x15","undo"}}
    for item in defaults {native_shell_bind_store(shell,"emacs-standard",item[0],{action=item[1]})}
    native_shell_bind_store(shell,"emacs-standard","\x16",{action="quoted-insert"})
}

native_shell_bind_quote :: proc(value:string)->string {
    bytes:=make([dynamic]u8);append(&bytes,'"')
    for ch in transmute([]u8)value {
        switch ch {case 27:append(&bytes,`\e`);case 127:append(&bytes,`\C-?`);case '"','\\':append(&bytes,'\\',ch);case 0..=26:append(&bytes,`\C-`);append(&bytes,'@'+ch);case:append(&bytes,ch)}
    }
    append(&bytes,'"');return string(bytes[:])
}

native_shell_bind_inputrc :: proc(shell:^Native_Shell,path:string,depth:int=0)->int {
    if depth>=32 {fmt.eprintln("bind: inputrc include nesting limit");return 1}
    filename:=path
    if strings.has_prefix(filename,"~/") {filename=strings.concatenate([]string{shell.variables["HOME"],filename[1:]})}
    bytes,error:=os.read_entire_file(filename,context.allocator)
    if error!=nil {fmt.eprintf("bind: cannot read %s\n",filename);return 1}
    text:=string(bytes);active:=true;parents:=make([dynamic]bool);conditions:=make([dynamic]bool);status:=0
    for record in strings.split_iterator(&text,"\n") {
        line:=strings.trim_space(record);if line==""||line[0]=='#' {continue}
        if strings.has_prefix(line,"$if ") {
            condition:=strings.trim_space(line[4:]);matched:=false
            if condition=="Bash"||condition=="bash"||condition=="terminal+" {matched=true}
            if strings.has_prefix(condition,"mode=") {matched=condition[5:]==native_shell_editing_mode}
            if strings.has_prefix(condition,"term=") {term:=shell.variables["TERM"];matched=term==condition[5:]||strings.has_prefix(term,strings.concatenate([]string{condition[5:],"-"}))}
            append(&parents,active);append(&conditions,matched);active=active&&matched;continue
        }
        if line=="$else" {if len(parents)==0 {status=1;continue};active=parents[len(parents)-1]&&!conditions[len(conditions)-1];continue}
        if line=="$endif" {if len(parents)==0 {status=1;continue};active=pop(&parents);pop(&conditions);continue}
        if !active {continue}
        if strings.has_prefix(line,"$include ") {
            include:=strings.trim(strings.trim_space(line[9:]),"\"")
            if !strings.has_prefix(include,"/")&&!strings.has_prefix(include,"~") {if slash:=strings.last_index_byte(filename,'/');slash>=0 {include=strings.concatenate([]string{filename[:slash+1],include})}}
            if native_shell_bind_inputrc(shell,include,depth+1)!=0 {status=1};continue
        }
        if native_shell_bind_builtin(shell,[]string{"bind",line})!=0 {status=1}
    }
    if len(parents)>0 {status=1};return status
}

native_shell_bind_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    native_shell_bind_initialize(shell)
    command:=false;keymap:=native_shell_readline_keymap
    for i:=1;i<len(args);i+=1 {
        value:=args[i]
        switch value {
        case "-m":
            if i+1==len(args) {return 2};i+=1;keymap=args[i]
            switch keymap {case "emacs":keymap="emacs-standard";case "vi","vi-move":keymap="vi-command";case "vi-insert":keymap="vi-insertion";case "emacs-standard","emacs-meta","emacs-ctlx","vi-command","vi-insertion":case:fmt.eprintln("bind: invalid keymap");return 1};continue
        case "-f":if i+1==len(args) {return 2};i+=1;if native_shell_bind_inputrc(shell,args[i])!=0 {return 1};continue
        case "-x":command=true;continue
        case "-v","-V":
            for name in strings.fields("bell-style completion-ignore-case completion-map-case completion-query-items completion-display-width disable-completion editing-mode enable-bracketed-paste history-preserve-point keymap keyseq-timeout mark-directories mark-symlinked-directories match-hidden-files page-completions show-all-if-ambiguous show-all-if-unmodified skip-completed-text") {if value=="-v" {fmt.printf("set %s %s\n",name,native_shell_editor_setting(name))} else {fmt.printf("%s is set to `%s'\n",name,native_shell_editor_setting(name))}};continue
        case "-p","-P","-s","-S","-X":
            keys:=make([dynamic]string);prefix:=native_shell_bind_key(keymap,"");for key,_ in native_shell_keybindings {if strings.has_prefix(key,prefix) {append(&keys,key)}};slice.sort(keys[:])
            for key in keys {binding:=native_shell_keybindings[key];if binding.action=="" {continue};if value=="-X"&&!binding.command||value!="-X"&&binding.command {continue};if (value=="-s"||value=="-S")!=binding.macro&&value!="-X" {continue};action:=binding.action;if binding.macro||binding.command {action=native_shell_bind_quote(action)};fmt.printf("%s: %s\n",native_shell_bind_quote(key[len(prefix):]),action)};continue
        case "-l":
            names:=make([dynamic]string);seen:=make(map[string]bool)
            for _,binding in native_shell_keybindings {if !binding.macro&&!binding.command&&binding.action!=""&&!seen[binding.action] {seen[binding.action]=true;append(&names,binding.action)}};slice.sort(names[:]);for name in names {fmt.println(name)};continue
        case "-q","-r","-u":
            if i+1==len(args) {return 2};i+=1;argument:=args[i];prefix:=native_shell_bind_key(keymap,"")
            if value=="-r" {native_shell_bind_store(shell,keymap,native_shell_bind_decode(argument),{});continue}
            keys:=make([dynamic]string);for key,binding in native_shell_keybindings {if strings.has_prefix(key,prefix)&&!binding.macro&&!binding.command&&binding.action==argument {append(&keys,key)}};slice.sort(keys[:])
            if value=="-q" {if len(keys)==0 {fmt.printf("%s is not bound to any keys\n",argument);return 1};fmt.printf("%s can be invoked via ",argument);for key,at in keys {if at>0 {fmt.print(", ")};fmt.print(native_shell_bind_quote(key[len(prefix):]))};fmt.println(".")} else {for key in keys {native_shell_bind_store(shell,keymap,key[len(prefix):],{})}};continue
        }
        if strings.has_prefix(value,"set ") {
            parts:=strings.fields(value)
            if len(parts)<3||!native_shell_editor_set_setting(shell,parts[1],parts[2]) {fmt.eprintf("bind: unsupported variable setting: %s\n",value);return 1};continue
        }
        colon:=-1;quoted:=false;escaped:=false
        for ch,at in transmute([]u8)value {if escaped {escaped=false;continue};if ch=='\\' {escaped=true;continue};if ch=='"' {quoted=!quoted};if ch==':'&&!quoted {colon=at;break}}
        if colon<0 {fmt.eprintln("bind: expected a key binding");return 1}
        key:=native_shell_bind_decode(strings.trim_space(value[:colon]));action:=strings.trim_space(value[colon+1:]);macro:=strings.has_prefix(action,"\"")&&!command
        if macro {action=native_shell_bind_decode(action)} else {action=strings.trim(action,"\"")}
        native_shell_bind_store(shell,keymap,key,{action=action,command=command,macro=macro})
    }
    return 0
}

native_shell_bind_decode :: proc(text:string)->string {
    input:=strings.trim(text,"\"");bytes:=make([dynamic]u8)
    for i:=0;i<len(input);i+=1 {
        byte:=input[i]
        if byte=='\\'&&i+1<len(input) {
            i+=1;byte=input[i]
            if (byte=='C'||byte=='M')&&i+2<len(input)&&input[i+1]=='-' {
                meta:=byte=='M';i+=2;byte=input[i]
                if meta {append(&bytes,27);if byte=='\\'&&i+3<len(input)&&input[i+1]=='C'&&input[i+2]=='-' {i+=3;byte=input[i];byte&=31}} else {if byte=='?' {byte=127} else {byte&=31}}
            } else {
                switch byte {case 'e':byte=27;case 'n':byte=10;case 'r':byte=13;case 't':byte=9;case 'b':byte=8;case 'a':byte=7;case 'v':byte=11;case 'f':byte=12
                case '0'..='7':number:=int(byte-'0');count:=1;for count<3&&i+1<len(input)&&input[i+1]>='0'&&input[i+1]<='7' {i+=1;number=number*8+int(input[i]-'0');count+=1};byte=u8(number&255)
                case 'x':number:=0;count:=0;for count<2&&i+1<len(input) {digit:=input[i+1];value:=-1;if digit>='0'&&digit<='9' {value=int(digit-'0')} else if digit>='a'&&digit<='f' {value=int(digit-'a')+10} else if digit>='A'&&digit<='F' {value=int(digit-'A')+10};if value<0 {break};i+=1;number=number*16+value;count+=1};byte=u8(number)
                }
            }
        }
        append(&bytes,byte)
    }
    return string(bytes[:])
}

native_shell_completion_option :: proc(spec:^Native_Shell_Completion,name:string,enabled:bool)->bool {
    switch name {
    case "nospace":spec.nospace=enabled
    case "filenames":spec.filenames=enabled
    case "default":spec.default_files=enabled
    case "bashdefault":spec.bashdefault=enabled
    case "nosort":spec.nosort=enabled
    case "noquote":spec.noquote=enabled
    case "dirnames":spec.dirnames=enabled
    case "plusdirs":spec.plusdirs=enabled
    case "fullquote":spec.fullquote=enabled
    case:return false
    }
    return true
}
native_shell_completion_action :: proc(name:string)->bool {
    switch name {case "alias","arrayvar","binding","builtin","command","directory","disabled","enabled","export","file","function","group","helptopic","hostname","job","keyword","running","service","setopt","shopt","signal","stopped","user","variable":return true}
    return false
}

native_shell_completion_arguments :: proc(args:[]string)->[]string {
    result:=make([dynamic]string)
    for i:=0;i<len(args);i+=1 {
        value:=args[i]
        if value=="--" {append(&result,..args[i:]);break}
        if len(value)>1&&value[0]=='-'&&value[1]!='-' {
            for at:=1;at<len(value);at+=1 {
                ch:=value[at];append(&result,fmt.aprintf("-%c",ch))
                if strings.index_byte("WFCAGPSXoV",ch)>=0 {
                    if at+1<len(value) {append(&result,value[at+1:])} else if i+1<len(args) {i+=1;append(&result,args[i])}
                    break
                }
            }
        } else {append(&result,value)}
    }
    return result[:]
}

native_shell_completion_parse :: proc(args:[]string)->(Native_Shell_Completion,string,string) {
    spec:Native_Shell_Completion;word:=""
    for i:=0;i<len(args);i+=1 {
        value:=args[i]
        if value=="--" {if i+1<len(args) {word=args[i+1]};break}
        if len(value)>0&&value[0]=='-' {
            if len(value)>2&&!strings.has_prefix(value,"--") {
                combined:=true
                for ch in transmute([]u8)value[1:] {if !strings.contains_any(string([]u8{ch}),"abcdefgjksuv") {combined=false;break}}
                if combined {for ch in transmute([]u8)value[1:] {action:="";switch ch {case 'a':action="alias";case 'b':action="builtin";case 'c':action="command";case 'd':action="directory";case 'e':action="export";case 'f':action="file";case 'g':action="group";case 'j':action="job";case 'k':action="keyword";case 's':action="service";case 'u':action="user";case 'v':action="variable"};append(&spec.actions,action)};continue}
            }
            switch value {
            case "-D","-E","-I":continue
            case "-W","-F","-C","-A","-G","-P","-S","-X","-o":
                if i+1==len(args) {return spec,word,"option requires an argument"};i+=1;argument:=args[i]
                switch value {case "-W":spec.words=argument;case "-F":spec.function=argument;case "-C":spec.command=argument;case "-A":if !native_shell_completion_action(argument) {return spec,word,"invalid action name"};append(&spec.actions,argument);case "-G":spec.glob=argument;case "-P":spec.prefix=argument;case "-S":spec.suffix=argument;case "-X":spec.filter=argument;case "-o":if !native_shell_completion_option(&spec,argument,true) {return spec,word,"unsupported completion option"}}
            case "-a":append(&spec.actions,"alias")
            case "-b":append(&spec.actions,"builtin")
            case "-c":append(&spec.actions,"command")
            case "-d":append(&spec.actions,"directory")
            case "-e":append(&spec.actions,"export")
            case "-f":append(&spec.actions,"file")
            case "-j":append(&spec.actions,"job")
            case "-k":append(&spec.actions,"keyword")
            case "-u":append(&spec.actions,"user")
            case "-v":append(&spec.actions,"variable")
            case "-g":append(&spec.actions,"group")
            case "-s":append(&spec.actions,"service")
            case: return spec,word,fmt.tprintf("unsupported option: %s",value)
            }
        } else {word=value}
    }
    return spec,word,""
}

native_shell_completion_print :: proc(name:string,spec:Native_Shell_Completion,compopt:bool=false) {
    if compopt {fmt.print("compopt")} else {fmt.print("complete")}
    for option in strings.fields("bashdefault default dirnames filenames fullquote noquote nosort nospace plusdirs") {
        enabled:=false
        switch option {case "bashdefault":enabled=spec.bashdefault;case "default":enabled=spec.default_files;case "dirnames":enabled=spec.dirnames;case "filenames":enabled=spec.filenames;case "fullquote":enabled=spec.fullquote;case "noquote":enabled=spec.noquote;case "nosort":enabled=spec.nosort;case "nospace":enabled=spec.nospace;case "plusdirs":enabled=spec.plusdirs}
        if enabled {fmt.printf(" -o %s",option)} else if compopt {fmt.printf(" +o %s",option)}
    }
    if !compopt {
        for action in spec.actions {fmt.printf(" -A %s",explorer_quote(action))}
        fields:=[][2]string{{"-G",spec.glob},{"-W",spec.words},{"-P",spec.prefix},{"-S",spec.suffix},{"-X",spec.filter},{"-F",spec.function},{"-C",spec.command}}
        for item in fields {if item[1]!="" {fmt.printf(" %s %s",item[0],explorer_quote(item[1]))}}
    }
    if name=="-D"||name=="-E"||name=="-I" {fmt.printf(" %s\n",name)} else if name!="" {fmt.printf(" -- %s\n",explorer_quote(name))} else {fmt.println()}
}

native_shell_complete_builtin :: proc(shell:^Native_Shell,input_args:[]string)->int {
    normalized:=make([dynamic]string);append(&normalized,input_args[0]);append(&normalized,..native_shell_completion_arguments(input_args[1:]));args:=normalized[:]
    if native_shell_completions==nil {native_shell_completions=make(map[string]Native_Shell_Completion,shell.allocator)}
    printing,removing:bool
    names:=make([dynamic]string)
    for i:=1;i<len(args);i+=1 {
        value:=args[i]
        if value=="--" {append(&names,..args[i+1:]);break}
        if value=="-p" {printing=true;continue};if value=="-r" {removing=true;continue}
        if value=="-D"||value=="-E"||value=="-I" {append(&names,value);continue}
        if strings.has_prefix(value,"-") {if value=="-W"||value=="-F"||value=="-C"||value=="-A"||value=="-G"||value=="-P"||value=="-S"||value=="-X"||value=="-o" {i+=1};continue}
        append(&names,value)
    }
    if len(args)==1||printing||removing {
        if len(names)==0 {for name,_ in native_shell_completions {append(&names,name)};slice.sort(names[:])}
        status:=0
        for name in names {
            spec,present:=native_shell_completions[name]
            if !present {fmt.eprintf("complete: %s: no completion specification\n",name);status=1;continue}
            if !removing {native_shell_completion_print(name,spec);continue}
            for owned,_ in native_shell_completions {if owned==name {native_shell_completion_free(spec,shell.allocator);delete_key(&native_shell_completions,owned);delete(owned,shell.allocator);break}}
        }
        return status
    }
    spec,_,error:=native_shell_completion_parse(args[1:]);if error!="" {fmt.eprintln("complete:",error);return 2}
    if len(names)==0 {fmt.eprintln("complete: expected a command name");return 2}
    for name in names {
        copy:=Native_Shell_Completion{function=strings.clone(spec.function,shell.allocator),words=strings.clone(spec.words,shell.allocator),command=strings.clone(spec.command,shell.allocator),prefix=strings.clone(spec.prefix,shell.allocator),suffix=strings.clone(spec.suffix,shell.allocator),filter=strings.clone(spec.filter,shell.allocator),glob=strings.clone(spec.glob,shell.allocator),nospace=spec.nospace,filenames=spec.filenames,default_files=spec.default_files,bashdefault=spec.bashdefault,nosort=spec.nosort,noquote=spec.noquote,dirnames=spec.dirnames,plusdirs=spec.plusdirs,fullquote=spec.fullquote,actions=make([dynamic]string,0,0,shell.allocator)}
        for action in spec.actions {append(&copy.actions,strings.clone(action,shell.allocator))}
        if old,exists:=native_shell_completions[name];exists {native_shell_completion_free(old,shell.allocator);for owned,_ in native_shell_completions {if owned==name {native_shell_completions[owned]=copy;break}}} else {native_shell_completions[strings.clone(name,shell.allocator)]=copy}
    }
    return 0
}

native_shell_completing:bool
native_shell_completion_status:int
native_shell_compopt_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    changes:=make([dynamic]Native_Shell_Option_Change);names:=make([dynamic]string)
    for i:=1;i<len(args);i+=1 {
        value:=args[i]
        if value=="-o"||value=="+o" {if i+1==len(args) {return 2};i+=1;test:=Native_Shell_Completion{};if !native_shell_completion_option(&test,args[i],true) {fmt.eprintf("compopt: invalid option %s\n",args[i]);return 2};append(&changes,Native_Shell_Option_Change{name=args[i],enabled=value=="-o"});continue}
        if value=="--" {append(&names,..args[i+1:]);break}
        append(&names,value)
    }
    if len(names)==0 {
        if !native_shell_completing {fmt.eprintln("compopt: not currently executing completion function");return 1}
        if len(changes)==0 {native_shell_completion_print("",native_shell_active_completion,true)} else {for change in changes {_=native_shell_completion_option(&native_shell_active_completion,change.name,change.enabled)}};return 0
    }
    status:=0
    for name in names {
        spec,present:=native_shell_completions[name];if !present {fmt.eprintf("compopt: %s: no completion specification\n",name);status=1;continue}
        if len(changes)==0 {native_shell_completion_print(name,spec,true)} else {for change in changes {_=native_shell_completion_option(&spec,change.name,change.enabled)};native_shell_completions[name]=spec}
    }
    return status
}

native_shell_completion_free :: proc(spec:Native_Shell_Completion,allocator:mem.Allocator) {
    delete(spec.function,allocator);delete(spec.words,allocator);delete(spec.command,allocator);delete(spec.prefix,allocator);delete(spec.suffix,allocator);delete(spec.filter,allocator);delete(spec.glob,allocator)
    for action in spec.actions {delete(action,allocator)};delete(spec.actions)
}

native_shell_active_completion:Native_Shell_Completion
native_shell_completion_fold :: proc(value:string)->string {
    folded:=value
    if native_shell_editor_setting_on("completion-ignore-case") {folded=strings.to_lower(folded)}
    if native_shell_editor_setting_on("completion-map-case") {folded,_=strings.replace_all(folded,"-","_")}
    return folded
}
native_shell_completion_prefix :: proc(value,prefix:string)->bool {return strings.has_prefix(native_shell_completion_fold(value),native_shell_completion_fold(prefix))}
native_shell_completion_common :: proc(candidates:[]string)->string {
    if len(candidates)==0 {return ""}
    common:=candidates[0]
    for candidate in candidates[1:] {left:=native_shell_completion_fold(common);right:=native_shell_completion_fold(candidate);i:=0;for i<len(left)&&i<len(right)&&left[i]==right[i] {i+=1};common=common[:min(i,len(common))]}
    for len(common)>0&&!utf8.valid_string(common) {common=common[:len(common)-1]};return common
}
native_shell_completion_replace :: proc(bytes:^[dynamic]u8,start:int,cursor:^int,replacement:string) {
    last:=cursor^
    if native_shell_editor_setting_on("skip-completed-text") {
        suffix:=replacement[min(len(replacement),cursor^-start):]
        for ch in transmute([]u8)suffix {if last>=len(bytes^)||bytes^[last]!=ch {break};last+=1}
    }
    native_shell_editor_replace(bytes,start,last,replacement);cursor^=start+len(replacement)
}
native_shell_completion_display :: proc(candidates:[]string) {
    native_shell_editor_write("\r\n")
    limit,_:=strconv.parse_int(native_shell_editor_setting("completion-query-items"))
    if limit>0&&len(candidates)>=limit {
        native_shell_editor_write(fmt.tprintf("Display all %d possibilities? (y or n) ",len(candidates)))
        reply,state:=native_shell_editor_read_byte(-1);native_shell_editor_write("\r\n")
        if state!=1||reply!='y'&&reply!='Y'&&reply!=' ' {return}
    }
    rows:=0
    for candidate in candidates {
        if rows>=20&&native_shell_editor_setting_on("page-completions") {
            native_shell_editor_write("--More--");reply,state:=native_shell_editor_read_byte(-1);native_shell_editor_write("\r\x1b[2K")
            if state!=1||reply=='q'||reply==3||reply==27 {break};rows=0;if reply==10||reply==13 {rows=19}
        }
        safe:=native_shell_editor_safe(candidate);native_shell_editor_write(safe);native_shell_editor_write("\r\n");rows+=1
    }
}
// Completion must tolerate unfinished quotes and must not evaluate user input.
// Keep raw spellings in COMP_WORDS; only the current callback argument is unquoted.
Native_Shell_Completion_Word :: struct {raw:string,first,last:int}
native_shell_completion_lex :: proc(shell:^Native_Shell,line:string,split_words:bool=true)->[]Native_Shell_Completion_Word {
    breaks,configured:=shell.variables["COMP_WORDBREAKS"]
    if !configured {breaks=" \t\n\"'@><=;|&(:"}
    if !split_words {breaks=""}
    words:=make([dynamic]Native_Shell_Completion_Word)
    for i:=0;i<len(line); {
        if line[i]==' '||line[i]=='\t'||line[i]=='\n' {i+=1;continue}
        first:=i;quote:u8
        for i<len(line) {
            ch:=line[i]
            if ch=='\\'&&quote!='\''&&i+1<len(line) {i+=2;continue}
            if quote!=0 {i+=1;if ch==quote {quote=0};continue}
            if ch=='\''||ch=='"' {quote=ch;i+=1;continue}
            if ch==' '||ch=='\t'||ch=='\n' {break}
            if strings.index_byte(breaks,ch)>=0 {if i==first {i+=1};break}
            i+=1
        }
        append(&words,Native_Shell_Completion_Word{line[first:i],first,i})
    }
    return words[:]
}
native_shell_completion_unquote :: proc(raw:string)->string {
    value:=make([dynamic]u8);quote:u8
    for i:=0;i<len(raw);i+=1 {
        ch:=raw[i]
        if ch=='\\'&&quote!='\''&&i+1<len(raw) {i+=1;append(&value,raw[i]);continue}
        if ch==quote&&quote!=0 {quote=0;continue}
        if quote==0&&(ch=='\''||ch=='"') {quote=ch;continue}
        append(&value,ch)
    }
    return string(value[:])
}
native_shell_completion_context :: proc(shell:^Native_Shell,line:string,point:int)->(words:[]string,current,start:int,word,previous:string) {
    tokens:=native_shell_completion_lex(shell,line)
    result:=make([dynamic]string);current= -1;start=point
    for token,index in tokens {
        append(&result,token.raw)
        if point>=token.first&&point<=token.last {current=index;start=token.first;word=native_shell_completion_unquote(line[token.first:point])}
    }
    if current<0&&point>0 {current=len(result);append(&result,"")}
    if current>0 {previous=result[current-1]}
    words=result[:];return
}
native_shell_completion_segment :: proc(line:string,point:int)->(string,int,int) {
    first:=0;last:=len(line);quote:u8
    for i:=0;i<len(line);i+=1 {
        ch:=line[i]
        if ch=='\\'&&quote!='\'' {i+=1;continue}
        if quote!=0 {if ch==quote {quote=0};continue}
        if ch=='\''||ch=='"' {quote=ch;continue}
        if ch==';'||ch=='|'||ch=='&'||ch=='\n' {
            if i<point {first=i+1} else {last=i;break}
        }
    }
    for first<point&&(line[first]==' '||line[first]=='\t') {first+=1}
    return line[first:last],point-first,first
}
native_shell_completion_ignored :: proc(shell:^Native_Shell,value:string)->bool {
    suffixes:=shell.variables["FIGNORE"]
    for suffix in strings.split_iterator(&suffixes,":") {if suffix!=""&&strings.has_suffix(value,suffix) {return true}}
    return false
}
native_shell_completion_wordlist :: proc(shell:^Native_Shell,source:string)->[]string {
    ifs,present:=shell.variables["IFS"];if !present {ifs=" \t\n"}
    words:=make([dynamic]string);first:=0;quote:u8
    for i:=0;i<len(source);i+=1 {
        ch:=source[i]
        if ch=='\\'&&quote!='\'' {i+=1;continue}
        if quote!='\''&&ch=='$'&&i+1<len(source)&&(source[i+1]=='{'||source[i+1]=='(') {
            end:int;error:string
            if source[i+1]=='{' {end,error=native_shell_parameter_end(source,i)} else if i+2<len(source)&&source[i+2]=='(' {end,error=native_shell_arithmetic_end(source,i)} else {end,error=native_shell_substitution_end(source,i)}
            if error=="" {i=end-1;continue}
        }
        if quote!=0 {if ch==quote {quote=0};continue}
        if ch=='\''||ch=='"' {quote=ch;continue}
        if strings.index_byte(ifs,ch)>=0 {if i>first {append(&words,source[first:i])};first=i+1}
    }
    if first<len(source) {append(&words,source[first:])}
    return words[:]
}

native_shell_completion_candidates :: proc(shell:^Native_Shell,source_spec:Native_Shell_Completion,word,line,previous:string,sort_results:bool=true,point:int= -1,completion_type:int=0,completion_key:int=0)->[]string {
    // Completion functions can replace their own registered specification.
    // Keep this invocation's strings alive until the callback has returned.
    spec:=source_spec
    spec.function=strings.clone(spec.function);spec.command=strings.clone(spec.command);spec.words=strings.clone(spec.words);spec.prefix=strings.clone(spec.prefix);spec.suffix=strings.clone(spec.suffix);spec.filter=strings.clone(spec.filter);spec.glob=strings.clone(spec.glob)
    candidates:=make([dynamic]string);seen:=make(map[string]bool)
    add :: proc(candidates:^[dynamic]string,seen:^map[string]bool,value,word:string) {if native_shell_completion_prefix(value,word)&&!seen^[value] {seen^[value]=true;append(candidates,value)}}
    if spec.words!="" {for raw in native_shell_completion_wordlist(shell,spec.words) {values,expand_error:=native_shell_expand(shell,Native_Shell_Word{raw=raw},true,false);if expand_error=="" {for value in values {add(&candidates,&seen,value,word)}}}}
    if spec.glob!="" {values,error:=native_shell_globstar(shell,spec.glob);if error=="" {for value in values {add(&candidates,&seen,value,"")}}}
    for action in spec.actions {
        switch action {
        case "variable","export":for name,_ in shell.variables {if action=="variable"||shell.exported[name] {add(&candidates,&seen,name,word)}}
        case "alias":if shell.compat!=nil {for name,_ in shell.compat.aliases {add(&candidates,&seen,name,word)}}
        case "arrayvar":for name,_ in shell.compat.arrays {add(&candidates,&seen,name,word)}
        case "binding":native_shell_bind_initialize(shell);for _,binding in native_shell_keybindings {if !binding.command&&!binding.macro&&binding.action!="" {add(&candidates,&seen,binding.action,word)}}
        case "setopt":for name in native_shell_option_names() {add(&candidates,&seen,name,word)}
        case "shopt":for name in native_shell_shopt_names() {add(&candidates,&seen,name,word)}
        case "signal":for name in strings.fields("SIGHUP SIGINT SIGQUIT SIGILL SIGTRAP SIGABRT SIGBUS SIGFPE SIGKILL SIGUSR1 SIGSEGV SIGUSR2 SIGPIPE SIGALRM SIGTERM SIGSTKFLT SIGCHLD SIGCONT SIGSTOP SIGTSTP SIGTTIN SIGTTOU SIGURG SIGXCPU SIGXFSZ SIGVTALRM SIGPROF SIGWINCH SIGIO SIGPWR SIGSYS") {add(&candidates,&seen,name,word)}
        case "enabled","disabled","helptopic":
            builtin_spec:=Native_Shell_Completion{actions=make([dynamic]string)};append(&builtin_spec.actions,"builtin")
            for name in native_shell_completion_candidates(shell,builtin_spec,word,line,previous,false) {if action=="helptopic"||shell.compat.disabled[name]==(action=="disabled") {add(&candidates,&seen,name,word)}}
        case "function":if shell.compat!=nil {for name,_ in shell.compat.functions {add(&candidates,&seen,name,word)}}
        case "builtin":for name in native_shell_builtin_inventory() {add(&candidates,&seen,name,word)}
        case "keyword":for name in strings.fields("if then else elif fi for while until do done case esac function select in time [[ ]] { }") {add(&candidates,&seen,name,word)}
        case "file","directory":
            slash:=strings.last_index_byte(word,'/');directory:=".";base:=word;head:=""
            if slash>=0 {directory=word[:slash+1];head=directory;base=word[slash+1:]}
            entries,error:=os.read_all_directory_by_path(directory,context.allocator)
            if error==nil {for entry in entries {if native_shell_completion_prefix(entry.name,base) {path:=strings.concatenate([]string{head,entry.name});info,err:=os.stat(path,context.temp_allocator);if err==nil&&(action!="directory"||info.type==.Directory) {add(&candidates,&seen,path,word)}}}}
        case "command":
            builtin_spec:=Native_Shell_Completion{actions=make([dynamic]string)};append(&builtin_spec.actions,"builtin","alias","function","keyword")
            for name in native_shell_completion_candidates(shell,builtin_spec,word,"","",false) {add(&candidates,&seen,name,word)}
            paths:=shell.variables["PATH"];for entry_directory in strings.split_iterator(&paths,":") {directory:=entry_directory;if directory=="" {directory="."};entries,error:=os.read_all_directory_by_path(directory,context.allocator);if error!=nil {continue};for entry in entries {if native_shell_completion_prefix(entry.name,word) {path:=strings.clone_to_cstring(strings.concatenate([]string{directory,"/",entry.name}),context.temp_allocator);if posix.access(path,{.X_OK})==.OK&&entry.type!=.Directory {add(&candidates,&seen,entry.name,word)}}}}
        case "job","running","stopped":for &job in shell.jobs {if native_shell_job_done(&job) {continue};if action=="running"&&native_shell_job_stopped(&job)||action=="stopped"&&!native_shell_job_stopped(&job) {continue};add(&candidates,&seen,fmt.tprintf("%%%d",job.id),word)}
        case "user":
            bytes,error:=os.read_entire_file("/etc/passwd",context.allocator);if error==nil {text:=string(bytes);for record in strings.split_iterator(&text,"\n") {if colon:=strings.index_byte(record,':');colon>0 {add(&candidates,&seen,record[:colon],word)}}}
        case "group","service":
            path:="/etc/group";if action=="service" {path="/etc/services"};bytes,error:=os.read_entire_file(path,context.allocator)
            if error==nil {text:=string(bytes);for record in strings.split_iterator(&text,"\n") {if record==""||record[0]=='#' {continue};end:=strings.index_byte(record,':');if action=="service" {end=len(record);for ch,at in record {if ch==' '||ch=='\t' {end=at;break}}};if end>0 {add(&candidates,&seen,record[:end],word)}}}
        case "hostname":
            path:=shell.variables["HOSTFILE"];if path=="" {path="/etc/hosts"};bytes,error:=os.read_entire_file(path,context.allocator)
            if error==nil {text:=string(bytes);for record in strings.split_iterator(&text,"\n") {parts:=strings.fields(record);for name in parts[min(1,len(parts)):] {if strings.has_prefix(name,"#") {break};add(&candidates,&seen,name,word)}}}
        }
    }
    if (spec.function!=""||spec.command!="")&&shell.compat!=nil {
        callback_point:=point;if callback_point<0 {callback_point=len(line)}
        words,current,_,_,_:=native_shell_completion_context(shell,line,callback_point)
        if completion_type!=0&&len(words)==0 {words=[]string{""};current=0}
        context_names:=[]string{"COMP_LINE","COMP_POINT","COMP_CWORD","COMP_WORDS","COMP_TYPE","COMP_KEY","COMPREPLY"}
        // Bash removes the temporary completion variables when the callback returns.
        for name in context_names {_=native_shell_value_unset(shell,name)}
        defer {for name in context_names {_=native_shell_value_unset(shell,name)}}
        native_shell_set_variable(shell,"COMP_LINE",line,spec.command!="")
        native_shell_set_variable(shell,"COMP_POINT",fmt.tprintf("%d",utf8.rune_count_in_string(line[:callback_point])),spec.command!="")
        native_shell_set_variable(shell,"COMP_TYPE",fmt.tprintf("%d",completion_type),spec.command!="")
        native_shell_set_variable(shell,"COMP_KEY",fmt.tprintf("%d",completion_key),spec.command!="")
        command:="";for token in native_shell_completion_lex(shell,line,false) {_,_,_,assignment:=native_shell_assignment_parts(token.raw);if !assignment {command=native_shell_completion_unquote(token.raw);break}}
        if spec.function!="" {
            native_shell_set_variable(shell,"COMP_CWORD",fmt.tprintf("%d",current))
            native_shell_array_ensure(shell,"COMP_WORDS")
            for value,i in words {_=native_shell_value_set(shell,fmt.tprintf("COMP_WORDS[%d]",i),value)}
            saved:=shell.status;native_shell_completion_status=native_shell_call_function(shell,[]string{spec.function,command,word,previous});shell.status=saved
            for value in native_shell_array_values(shell,"COMPREPLY") {if !seen[value] {owned:=strings.clone(value);seen[owned]=true;append(&candidates,owned)}}
        }
        if spec.command!="" {
            source:=strings.concatenate([]string{spec.command," ",explorer_quote(command)," ",explorer_quote(word)," ",explorer_quote(previous)})
            output,error:=native_shell_capture(shell,source)
            if error=="" {
                record:=make([dynamic]u8)
                for i:=0;i<len(output);i+=1 {
                    if output[i]=='\\'&&i+1<len(output)&&output[i+1]=='\n' {append(&record,'\n');i+=1;continue}
                    if output[i]=='\n' {value:=string(record[:]);if !seen[value] {seen[value]=true;append(&candidates,strings.clone(value))};clear(&record)} else {append(&record,output[i])}
                }
                if len(record)>0 {value:=string(record[:]);if !seen[value] {seen[value]=true;append(&candidates,value)}}
            }
        }
    }
    result:=make([dynamic]string)
    for value in candidates {
        if spec.filter!="" {filter_bytes:=make([dynamic]u8);for i:=0;i<len(spec.filter);i+=1 {ch:=spec.filter[i];if ch=='\\'&&i+1<len(spec.filter)&&spec.filter[i+1]=='&' {append(&filter_bytes,'&');i+=1} else if ch=='&' {append(&filter_bytes,word)} else {append(&filter_bytes,ch)}};filter:=string(filter_bytes[:]);negate:=strings.has_prefix(filter,"!");if negate {filter=filter[1:]};matched:=native_shell_pattern_matches(shell,filter,value);if matched!=negate {continue}}
        append(&result,strings.concatenate([]string{spec.prefix,value,spec.suffix}))
    }
    if spec.plusdirs||spec.dirnames&&len(result)==0 {
        directory_spec:=Native_Shell_Completion{actions=make([dynamic]string)};append(&directory_spec.actions,"directory")
        for value in native_shell_completion_candidates(shell,directory_spec,word,line,previous,false) {if !seen[value] {seen[value]=true;append(&result,value)}}
    }
    if sort_results&&!spec.nosort&&!native_shell_active_completion.nosort {slice.sort(result[:])};return result[:]
}

native_shell_prompt_match :: proc(pattern,value:string)->bool {
    cpattern:=strings.clone_to_cstring(pattern);defer delete(cpattern)
    cvalue:=strings.clone_to_cstring(value);defer delete(cvalue)
    return posix.fnmatch(cpattern,cvalue,{})==0
}

Native_Shell_History_Record :: struct {text:string,timestamp:posix.time_t,offset:int}

native_shell_history_stamp :: proc(line:string)->(posix.time_t,bool) {
    if len(line)<2||line[0]!='#' {return 0,false}
    for ch in transmute([]u8)line[1:] {if ch<'0'||ch>'9' {return 0,false}}
    timestamp,valid:=strconv.parse_i64(line[1:]);return posix.time_t(timestamp),valid
}

native_shell_history_records :: proc(source:string,allow_multiline:bool=false)->[]Native_Shell_History_Record {
    text:=source
    input_length:=len(source)
    records:=make([dynamic]Native_Shell_History_Record)
    // Bash enables multiline history decoding when the first nonempty line
    // is a timestamp. Plain files retain one entry per nonempty physical line,
    // even when a later line happens to contain a timestamp marker.
    multiline,determined:=false,false
    timestamp:=posix.time(nil);offset:=0;pending:=false
    lines:=make([dynamic]string);record_offset:=0
    for line in strings.split_iterator(&text,"\n") {
        line_offset:=offset;offset+=len(line)+1
        stamp,is_stamp:=native_shell_history_stamp(line)
        if !determined&&line!="" {determined=true;multiline=is_stamp&&allow_multiline}
        if is_stamp {
            if multiline&&len(lines)>0 {append(&records,Native_Shell_History_Record{strings.join(lines[:],"\n"),timestamp,record_offset});clear(&lines)}
            timestamp=stamp;record_offset=line_offset;pending=true;continue
        }
        if multiline {
            // Empty lines before a command are not history entries. Empty
            // lines inside a timestamp-delimited command remain part of it.
            if len(lines)==0&&line=="" {continue}
            if line_offset>=input_length {continue}
            if len(lines)==0&&!pending {record_offset=line_offset}
            append(&lines,line);continue
        }
        if line=="" {continue}
        entry_offset:=line_offset;if pending {entry_offset=record_offset}
        append(&records,Native_Shell_History_Record{line,timestamp,entry_offset})
        timestamp=posix.time(nil);pending=false
    }
    if multiline&&len(lines)>0 {append(&records,Native_Shell_History_Record{strings.join(lines[:],"\n"),timestamp,record_offset})}
    return records[:]
}

native_shell_history_append :: proc(text:string,source_timestamp:posix.time_t= -1) {
    timestamp:=source_timestamp
    allocator:=native_shell_editor.allocator
    if native_shell_editor.history.allocator.procedure==nil {native_shell_editor.history=make([dynamic]string,0,0,allocator)}
    if native_shell_editor.history_timestamps==nil {native_shell_editor.history_timestamps=make(map[rawptr]posix.time_t,allocator)}
    if timestamp<0 {timestamp=posix.time(nil)}
    owned:=strings.clone(text,allocator);append(&native_shell_editor.history,owned)
    native_shell_editor.history_timestamps[rawptr(raw_data(owned))]=timestamp
}

native_shell_history_submission :: proc(shell:^Native_Shell,source:string)->int {
    original_allocator,original_temp:=context.allocator,context.temp_allocator
    arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
    context.allocator=mem.dynamic_arena_allocator(&arena);context.temp_allocator=context.allocator
    defer {context.allocator=original_allocator;context.temp_allocator=original_temp}
    before:=native_shell_editor.command_number
    if !shell.compat.shopts["cmdhist"] {
        text:=source;for line in strings.split_iterator(&text,"\n") {native_shell_history_add_for(shell,line)}
    } else {
        record:=source
        if !shell.compat.shopts["lithist"]&&strings.contains(source,"\n")&&!strings.contains(source,"#") {
            tokens,error:=native_shell_tokens(source)
            if error=="" {
                result:=make([dynamic]u8);offset:=0;previous:="";heredoc:=false
                for token in tokens {
                    if token.raw=="<<"||token.raw=="<<-" {heredoc=true;break}
                    if token.raw!="\n" {previous=token.raw;continue}
                    separator:="; "
                    switch previous {case "","if","then","else","elif","while","until","do","in","{","(",";",";;",";&",";;&","|","|&","&&","||","&":separator=" "}
                    append(&result,source[offset:token.start]);append(&result,separator);offset=token.end
                }
                append(&result,source[offset:]);candidate:=string(result[:])
                if !heredoc {if _,parse_error:=native_shell_parse(candidate);parse_error=="" {record=candidate}}
            }
        }
        native_shell_history_add_for(shell,record)
    }
    if native_shell_editor.command_number>before&&len(native_shell_editor.history)>0 {return len(native_shell_editor.history)-1}
    return -1
}

native_shell_history_remove :: proc(index:int,session:bool=true) {
    record:=native_shell_editor.history[index]
    delete_key(&native_shell_editor.history_timestamps,rawptr(raw_data(record)))
    delete(record,native_shell_editor.allocator);ordered_remove(&native_shell_editor.history,index)
    if index<native_shell_editor.history_saved {native_shell_editor.history_saved-=1}
    if session {native_shell_editor.history_session_entries-=1}
}

native_shell_history_display :: proc(text:string)->string {
    bytes:=make([dynamic]u8)
    for ch in text {
        if ch=='\n'||ch=='\t' {append(&bytes,u8(ch));continue}
        if ch<32||ch==127||ch>=0x80&&ch<=0x9f {append(&bytes,' ');continue}
        encoded,n:=utf8.encode_rune(ch);append(&bytes,..encoded[:n])
    }
    return string(bytes[:])
}

native_shell_history_time :: proc(record:string)->string {
    shell:=native_shell_editor.shell;if shell==nil {return ""}
    format:=shell.variables["HISTTIMEFORMAT"];if format=="" {return ""}
    timestamp,present:=native_shell_editor.history_timestamps[rawptr(raw_data(record))]
    if !present {timestamp=shell.compat.started_wall}
    if timestamp<=0 {return fmt.tprintf("%d: invalid timestamp",timestamp)}
    previous_locale:=native_shell_printf_locale(shell)
    defer {_=libc.setlocale(.ALL,strings.clone_to_cstring(previous_locale));delete(previous_locale)}
    return native_shell_printf_time(shell,format,i64(timestamp))
}

native_shell_history_limit :: proc() {
    limit:=NATIVE_SHELL_HISTORY_LIMIT
    if shell:=native_shell_editor.shell;shell!=nil {if text,exists:=shell.variables["HISTSIZE"];exists {if number,ok:=strconv.parse_int(text);ok {if number<0 {return};limit=number}}}
    for len(native_shell_editor.history)>limit {native_shell_history_remove(0,false);native_shell_editor.history_base+=1}
    // fc can replace entries through the shared string array. Retire metadata
    // for any such deleted strings without changing the fc API.
    live:=make(map[rawptr]bool)
    defer delete(live)
    for record in native_shell_editor.history {live[rawptr(raw_data(record))]=true}
    for key,_ in native_shell_editor.history_timestamps {if !live[key] {delete_key(&native_shell_editor.history_timestamps,key)}}
}

native_shell_history_write_bytes :: proc(fd:posix.FD,source:[]u8)->bool {
    bytes:=source
    for len(bytes)>0 {amount:=posix.write(fd,raw_data(bytes),c.size_t(len(bytes)));if amount<0&&posix.errno()==.EINTR {continue};if amount<=0 {return false};bytes=bytes[int(amount):]}
    return true
}

native_shell_history_write :: proc(path:string,truncate:bool)->int {
    if path=="" {return 0}
    if !truncate&&native_shell_editor.history_session_entries<=0 {return 0}
    fd:=native_shell_editor_history_open(path,true);if fd<0 {return 1};defer posix.close(fd)
    start:=max(0,len(native_shell_editor.history)-native_shell_editor.history_session_entries)
    if truncate {if posix.ftruncate(fd,0)!=.OK {return 1};start=0}
    timestamped:=false
    if shell:=native_shell_editor.shell;shell!=nil {_,timestamped=shell.variables["HISTTIMEFORMAT"]}
    for record in native_shell_editor.history[start:] {
        if timestamped {
            stamp,present:=native_shell_editor.history_timestamps[rawptr(raw_data(record))];if !present {stamp=posix.time(nil)}
            header:=fmt.tprintf("#%d\n",stamp)
            if !native_shell_history_write_bytes(fd,transmute([]u8)header) {return 1}
        }
        bytes:=transmute([]u8)strings.concatenate([]string{record,"\n"},context.temp_allocator)
        if !native_shell_history_write_bytes(fd,bytes) {return 1}
    }
    native_shell_editor.history_saved=len(native_shell_editor.history)
    if !truncate {native_shell_editor.history_session_entries=0}
    if truncate {native_shell_editor.history_file_read=len(native_shell_editor.history)} else {native_shell_editor.history_file_read+=len(native_shell_editor.history)-start}
    return 0
}

native_shell_history_file_limit :: proc(shell:^Native_Shell,source_path:string="")->int {
    value,present:=shell.variables["HISTFILESIZE"];if !present {return 0}
    limit,valid:=strconv.parse_int(value);if !valid||limit<0 {return 0}
    path:=source_path
    if path=="" {
        configured,has_file:=shell.variables["HISTFILE"]
        if has_file {path=configured;if path=="" {return 0}} else if shell.interactive {suffix:="/.bash_history";if shell.compat.options["posix"] {suffix="/.sh_history"};if home:=shell.variables["HOME"];home!="" {path=strings.concatenate([]string{home,suffix},context.temp_allocator)}}
    }
    if path=="" {return 0}
    fd:=native_shell_editor_history_open(path,false);if fd<0 {return 0}
    data:=make([dynamic]u8);buffer:[16384]u8
    for {count:=posix.read(fd,raw_data(buffer[:]),len(buffer));if count<0&&posix.errno()==.EINTR {continue};if count<=0 {break};append(&data,..buffer[:int(count)])};posix.close(fd)
    first:=0
    if shell.variables["HISTTIMEFORMAT"]!="" {
        records:=native_shell_history_records(string(data[:]),true)
        if len(records)<=limit {return 0}
        first=len(data);if limit>0 {first=records[len(records)-limit].offset}
    } else {
        lines:=0;first=len(data)
        for first>0 {first-=1;if data[first]=='\n' {if first==len(data)-1 {continue};lines+=1;if lines>=limit {first+=1;break}}}
        if limit==0 {first=len(data)}
    }
    if first<=0 {return 0}
    output:=native_shell_editor_history_open(path,true);if output<0 {return 1};defer posix.close(output)
    if posix.ftruncate(output,0)!=.OK {return 1}
    if !native_shell_history_write_bytes(output,data[first:]) {return 1}
    return 0
}

native_shell_history_read :: proc(shell:^Native_Shell,path:string,only_new:bool)->int {
    if path=="" {return 0}
    bytes,error:=os.read_entire_file(path,context.allocator);if error!=nil {return 1}
    _,multiline:=shell.variables["HISTTIMEFORMAT"]
    records:=native_shell_history_records(string(bytes),multiline)
    skip:=0;if only_new {skip=native_shell_editor.history_file_read}
    for record,index in records {if index<skip {continue};native_shell_history_append(record.text,record.timestamp)}
    native_shell_editor.history_file_read=len(records);native_shell_history_limit();return 0
}

native_shell_history_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    native_shell_editor.shell=shell;native_shell_editor_load_history()
    native_shell_history_limit()
    if len(args)==1 {native_shell_history_print();return 0}
    index:=1
    for index<len(args) {
        argument:=args[index]
        switch argument {
        case "-c":for record in native_shell_editor.history {delete(record,native_shell_editor.allocator)};clear(&native_shell_editor.history);clear(&native_shell_editor.history_timestamps);native_shell_editor.history_saved=0;native_shell_editor.history_base=1;native_shell_editor.history_session_entries=0;index+=1
        case "-d":
            if index+1==len(args) {fmt.eprintln("history: -d requires an offset");return 2};index+=1
            range_text:=args[index];separator:=-1;for at:=1;at<len(range_text);at+=1 {if range_text[at]=='-' {separator=at;break}}
            first_text,last_text:=range_text,range_text;if separator>=0 {first_text=range_text[:separator];last_text=range_text[separator+1:]}
            first,valid_first:=strconv.parse_int(first_text);last,valid_last:=strconv.parse_int(last_text)
            if !valid_first||!valid_last {fmt.eprintln("history: invalid offset");return 1}
            if first<0 {first=len(native_shell_editor.history)+first} else {first-=native_shell_editor.history_base};if last<0 {last=len(native_shell_editor.history)+last} else {last-=native_shell_editor.history_base}
            if first<0||last<first||last>=len(native_shell_editor.history) {fmt.eprintln("history: offset out of range");return 1}
            for at:=last;at>=first;at-=1 {native_shell_history_remove(at)}
            index+=1
        case "-s":native_shell_history_add_for(shell,strings.join(args[index+1:]," "));return 0
        case "-p":
            old_histexpand:=shell.compat.options["histexpand"];shell.compat.options["histexpand"]=true;defer {shell.compat.options["histexpand"]=old_histexpand}
            for value in args[index+1:] {expanded,error:=native_shell_history_expand(shell,value);if error!="" {fmt.eprintln("history:",error);return 1};fmt.println(expanded)};return 0
        case "-a","-w","-r","-n":
            default_path:="";if _,present:=shell.variables["HISTFILE"];present||shell.interactive {default_path=native_shell_editor_history_path()};defer delete(default_path);path:=default_path
            if index+1<len(args) {index+=1;path=args[index]}
            if path=="" {fmt.eprintln("history: HISTFILE: parameter null or not set");return 1}
            if argument=="-a"||argument=="-w" {return native_shell_history_write(path,argument=="-w")}
            return native_shell_history_read(shell,path,argument=="-n")
        case:
            number,ok:=strconv.parse_int(argument);if !ok||number<0||index+1<len(args) {fmt.eprintln("history: invalid argument");return 2}
            first:=max(0,len(native_shell_editor.history)-number)
            for record,at in native_shell_editor.history[first:] {safe:=native_shell_history_display(record);number:=fmt.tprintf("%d",native_shell_editor.history_base+first+at);fmt.printf("%s%s  %s%s\n",strings.repeat(" ",max(0,5-len(number))),number,native_shell_history_time(record),safe);delete(safe)};return 0
        }
    }
    return 0
}

native_shell_history_words :: proc(event:string)->[]string {
    tokens,error:=native_shell_tokens(event)
    if error!="" {return strings.fields(event)}
    words:=make([dynamic]string);for token in tokens {if !token.operator {append(&words,token.raw)}};return words[:]
}
native_shell_history_remember :: proc(target:^string,value:string) {owned:=strings.clone(value,native_shell_editor.allocator);delete(target^,native_shell_editor.allocator);target^=owned}
native_shell_history_substitution_part :: proc(line:string,start:int,delimiter:u8,replacement:bool=false)->(string,int,bool) {
    bytes:=make([dynamic]u8);i:=start
    for i<len(line) {
        ch:=line[i];i+=1
        if ch==delimiter {return string(bytes[:]),i,true}
        if ch=='\\'&&i<len(line) {if replacement&&line[i]=='&' {append(&bytes,'\\')};ch=line[i];i+=1}
        append(&bytes,ch)
    }
    return string(bytes[:]),i,false
}
native_shell_history_substitute :: proc(event,old,raw_replacement:string,global:bool,per_word:bool=false)->(string,string) {
    if old=="" {return "","no previous substitution"}
    if per_word {
        tokens,error:=native_shell_tokens(event)
        if error!="" {return "",error}
        result:=make([dynamic]u8);offset:=0;matched:=false
        for token in tokens {
            if token.operator||!strings.contains(token.raw,old) {continue}
            replaced,replacement_error:=native_shell_history_substitute(token.raw,old,raw_replacement,false)
            if replacement_error!="" {continue}
            append(&result,event[offset:token.start]);append(&result,replaced);offset=token.end;matched=true
        }
        if !matched {return "","substitution failed"}
        append(&result,event[offset:]);return string(result[:]),""
    }
    replacement:=make([dynamic]u8)
    for i:=0;i<len(raw_replacement);i+=1 {ch:=raw_replacement[i];if ch=='\\'&&i+1<len(raw_replacement) {i+=1;append(&replacement,raw_replacement[i])} else if ch=='&' {append(&replacement,old)} else {append(&replacement,ch)}}
    position:=strings.index(event,old);if position<0 {return "","substitution failed"}
    if global {result,_:=strings.replace_all(event,old,string(replacement[:]));return result,""}
    return strings.concatenate([]string{event[:position],string(replacement[:]),event[position+len(old):]}),""
}

native_shell_history_expand :: proc(shell:^Native_Shell,line:string)->(string,string) {
    result_allocator:=context.allocator
    arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
    context.allocator=mem.dynamic_arena_allocator(&arena);context.temp_allocator=context.allocator
    native_shell_editor.shell=shell;native_shell_editor_load_history()
    native_shell_editor.history_print_only=false
    if shell.compat!=nil&&!shell.compat.options["histexpand"] {return strings.clone(line,result_allocator),""}
    event_character,quick_character:u8='!','^';comment_character:u8
    if configured,present:=shell.variables["histchars"];present {event_character=0;quick_character=0;if len(configured)>0 {event_character=configured[0]};if len(configured)>1 {quick_character=configured[1]};if len(configured)>2 {comment_character=configured[2]}}
    if event_character==0 {return strings.clone(line,result_allocator),""}
    history:=native_shell_editor.history
    if len(line)>0&&line[0]==quick_character&&quick_character!=0&&len(history)>0 {
        old,next,closed:=native_shell_history_substitution_part(line,1,quick_character)
        if closed {
            replacement,end,_:=native_shell_history_substitution_part(line,next,quick_character,true)
            if old=="" {old=native_shell_editor.history_substitution}
            native_shell_history_remember(&native_shell_editor.history_substitution,old);native_shell_history_remember(&native_shell_editor.history_replacement,replacement)
            substituted,substitution_error:=native_shell_history_substitute(history[len(history)-1],old,replacement,false)
            if substitution_error!="" {return "",substitution_error}
            return strings.concatenate([]string{substituted,line[end:]},result_allocator),""
        }
    }
    result:=make([dynamic]u8);single,double:=false,false
    for i:=0;i<len(line); {
        if !single&&!double&&comment_character!=0&&line[i]==comment_character&&(i==0||native_shell_space(line[i-1])) {append(&result,line[i:]);break}
        if line[i]=='\\'&&i+1<len(line) {append(&result,line[i],line[i+1]);i+=2;continue}
        if line[i]=='\''&&!double {single=!single;append(&result,line[i]);i+=1;continue}
        if line[i]=='"'&&!single {double=!double;append(&result,line[i]);i+=1;continue}
        if line[i]!=event_character||single||double&&shell.compat.options["posix"]||i+1==len(line)||strings.contains_any(line[i+1:i+2]," \t\n=\"") {append(&result,line[i]);i+=1;continue}
        i+=1;event:="";event_index:=-1;shorthand:u8;event_present:=false
        switch line[i] {
        case '#':event=string(result[:]);event_present=true;i+=1
        case '$','^','*','%':event_index=len(history)-1;shorthand=line[i];i+=1
        case '?':
            i+=1;start:=i;for i<len(line)&&line[i]!='?' {i+=1};needle:=line[start:i];if i<len(line) {i+=1}
            if needle=="" {needle=native_shell_editor.history_search} else {native_shell_history_remember(&native_shell_editor.history_search,needle)}
            for at:=len(history)-1;at>=0;at-=1 {if strings.contains(history[at],needle) {event_index=at;break}}
        case:
            if line[i]==event_character {event_index=len(history)-1;i+=1;break}
            start:=i
            if line[i]=='-' {i+=1}
            digits:=i;for i<len(line)&&line[i]>='0'&&line[i]<='9' {i+=1}
            if i>digits {
                number,valid:=strconv.parse_int(line[start:i]);if valid {if number<0 {event_index=len(history)+number} else {event_index=number-native_shell_editor.history_base}}
            } else {
                i=start;for i<len(line)&&!strings.contains_any(line[i:i+1]," \t\n:;|&()<>\"'") {i+=1}
                needle:=line[start:i];if needle=="" {append(&result,event_character);continue}
                for at:=len(history)-1;at>=0;at-=1 {if strings.has_prefix(history[at],needle) {event_index=at;break}}
            }
        }
        if !event_present {if event_index<0||event_index>=len(history) {return "","event not found"};event=history[event_index]}
        if shorthand!=0||i+1<len(line)&&line[i]==':'&&strings.contains_any(line[i+1:i+2],"0123456789^$*-%") {
            if shorthand==0 {i+=1;shorthand=line[i];i+=1}
            words:=native_shell_history_words(event);first,last:=0,len(words)-1
            switch shorthand {case '$':first=last;case '^':first=1;last=1;case '*':first=1;case '-':first=0;last=max(0,last-1);case '%':first=-1;for word,at in words {if strings.contains(word,native_shell_editor.history_search) {first=at;last=at;break}};case:
                start:=i-1;for i<len(line)&&line[i]>='0'&&line[i]<='9' {i+=1};first,_=strconv.parse_int(line[start:i]);last=first
            }
            if i<len(line)&&line[i]=='-' {i+=1;if i<len(line)&&line[i]=='$' {last=len(words)-1;i+=1} else {start:=i;for i<len(line)&&line[i]>='0'&&line[i]<='9' {i+=1};if i>start {last,_=strconv.parse_int(line[start:i])} else {last=len(words)-2}}} else if i<len(line)&&line[i]=='*' {last=len(words)-1;i+=1}
            if first<0||first>=len(words)||last<first||last>=len(words) {if shorthand=='*'&&len(words)<=1||shorthand=='%'&&native_shell_editor.history_search=="" {event=""} else {return "","bad word specifier"}} else if shorthand=='%'&&native_shell_editor.history_search=="" {event=""} else {event=strings.join(words[first:last+1]," ")}
        }
        for i+1<len(line)&&line[i]==':' {
            i+=1;modifier:=line[i];i+=1
            switch modifier {
            case 'p':native_shell_editor.history_print_only=true
            case 'q':event=explorer_quote(event)
            case 'x':words:=strings.fields(event);for &word in words {word=explorer_quote(word)};event=strings.join(words," ")
            case 'h':if slash:=strings.last_index_byte(event,'/');slash>=0 {event=event[:max(1,slash)]}
            case 't':if slash:=strings.last_index_byte(event,'/');slash>=0 {event=event[slash+1:]}
            case 'r':if dot:=strings.last_index_byte(event,'.');dot>=0 {event=event[:dot]}
            case 'e':if dot:=strings.last_index_byte(event,'.');dot>=0 {event=event[dot+1:]} else {event=""}
            case 's','g','a','G','&':
                global:=modifier=='g'||modifier=='a';per_word:=modifier=='G';repeat:=modifier=='&'
                if global||per_word {if i>=len(line)||(line[i]!='s'&&line[i]!='&') {return "","unsupported history modifier"};repeat=line[i]=='&';i+=1}
                old,replacement:=native_shell_editor.history_substitution,native_shell_editor.history_replacement
                if !repeat {
                    if i>=len(line) {return "","bad history substitution"};delimiter:=line[i];i+=1
                    parsed,next,closed:=native_shell_history_substitution_part(line,i,delimiter);if !closed {return "","bad history substitution"};old=parsed;i=next
                    parsed,next,_=native_shell_history_substitution_part(line,i,delimiter,true);replacement=parsed;i=next
                    if old=="" {old=native_shell_editor.history_substitution;if old=="" {old=native_shell_editor.history_search}}
                    native_shell_history_remember(&native_shell_editor.history_substitution,old);native_shell_history_remember(&native_shell_editor.history_replacement,replacement)
                }
                substituted,substitution_error:=native_shell_history_substitute(event,old,replacement,global,per_word);if substitution_error!="" {return "",substitution_error};event=substituted
            case:return "","unsupported history modifier"
            }
        }
        append(&result,event)
    }
    return strings.clone(string(result[:]),result_allocator),""
}

native_shell_programmable_complete :: proc(shell:^Native_Shell,bytes:^[dynamic]u8,cursor:^int,repeated:bool=false,completion_type:int=9,completion_key:int=9)->(bool,bool) {
    if !shell.compat.shopts["progcomp"]||len(native_shell_completions)==0 {return false,false}
    line,point,offset:=native_shell_completion_segment(string(bytes^[:]),cursor^)
    logical,current,start,word,previous:=native_shell_completion_context(shell,line,point)
    command_index:=0;command:="";command_raw_index:=0
    command_tokens:=native_shell_completion_lex(shell,line,false)
    for token,index in command_tokens {
        _,_,_,assignment:=native_shell_assignment_parts(token.raw);if assignment {continue}
        command=native_shell_completion_unquote(token.raw);command_raw_index=index
        split_tokens:=native_shell_completion_lex(shell,line)
        for item,at in split_tokens {if item.first==token.first {command_index=at;break}}
        break
    }
    spec:Native_Shell_Completion;found:bool;spec_name:=command
    if strings.trim_space(line)=="" {spec,found=native_shell_completions["-E"];spec_name="-E"} else if current==command_index {spec,found=native_shell_completions["-I"];spec_name="-I"} else {
        spec,found=native_shell_completions[command]
        if !found {if slash:=strings.last_index_byte(command,'/');slash>=0 {spec_name=command[slash+1:];spec,found=native_shell_completions[spec_name]}}
    }
    if !found {spec,found=native_shell_completions["-D"];spec_name="-D"}
    callback_line,callback_point:=line,point
    if !found&&shell.compat.shopts["progcomp_alias"]&&command_index<len(logical)&&current>command_index {
        aliases:=make(map[string]bool);alias_command:=command
        for depth:=0;depth<32;depth+=1 {
            alias,present:=shell.compat.aliases[alias_command];if !present||aliases[alias_command] {break};aliases[alias_command]=true
            tokens:=native_shell_completion_lex(shell,callback_line,false);if command_raw_index>=len(tokens) {break}
            token:=tokens[command_raw_index]
            callback_line=strings.concatenate([]string{callback_line[:token.first],alias,callback_line[token.last:]})
            callback_point+=len(alias)-(token.last-token.first)
            alias_tokens:=native_shell_completion_lex(shell,alias,false);if len(alias_tokens)==0 {break};alias_command=native_shell_completion_unquote(alias_tokens[0].raw)
            spec_name=alias_command;spec,found=native_shell_completions[alias_command]
            if !found {if slash:=strings.last_index_byte(alias_command,'/');slash>=0 {spec_name=alias_command[slash+1:];spec,found=native_shell_completions[spec_name]}}
            if found {_,_,_,word,previous=native_shell_completion_context(shell,callback_line,callback_point);break}
        }
    }
    if !found {return false,false}
    native_shell_active_completion=spec
    previous_completing:=native_shell_completing;native_shell_completing=true;defer {native_shell_completing=previous_completing}
    candidates:[]string
    invocation_type:=completion_type
    invocation_key:=completion_key;if completion_type==37 {invocation_key=0}
    if completion_type==9 {if repeated {invocation_type=63} else if native_shell_editor_setting_on("show-all-if-ambiguous") {invocation_type=33} else if native_shell_editor_setting_on("show-all-if-unmodified") {invocation_type=64}}
    for attempt:=0;attempt<32;attempt+=1 {
        native_shell_completion_status=0
        candidates=native_shell_completion_candidates(shell,spec,word,callback_line,previous,true,callback_point,invocation_type,invocation_key)
        if native_shell_completion_status!=124 {break}
        updated,present:=native_shell_completions[spec_name]
        if !present {updated,present=native_shell_completions[command]}
        if !present {return false,false}
        spec=updated;native_shell_active_completion=updated
    }
    spec=native_shell_active_completion
    for action in spec.actions {if action=="file"||action=="directory" {spec.filenames=true}}
    if spec.glob!=""||spec.dirnames||spec.plusdirs {spec.filenames=true}
    if spec.filenames {for &candidate in candidates {if !strings.has_suffix(candidate,"/") {if info,stat_error:=os.stat(candidate,context.temp_allocator);stat_error==nil&&info.type==.Directory {candidate=strings.concatenate([]string{candidate,"/"})}}}}
    if len(candidates)==0 {return !spec.default_files&&!spec.bashdefault,!spec.bashdefault}
    native_shell_completion_apply(bytes,offset+start,cursor,word,candidates,spec,completion_type,repeated)
    return true,false
}

native_shell_completion_apply :: proc(bytes:^[dynamic]u8,start:int,cursor:^int,word:string,candidates:[]string,spec:Native_Shell_Completion,completion_type:int,repeated:bool) {
    if completion_type==63||completion_type==33 {native_shell_completion_display(candidates);return}
    if completion_type==37 {
        native_shell_editor_menu_clear()
        for candidate in candidates {append(&native_shell_editor.menu_candidates,strings.clone(candidate,native_shell_editor.allocator))}
        native_shell_editor.menu_index=0;if native_shell_editor.menu_backwards {native_shell_editor.menu_index=len(candidates)-1};native_shell_editor.menu_start=start
        selected:=candidates[native_shell_editor.menu_index]
        replacement:=selected;if !spec.noquote {replacement=native_shell_editor_quote(replacement)}
        if !spec.nospace&&!strings.has_suffix(selected,"/") {replacement=strings.concatenate([]string{replacement," "})}
        native_shell_completion_replace(bytes,start,cursor,replacement);native_shell_editor.menu_end=cursor^;native_shell_editor.menu_noquote=spec.noquote;native_shell_editor.menu_nospace=spec.nospace
        return
    }
    common:=native_shell_completion_common(candidates)
    if len(common)>len(word)||len(candidates)==1 {replacement:=common;if !spec.noquote {replacement=native_shell_editor_quote(common)};if len(candidates)==1&&!spec.nospace&&!strings.has_suffix(common,"/") {replacement=strings.concatenate([]string{replacement," "})};native_shell_completion_replace(bytes,start,cursor,replacement);if len(candidates)>1&&native_shell_editor_setting_on("show-all-if-ambiguous") {native_shell_completion_display(candidates)}} else if repeated||native_shell_editor_setting_on("show-all-if-ambiguous")||native_shell_editor_setting_on("show-all-if-unmodified") {native_shell_completion_display(candidates)} else {native_shell_editor_write("\a")}
}

native_shell_editor_configuration_destroy :: proc() {
    allocator:=native_shell_editor.allocator
    for name,spec in native_shell_completions {native_shell_completion_free(spec,allocator);delete(name,allocator)};delete(native_shell_completions);native_shell_completions=nil
    for key,binding in native_shell_keybindings {delete(key,allocator);delete(binding.action,allocator)};delete(native_shell_keybindings);native_shell_keybindings=nil
    for key,value in native_shell_readline_variables {delete(key,allocator);delete(value,allocator)};delete(native_shell_readline_variables);native_shell_readline_variables=nil
    native_shell_readline_configured=false
}

native_shell_editor_queue :: proc(bytes:[]u8) {
    if len(bytes)==0 {return}
    if native_shell_editor.pending.allocator.procedure==nil {native_shell_editor.pending=make([dynamic]u8,0,0,native_shell_editor.allocator)}
    old:=len(native_shell_editor.pending);resize(&native_shell_editor.pending,old+len(bytes));copy(native_shell_editor.pending[len(bytes):],native_shell_editor.pending[:old]);copy(native_shell_editor.pending[:len(bytes)],bytes)
}

native_shell_editor_binding :: proc(first:u8,vi_command:bool=false)->(Native_Shell_Keybinding,bool) {
    sequence:=make([dynamic]u8);defer delete(sequence);append(&sequence,first)
    keymap:=native_shell_readline_keymap
    if native_shell_editing_mode=="vi" {keymap="vi-command" if vi_command else "vi-insertion"}
    timeout,_:=strconv.parse_int(native_shell_editor_setting("keyseq-timeout"));if timeout<0 {timeout=0}
    for len(sequence)<64 {
        current:=string(sequence[:]);prefix:=false
        mapped:=native_shell_bind_key(keymap,current)
        if binding,found:=native_shell_keybindings[mapped];found {binding.key=sequence[len(sequence)-1];return binding,true}
        for key,_ in native_shell_keybindings {if strings.has_prefix(key,mapped) {prefix=true;break}}
        if keymap=="emacs-standard"&&len(current)>1&&(current[0]==27||current[0]==24) {
            submap:="emacs-meta" if current[0]==27 else "emacs-ctlx";nested:=native_shell_bind_key(submap,current[1:])
            if binding,found:=native_shell_keybindings[nested];found {binding.key=sequence[len(sequence)-1];return binding,true}
            for key,_ in native_shell_keybindings {if strings.has_prefix(key,nested) {prefix=true;break}}
        }
        if keymap=="emacs-standard"&&len(current)==1&&(current[0]==27||current[0]==24) {submap:="emacs-meta" if current[0]==27 else "emacs-ctlx";nested:=native_shell_bind_key(submap,"");for key,_ in native_shell_keybindings {if strings.has_prefix(key,nested) {prefix=true;break}}}
        if !prefix {break}
        byte,state:=native_shell_editor_read_byte(timeout);if state!=1 {break};append(&sequence,byte)
    }
    if len(sequence)>1 {native_shell_editor_queue(sequence[1:])}
    return {},false
}

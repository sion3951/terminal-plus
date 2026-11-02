#+build linux
package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"
import posix "core:sys/posix"

// Editing belongs to the shell process. Raw mode is scoped to readline so
// foreground programs retain the PTY's normal canonical input and signals.
Native_Shell_Editor :: struct {
    allocator:mem.Allocator,
    history:[dynamic]string,
    path:string,
    loaded:bool,
    shell:^Native_Shell,
    prompt:string,
    command_number,history_saved,history_file_read:int,
    history_base:int,
    history_session_entries:int,
    history_timestamps:map[rawptr]posix.time_t,
    current_submission:int,
    history_print_only:bool,
    pending:[dynamic]u8,
    output_fd:posix.FD,
    timed_out:bool,
    interrupted_signal:int,
    kill_ring:[dynamic]string,
    last_completion:string,
    menu_candidates:[dynamic]string,
    menu_index,menu_start,menu_end:int,
    menu_noquote,menu_backwards,menu_nospace,completion_literal:bool,
    completed:bool,
    history_search,history_substitution,history_replacement:string,
}
native_shell_editor:Native_Shell_Editor
NATIVE_SHELL_HISTORY_LIMIT :: 2000

native_shell_editor_write :: proc(source:string) {
    text:=source
    if text=="\a" {
        switch native_shell_editor_setting("bell-style") {case "none":return;case "visible":text="\x1b[?5h\x1b[?5l"}
    }
    bytes:=transmute([]u8)text
    output:=native_shell_editor.output_fd;if output<=0 {output=1}
    for len(bytes)>0 {
        amount:=posix.write(output,raw_data(bytes),c.size_t(len(bytes)))
        if amount>0 {bytes=bytes[int(amount):]}
        else if amount<0&&posix.errno()==.EINTR {continue}
        else {break}
    }
}

// Never reproduce control characters from a path or completion as terminal
// commands. The editor also displays pasted newlines as spaces until Enter.
native_shell_editor_safe :: proc(text:string)->string {
    result:=make([dynamic]u8)
    for ch in text {
        if ch<32||ch==127||(ch>=0x80&&ch<=0x9f) {append(&result,u8(' '));continue}
        bytes,n:=utf8.encode_rune(ch);append(&result,..bytes[:n])
    }
    return string(result[:])
}

native_shell_editor_width :: proc()->int {
    size:PTY_Winsize
    if pty_ioctl(0,0x5413,&size)==0&&size.cols>0 {return max(8,int(size.cols))}
    return 80
}

native_shell_editor_rune_width :: proc(ch:rune)->int {
    // Share the terminal's cell-width rules so redraw and cursor agree.
    if terminal_combining(ch) {return 0}
    if terminal_wide(ch) {return 2}
    return 1
}

native_shell_editor_cells :: proc(text:string)->int {
    if !native_shell_editor_setting_on("output-meta") {count:=0;for ch in transmute([]u8)text {count+=4 if ch>=128 else 1};return count}
    count:=0;for ch in text {count+=native_shell_editor_rune_width(ch)};return count
}

native_shell_editor_previous :: proc(bytes:[]u8,cursor:int)->int {
    if cursor<=0 {return 0}
    _,n:=utf8.decode_last_rune(bytes[:cursor]);return max(0,cursor-max(1,n))
}
native_shell_editor_next :: proc(bytes:[]u8,cursor:int)->int {
    if cursor>=len(bytes) {return len(bytes)}
    _,n:=utf8.decode_rune(bytes[cursor:]);return min(len(bytes),cursor+max(1,n))
}
native_shell_editor_word_left :: proc(bytes:[]u8,cursor:int)->int {
    at:=cursor
    for at>0 {previous:=native_shell_editor_previous(bytes,at);ch,_:=utf8.decode_rune(bytes[previous:at]);if !unicode.is_space(ch) {break};at=previous}
    for at>0 {previous:=native_shell_editor_previous(bytes,at);ch,_:=utf8.decode_rune(bytes[previous:at]);if unicode.is_space(ch) {break};at=previous}
    return at
}
native_shell_editor_word_right :: proc(bytes:[]u8,cursor:int)->int {
    at:=cursor
    for at<len(bytes) {ch,_:=utf8.decode_rune(bytes[at:]);if !unicode.is_space(ch) {break};at=native_shell_editor_next(bytes,at)}
    for at<len(bytes) {ch,_:=utf8.decode_rune(bytes[at:]);if unicode.is_space(ch) {break};at=native_shell_editor_next(bytes,at)}
    return at
}

native_shell_editor_replace :: proc(bytes:^[dynamic]u8,first,last:int,text:string) {
    old_length:=len(bytes^);retained:=old_length-(last-first)
    if len(text)>max(int)-retained {native_shell_editor_write("\a");return}
    difference:=len(text)-(last-first)
    if difference>0 {resize(bytes,old_length+difference)}
    copy(bytes^[first+len(text):old_length+difference],bytes^[last:old_length])
    copy(bytes^[first:first+len(text)],transmute([]u8)text)
    if difference<0 {resize(bytes,old_length+difference)}
}

native_shell_editor_prompt :: proc(shell:^Native_Shell,width:int)->string {
    return strings.clone(native_shell_editor.prompt)
}

native_shell_editor_redraw :: proc(shell:^Native_Shell,bytes:[]u8,cursor:int,viewport:^int) {
    width:=native_shell_editor_width()
    prompt:=native_shell_editor_prompt(shell,width);defer delete(prompt)
    available:=max(1,width-native_shell_prompt_cells(prompt)-2)
    start:=min(viewport^,cursor)
    for start>0&&start<len(bytes)&&(bytes[start]&0xc0)==0x80 {start-=1}
    for start<cursor&&native_shell_editor_cells(string(bytes[start:cursor]))>=available {start=native_shell_editor_next(bytes,start)}
    if cursor==0 {start=0}
    end:=start;cells:=0
    for end<len(bytes) {
        ch,n:=utf8.decode_rune(bytes[end:]);n=max(1,n);size:=native_shell_editor_rune_width(ch)
        if ch>=128&&!native_shell_editor_setting_on("output-meta") {size=n*4}
        if cells+size>available {break}
        cells+=size;end+=n
    }
    viewport^=start
    visible:=native_shell_editor_safe(string(bytes[start:end]));defer delete(visible)
    if !native_shell_editor_setting_on("output-meta") {display:=make([dynamic]u8);for ch in transmute([]u8)visible {if ch>=128 {append(&display,fmt.tprintf("\\%03o",ch))} else {append(&display,ch)}};delete(visible);visible=string(display[:])}
    native_shell_editor_write("\r\x1b[2K")
    prompt_text:=native_shell_prompt_visible(prompt);defer delete(prompt_text)
    native_shell_editor_write(prompt_text)
    native_shell_editor_write(visible)
    if end<len(bytes) {native_shell_editor_write("›")}
    column:=native_shell_prompt_cells(prompt)+native_shell_editor_cells(string(bytes[start:cursor]))+1
    native_shell_editor_write(fmt.tprintf("\r\x1b[%dC",max(0,column-1)))
}

native_shell_editor_history_path :: proc()->string {
    shell:=native_shell_editor.shell
    if shell!=nil {
        if path,exists:=shell.variables["HISTFILE"];exists {return strings.clone(path)}
        if home:=shell.variables["HOME"];home!="" {suffix:="/.bash_history";if shell.compat.options["posix"] {suffix="/.sh_history"};return strings.concatenate([]string{home,suffix})}
    }
    return ""
}

native_shell_editor_history_open :: proc(path:string,writing:bool)->posix.FD {
    if path=="" {return -1}
    flags:posix.O_Flags={.CLOEXEC,.NOFOLLOW,.NONBLOCK}
    if writing {flags={.WRONLY,.CREAT,.APPEND,.CLOEXEC,.NOFOLLOW,.NONBLOCK}}
    cpath:=strings.clone_to_cstring(path);defer delete(cpath)
    fd:=posix.open(cpath,flags,{.IRUSR,.IWUSR})
    if fd<0 {return -1}
    stat:posix.stat_t
    if posix.fstat(fd,&stat)!=nil||stat.st_uid!=posix.getuid()||!posix.S_ISREG(stat.st_mode) {posix.close(fd);return -1}
    if writing {_=posix.fchmod(fd,{.IRUSR,.IWUSR})}
    return fd
}

native_shell_editor_load_history :: proc() {
    if native_shell_editor.loaded {return}
    // `history` may first run from shellrc or a builtin under the execution
    // arena. Editor state must survive that command and use the shell's heap.
    previous_allocator:=context.allocator
    context.allocator=native_shell_editor.allocator
    defer {context.allocator=previous_allocator}
    native_shell_editor.loaded=true
    native_shell_editor.current_submission=-1
    native_shell_editor.history_base=1
    native_shell_editor.path=native_shell_editor_history_path()
    if shell:=native_shell_editor.shell;shell!=nil&&!shell.interactive {return}
    arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
    original_temp:=context.temp_allocator;defer {context.temp_allocator=original_temp}
    context.allocator=mem.dynamic_arena_allocator(&arena);context.temp_allocator=context.allocator
    fd:=native_shell_editor_history_open(native_shell_editor.path,false)
    if fd<0 {return};defer posix.close(fd)
    // Apply HISTSIZE after loading, without silently dropping large records
    // or histories whose configured size exceeds a fixed byte window.
    end:=posix.lseek(fd,0,.END)
    if end<0 {return}
    offset:=posix.off_t(0)
    _=posix.lseek(fd,offset,.SET)
    data:=make([]u8,int(end-offset));defer delete(data)
    used:=0
    for used<len(data) {count:=posix.read(fd,&data[used],c.size_t(int(len(data))-used));if count<=0 {break};used+=int(count)}
    multiline:=false;if shell:=native_shell_editor.shell;shell!=nil {_,multiline=shell.variables["HISTTIMEFORMAT"]}
    for record in native_shell_history_records(string(data[:used]),multiline) {
        native_shell_history_append(record.text,record.timestamp)
        native_shell_editor.history_file_read+=1
    }
    native_shell_history_limit()
    native_shell_editor.history_saved=len(native_shell_editor.history)
}

native_shell_history_add :: proc(line:string) {
    shell:=native_shell_editor.shell
    if shell!=nil {native_shell_history_add_for(shell,line)}
}

native_shell_history_add_for :: proc(shell:^Native_Shell,line:string) {
    if strings.trim_space(line)=="" {return}
    native_shell_editor.shell=shell
    previous_allocator:=context.allocator;context.allocator=native_shell_editor.allocator;defer {context.allocator=previous_allocator}
    native_shell_editor_load_history()
    control:=shell.variables["HISTCONTROL"]
    if strings.has_prefix(line," ")&&(strings.contains(control,"ignorespace")||strings.contains(control,"ignoreboth")) {return}
    history:=&native_shell_editor.history
    if len(history^)>0&&history^[len(history^)-1]==line&&(strings.contains(control,"ignoredups")||strings.contains(control,"ignoreboth")) {return}
    ignore:=shell.variables["HISTIGNORE"]
    for pattern in strings.split_iterator(&ignore,":") {if pattern=="&"&&len(history^)>0&&history^[len(history^)-1]==line {return};if pattern!=""&&native_shell_prompt_match(pattern,line) {return}}
    if strings.contains(control,"erasedups") {for i:=len(history^)-1;i>=0;i-=1 {if history^[i]==line {native_shell_history_remove(i)}}}
    native_shell_history_append(line);native_shell_editor.command_number+=1;native_shell_editor.history_session_entries+=1
    native_shell_history_limit()
}

native_shell_editor_destroy :: proc() {
    if native_shell_editor.loaded&&native_shell_editor.shell!=nil&&native_shell_editor.shell.interactive {path:=native_shell_editor_history_path();_=native_shell_history_write(path,!native_shell_editor.shell.compat.shopts["histappend"]);_=native_shell_history_file_limit(native_shell_editor.shell,path);delete(path)}
    native_shell_editor_configuration_destroy()
    previous_allocator:=context.allocator
    context.allocator=native_shell_editor.allocator
    defer {context.allocator=previous_allocator}
    for line in native_shell_editor.history {delete(line)}
    native_shell_editor_menu_clear()
    for text in native_shell_editor.kill_ring {delete(text)};delete(native_shell_editor.kill_ring)
    delete(native_shell_editor.history);delete(native_shell_editor.path);delete(native_shell_editor.prompt);delete(native_shell_editor.pending);delete(native_shell_editor.last_completion)
    delete(native_shell_editor.history_search);delete(native_shell_editor.history_substitution);delete(native_shell_editor.history_replacement)
    delete(native_shell_editor.history_timestamps)
    native_shell_editor={}
}

native_shell_history_print :: proc() {
    native_shell_editor_load_history()
    for line,index in native_shell_editor.history {
        safe:=native_shell_history_display(line)
        number:=fmt.tprintf("%d",native_shell_editor.history_base+index)
        fmt.printf("%s%s  %s%s\n",strings.repeat(" ",max(0,5-len(number))),number,native_shell_history_time(line),safe)
        delete(safe)
    }
}

native_shell_editor_menu_clear :: proc() {
    for candidate in native_shell_editor.menu_candidates {delete(candidate,native_shell_editor.allocator)}
    delete(native_shell_editor.menu_candidates)
    native_shell_editor.menu_candidates=make([dynamic]string,0,0,native_shell_editor.allocator)
    native_shell_editor.menu_index= -1
}

// Directory completion expands variable names without running substitutions.
// Unless direxpand is set, the editor preserves the original directory spelling.
native_shell_completion_directory :: proc(shell:^Native_Shell,source:string)->(string,bool) {
    bytes:=make([dynamic]u8);expanded:=false;i:=0
    if source=="~"||strings.has_prefix(source,"~/") {append(&bytes,shell.variables["HOME"]);i=1;expanded=true}
    for i<len(source) {
        if source[i]=='$' {
            first:=i+1;last:=first;braced:=first<len(source)&&source[first]=='{'
            if braced {first+=1;last=first;for last<len(source)&&source[last]!='}' {last+=1};if last==len(source) {return source,false}} else {for last<len(source)&&(source[last]>='a'&&source[last]<='z'||source[last]>='A'&&source[last]<='Z'||source[last]=='_'||last>first&&source[last]>='0'&&source[last]<='9') {last+=1}}
            if last>first&&native_shell_name(source[first:last]) {value,_:=native_shell_value_get(shell,source[first:last]);append(&bytes,value);i=last;if braced {i+=1};expanded=true;continue}
        }
        append(&bytes,source[i]);i+=1
    }
    return string(bytes[:]),expanded
}

native_shell_editor_complete :: proc(shell:^Native_Shell,bytes:^[dynamic]u8,cursor:^int,filename_only:bool=false,completion_type:int=9,completion_key:int=9,backwards:bool=false) {
    native_shell_editor.menu_backwards=backwards
    files_only_mode:=filename_only
    arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
    original_allocator:=context.allocator;context.allocator=mem.dynamic_arena_allocator(&arena);defer {context.allocator=original_allocator}
    repeated:=native_shell_editor.completed&&native_shell_editor.last_completion==string(bytes^[:cursor^])
    defer {delete(native_shell_editor.last_completion,native_shell_editor.allocator);native_shell_editor.last_completion=strings.clone(string(bytes^[:cursor^]),native_shell_editor.allocator);native_shell_editor.completed=true}
    if native_shell_editor_setting_on("disable-completion") {native_shell_editor_write("\a");return}
    if completion_type==37&&repeated&&len(native_shell_editor.menu_candidates)>0&&native_shell_editor.menu_end==cursor^ {
        direction:=1;if backwards {direction= -1}
        native_shell_editor.menu_index=(native_shell_editor.menu_index+len(native_shell_editor.menu_candidates)+direction)%len(native_shell_editor.menu_candidates)
        replacement:=native_shell_editor.menu_candidates[native_shell_editor.menu_index]
        if !native_shell_editor.menu_noquote {replacement=native_shell_editor_quote(replacement)}
        if !native_shell_editor.menu_nospace&&!strings.has_suffix(native_shell_editor.menu_candidates[native_shell_editor.menu_index],"/") {replacement=strings.concatenate([]string{replacement," "})}
        native_shell_editor_replace(bytes,native_shell_editor.menu_start,native_shell_editor.menu_end,replacement)
        cursor^=native_shell_editor.menu_start+len(replacement);native_shell_editor.menu_end=cursor^;return
    }
    if completion_type!=37 {native_shell_editor_menu_clear()}
    if !files_only_mode {
        handled,files_only:=native_shell_programmable_complete(shell,bytes,cursor,repeated,completion_type,completion_key)
        if handled {return};if files_only {files_only_mode=true}
    }
    if strings.trim_space(string(bytes^[:]))==""&&shell.compat.shopts["no_empty_cmd_completion"] {return}
    line:=string(bytes^[:cursor^]);start:=0;quote:u8;escaped:=false;initial:=true
    for ch,i in transmute([]u8)line {
        if escaped {escaped=false;continue}
        if ch=='\\'&&quote!='\'' {escaped=true;continue}
        if quote!=0 {if ch==quote {quote=0};continue}
        if ch=='\''||ch=='"' {quote=ch;continue}
        if ch==' '||ch=='\t'||ch=='\n'||ch=='|'||ch=='&'||ch==';'||ch=='<'||ch=='>' {
            if ch=='|'||ch=='&'||ch==';'||ch=='\n' {initial=true} else if i>start {initial=false}
            start=i+1
        }
    }
    raw:=line[start:];prefix:=native_shell_completion_unquote(raw)
    candidates:=make([dynamic]string);seen:=make(map[string]bool)
    if !files_only_mode&&strings.has_prefix(prefix,"$")&&!strings.contains(prefix,"/")&&!strings.contains(prefix,"(") {
        braced:=strings.has_prefix(prefix,"${");name:=prefix[1:];head:="$";tail:=""
        if braced {name=prefix[2:];head="${";tail="}"}
        for key in shell.variables {if strings.has_prefix(key,name) {append(&candidates,strings.concatenate([]string{head,key,tail}))}}
        if len(candidates)>0 {slice.sort(candidates[:]);native_shell_completion_apply(bytes,start,cursor,prefix,candidates[:],{noquote=true},completion_type,repeated)} else {native_shell_editor_write("\a")};return
    }
    if strings.contains(prefix,"$(")||strings.contains(prefix,"`") {native_shell_editor_write("\a");return}
    lookup,expanded:=native_shell_completion_directory(shell,prefix)
    if expanded&&shell.compat.shopts["direxpand"] {
        // Resolve the existing directory, not the unfinished filename prefix.
        if slash:=strings.last_index_byte(lookup,'/');slash>=0 {if absolute,path_error:=os.get_absolute_path(lookup[:slash+1],context.allocator);path_error==nil {lookup=strings.concatenate([]string{strings.trim_suffix(absolute,"/"),"/",lookup[slash+1:]})}}
    }
    slash:=strings.last_index_byte(lookup,'/');directory:=".";base:=lookup;head:=""
    typed_slash:=strings.last_index_byte(prefix,'/');typed_head:="";if typed_slash>=0 {typed_head=prefix[:typed_slash+1]}
    preserve:=expanded&&!shell.compat.shopts["direxpand"]&&typed_slash>=0
    if slash>=0 {directory=lookup[:slash+1];base=lookup[slash+1:];head=directory;if preserve {head=typed_head}}
    ignored:=make([dynamic]string)
    entries,error:=os.read_all_directory_by_path(directory,context.allocator)
    if error==nil {
        for entry in entries {
            if !native_shell_completion_prefix(entry.name,base)||(!native_shell_editor_setting_on("match-hidden-files")&&!strings.has_prefix(base,".")&&strings.has_prefix(entry.name,".")) {continue}
            candidate:=strings.concatenate([]string{head,entry.name})
            info,stat_error:=os.stat(strings.concatenate([]string{directory,"/",entry.name}),context.allocator)
            is_directory:=stat_error==nil&&info.type==.Directory
            if !files_only_mode&&initial&&!strings.contains(prefix,"/")&&!is_directory {continue}
            if is_directory&&native_shell_editor_setting_on("mark-directories") {stat:posix.stat_t;symlink:=posix.lstat(strings.clone_to_cstring(strings.concatenate([]string{directory,"/",entry.name}),context.temp_allocator),&stat)==.OK&&posix.S_ISLNK(stat.st_mode);if !symlink||native_shell_editor_setting_on("mark-symlinked-directories") {candidate=strings.concatenate([]string{candidate,"/"})}}
            if !is_directory&&native_shell_completion_ignored(shell,entry.name) {append(&ignored,candidate);continue}
            if !seen[candidate] {seen[candidate]=true;append(&candidates,candidate)}
        }
    }
    if len(candidates)==0&&!shell.compat.shopts["force_fignore"] {for candidate in ignored {append(&candidates,candidate)}}
    if !files_only_mode&&initial&&!strings.contains(prefix,"/") {
        for action in ([]string{"builtin","alias","function","keyword","command"}) {
            spec:=Native_Shell_Completion{actions=make([dynamic]string)};append(&spec.actions,action)
            for name in native_shell_completion_candidates(shell,spec,prefix,"","",false) {if !seen[name] {seen[name]=true;append(&candidates,name)}}
        }
    }
    if len(candidates)==0 {native_shell_editor_write("\a");return}
    slice.sort(candidates[:])
    if !preserve {comparison:=prefix;if expanded {comparison=lookup};native_shell_completion_apply(bytes,start,cursor,comparison,candidates[:],{},completion_type,repeated);return}
    if completion_type==63||completion_type==33 {native_shell_completion_display(candidates[:]);return}
    common:=native_shell_completion_common(candidates[:])
    if len(common)>len(prefix)||len(candidates)==1 {
        suffix:=common[min(len(typed_head),len(common)):]
        raw_slash:=strings.last_index_byte(raw,'/');replacement:=raw[:raw_slash+1]
        if quote!=0 {
            escaped_suffix:=make([dynamic]u8);for ch in transmute([]u8)suffix {if quote=='"'&&(ch=='"'||ch=='\\'||ch=='$'||ch=='`') {append(&escaped_suffix,'\\')};append(&escaped_suffix,ch)}
            replacement=strings.concatenate([]string{replacement,string(escaped_suffix[:])})
            if len(candidates)==1&&!strings.has_suffix(common,"/") {replacement=strings.concatenate([]string{replacement,string([]u8{quote})," "})}
        } else {replacement=strings.concatenate([]string{replacement,native_shell_editor_quote(suffix)});if len(candidates)==1&&!strings.has_suffix(common,"/") {replacement=strings.concatenate([]string{replacement," "})}}
        native_shell_completion_replace(bytes,start,cursor,replacement)
    } else if repeated||native_shell_editor_setting_on("show-all-if-ambiguous")||native_shell_editor_setting_on("show-all-if-unmodified") {native_shell_completion_display(candidates[:])} else {native_shell_editor_write("\a")}
}

native_shell_editor_quote :: proc(text:string)->string {
    if native_shell_editor.completion_literal {return strings.clone(text)}
    simple:=len(text)>0
    for ch in text {if !(unicode.is_letter(ch)||unicode.is_digit(ch)||ch=='/'||ch=='.'||ch=='_'||ch=='-'||ch==':') {simple=false;break}}
    if simple {return strings.clone(text)}
    result:=make([dynamic]u8);append(&result,u8('\''))
    for ch in transmute([]u8)text {if ch=='\'' {append(&result,"'\\''")} else {append(&result,ch)}}
    append(&result,u8('\''));return string(result[:])
}

native_shell_editor_read_byte :: proc(timeout:int)->(u8,int) {
    if len(native_shell_editor.pending)>0 {byte:=native_shell_editor.pending[0];ordered_remove(&native_shell_editor.pending,0);return byte,1}
    descriptor:=posix.pollfd{fd=0,events={.IN}}
    ready:=posix.poll(&descriptor,1,c.int(timeout))
    if ready==0 {return 0,0}
    if ready<0 {if posix.errno()==.EINTR {return 0,0};return 0,-1}
    byte:u8;count:=posix.read(0,&byte,1)
    if count==1 {return byte,1}
    if count<0&&(posix.errno()==.EINTR||posix.errno()==.EAGAIN) {return 0,0}
    return 0,-1
}

native_shell_editor_kill :: proc(bytes:^[dynamic]u8,first,last:int) {
    if last<=first {return}
    if native_shell_editor.kill_ring.allocator.procedure==nil {native_shell_editor.kill_ring=make([dynamic]string,0,0,native_shell_editor.allocator)}
    append(&native_shell_editor.kill_ring,strings.clone(string(bytes^[first:last]),native_shell_editor.allocator))
    if len(native_shell_editor.kill_ring)>60 {delete(native_shell_editor.kill_ring[0],native_shell_editor.allocator);ordered_remove(&native_shell_editor.kill_ring,0)}
    native_shell_editor_replace(bytes,first,last,"")
}

native_shell_readline :: proc(shell:^Native_Shell,prompt_override:string="",use_prompt:bool=false,initial:string="",filename_completion:bool=false,delimiter:u8='\n',count:int=0,exact:bool=false,timeout:f64= -1)->(line:string,eof:bool) {
    shell.input_cancelled=false
    native_shell_editor.completion_literal=use_prompt
    native_shell_editor.timed_out=false
    native_shell_editor.interrupted_signal=0
    native_shell_editor.shell=shell
    native_shell_editor_load_history()
    native_shell_bind_initialize(shell)
    if shell.compat.options["vi"] {native_shell_editing_mode="vi"} else if shell.compat.options["emacs"] {native_shell_editing_mode="emacs"}
    if !native_shell_readline_configured {
        native_shell_readline_configured=true
        path:=shell.variables["INPUTRC"];if path=="" {path=strings.concatenate([]string{shell.variables["HOME"],"/.inputrc"})}
        if _,error:=os.stat(path,context.temp_allocator);error==nil {_=native_shell_bind_inputrc(shell,path)} else if shell.variables["INPUTRC"]=="" {if _,system_error:=os.stat("/etc/inputrc",context.temp_allocator);system_error==nil {_=native_shell_bind_inputrc(shell,"/etc/inputrc")}}
    }
    saved:posix.termios
    if posix.tcgetattr(0,&saved)!=nil {return native_shell_readline_stream(shell)}
    delete(native_shell_editor.prompt,native_shell_editor.allocator)
    if use_prompt {native_shell_editor.prompt=strings.clone(prompt_override,native_shell_editor.allocator)} else {expanded:=native_shell_prompt(shell,shell.continuation);native_shell_editor.prompt=strings.clone(expanded,native_shell_editor.allocator);delete(expanded)}
    if newline:=strings.last_index_byte(native_shell_editor.prompt,'\n');newline>=0 {
        prefix:=native_shell_prompt_visible(native_shell_editor.prompt[:newline+1]);native_shell_editor_write(prefix);delete(prefix)
        tail:=strings.clone(native_shell_editor.prompt[newline+1:],native_shell_editor.allocator);delete(native_shell_editor.prompt,native_shell_editor.allocator);native_shell_editor.prompt=tail
    }
    raw:=saved
    raw.c_lflag-={.ICANON,.ECHO,.ECHONL,.IEXTEN,.ISIG}
    raw.c_iflag-={.IXON,.IXOFF,.ICRNL,.INLCR}
    raw.c_cc[.VMIN]=1;raw.c_cc[.VTIME]=0
    if posix.tcsetattr(0,.TCSANOW,&raw)!=nil {return "",true}
    bracketed:=native_shell_editor_setting_on("enable-bracketed-paste")
    if bracketed {native_shell_editor_write("\x1b[?2004h")}
    defer {if bracketed {native_shell_editor_write("\x1b[?2004l")};_=posix.tcsetattr(0,.TCSANOW,&saved)}
    buffer:=make([dynamic]u8);defer delete(buffer)
    append(&buffer,initial)
    cursor:=len(buffer);viewport,mark:int
    undo:=make([dynamic]string);defer {for item in undo {delete(item)};delete(undo)}
    last_yank_first,last_yank_end:=-1,-1;yank_index:=-1
    started:=time.tick_now()
    history_index:=len(native_shell_editor.history)
    draft:string;defer delete(draft)
    reverse_query:string;defer delete(reverse_query)
    reverse_active:=false
    pasted:=false
    paste_buffer:=make([dynamic]u8);defer delete(paste_buffer)
    vi_command:=false
    vi_delete:=false
    columns:=native_shell_editor_width()
    native_shell_editor_redraw(shell,buffer[:],cursor,&viewport)
    native_shell_editor.completed=false
    for {
        if len(undo)==0||undo[len(undo)-1]!=string(buffer[:]) {append(&undo,strings.clone(string(buffer[:])))}
        if use_prompt {if signal:=native_shell_read_pending_signal(shell);signal==int(posix.Signal.SIGINT) {native_shell_editor.interrupted_signal=signal;return strings.clone(string(buffer[:])),true}}
        native_shell_dispatch_traps(shell)
        if native_shell_cancelled() {return "",true}
        wait:=100
        if timeout>=0 {remaining:=timeout-time.duration_seconds(time.tick_diff(started,time.tick_now()));if remaining<=0 {native_shell_editor.timed_out=true;return strings.clone(string(buffer[:])),true};wait=min(wait,max(0,int(remaining*1000)))}
        byte,state:=native_shell_editor_read_byte(wait)
        if state<0 {native_shell_editor_write("\r\n");return strings.clone(string(buffer[:])),true}
        if state==0 {width:=native_shell_editor_width();if width!=columns {columns=width;if !pasted {native_shell_editor_redraw(shell,buffer[:],cursor,&viewport)}};continue}
        if byte>=128&&!native_shell_editor_setting_on("input-meta") {byte&=127}
        if byte>=128&&native_shell_editor_setting_on("convert-meta") {converted:=[1]u8{byte&127};native_shell_editor_queue(converted[:]);byte=27}
        if use_prompt&&!exact&&byte==delimiter&&delimiter!='\n' {native_shell_editor_write("\r\n");return strings.clone(string(buffer[:])),false}
        if byte!=18 {reverse_active=false}
        mapped_binding:=false
        if !pasted {
            if binding,found:=native_shell_editor_binding(byte,vi_command);found {
                mapped_binding=true
                if binding.macro {native_shell_editor_queue(transmute([]u8)binding.action);continue}
                if binding.command {
                    native_shell_set_variable(shell,"READLINE_LINE",string(buffer[:]))
                    native_shell_set_variable(shell,"READLINE_POINT",fmt.tprintf("%d",cursor))
                    native_shell_editor_write("\x1b[?2004l");_=posix.tcsetattr(0,.TCSANOW,&saved)
                    native_shell_execute(shell,binding.action)
                    _=posix.tcsetattr(0,.TCSANOW,&raw);native_shell_editor_write("\x1b[?2004h")
                    clear(&buffer);append(&buffer,shell.variables["READLINE_LINE"])
                    point,ok:=strconv.parse_int(shell.variables["READLINE_POINT"]);if ok {cursor=clamp(point,0,len(buffer))} else {cursor=len(buffer)}
                    native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                }
                switch binding.action {
                case "accept-line":byte=13
                case "beginning-of-line":byte=1
                case "end-of-line":byte=5
                case "backward-char":byte=2
                case "forward-char":byte=6
                case "backward-delete-char","rubout":byte=127
                case "delete-char":byte=4
                case "kill-line":byte=11
                case "unix-line-discard","backward-kill-line":byte=21
                case "unix-word-rubout","backward-kill-word":byte=23
                case "clear-screen","clear-display":byte=12
                case "complete":
                    native_shell_editor_complete(shell,&buffer,&cursor,filename_completion,9,int(binding.key));native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "possible-completions","menu-complete","menu-complete-backward":
                    kind:=63;if binding.action!="possible-completions" {kind=37}
                    native_shell_editor_complete(shell,&buffer,&cursor,filename_completion,kind,int(binding.key),binding.action=="menu-complete-backward");native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "reverse-search-history":byte=18
                case "previous-history":byte=16
                case "next-history":byte=14
                case "yank":byte=25
                case "transpose-chars":byte=20
                case "undo","revert-line":byte=31
                case "set-mark":mark=cursor;continue
                case "quoted-insert":
                    quoted,available:=native_shell_editor_read_byte(-1);if available==1 {text:=[1]u8{quoted};native_shell_editor_replace(&buffer,cursor,cursor,string(text[:]));cursor+=1};native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "exchange-point-and-mark":cursor,mark=clamp(mark,0,len(buffer)),cursor;native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "kill-word":native_shell_editor_kill(&buffer,cursor,native_shell_editor_word_right(buffer[:],cursor));native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "kill-region":first,last:=min(mark,cursor),max(mark,cursor);native_shell_editor_kill(&buffer,first,min(last,len(buffer)));cursor=first;native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "copy-region-as-kill":
                    first,last:=min(mark,cursor),min(max(mark,cursor),len(buffer));if first<last {if native_shell_editor.kill_ring.allocator.procedure==nil {native_shell_editor.kill_ring=make([dynamic]string,0,0,native_shell_editor.allocator)};append(&native_shell_editor.kill_ring,strings.clone(string(buffer[first:last]),native_shell_editor.allocator))};continue
                case "yank-pop":
                    if last_yank_first>=0&&last_yank_end==cursor&&len(native_shell_editor.kill_ring)>0 {yank_index=(yank_index+len(native_shell_editor.kill_ring)-1)%len(native_shell_editor.kill_ring);text:=native_shell_editor.kill_ring[yank_index];native_shell_editor_replace(&buffer,last_yank_first,last_yank_end,text);cursor=last_yank_first+len(text);last_yank_end=cursor};native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "upcase-word","downcase-word","capitalize-word":
                    end:=native_shell_editor_word_right(buffer[:],cursor);text:=string(buffer[cursor:end]);if binding.action=="downcase-word" {text=strings.to_lower(text)} else if binding.action=="upcase-word" {text=strings.to_upper(text)} else {text=strings.to_lower(text);for ch,width in text {if unicode.is_letter(ch) {encoded,n:=utf8.encode_rune(unicode.to_upper(ch));_,old:=utf8.decode_rune(text[width:]);text=strings.concatenate([]string{text[:width],string(encoded[:n]),text[width+old:]});break}}}
                    native_shell_editor_replace(&buffer,cursor,end,text);cursor+=len(text);native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "yank-last-arg","yank-nth-arg":
                    if len(native_shell_editor.history)>0 {words:=native_shell_history_words(native_shell_editor.history[len(native_shell_editor.history)-1]);if len(words)>0 {text:=words[len(words)-1];native_shell_editor_replace(&buffer,cursor,cursor,text);cursor+=len(text)}};native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "beginning-of-history":history_index=0;if len(native_shell_editor.history)>0 {clear(&buffer);append(&buffer,native_shell_editor.history[0]);cursor=len(buffer)};native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "end-of-history":history_index=len(native_shell_editor.history);clear(&buffer);append(&buffer,draft);cursor=len(buffer);native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "backward-word":cursor=native_shell_editor_word_left(buffer[:],cursor);native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "forward-word":cursor=native_shell_editor_word_right(buffer[:],cursor);native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case "kill-whole-line":native_shell_editor_kill(&buffer,0,len(buffer));cursor=0;native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case: native_shell_editor_write("\a");continue
                }
            }
            if !mapped_binding&&native_shell_editing_mode=="vi"&&vi_command&&byte!=27 {
                switch byte {
                case 'i':vi_command=false;vi_delete=false;continue
                case 'a':cursor=native_shell_editor_next(buffer[:],cursor);vi_command=false;continue
                case 'I':cursor=0;vi_command=false;continue
                case 'A':cursor=len(buffer);vi_command=false;continue
                case 'h':byte=2
                case 'l':byte=6
                case '0','^':byte=1
                case '$':byte=5
                case 'b':cursor=native_shell_editor_word_left(buffer[:],cursor);native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case 'w':cursor=native_shell_editor_word_right(buffer[:],cursor);native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case 'x':byte=4
                case 'D':byte=11
                case 'C':byte=11;vi_command=false
                case 's':byte=4;vi_command=false
                case 'd':if !vi_delete {vi_delete=true;continue};native_shell_editor_kill(&buffer,0,len(buffer));cursor=0;vi_delete=false;native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue
                case 'p':cursor=native_shell_editor_next(buffer[:],cursor);byte=25
                case 'P':byte=25
                case 'u':byte=31
                case 'k','-':byte=16
                case 'j','+':byte=14
                case 10,13,3,4: {}
                case: native_shell_editor_write("\a");continue
                }
            }
        }
        if byte==27 {
            sequence:=make([dynamic]u8);defer delete(sequence)
            next,read:=native_shell_editor_read_byte(40)
            if read<=0 {if native_shell_editing_mode=="vi" {vi_command=true;cursor=native_shell_editor_previous(buffer[:],cursor);native_shell_editor_redraw(shell,buffer[:],cursor,&viewport)};continue}
            append(&sequence,next)
            if next=='['||next=='O' {
                for len(sequence)<32 {ch,ok:=native_shell_editor_read_byte(40);if ok<=0 {break};append(&sequence,ch);if ch>=0x40&&ch<=0x7e {break}}
            }
            key:=string(sequence[:])
            if key=="[200~" {if !pasted {clear(&paste_buffer)};pasted=true;continue}
            if key=="[201~" {if pasted {native_shell_editor_replace(&buffer,cursor,cursor,string(paste_buffer[:]));cursor=min(len(buffer),cursor+len(paste_buffer));clear(&paste_buffer)};pasted=false;native_shell_editor_redraw(shell,buffer[:],cursor,&viewport);continue}
            if pasted {continue}
            switch key {
            case "[D","OD":cursor=native_shell_editor_previous(buffer[:],cursor)
            case "[C","OC":cursor=native_shell_editor_next(buffer[:],cursor)
            case "[H","OH","[1~","[7~":cursor=0
            case "[F","OF","[4~","[8~":cursor=len(buffer)
            case "[1;5D","[1;3D","b":cursor=native_shell_editor_word_left(buffer[:],cursor)
            case "[1;5C","[1;3C","f":cursor=native_shell_editor_word_right(buffer[:],cursor)
            case "[3~":if cursor<len(buffer) {native_shell_editor_replace(&buffer,cursor,native_shell_editor_next(buffer[:],cursor),"")}
            case "[3;5~":native_shell_editor_kill(&buffer,cursor,native_shell_editor_word_right(buffer[:],cursor))
            case "\x7f","\b":first:=native_shell_editor_word_left(buffer[:],cursor);native_shell_editor_kill(&buffer,first,cursor);cursor=first
            case "[A","OA","[B","OB":
                if history_index==len(native_shell_editor.history) {delete(draft);draft=strings.clone(string(buffer[:]))}
                if key=="[A"||key=="OA" {history_index=max(0,history_index-1)} else {history_index=min(len(native_shell_editor.history),history_index+1)}
                text:=draft;if history_index<len(native_shell_editor.history) {text=native_shell_editor.history[history_index]}
                clear(&buffer);append(&buffer,..transmute([]u8)text);if native_shell_editor_setting_on("history-preserve-point") {cursor=min(cursor,len(buffer))} else {cursor=len(buffer)};viewport=0
            }
        } else if pasted {
            if byte=='\r' {byte='\n'}
            if byte>=32||byte=='\n'||byte=='\t' {append(&paste_buffer,byte)}
        } else {
            switch byte {
            case 10,13:
                if use_prompt&&exact {native_shell_editor_replace(&buffer,cursor,cursor,"\n");cursor+=1} else {native_shell_editor_write("\r\n");return strings.clone(string(buffer[:])),false}
            case 3:
                native_shell_editor_write("^C\r\n");shell.status=130;shell.input_cancelled=true;native_shell_run_trap(shell,int(posix.Signal.SIGINT))
                return "",false
            case 4:
                if len(buffer)==0 {native_shell_editor_write("\r\n");return "",true}
                if cursor<len(buffer) {native_shell_editor_replace(&buffer,cursor,native_shell_editor_next(buffer[:],cursor),"")}
            case 1:cursor=0
            case 5:cursor=len(buffer)
            case 2:cursor=native_shell_editor_previous(buffer[:],cursor)
            case 6:cursor=native_shell_editor_next(buffer[:],cursor)
            case 8,127:
                if cursor>0 {first:=native_shell_editor_previous(buffer[:],cursor);native_shell_editor_replace(&buffer,first,cursor,"");cursor=first}
            case 11:native_shell_editor_kill(&buffer,cursor,len(buffer))
            case 21:native_shell_editor_kill(&buffer,0,cursor);cursor=0
            case 23:first:=native_shell_editor_word_left(buffer[:],cursor);native_shell_editor_kill(&buffer,first,cursor);cursor=first
            case 25:
                if len(native_shell_editor.kill_ring)>0 {yank_index=len(native_shell_editor.kill_ring)-1;text:=native_shell_editor.kill_ring[yank_index];last_yank_first=cursor;native_shell_editor_replace(&buffer,cursor,cursor,text);cursor+=len(text);last_yank_end=cursor}
            case 20:
                if cursor>0&&len(buffer)>1 {end:=cursor;if end==len(buffer) {end=native_shell_editor_previous(buffer[:],end)};first:=native_shell_editor_previous(buffer[:],end);last:=native_shell_editor_next(buffer[:],end);left:=strings.clone(string(buffer[first:end]));right:=strings.clone(string(buffer[end:last]));text:=strings.concatenate([]string{right,left});native_shell_editor_replace(&buffer,first,last,text);cursor=last;delete(left);delete(right);delete(text)}
            case 31:
                if len(undo)>1 {delete(pop(&undo));text:=undo[len(undo)-1];clear(&buffer);append(&buffer,text);cursor=len(buffer)} else {native_shell_editor_write("\a")}
            case 12:native_shell_editor_write("\x1b[2J\x1b[H")
            case 9:native_shell_editor_complete(shell,&buffer,&cursor,filename_completion)
            case 18:
                if !reverse_active {delete(reverse_query);reverse_query=strings.clone(string(buffer[:]));reverse_active=true}
                query:=reverse_query;found:=false
                for index:=history_index-1;index>=0;index-=1 {
                    if strings.contains(native_shell_editor.history[index],query) {history_index=index;text:=native_shell_editor.history[index];clear(&buffer);append(&buffer,..transmute([]u8)text);cursor=len(buffer);viewport=0;found=true;break}
                }
                if !found {native_shell_editor_write("\a")}
            case 16,14:
                if history_index==len(native_shell_editor.history) {delete(draft);draft=strings.clone(string(buffer[:]))}
                if byte==16 {history_index=max(0,history_index-1)} else {history_index=min(len(native_shell_editor.history),history_index+1)}
                text:=draft;if history_index<len(native_shell_editor.history) {text=native_shell_editor.history[history_index]}
                clear(&buffer);append(&buffer,..transmute([]u8)text);if native_shell_editor_setting_on("history-preserve-point") {cursor=min(cursor,len(buffer))} else {cursor=len(buffer)};viewport=0
            case:
                if byte>=32 {
                    encoded:[4]u8;encoded[0]=byte;length:=1
                    needed:=1;if byte>=0xc2&&byte<=0xdf {needed=2} else if byte>=0xe0&&byte<=0xef {needed=3} else if byte>=0xf0&&byte<=0xf4 {needed=4}
                    for length<needed {next,ok:=native_shell_editor_read_byte(100);if ok<=0 {break};encoded[length]=next;length+=1}
                    text:=string(encoded[:length]);if !utf8.valid_string(text) {text="�"}
                    native_shell_editor_replace(&buffer,cursor,cursor,text);cursor+=len(text)
                }
            }
        }
        cursor=min(cursor,len(buffer))
        if count>0&&utf8.rune_count_in_string(string(buffer[:]))>=count {end:=0;for _ in 0..<count {end=native_shell_editor_next(buffer[:],end)};return strings.clone(string(buffer[:end])),false}
        if !pasted {native_shell_editor_redraw(shell,buffer[:],cursor,&viewport)}
    }
}

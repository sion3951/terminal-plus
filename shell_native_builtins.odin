#+build linux
package main

import "core:c"
import libc "core:c/libc"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import atomic "core:sync"
import "core:time"
import "core:unicode/utf8"
import posix "core:sys/posix"

native_shell_compat_builtin_name :: proc(name:string)->bool {
    switch name {
    case "set","shift","getopts","declare","typeset","local","readonly","alias","unalias","shopt","read","readarray","mapfile","test","[","let","break","continue","return","builtin","trap","dirs","pushd","popd","umask","ulimit","hash","enable","caller","suspend","logout","kill","times":return true
    }
    return false
}
native_shell_option_name :: proc(ch:u8)->string {
    switch ch {case 'e':return "errexit";case 'u':return "nounset";case 'x':return "xtrace";case 'f':return "noglob";case 'a':return "allexport";case 'C':return "noclobber";case 'n':return "noexec";case 'v':return "verbose";case 'm':return "monitor";case 'h':return "hashall";case 'B':return "braceexpand";case 'E':return "errtrace";case 'T':return "functrace";case 'b':return "notify";case 'H':return "histexpand";case 'P':return "physical";case 't':return "onecmd";case 'k':return "keyword";case 'p':return "privileged";case 'r':return "restricted"}
    return ""
}
native_shell_known_option :: proc(name:string)->bool {
    switch name {case "errexit","nounset","xtrace","noglob","allexport","noclobber","noexec","verbose","monitor","hashall","braceexpand","errtrace","functrace","notify","histexpand","physical","onecmd","keyword","privileged","pipefail","posix","nolog","ignoreeof","history","interactive-comments","emacs","vi":return true}
    return false
}
native_shell_option_names :: proc()->[]string {return strings.fields("allexport braceexpand emacs errexit errtrace functrace hashall histexpand history ignoreeof interactive-comments keyword monitor noclobber noexec noglob nolog notify nounset onecmd physical pipefail posix privileged verbose vi xtrace")}
// One ordered inventory drives validation, shopt output, and completion.
native_shell_shopt_names :: proc()->[]string {
    return strings.fields("array_expand_once assoc_expand_once autocd bash_source_fullpath cdable_vars cdspell checkhash checkjobs checkwinsize cmdhist compat31 compat32 compat40 compat41 compat42 compat43 compat44 complete_fullquote direxpand dirspell dotglob execfail expand_aliases extdebug extglob extquote failglob force_fignore globasciiranges globskipdots globstar gnu_errfmt histappend histreedit histverify hostcomplete huponexit inherit_errexit interactive_comments lastpipe lithist localvar_inherit localvar_unset login_shell mailwarn no_empty_cmd_completion nocaseglob nocasematch noexpand_translation nullglob patsub_replacement progcomp progcomp_alias promptvars restricted_shell shift_verbose sourcepath varredir_close xpg_echo")
}
native_shell_known_shopt :: proc(name:string)->bool {
    for known in native_shell_shopt_names() {if known==name {return true}}
    return false
}
native_shell_shopt_set :: proc(shell:^Native_Shell,name:string,enabled:bool) {
    // These describe invocation state and cannot be changed by shopt.
    if name=="restricted_shell"||name=="login_shell" {return}
    native_shell_bool_set(shell,&shell.compat.shopts,name,enabled)
    if name=="extdebug" {native_shell_option_set(shell,"functrace",enabled);native_shell_option_set(shell,"errtrace",enabled)}
    if name=="array_expand_once" {native_shell_bool_set(shell,&shell.compat.shopts,"assoc_expand_once",enabled)}
    if name=="assoc_expand_once" {native_shell_bool_set(shell,&shell.compat.shopts,"array_expand_once",enabled)}
    if strings.has_prefix(name,"compat") {
        number,_:=strconv.parse_int(name[6:])
        if enabled {native_shell_compat_set(shell,fmt.tprintf("%d",number));native_shell_set_variable(shell,"BASH_COMPAT",fmt.tprintf("%d",number))}
        else if native_shell_compat_level(shell)==number {native_shell_compat_set(shell,"");native_shell_set_variable(shell,"BASH_COMPAT","53")}
    }
}
native_shell_builtin_shopt :: proc(shell:^Native_Shell,args:[]string)->int {
    enabled,disabled,quiet,printing,standard:bool;i:=1
    for i<len(args)&&len(args[i])>1&&args[i][0]=='-' {
        if args[i]=="--" {i+=1;break}
        for ch in transmute([]u8)args[i][1:] {
            switch ch {
            case 's':enabled=true
            case 'u':disabled=true
            case 'q':quiet=true
            case 'p':printing=true
            case 'o':standard=true
            case:fmt.eprintf("shopt: invalid option -%c\n",ch);return 2
            }
        }
        i+=1
    }
    if enabled&&disabled {fmt.eprintln("shopt: cannot set and unset shell options simultaneously");return 1}
    names:=args[i:];explicit_names:=len(names)>0
    if !explicit_names {if quiet {return 0};if standard {names=native_shell_option_names()} else {names=native_shell_shopt_names()}}
    status:=0
    for name in names {
        valid:=native_shell_known_shopt(name);if standard {valid=native_shell_known_option(name)}
        if !valid {fmt.eprintf("shopt: %s: invalid shell option name\n",name);status=1;continue}
        value:=shell.compat.shopts[name];if standard {value=shell.compat.options[name]}
        if explicit_names&&(enabled||disabled) {
            if standard {native_shell_option_set(shell,name,enabled)} else {native_shell_shopt_set(shell,name,enabled)}
            value=shell.compat.shopts[name];if standard {value=shell.compat.options[name]}
        }
        if quiet {if !value {status=1};continue}
        if explicit_names&&!enabled&&!disabled&&!value {status=1}
        if !explicit_names&&(enabled&&!value||disabled&&value) {continue}
        if explicit_names&&(enabled||disabled)&&!printing {continue}
        if printing {
            if standard {flag:="+o";if value {flag="-o"};fmt.printf("set %s %s\n",flag,name)}
            else {flag:="-u";if value {flag="-s"};fmt.printf("shopt %s %s\n",flag,name)}
        } else {label:="off";if value {label="on"};fmt.printf("%-20s\t%s\n",name,label)}
    }
    return status
}
native_shell_set_parameters :: proc(shell:^Native_Shell,values:[]string) {
    // Parameters set by `set --` can outlive this command's arena.
    copy:=make([]string,len(values),shell.allocator)
    for value,i in values {copy[i]=strings.clone(value,shell.allocator)}
    // Owned parameter blocks are retired only at shell destruction, since a
    // function/source frame may still reference an earlier set of parameters.
    append(&shell.compat.parameter_blocks,copy)
    shell.compat.parameters=copy
    shell.compat.parameter_generation+=1
}
native_shell_builtin_set :: proc(shell:^Native_Shell,args:[]string)->int {
    if len(args)==1 {names:=make([dynamic]string);for name,_ in shell.variables {append(&names,name)};slice.sort(names[:]);for name in names {fmt.printf("%s=%s\n",name,explorer_quote(shell.variables[name]))};return 0}
    i:=1
    for i<len(args) {
        word:=args[i]
        if word=="--" {native_shell_set_parameters(shell,args[i+1:]);return 0}
        if word=="-" {shell.compat.options["xtrace"]=false;shell.compat.options["verbose"]=false;i+=1;break}
        if len(word)<2||(word[0]!='-'&&word[0]!='+') {break}
        enabled:=word[0]=='-'
        if word=="-o"||word=="+o" {
            if i+1==len(args) {for name in native_shell_option_names() {if enabled {label:="off";if shell.compat.options[name] {label="on"};fmt.printf("%-15s\t%s\n",name,label)} else {flag:="+o";if shell.compat.options[name] {flag="-o"};fmt.printf("set %s %s\n",flag,name)}};return 0}
            i+=1;name:=args[i];if !native_shell_known_option(name) {fmt.eprintf("set: %s: invalid option name\n",name);return 2};native_shell_option_set(shell,name,enabled);i+=1;continue
        }
        for ch in transmute([]u8)word[1:] {name:=native_shell_option_name(ch);if name=="" {fmt.eprintf("set: %c%c: invalid option\n",word[0],ch);return 2};if name=="restricted"&&!enabled&&shell.compat.restricted {fmt.eprintln("set: +r: invalid option");return 1};native_shell_option_set(shell,name,enabled)}
        i+=1
    }
    if i<len(args) {native_shell_set_parameters(shell,args[i:])}
    return 0
}
native_shell_declaration_quote :: proc(shell:^Native_Shell,value:string)->string {
    quoted:=native_shell_parameter_quote(shell,value)
    if strings.has_prefix(quoted,"$'") {return quoted}
    return native_shell_parameter_double_quote(value)
}
native_shell_print_declaration :: proc(shell:^Native_Shell,name:string,readonly_style:bool=false) {
    attributes:=shell.compat.attributes[name];if shell.exported[name] {attributes|=NATIVE_SHELL_EXPORT}
    flags:="--"
    if attributes!=0 {
        bytes:=make([dynamic]u8);append(&bytes,'-')
        bits:=[]u32{NATIVE_SHELL_ASSOCIATIVE,NATIVE_SHELL_INDEXED,NATIVE_SHELL_INTEGER,NATIVE_SHELL_LOWER,NATIVE_SHELL_NAMEREF,NATIVE_SHELL_READONLY,NATIVE_SHELL_TRACE,NATIVE_SHELL_UPPER,NATIVE_SHELL_EXPORT}
        letters:="Aailnrtux"
        for bit,index in bits {if attributes&bit!=0 {append(&bytes,letters[index])}}
        flags=string(bytes[:])
    }
    if array,exists:=shell.compat.arrays[name];exists {
        keys:=native_shell_array_values(shell,name,true)
        if !array.initialized&&len(keys)==0 {fmt.printf("declare %s %s\n",flags,name);return}
        fmt.printf("declare %s %s=(",flags,name)
        for key,i in keys {
            if i>0&&!array.associative_mode {fmt.print(" ")}
            printed_key:=key
            if array.associative_mode&&strings.contains_any(key," \t\n\r\"'\\`$*?[]{}();&|<>!~") {printed_key=native_shell_declaration_quote(shell,key)}
            value,_:=native_shell_value_get(shell,fmt.tprintf("%s[%s]",name,key))
            fmt.printf("[%s]=%s",printed_key,native_shell_declaration_quote(shell,value))
            if array.associative_mode {fmt.print(" ")}
        }
        fmt.println(")");return
    }
    prefix:=fmt.tprintf("declare %s ",flags)
    if readonly_style&&shell.compat.options["posix"] {prefix="readonly "}
    value,exists:=native_shell_value_get(shell,name)
    if attributes&NATIVE_SHELL_NAMEREF!=0 {value,exists=shell.variables[name]}
    if exists {fmt.printf("%s%s=%s\n",prefix,name,native_shell_declaration_quote(shell,value))} else {fmt.printf("%s%s\n",prefix,name)}
}
Native_Shell_Array_Element :: struct {key,value:string}
native_shell_array_assign :: proc(shell:^Native_Shell,name,raw:string,append_value:bool=false)->string {
    if !strings.has_prefix(raw,"(")||!strings.has_suffix(raw,")") {return "invalid array assignment"}
    if shell.compat.attributes[name]&NATIVE_SHELL_READONLY!=0 {return fmt.tprintf("%s: readonly variable",name)}
    array:=native_shell_array_ensure(shell,name,shell.compat.attributes[name]&NATIVE_SHELL_ASSOCIATIVE!=0)
    next:=0
    if append_value {for at,_ in array.indexed {next=max(next,at+1)}}
    // Expand the whole initializer while the previous array is still visible.
    // In particular a=("${a[@]}") must not erase a before reading its values.
    elements:=make([dynamic]Native_Shell_Array_Element)
    tokens,token_error:=native_shell_tokens(raw[1:len(raw)-1]);if token_error!="" {return token_error}
    alternating:=array.associative_mode&&len(tokens)>0&&!(strings.has_prefix(tokens[0].raw,"[")&&strings.contains(tokens[0].raw,"]="))
    if alternating {
        for index:=0;index<len(tokens);index+=2 {
            if tokens[index].operator {return "invalid operator in array assignment"}
            key,key_error:=native_shell_expand_assignment(shell,tokens[index].raw);if key_error!="" {return key_error};if key=="" {return "bad array subscript"}
            value:="";if index+1<len(tokens) {if tokens[index+1].operator {return "invalid operator in array assignment"};expanded,value_error:=native_shell_expand_assignment(shell,tokens[index+1].raw);if value_error!="" {return value_error};value=expanded}
            append(&elements,Native_Shell_Array_Element{key,value})
        }
    }
    for token in tokens {
        if alternating {break}
        if token.operator {return "invalid operator in array assignment"}
        word:=token.raw;key:="";explicit:=false
        if strings.has_prefix(word,"[") {close:=strings.index(word,"]=");if close>0 {key=word[1:close];word=word[close+2:];explicit=true}}
        if explicit {
            if array.associative_mode {expanded,expand_error:=native_shell_expand_assignment(shell,key);if expand_error!="" {return expand_error};key=expanded} else {index,index_error:=native_shell_array_index(shell,array,key);if index_error!="" {return index_error};next=index;key=fmt.tprintf("%d",index)}
            value,expand_error:=native_shell_expand_assignment(shell,word);if expand_error!="" {return expand_error}
            append(&elements,Native_Shell_Array_Element{key,value});next+=1;continue
        }
        fields,expand_error:=native_shell_expand(shell,{raw=word});if expand_error!="" {return expand_error}
        if array.associative_mode {return "associative array assignment requires [key]=value entries"}
        for value in fields {append(&elements,Native_Shell_Array_Element{fmt.tprintf("%d",next),value});next+=1}
    }
    if !append_value {native_shell_array_clear(shell,array)}
    for item in elements {if error:=native_shell_value_set(shell,fmt.tprintf("%s[%s]",name,item.key),item.value);error!="" {return error}}
    native_shell_attribute_set(shell,name,shell.compat.attributes[name]|(NATIVE_SHELL_ASSOCIATIVE if array.associative_mode else NATIVE_SHELL_INDEXED))
    return ""
}

native_shell_builtin_declare :: proc(shell:^Native_Shell,args:[]string)->int {
    local_scope:=args[0]=="local"||(args[0]!="readonly"&&shell.compat.function_depth>0)
    if args[0]=="local"&&shell.compat.function_depth==0 {fmt.eprintln("local: can only be used in a function");return 1}
    flags:u32;remove:u32;printing,functions,names_only,inherit,global_scope:bool
    if args[0]=="readonly" {flags|=NATIVE_SHELL_READONLY}
    i:=1
    for i<len(args)&&len(args[i])>1&&(args[i][0]=='-'||args[i][0]=='+') {
        option:=args[i];if option=="--" {i+=1;break}
        enabled:=option[0]=='-'
        for ch in transmute([]u8)option[1:] {
            bit:u32
            switch ch {case 'a':bit=NATIVE_SHELL_INDEXED;case 'A':bit=NATIVE_SHELL_ASSOCIATIVE;case 'i':bit=NATIVE_SHELL_INTEGER;case 'r':bit=NATIVE_SHELL_READONLY;case 'x':bit=NATIVE_SHELL_EXPORT;case 'u':bit=NATIVE_SHELL_UPPER;case 'l':bit=NATIVE_SHELL_LOWER;case 'n':bit=NATIVE_SHELL_NAMEREF;case 't':bit=NATIVE_SHELL_TRACE;case 'I':inherit=enabled;case 'p':printing=true;case 'f':functions=true;case 'F':functions=true;names_only=true;case 'g':local_scope=false;global_scope=true;case:fmt.eprintf("%s: unsupported option: %c\n",args[0],ch);return 2}
            if enabled {flags|=bit} else {remove|=bit}
        }
        i+=1
    }
    if functions {
        names:=args[i:];if len(names)==0 {all:=make([dynamic]string);for name,_ in shell.compat.functions {append(&all,name)};slice.sort(all[:]);names=all[:]}
        status:=0
        for name in names {
            body,exists:=shell.compat.functions[name];if !exists {fmt.eprintf("%s: %s: not a function\n",args[0],name);status=1;continue}
            key:=strings.concatenate([]string{"BASH_FUNC_",name,"%%"})
            attributes:=shell.compat.attributes[key]
            if remove&NATIVE_SHELL_READONLY!=0&&attributes&NATIVE_SHELL_READONLY!=0 {fmt.eprintf("%s: %s: readonly function\n",args[0],name);status=1;continue}
            if flags!=0||remove!=0 {
                if flags&~(NATIVE_SHELL_READONLY|NATIVE_SHELL_EXPORT|NATIVE_SHELL_TRACE)!=0 {fmt.eprintf("%s: invalid function attribute\n",args[0]);status=1;continue}
                native_shell_attribute_set(shell,key,(attributes|flags)&~remove)
                if !printing {continue}
            }
            if names_only {
                if shell.compat.shopts["extdebug"]&&i<len(args) {fmt.printf("%s %d %s\n",name,shell.compat.function_lines[name],shell.compat.function_sources[name])} else if i==len(args) {fmt.printf("declare -f%s%s%s %s\n",("r" if attributes&NATIVE_SHELL_READONLY!=0 else ""),("t" if attributes&NATIVE_SHELL_TRACE!=0 else ""),("x" if attributes&NATIVE_SHELL_EXPORT!=0 else ""),name)} else {fmt.println(name)}
            } else {fmt.printf("%s () {\n%s\n}\n",name,strings.trim_space(body))}
        }
        return status
    }
    if i==len(args) {
        names:=make([dynamic]string);seen:=make(map[string]bool)
        for name,_ in shell.variables {if flags==0||shell.compat.attributes[name]&flags==flags {append(&names,name);seen[name]=true}}
        for name,_ in shell.compat.arrays {if !seen[name]&&(flags==0||shell.compat.attributes[name]&flags==flags) {append(&names,name)}}
        for name,declared in shell.compat.declared {if declared&&!seen[name]&&shell.compat.arrays[name]==nil&&(flags==0||shell.compat.attributes[name]&flags==flags) {append(&names,name)}}
        slice.sort(names[:]);for name in names {native_shell_print_declaration(shell,name,args[0]=="readonly")};return 0
    }
    status:=0
    for argument in args[i:] {
        if argument=="-"&&args[0]=="local" {
            frame:=&shell.compat.frames[len(shell.compat.frames)-1]
            if !frame.save_options {
                frame.options=make(map[string]bool,shell.allocator);for name,value in shell.compat.options {frame.options[name]=value}
                for option,index in ([]string{"inherit_errexit","shift_verbose","interactive_comments"}) {frame.posix_shopts[index]=shell.compat.shopts[option]}
                frame.editing_mode=native_shell_editing_mode;frame.save_options=true
            }
            continue
        }
        equals:=strings.index_byte(argument,'=');assignment:=equals>=0;name:=argument;value:=""
        if assignment {name=argument[:equals];value=argument[equals+1:]}
        append_value:=strings.has_suffix(name,"+");if append_value {name=name[:len(name)-1]}
        base,_,_:=native_shell_reference(name)
        if !native_shell_name(base) {fmt.eprintf("%s: %s: invalid identifier\n",args[0],base);status=1;continue}
        global:Native_Shell_Global_Scope
        if global_scope&&!printing {global=native_shell_global_enter(shell,base)}
        defer native_shell_global_leave(shell,global)
        if printing {if _,exists:=native_shell_value_get(shell,base);!exists&&shell.compat.arrays[base]==nil&&!shell.compat.declared[base] {fmt.eprintf("%s: %s: not found\n",args[0],base);status=1} else {native_shell_print_declaration(shell,base,args[0]=="readonly")};continue}
        if local_scope {
            if shell.compat.attributes[base]&NATIVE_SHELL_READONLY!=0 {fmt.eprintf("%s: %s: readonly variable\n",args[0],base);status=1;continue}
            frame:=&shell.compat.frames[len(shell.compat.frames)-1]
            if item,saved:=frame.locals[base];!saved||item.removed {
                native_shell_local_save(shell,base)
                if !inherit&&!shell.compat.shopts["localvar_inherit"] {
                    exported:=shell.exported[base]
                    attributes:=u32(0);if exported {attributes=NATIVE_SHELL_EXPORT}
                    native_shell_unset_variable(shell,base);native_shell_array_remove(shell,base)
                    native_shell_attribute_set(shell,base,attributes)
                } else {native_shell_attribute_set(shell,base,shell.compat.attributes[base]&~NATIVE_SHELL_NAMEREF)}
            }
        }
        native_shell_bool_set(shell,&shell.compat.declared,base,true)
        attributes:=shell.compat.attributes[base]
        if attributes&NATIVE_SHELL_READONLY!=0&&(assignment||remove&NATIVE_SHELL_READONLY!=0) {fmt.eprintf("%s: %s: readonly variable\n",args[0],base);status=1;continue}
        if attributes&remove&(NATIVE_SHELL_ASSOCIATIVE|NATIVE_SHELL_INDEXED)!=0 {fmt.eprintf("%s: %s: cannot destroy array variables in this way\n",args[0],base);status=1;continue}
        if flags&NATIVE_SHELL_ASSOCIATIVE!=0&&attributes&NATIVE_SHELL_INDEXED!=0||flags&NATIVE_SHELL_INDEXED!=0&&attributes&NATIVE_SHELL_ASSOCIATIVE!=0 {fmt.eprintf("%s: %s: cannot convert array type\n",args[0],base);status=1;continue}
        if flags&NATIVE_SHELL_LOWER!=0 {attributes&=~NATIVE_SHELL_UPPER};if flags&NATIVE_SHELL_UPPER!=0 {attributes&=~NATIVE_SHELL_LOWER}
        // readonly is applied after the initializer has been evaluated.
        native_shell_attribute_set(shell,base,(attributes|flags)&~remove&~(flags&NATIVE_SHELL_READONLY))
        if flags&(NATIVE_SHELL_INDEXED|NATIVE_SHELL_ASSOCIATIVE)!=0 {native_shell_array_ensure(shell,base,flags&NATIVE_SHELL_ASSOCIATIVE!=0)}
        error:=""
        if assignment {
            if strings.has_prefix(value,"(")&&strings.has_suffix(value,")") {error=native_shell_array_assign(shell,base,value,append_value)} else {
                if append_value {
                    old,_:=native_shell_value_get(shell,name)
                    if shell.compat.attributes[base]&NATIVE_SHELL_INTEGER!=0 {
                        if old=="" {old="0"};operand:=value;if operand=="" {operand="0"}
                        number,append_error:=native_shell_arithmetic(shell,strings.concatenate([]string{"(",old,") + (",operand,")"}))
                        if append_error!="" {error=append_error} else {value=fmt.tprintf("%d",number)}
                    } else {value=strings.concatenate([]string{old,value})}
                }
                if error!="" {fmt.eprintf("%s: %s\n",args[0],error);status=1;continue}
                if flags&NATIVE_SHELL_NAMEREF!=0 {native_shell_set_variable(shell,name,value)} else {error=native_shell_value_set(shell,name,value)}
            }
        }
        if error!="" {fmt.eprintf("%s: %s\n",args[0],error);status=1}
        native_shell_attribute_set(shell,base,shell.compat.attributes[base]|flags)
        if flags&NATIVE_SHELL_EXPORT!=0 {if exported_value,found:=native_shell_value_get(shell,base);found {native_shell_set_variable(shell,base,exported_value,true)}}
        if remove&NATIVE_SHELL_EXPORT!=0 {delete_key(&shell.exported,base)}
    }
    return status
}

native_shell_test_unary :: proc(shell:^Native_Shell,operator,value:string)->(bool,string) {
    switch operator {
    case "-n":return value!="",""
    case "-z":return value=="",""
    case "-v":
        base,key,indexed:=native_shell_reference(value)
        if indexed&&(key=="@"||key=="*") {if array,present:=shell.compat.arrays[base];present&&(!array.associative_mode||native_shell_compat_level(shell)<=51) {return len(native_shell_array_values(shell,base))>0,""}}
        _,exists:=native_shell_value_get(shell,value);return exists,""
    case "-R":return shell.compat.attributes[value]&NATIVE_SHELL_NAMEREF!=0,""
    case "-o":return shell.compat.options[value],""
    case "-t":number,valid:=strconv.parse_int(value);return valid&&bool(posix.isatty(posix.FD(number))),""
    }
    name:=strings.clone_to_cstring(value);info:posix.stat_t
    result:=posix.stat(name,&info)
    switch operator {
    case "-e","-a":return result==.OK,""
    case "-f":return result==.OK&&posix.S_ISREG(info.st_mode),""
    case "-d":return result==.OK&&posix.S_ISDIR(info.st_mode),""
    case "-s":return result==.OK&&info.st_size>0,""
    case "-N":return result==.OK&&(info.st_mtim.tv_sec>info.st_atim.tv_sec||info.st_mtim.tv_sec==info.st_atim.tv_sec&&info.st_mtim.tv_nsec>info.st_atim.tv_nsec),""
    case "-r":return posix.access(name,{.R_OK})==.OK,""
    case "-w":return posix.access(name,{.W_OK})==.OK,""
    case "-x":return posix.access(name,{.X_OK})==.OK,""
    case "-L","-h":return posix.lstat(name,&info)==.OK&&posix.S_ISLNK(info.st_mode),""
    case "-b":return result==.OK&&posix.S_ISBLK(info.st_mode),""
    case "-c":return result==.OK&&posix.S_ISCHR(info.st_mode),""
    case "-p":return result==.OK&&posix.S_ISFIFO(info.st_mode),""
    case "-S":return result==.OK&&posix.S_ISSOCK(info.st_mode),""
    case "-O":return result==.OK&&info.st_uid==posix.geteuid(),""
    case "-G":return result==.OK&&info.st_gid==posix.getegid(),""
    case "-u":return result==.OK&&.ISUID in info.st_mode,""
    case "-g":return result==.OK&&.ISGID in info.st_mode,""
    case "-k":return result==.OK&&.ISVXT in info.st_mode,""
    }
    return false,"unknown test operator"
}
native_shell_test_binary :: proc(shell:^Native_Shell,left,operator,right:string)->(bool,string) {
    switch operator {
    case "=","==":return left==right,""
    case "!=":return left!=right,""
    case "<",">":
        comparison:=0
        if shell.compat.options["posix"] {previous:=native_shell_text_locale(shell);comparison=int(libc.strcoll(strings.clone_to_cstring(left),strings.clone_to_cstring(right)));native_shell_text_locale_restore(previous)} else {if left<right {comparison= -1} else if left>right {comparison=1}}
        if operator=="<" {return comparison<0,""};return comparison>0,""
    case "-eq","-ne","-lt","-le","-gt","-ge":
        a,valid_a:=strconv.parse_i64(left);b,valid_b:=strconv.parse_i64(right)
        if !valid_a||!valid_b {return false,"integer expression expected"}
        switch operator {case "-eq":return a==b,"";case "-ne":return a!=b,"";case "-lt":return a<b,"";case "-le":return a<=b,"";case "-gt":return a>b,"";case "-ge":return a>=b,""}
    case "-nt","-ot","-ef":
        a,b:posix.stat_t;have_a:=posix.stat(strings.clone_to_cstring(left),&a)==.OK;have_b:=posix.stat(strings.clone_to_cstring(right),&b)==.OK
        if operator=="-ef" {return have_a&&have_b&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino,""}
        if operator=="-nt" {return have_a&&(!have_b||a.st_mtim.tv_sec>b.st_mtim.tv_sec||a.st_mtim.tv_sec==b.st_mtim.tv_sec&&a.st_mtim.tv_nsec>b.st_mtim.tv_nsec),""}
        return have_b&&(!have_a||a.st_mtim.tv_sec<b.st_mtim.tv_sec||a.st_mtim.tv_sec==b.st_mtim.tv_sec&&a.st_mtim.tv_nsec<b.st_mtim.tv_nsec),""
    }
    return false,"unknown test operator"
}
native_shell_test_expression :: proc(shell:^Native_Shell,args:[]string)->(bool,string) {
    if len(args)==0 {return false,""}
    if len(args)==1 {return args[0]!="",""}
    if args[0]=="!" {value,error:=native_shell_test_expression(shell,args[1:]);return !value,error}
    if len(args)==2 {return native_shell_test_unary(shell,args[0],args[1])}
    if len(args)==3 {if args[0]=="("&&args[2]==")" {return args[1]!="",""};if args[1]=="-a" {return args[0]!=""&&args[2]!="",""};if args[1]=="-o" {return args[0]!=""||args[2]!="",""};return native_shell_test_binary(shell,args[0],args[1],args[2])}
    depth:=0
    for word,i in args {if word=="(" {depth+=1};if word==")" {depth-=1};if depth==0&&word=="-o" {left,error:=native_shell_test_expression(shell,args[:i]);if error!="" {return false,error};right,other:=native_shell_test_expression(shell,args[i+1:]);return left||right,other}}
    depth=0
    for word,i in args {if word=="(" {depth+=1};if word==")" {depth-=1};if depth==0&&word=="-a" {left,error:=native_shell_test_expression(shell,args[:i]);if error!="" {return false,error};right,other:=native_shell_test_expression(shell,args[i+1:]);return left&&right,other}}
    if args[0]=="("&&args[len(args)-1]==")" {return native_shell_test_expression(shell,args[1:len(args)-1])}
    return false,"too many arguments"
}

Native_Shell_Read_Record :: struct {
    text:string,
    quoted:[]bool,
    complete,timed_out:bool,
    signal:int,
}

// POSIX read stops before assigning its variables when a trapped signal is
// received. Leave flags queued until terminal state has been restored, then
// execute the trap with the interrupted read's status.
native_shell_read_pending_signal :: proc(shell:^Native_Shell,trapped:bool=true)->int {
    for signal:=1;signal<len(native_shell_pending_signals);signal+=1 {
        if atomic.atomic_load(&native_shell_pending_signals[signal])==0 {continue}
        action,present:=shell.compat.traps[signal]
        if present&&action=="" {continue}
        if signal==int(posix.Signal.SIGINT)||trapped&&shell.compat.options["posix"]&&present {return signal}
    }
    return 0
}

native_shell_read_record :: proc(shell:^Native_Shell,fd:posix.FD,delimiter:u8='\n',raw:bool=false,count:int=0,timeout:f64= -1,exact:bool=false,limited:bool=false,preserve_null:bool=false,interrupt_traps:bool=false)->(record:Native_Shell_Read_Record) {
    shell.compat.read_interrupted=false
    // The prompt ignores SIGINT while the editor handles raw Ctrl+C itself.
    // A cooked builtin read must instead observe the terminal's real signal.
    // Queue it for the ordinary command boundary; never execute a trap here.
    previous:posix.sigaction_t;installed:=false
    action,explicit_ignore:=shell.compat.traps[int(posix.Signal.SIGINT)]
    ignored:=explicit_ignore&&action==""
    if !ignored {
        handler:posix.sigaction_t;handler.sa_handler=native_shell_trap_signal
        posix.sigemptyset(&handler.sa_mask)
        installed=posix.sigaction(.SIGINT,&handler,&previous)==.OK
    }
    defer {if installed {_=posix.sigaction(.SIGINT,&previous,nil)}}
    bytes:=make([dynamic]u8);quoted:=make([dynamic]bool);escaped:=false;started:=time.tick_now()
    characters,continuations:int
    locale:=shell.variables["LC_ALL"];if locale=="" {locale=shell.variables["LC_CTYPE"]};if locale=="" {locale=shell.variables["LANG"]}
    multibyte:=locale!=""&&locale!="C"&&locale!="POSIX"
    for !limited||characters<count||continuations>0 {
        if signal:=native_shell_read_pending_signal(shell,interrupt_traps);signal>0 {record.signal=signal;shell.compat.read_interrupted=true;break}
        if native_shell_cancelled() {break}
        wait:=100
        if timeout>=0 {left:=timeout-time.duration_seconds(time.tick_diff(started,time.tick_now()));if left<=0 {record.timed_out=true;break};wait=min(wait,max(1,int(left*1000)))}
        descriptor:=posix.pollfd{fd=fd,events={.IN}}
        result:=posix.poll(&descriptor,1,c.int(wait));if result==0 {continue};if result<0 {if posix.errno()==.EINTR {continue};break}
        byte:u8;amount:=posix.read(fd,&byte,1)
        if amount<0&&posix.errno()==.EINTR {continue};if amount<=0 {break}
        if byte==0&&!preserve_null&&(delimiter!=0||exact) {continue}
        protected:=escaped
        if escaped {escaped=false;if byte=='\n' {continue}} else {
            if !raw&&byte=='\\' {escaped=true;continue}
            if !exact&&byte==delimiter {record.complete=true;break}
        }
        append(&bytes,byte)
        append(&quoted,protected)
        if multibyte&&continuations>0&&byte>=0x80&&byte<=0xbf {continuations-=1} else {
            characters+=1;continuations=0
            if multibyte {if byte>=0xc2&&byte<=0xdf {continuations=1} else if byte>=0xe0&&byte<=0xef {continuations=2} else if byte>=0xf0&&byte<=0xf4 {continuations=3}}
        }
    }
    if limited&&characters>=count&&continuations==0 {record.complete=true}
    record.text=string(bytes[:]);record.quoted=quoted[:]
    return
}

Native_Shell_Read_Field :: struct {start,end:int}
native_shell_read_separator :: proc(text:string,at:int,separator:string,quoted:[]bool)->(present,whitespace:bool,width:int) {
    character,size:=utf8.decode_rune(text[at:]);width=max(1,size)
    if at<len(quoted)&&quoted[at] {return}
    for ch in separator {if ch==character {present=true;whitespace=character==' '||character=='\t'||character=='\n';return}}
    return
}

native_shell_read_fields :: proc(shell:^Native_Shell,text:string,quoted:[]bool=nil)->[]Native_Shell_Read_Field {
    separator,exists:=shell.variables["IFS"];if !exists {separator=" \t\n"}
    result:=make([dynamic]Native_Shell_Read_Field)
    if separator=="" {if text!="" {append(&result,Native_Shell_Read_Field{0,len(text)})};return result[:]}
    i:=0
    for i<len(text) {present,white,width:=native_shell_read_separator(text,i,separator,quoted);if !present||!white {break};i+=width}
    for i<len(text) {
        start:=i
        for i<len(text) {present,_,width:=native_shell_read_separator(text,i,separator,quoted);if present {break};i+=width}
        append(&result,Native_Shell_Read_Field{start,i})
        if i==len(text) {break}
        _,white,width:=native_shell_read_separator(text,i,separator,quoted);i+=width
        if white {
            for i<len(text) {present,next_white,next_width:=native_shell_read_separator(text,i,separator,quoted);if !present||!next_white {break};i+=next_width}
            if i<len(text) {present,next_white,next_width:=native_shell_read_separator(text,i,separator,quoted);if present&&!next_white {i+=next_width}}
        }
        for i<len(text) {present,next_white,next_width:=native_shell_read_separator(text,i,separator,quoted);if !present||!next_white {break};i+=next_width}
    }
    return result[:]
}

native_shell_read_array_name :: proc(shell:^Native_Shell,name:string)->(resolved:string,error:string) {
    resolved=name
    for depth:=0;depth<64;depth+=1 {
        if !native_shell_name(resolved) {return resolved,"invalid array identifier"}
        if shell.compat.attributes[resolved]&NATIVE_SHELL_NAMEREF==0 {return}
        target:=shell.variables[resolved]
        if target=="" {native_shell_attribute_set(shell,resolved,shell.compat.attributes[resolved]&~NATIVE_SHELL_NAMEREF);native_shell_unset_variable(shell,resolved);return}
        if target==resolved {return resolved,"circular name reference"}
        resolved=target
    }
    return resolved,"circular name reference"
}

native_shell_builtin_read :: proc(shell:^Native_Shell,args:[]string)->int {
    shell.compat.read_interrupted=false
    raw,silent,edit,filename_completion,exact,limited:bool;array,prompt,initial:string;delimiter:u8='\n';count:=0;fd:=posix.FD(0);timeout:f64= -1;i:=1
    if value:=shell.variables["TMOUT"];value!="" {number,valid:=strconv.parse_f64(value);if valid&&number>0&&number<=max(f64) {timeout=number}}
    for i<len(args)&&strings.has_prefix(args[i],"-")&&args[i]!="-" {
        option:=args[i];if option=="--" {i+=1;break}
        for at:=1;at<len(option);at+=1 {
            ch:=option[at]
            if ch=='r' {raw=true;continue};if ch=='s' {silent=true;continue}
            if ch=='e'||ch=='E' {edit=true;filename_completion=ch=='e';continue}
            if ch!='a'&&ch!='p'&&ch!='d'&&ch!='n'&&ch!='N'&&ch!='t'&&ch!='u'&&ch!='i' {fmt.eprintf("read: unsupported option -%c\n",ch);return 2}
            value:=option[at+1:];if value=="" {i+=1;if i==len(args) {fmt.eprintln("read: option requires an argument");return 2};value=args[i]}
            switch ch {
            case 'a':array=value
            case 'p':prompt=value
            case 'i':initial=value
            case 'd':if value=="" {delimiter=0} else {delimiter=value[0]}
            case 'n','N':number,ok:=strconv.parse_int(value);if !ok||number<0 {fmt.eprintln("read: invalid count");return 1};count=number;exact=ch=='N';limited=true
            case 't':number,ok:=strconv.parse_f64(value);if !ok||number<0||number!=number||number>max(f64) {fmt.eprintln("read: invalid timeout");return 1};timeout=number
            case 'u':number,ok:=strconv.parse_int(value);if !ok||number<0||number>int(max(posix.FD)) {fmt.eprintln("read: invalid descriptor");return 1};fd=posix.FD(number)
            }
            break
        }
        i+=1
    }
    if posix.fcntl(fd,.GETFD)<0 {fmt.eprintf("read: %d: invalid file descriptor\n",fd);return 1}
    // A zero timeout is a readiness probe; it consumes no bytes and performs
    // no assignments, even when a variable name is supplied.
    if timeout==0 {descriptor:=posix.pollfd{fd=fd,events={.IN}};if posix.poll(&descriptor,1,0)>0&&(.IN in descriptor.revents||.HUP in descriptor.revents) {return 0};return 1}
    if timeout>0 {info:posix.stat_t;if posix.fstat(fd,&info)==.OK&&posix.S_ISREG(info.st_mode) {timeout=-1}}
    record:Native_Shell_Read_Record
    saved:posix.termios;changed:=false
    editing:=edit&&bool(posix.isatty(fd))&&(!limited||count>0)
    if editing {
        original_stdin:=posix.FD(-1)
        if fd!=0 {original_stdin=posix.dup(0);if original_stdin<0&&posix.errno()!=.EBADF {return 1};if posix.dup2(fd,0)<0 {if original_stdin>=0 {posix.close(original_stdin)};return 1}}
        original_output:=native_shell_editor.output_fd
        native_shell_editor.output_fd=2
        quiet_output:=posix.FD(-1);edit_prompt:=prompt
        if silent {if prompt!="" {fmt.eprint(prompt)};quiet_output=posix.open("/dev/null",{.WRONLY,.CLOEXEC});if quiet_output>=0 {native_shell_editor.output_fd=quiet_output};edit_prompt=""}
        line,eof:=native_shell_readline(shell,edit_prompt,true,initial,filename_completion,delimiter,count,exact,timeout)
        if quiet_output>=0 {posix.close(quiet_output)}
        native_shell_editor.output_fd=original_output
        if fd!=0 {if original_stdin>=0 {posix.dup2(original_stdin,0);posix.close(original_stdin)} else {posix.close(0)}}
        record.text=line;record.complete=!eof;record.timed_out=native_shell_editor.timed_out;record.signal=native_shell_editor.interrupted_signal
        if record.signal>0 {shell.compat.read_interrupted=true}
        if shell.input_cancelled {shell.compat.read_interrupted=true;record.signal=int(posix.Signal.SIGINT)}
        if !raw {
            decoded:=make([dynamic]u8);quoted:=make([dynamic]bool)
            for at:=0;at<len(line);at+=1 {protected:=line[at]=='\\'&&at+1<len(line);if protected {at+=1;if line[at]=='\n' {continue}};append(&decoded,line[at]);append(&quoted,protected)}
            record.text=string(decoded[:]);record.quoted=quoted[:]
        }
    } else if posix.isatty(fd) {
        if prompt!="" {fmt.eprint(prompt)}
        if (silent||count>0||delimiter!='\n')&&posix.tcgetattr(fd,&saved)==.OK {
            current:=saved;if silent {current.c_lflag-={.ECHO}};if count>0||delimiter!='\n' {current.c_lflag-={.ICANON};current.c_cc[.VMIN]=1;current.c_cc[.VTIME]=0}
            changed=posix.tcsetattr(fd,.TCSANOW,&current)==.OK
        }
    }
    defer {if changed {_=posix.tcsetattr(fd,.TCSANOW,&saved)}}
    if !editing {record=native_shell_read_record(shell,fd,delimiter,raw,count,timeout,exact,limited,false,true)}
    if record.signal>0&&shell.compat.options["posix"] {
        if changed {_=posix.tcsetattr(fd,.TCSANOW,&saved);changed=false}
        shell.status=128+record.signal
        native_shell_dispatch_traps(shell)
        return 128+record.signal
    }
    if array!="" {
        resolved,resolve_error:=native_shell_read_array_name(shell,array);if resolve_error!="" {fmt.eprintf("read: %s: %s\n",array,resolve_error);return 1};array=resolved
        if shell.compat.attributes[array]&NATIVE_SHELL_READONLY!=0 {fmt.eprintf("read: %s: readonly variable\n",array);return 1}
        if existing:=shell.compat.arrays[array];existing!=nil&&existing.associative_mode {fmt.eprintf("read: %s: not an indexed array\n",array);return 1}
        native_shell_array_remove(shell,array);target:=native_shell_array_ensure(shell,array);native_shell_array_clear(shell,target)
        native_shell_attribute_set(shell,array,shell.compat.attributes[array]|NATIVE_SHELL_INDEXED)
        if exact {if record.text!="" {if error:=native_shell_value_set(shell,fmt.tprintf("%s[0]",array),record.text);error!="" {fmt.eprintf("read: %s\n",error);return 1}}} else {
            for field,index in native_shell_read_fields(shell,record.text,record.quoted) {if error:=native_shell_value_set(shell,fmt.tprintf("%s[%d]",array,index),record.text[field.start:field.end]);error!="" {fmt.eprintf("read: %s\n",error);return 1}}
        }
    } else {
        names:=args[i:]
        if len(names)==0 {if error:=native_shell_value_set(shell,"REPLY",record.text);error!="" {fmt.eprintf("read: %s\n",error);return 1}} else {
            fields:=native_shell_read_fields(shell,record.text,record.quoted)
            for name,index in names {
                value:=""
                if exact {if index==0 {value=record.text}} else if index<len(fields) {
                    field:=fields[index];value=record.text[field.start:field.end]
                    if index==len(names)-1&&index+1<len(fields) {
                        end:=len(record.text);separator,exists:=shell.variables["IFS"];if !exists {separator=" \t\n"}
                        for end>field.start {ch,width:=utf8.decode_last_rune(record.text[:end]);start:=end-max(1,width);present,white,_:=native_shell_read_separator(record.text,start,separator,record.quoted);if !present||!white||!(ch==' '||ch=='\t'||ch=='\n') {break};end=start}
                        value=record.text[field.start:end]
                    }
                }
                if error:=native_shell_value_set(shell,name,value);error!="" {fmt.eprintf("read: %s\n",error);return 1}
            }
        }
    }
    if shell.compat.read_interrupted {return 130};if record.complete {return 0};if record.timed_out {return 142};return 1
}
native_shell_builtin_mapfile :: proc(shell:^Native_Shell,args:[]string)->int {
    trim,explicit_offset:bool;delimiter:u8='\n';maximum,skip,offset:int;quantum:=5000;callback:string;fd:=posix.FD(0);i:=1
    for i<len(args)&&len(args[i])>1&&strings.has_prefix(args[i],"-") {
        option:=args[i];if option=="--" {i+=1;break}
        for at:=1;at<len(option);at+=1 {
            ch:=option[at];if ch=='t' {trim=true;continue}
            if ch!='d'&&ch!='n'&&ch!='O'&&ch!='s'&&ch!='u'&&ch!='C'&&ch!='c' {fmt.eprintf("%s: unsupported option -%c\n",args[0],ch);return 2}
            value:=option[at+1:];if value=="" {i+=1;if i==len(args) {fmt.eprintln("mapfile: option requires an argument");return 2};value=args[i]}
            if ch=='d' {if value=="" {delimiter=0} else {delimiter=value[0]}} else if ch=='C' {callback=value} else {
                number,ok:=strconv.parse_int(value);if !ok||number<0 {fmt.eprintln("mapfile: invalid number");return 1}
                switch ch {case 'n':maximum=number;case 'O':offset=number;explicit_offset=true;case 's':skip=number;case 'u':if number>int(max(posix.FD)) {fmt.eprintln("mapfile: invalid descriptor");return 1};fd=posix.FD(number);case 'c':if number==0 {fmt.eprintln("mapfile: invalid callback quantum");return 1};quantum=number}
            }
            break
        }
        i+=1
    }
    name:="MAPFILE";if i<len(args) {name=args[i];i+=1};if i!=len(args)||!native_shell_name(name) {fmt.eprintln("mapfile: expected one array name");return 2}
    resolved,resolve_error:=native_shell_read_array_name(shell,name);if resolve_error!="" {fmt.eprintf("mapfile: %s: %s\n",name,resolve_error);return 1};name=resolved
    if posix.fcntl(fd,.GETFD)<0 {fmt.eprintf("mapfile: %d: invalid file descriptor\n",fd);return 1}
    if shell.compat.attributes[name]&NATIVE_SHELL_READONLY!=0 {fmt.eprintf("mapfile: %s: readonly variable\n",name);return 1}
    if existing:=shell.compat.arrays[name];existing!=nil&&existing.associative_mode {fmt.eprintf("mapfile: %s: not an indexed array\n",name);return 1}
    if !explicit_offset {native_shell_array_remove(shell,name)};target:=native_shell_array_ensure(shell,name);if !explicit_offset {native_shell_array_clear(shell,target)}
    native_shell_attribute_set(shell,name,shell.compat.attributes[name]|NATIVE_SHELL_INDEXED)
    for _ in 0..<skip {record:=native_shell_read_record(shell,fd,delimiter,true);if shell.compat.read_interrupted {return 130};if !record.complete {return 0}}
    count:=0
    for maximum==0||count<maximum {
        record:=native_shell_read_record(shell,fd,delimiter,true,0,-1,false,false,true);line:=record.text
        if shell.compat.read_interrupted {return 130}
        if !record.complete&&line=="" {break}
        null:=strings.index_byte(line,0)
        if null>=0 {line=line[:null]} else if record.complete&&!trim&&delimiter!=0 {line=strings.concatenate([]string{line,string([]u8{delimiter})})}
        if callback!=""&&(count+1)%quantum==0 {
            native_shell_execute(shell,fmt.tprintf("%s %d %s",callback,offset+count,explorer_quote(line)))
            if shell.exiting||shell.compat.returning||native_shell_cancelled() {return shell.status}
        }
        if error:=native_shell_value_set(shell,fmt.tprintf("%s[%d]",name,offset+count),line);error!="" {fmt.eprintf("mapfile: %s\n",error);return 1}
        count+=1;if !record.complete {break}
    }
    return 0
}
native_shell_signal_number :: proc(name:string)->(int,bool) {
    value:=strings.to_upper(name,context.temp_allocator);if strings.has_prefix(value,"SIG") {value=value[3:]}
    if number,valid:=strconv.parse_int(value);valid&&number>=0&&number<65 {return number,true}
    switch value {case "EXIT":return 0,true;case "DEBUG":return -1,true;case "RETURN":return -2,true;case "ERR":return -3,true;case "IOT":return 6,true;case "CLD":return 17,true;case "POLL":return 29,true;case "UNUSED":return 31,true}
    for signal:=1;signal<=64;signal+=1 {if native_shell_signal_name(signal)==value {return signal,true}}
    if strings.has_prefix(value,"RTMIN+") {offset,ok:=strconv.parse_int(value[6:]);if ok&&offset>=0&&offset<=30 {return 34+offset,true}}
    if strings.has_prefix(value,"RTMAX-") {offset,ok:=strconv.parse_int(value[6:]);if ok&&offset>=0&&offset<=30 {return 64-offset,true}}
    return 0,false
}
native_shell_signal_name :: proc(signal:int)->string {
    names:=[]string{"EXIT","HUP","INT","QUIT","ILL","TRAP","ABRT","BUS","FPE","KILL","USR1","SEGV","USR2","PIPE","ALRM","TERM","STKFLT","CHLD","CONT","STOP","TSTP","TTIN","TTOU","URG","XCPU","XFSZ","VTALRM","PROF","WINCH","IO","PWR","SYS"}
    if signal>=0&&signal<len(names) {return names[signal]}
    if signal==34 {return "RTMIN"};if signal==64 {return "RTMAX"}
    if signal>34&&signal<50 {return fmt.aprintf("RTMIN+%d",signal-34)}
    if signal>=50&&signal<64 {return fmt.aprintf("RTMAX-%d",64-signal)}
    return ""
}
native_shell_builtin_trap :: proc(shell:^Native_Shell,args:[]string)->int {
    printing,actions,listing:bool;i:=1
    for i<len(args)&&len(args[i])>1&&args[i][0]=='-' {
        if args[i]=="--" {i+=1;break}
        for flag in transmute([]u8)args[i][1:] {
            switch flag {case 'p':printing=true;case 'P':actions=true;case 'l':listing=true;case:fmt.eprintf("trap: -%c: invalid option\n",flag);return 2}
        }
        i+=1
    }
    if printing&&actions {fmt.eprintln("trap: cannot specify both -p and -P");return 2}
    if actions&&i==len(args) {fmt.eprintln("trap: -P requires at least one signal name");return 2}
    if listing {arguments:=make([dynamic]string);append(&arguments,"kill","-l");append(&arguments,..args[i:]);return native_shell_kill_builtin(shell,arguments[:])}
    if printing||actions||i==len(args) {
        signals:=make([dynamic]int);status:=0
        if i==len(args) {
            for number:=0;number<=64;number+=1 {if _,exists:=shell.compat.traps[number];exists {append(&signals,number)}}
            for number in ([]int{-1,-3,-2}) {if _,exists:=shell.compat.traps[number];exists {append(&signals,number)}}
        } else {
            for name in args[i:] {number,ok:=native_shell_signal_number(name);if ok {append(&signals,number)} else {fmt.eprintf("trap: %s: invalid signal specification\n",name);status=1}}
        }
        for number in signals {
            command,exists:=shell.compat.traps[number];if !exists {continue}
            if actions {fmt.println(command);continue}
            name:=native_shell_signal_name(number)
            switch number {case -1:name="DEBUG";case -2:name="RETURN";case -3:name="ERR"}
            if number>0&&!shell.compat.options["posix"] {name=strings.concatenate([]string{"SIG",name})}
            quoted,_:=strings.replace_all(command,"'","'\\''")
            fmt.printf("trap -- '%s' %s\n",quoted,name)
        }
        return status
    }
    command:=args[i];i+=1;reset:=command=="-"
    if i==len(args) {if _,valid:=native_shell_signal_number(command);valid&&(!shell.compat.options["posix"]||native_shell_digits(command)) {i-=1;reset=true} else {fmt.eprintln("trap: missing signal");return 2}}
    status:=0
    for signal_name in args[i:] {
        number,valid:=native_shell_signal_number(signal_name)
        if !valid {fmt.eprintf("trap: %s: invalid signal\n",signal_name);status=1;continue}
        if old,exists:=shell.compat.traps[number];exists {delete(old,shell.allocator);delete_key(&shell.compat.traps,number)}
        delete_key(&shell.compat.trap_owners,number);delete_key(&shell.compat.trap_depths,number)
        if !reset {shell.compat.traps[number]=strings.clone(command,shell.allocator);shell.compat.trap_owners[number]=posix.getpid();shell.compat.trap_depths[number]=shell.compat.function_depth}
        if number>0&&number!=9&&number!=19&&!native_shell_trap_install(shell,number,!reset&&command=="") {fmt.eprintf("trap: %s: cannot install handler\n",signal_name);status=1}
    }
    return status
}

native_shell_builtin_getopts :: proc(shell:^Native_Shell,args:[]string)->int {
    if len(args)<3 {fmt.eprintln("getopts: usage: getopts optstring name [arg ...]");return 2}
    options:=args[1];name:=args[2];arguments:=shell.compat.parameters;if len(args)>3 {arguments=args[3:]}
    optind:=1;if value,exists:=shell.variables["OPTIND"];exists {number,valid:=strconv.parse_int(value);if valid&&number>0 {optind=number}}
    if optind==1&&shell.compat.getopts_last_index!=1 {shell.compat.getopts_index=0}
    shell.compat.getopts_last_index=optind
    if optind>len(arguments)||arguments[optind-1]=="--"||len(arguments[optind-1])<2||arguments[optind-1][0]!='-' {
        if optind<=len(arguments)&&arguments[optind-1]=="--" {optind+=1}
        native_shell_set_variable(shell,"OPTIND",fmt.tprintf("%d",optind));native_shell_set_variable(shell,name,"?");return 1
    }
    word:=arguments[optind-1];at:=shell.compat.getopts_index;if at<1 {at=1}
    if at>=len(word) {at=1;optind+=1;if optind>len(arguments) {native_shell_set_variable(shell,"OPTIND",fmt.tprintf("%d",optind));return 1};word=arguments[optind-1]}
    option:=word[at];at+=1;silent:=strings.has_prefix(options,":");found:=strings.index_byte(options,option)
    native_shell_unset_variable(shell,"OPTARG")
    result:=string([]u8{option})
    if found<0||option==':' {
        result="?";if silent {native_shell_set_variable(shell,"OPTARG",string([]u8{option}))} else {fmt.eprintf("getopts: illegal option -- %c\n",option)}
    } else if found+1<len(options)&&options[found+1]==':' {
        value:=word[at:]
        if value=="" {optind+=1;if optind<=len(arguments) {value=arguments[optind-1]} else {result="?";if silent {result=":";native_shell_set_variable(shell,"OPTARG",string([]u8{option}))} else {fmt.eprintf("getopts: option requires an argument -- %c\n",option)}}}
        if optind<=len(arguments) {native_shell_set_variable(shell,"OPTARG",value)}
        at=len(word)
    }
    if at>=len(word) {optind+=1;at=0}
    shell.compat.getopts_index=at;shell.compat.getopts_last_index=optind
    native_shell_set_variable(shell,"OPTIND",fmt.tprintf("%d",optind));native_shell_set_variable(shell,name,result);return 0
}
native_shell_builtin_umask :: proc(args:[]string)->int {
    old:=posix.umask({});_=posix.umask(old)
    if len(args)==1||(len(args)==2&&args[1]=="-p") {if len(args)==2 {fmt.print("umask ")};fmt.printf("%04o\n",transmute(posix._mode_t)old);return 0}
    if len(args)==2&&args[1]=="-S" {
        permissions:=u32(~transmute(posix._mode_t)old)&0o777
        labels:=[]string{"u=","g=","o="}
        for shift,i in ([]u32{6,3,0}) {if i>0 {fmt.print(",")};fmt.print(labels[i]);if permissions&(4<<shift)!=0 {fmt.print("r")};if permissions&(2<<shift)!=0 {fmt.print("w")};if permissions&(1<<shift)!=0 {fmt.print("x")}};fmt.println();return 0
    }
    if len(args)!=2 {fmt.eprintln("umask: expected one mask");return 2}
    value:=args[1];mask:u32
    if value!=""&&value[0]>='0'&&value[0]<='7' {for byte in transmute([]u8)value {if byte<'0'||byte>'7' {fmt.eprintln("umask: invalid octal mask");return 1};mask=mask*8+u32(byte-'0')};if mask>0o777 {return 1}} else {
        permissions:=u32(~transmute(posix._mode_t)old)&0o777
        source:=value
        for clause in strings.split_iterator(&source,",") {
            at:=0;who:u32
            for at<len(clause) {ch:=clause[at];if ch=='u' {who|=0o700} else if ch=='g' {who|=0o070} else if ch=='o' {who|=0o007} else if ch=='a' {who|=0o777} else {break};at+=1}
            if who==0 {who=0o777};if at>=len(clause) {return 1}
            for at<len(clause) {
                operator:=clause[at];at+=1;bits:u32
                if operator!='='&&operator!='+'&&operator!='-' {return 1}
                for at<len(clause)&&clause[at]!='='&&clause[at]!='+'&&clause[at]!='-' {
                    ch:=clause[at];at+=1
                    switch ch {
                    case 'r':bits|=0o444;case 'w':bits|=0o222;case 'x':bits|=0o111
                    case 'u':bits|=((permissions>>6)&7)*0o111
                    case 'g':bits|=((permissions>>3)&7)*0o111
                    case 'o':bits|=(permissions&7)*0o111
                    case:return 1
                    }
                }
                bits&=who;switch operator {case '=':permissions=(permissions&~who)|bits;case '+':permissions|=bits;case '-':permissions&=~bits}
            }
        }
        mask=(~permissions)&0o777
    }
    _=posix.umask(transmute(posix.mode_t)posix._mode_t(mask));return 0
}

native_shell_compat_builtin :: proc(shell:^Native_Shell,args:[]string)->(int,bool) {
    if len(args)==0 {return 0,false}
    switch args[0] {
    case "set":return native_shell_builtin_set(shell,args),true
    case "shift":
        if len(args)>2 {fmt.eprintln("shift: too many arguments");return 1,true}
        count:=1;if len(args)==2 {number,valid:=strconv.parse_int(args[1]);if !valid||number<0 {fmt.eprintln("shift: invalid count");return 1,true};count=number}
        if count>len(shell.compat.parameters) {if shell.compat.shopts["shift_verbose"] {fmt.eprintln("shift: shift count out of range")};return 1,true};shell.compat.parameters=shell.compat.parameters[count:];return 0,true
    case "getopts":return native_shell_builtin_getopts(shell,args),true
    case "declare","typeset","local","readonly":return native_shell_builtin_declare(shell,args),true
    case "alias":return native_shell_alias_builtin(shell,args),true
    case "unalias":
        if len(args)>1&&args[1]=="-a" {for name,value in shell.compat.aliases {delete_key(&shell.compat.aliases,name);delete(name,shell.allocator);delete(value,shell.allocator)};return 0,true}
        status:=0;for name in args[1:] {if _,exists:=shell.compat.aliases[name];!exists {fmt.eprintf("unalias: %s: not found\n",name);status=1} else {native_shell_owned_text_remove(&shell.compat.aliases,name,shell.allocator)}};return status,true
    case "shopt":return native_shell_builtin_shopt(shell,args),true
    case "read":return native_shell_builtin_read(shell,args),true
    case "readarray","mapfile":return native_shell_builtin_mapfile(shell,args),true
    case "test","[":
        values:=args[1:];if args[0]=="[" {if len(values)==0||values[len(values)-1]!="]" {fmt.eprintln("[: missing ]");return 2,true};values=values[:len(values)-1]}
        value,error:=native_shell_test_expression(shell,values);if error!="" {fmt.eprintf("%s: %s\n",args[0],error);return 2,true};if value {return 0,true};return 1,true
    case "let":
        if len(args)==1 {fmt.eprintln("let: expression required");return 1,true}
        result:i64;for expression in args[1:] {value,error:=native_shell_arithmetic(shell,expression);if error!="" {fmt.eprintf("let: %s\n",error);return 1,true};result=value};if result==0 {return 1,true};return 0,true
    case "break","continue":
        if len(args)>2 {fmt.eprintf("%s: too many arguments\n",args[0]);return 1,true}
        depth:=1;if len(args)==2 {number,valid:=strconv.parse_int(args[1]);if !valid||number<1 {fmt.eprintf("%s: invalid loop count\n",args[0]);return 1,true};depth=number}
        if shell.compat.loop_depth==0 {fmt.eprintf("%s: only meaningful in a loop\n",args[0]);return 0,true}
        depth=min(depth,shell.compat.loop_depth);if args[0]=="break" {shell.compat.break_depth=depth} else {shell.compat.continue_depth=depth};return 0,true
    case "return":
        if shell.compat.function_depth==0&&shell.source_depth==0 {fmt.eprintln("return: can only return from a function or sourced script");return 1,true}
        if len(args)>2 {fmt.eprintln("return: too many arguments");return 1,true};status:=shell.status
        if len(args)==2 {number,valid:=strconv.parse_int(args[1]);if !valid {fmt.eprintln("return: numeric argument required");return 2,true};status=number&255}
        shell.compat.returning=true;shell.compat.return_status=status;return status,true
    case "builtin":
        if len(args)==1 {return 0,true};if !native_shell_builtin_name(args[1]) {fmt.eprintf("builtin: %s: not a shell builtin\n",args[1]);return 1,true};return native_shell_builtin(shell,args[1:]),true
    case "trap":return native_shell_builtin_trap(shell,args),true
    case "dirs","pushd","popd":return native_shell_directory_stack_builtin(shell,args),true
    case "umask":return native_shell_builtin_umask(args),true
    case "ulimit":return native_shell_system_ulimit(shell,args),true
    case "caller":
        if len(args)>2 {fmt.eprintln("caller: too many arguments");return 1,true}
        depth:=0;if len(args)==2 {number,valid:=strconv.parse_int(args[1]);if !valid||number<0 {return 1,true};depth=number}
        at:=len(shell.compat.call_names)-1-depth
        if at<0||at==0&&!shell.compat.script_mode {return 1,true}
        function:="main";source:=shell.compat.top_source
        if at>0 {function=shell.compat.call_names[at-1];source=shell.compat.call_sources[at-1]}
        if len(args)==1 {fmt.printf("%d %s\n",shell.compat.call_lines[at],source)} else {fmt.printf("%d %s %s\n",shell.compat.call_lines[at],function,source)}
        return 0,true
    case "suspend":
        force:=len(args)==2&&args[1]=="-f"
        if len(args)>2||len(args)==2&&!force {fmt.eprintln("suspend: usage: suspend [-f]");return 2,true}
        if shell.compat.shopts["login_shell"]&&!force {fmt.eprintln("suspend: cannot suspend a login shell");return 1,true}
        if posix.kill(posix.getpid(),.SIGSTOP)!=.OK {fmt.eprintf("suspend: %v\n",posix.errno());return 1,true}
        return 0,true
    case "logout":
        if !shell.compat.shopts["login_shell"] {fmt.eprintln("logout: not a login shell: use exit");return 1,true};shell.exiting=true;shell.exit_status=shell.status;return shell.status,true
    case "kill":return native_shell_kill_builtin(shell,args),true
    case "hash":return native_shell_hash_builtin(shell,args),true
    case "enable":return native_shell_enable_builtin(shell,args),true
    case "times":
        stamp:posix.tms;_=posix.times(&stamp);ticks:=f64(posix.sysconf(._CLK_TCK));if ticks<=0 {ticks=100}
        for pair in ([][2]posix.clock_t{{stamp.tms_utime,stamp.tms_stime},{stamp.tms_cutime,stamp.tms_cstime}}) {for ticks_value,i in pair {if i>0 {fmt.print(" ")};seconds:=f64(ticks_value)/ticks;fmt.printf("%dm%.3fs",int(seconds/60),seconds-f64(int(seconds/60))*60)};fmt.println()};return 0,true
    }
    return 0,false
}


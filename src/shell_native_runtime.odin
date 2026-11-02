#+build linux
package main

import "core:fmt"
import "core:c"
import "core:os"
import "core:strings"
import "core:strconv"
import atomic "core:sync"
import posix "core:sys/posix"

Native_Shell_Option_Change :: struct {name:string,enabled,shopt:bool}
Native_Shell_Invocation :: struct {
    command,script,rcfile,arg0:string,
    parameters:[]string,
    changes:[dynamic]Native_Shell_Option_Change,
    interactive,stdin,login,norc,noprofile,command_mode,restricted,help,version:bool,
    noediting,debugger,dump_strings,dump_po_strings:bool,
    option_query:string,
}

native_shell_dump_strings_enabled:bool
native_shell_dump_po_strings:bool
native_shell_dump_line_count :: proc(source:string)->int {
    if !native_shell_dump_strings_enabled {return 0}
    return strings.count(source,"\n")
}
native_shell_dump_translation :: proc(message,prefix:string,line_offset:int=0) {
    if !native_shell_dump_strings_enabled {return}
    if !native_shell_dump_po_strings {fmt.printf("\"%s\"\n",message);return}
    encoded:=make([dynamic]u8)
    for byte in transmute([]u8)message {
        switch byte {
        case '\\':append(&encoded,"\\\\")
        case '"':append(&encoded,"\\\"")
        case '\n':append(&encoded,"\\n")
        case '\r':append(&encoded,"\\r")
        case '\t':append(&encoded,"\\t")
        case:append(&encoded,byte)
        }
    }
    source:="-c";line:=1+line_offset+strings.count(prefix,"\n")
    if shell:=native_shell_parser_shell;shell!=nil&&shell.compat!=nil {
        if shell.compat.current_source!="" {source=shell.compat.current_source}
        line+=max(1,shell.compat.current_line)-1
    }
    fmt.printf("#: %s:%d\nmsgid \"%s\"\nmsgstr \"\"\n",source,line,string(encoded[:]))
}

native_shell_runtime_source_state :: proc(source:string)->(bool,bool) {
    // Completeness probes parse the same input several times. Translation
    // extraction belongs to the final parse, not those speculative probes.
    dumping:=native_shell_dump_strings_enabled
    native_shell_dump_strings_enabled=false
    defer {native_shell_dump_strings_enabled=dumping}
    return native_shell_source_state(source)
}

native_shell_short_option :: proc(flag:u8)->string {
    switch flag {
    case 'e':return "errexit";case 'u':return "nounset";case 'x':return "xtrace"
    case 'v':return "verbose";case 'f':return "noglob";case 'C':return "noclobber"
    case 'a':return "allexport";case 'n':return "noexec";case 'B':return "braceexpand"
    case 'H':return "histexpand";case 'h':return "hashall";case 'm':return "monitor"
    case 'b':return "notify";case 'P':return "physical";case 'E':return "errtrace"
    case 'T':return "functrace";case 'k':return "keyword";case 't':return "onecmd"
    case 'p':return "privileged";case 'r':return "restricted"
    }
    return ""
}

native_shell_invocation :: proc(arguments:[]string)->(invocation:Native_Shell_Invocation,error:string) {
    invocation.arg0="terminal+"
    index:=0;force_interactive,interactive_explicit:bool
    for index<len(arguments) {
        argument:=arguments[index]
        if argument=="--" {index+=1;break}
        if argument=="-" {index+=1;break}
        if argument=="+" {index+=1;continue}
        if len(argument)<2||(argument[0]!='-'&&argument[0]!='+') {break}
        switch argument {
        case "--noprofile":invocation.noprofile=true;index+=1;continue
        case "--norc":invocation.norc=true;index+=1;continue
        case "--login":invocation.login=true;index+=1;continue
        case "--restricted":invocation.restricted=true;index+=1;continue
        case "--noediting":invocation.noediting=true;index+=1;continue
        case "--debugger":invocation.debugger=true;index+=1;continue
        // GNU Bash 5.3 retains these legacy switches without changing normal
        // command execution; --debugger is the separate debugger interface.
        case "--debug","--pretty-print":index+=1;continue
        case "--verbose":append(&invocation.changes,Native_Shell_Option_Change{"verbose",true,false});index+=1;continue
        case "--dump-strings":invocation.dump_strings=true;index+=1;continue
        case "--dump-po-strings":invocation.dump_strings=true;invocation.dump_po_strings=true;index+=1;continue
        case "--help":invocation.help=true;return invocation,""
        case "--version":invocation.version=true;return invocation,""
        case "--posix":append(&invocation.changes,Native_Shell_Option_Change{"posix",true,false});index+=1;continue
        case "--rcfile","--init-file":
            if index+1>=len(arguments) {return invocation,"startup file option requires a filename"}
            index+=1;invocation.rcfile=arguments[index];index+=1;continue
        }
        if strings.has_prefix(argument,"--") {return invocation,fmt.tprintf("unknown shell option: %s",argument)}
        enabled:=argument[0]=='-'
        for at:=1;at<len(argument);at+=1 {
            flag:=argument[at]
            if flag=='i' {force_interactive=enabled;interactive_explicit=true;continue}
            if flag=='l' {invocation.login=enabled;continue}
            if flag=='s' {invocation.stdin=enabled;continue}
            if flag=='r' {invocation.restricted=enabled;continue}
            if flag=='D' {invocation.dump_strings=enabled;continue}
            if flag=='c' {
                if index+1>=len(arguments) {return invocation,"-c requires a command"}
                index+=1;invocation.command=arguments[index];invocation.command_mode=true
                continue
            }
            if flag=='o'||flag=='O' {
                if index+1>=len(arguments) {
                    if flag=='o' {invocation.option_query="-o" if enabled else "+o"} else {invocation.option_query="-O" if enabled else "+O"}
                    break
                }
                index+=1;append(&invocation.changes,Native_Shell_Option_Change{arguments[index],enabled,flag=='O'});continue
            }
            name:=native_shell_short_option(flag)
            if name=="" {return invocation,fmt.tprintf("invalid shell option: %c",flag)}
            append(&invocation.changes,Native_Shell_Option_Change{name,enabled,false})
        }
        index+=1
        if invocation.command_mode {break}
    }
    if invocation.command_mode {
        if index<len(arguments) {invocation.arg0=arguments[index];index+=1}
        invocation.parameters=arguments[index:]
    } else if !invocation.stdin&&index<len(arguments) {
        invocation.script=arguments[index];invocation.arg0=invocation.script;index+=1
        invocation.parameters=arguments[index:]
    } else {invocation.parameters=arguments[index:]}
    invocation.interactive=force_interactive||(!interactive_explicit&&!invocation.command_mode&&invocation.script==""&&bool(posix.isatty(0))&&bool(posix.isatty(2)))
    return
}

// Read only through the next complete command. The next line remains in the
// descriptor for commands such as `read`, rather than being consumed by a
// script-wide read-ahead buffer.
native_shell_run_stream :: proc(shell:^Native_Shell,fd:posix.FD,owned:bool=false,fatal_syntax:bool=false)->int {
    input_fd:=fd
    if fd!=0 {append(&shell.script_fds,&input_fd)}
    defer {if fd!=0 {pop(&shell.script_fds)};if owned&&input_fd>=0 {posix.close(input_fd)}}
    input:=make([dynamic]u8);defer delete(input)
    executed:=false
    line_number:=max(1,shell.compat.current_line)
    first_line:=line_number
    for !shell.exiting&&!shell.compat.returning&&shell.compat.break_depth==0&&shell.compat.continue_depth==0 {
        if native_shell_cancelled() {shell.exiting=true;shell.exit_status=128+int(atomic.atomic_load(&native_shell_termination_signal));break}
        byte:u8
        amount:=posix.read(input_fd,&byte,1)
        if amount<0 {if posix.errno()==.EINTR {native_shell_dispatch_traps(shell);continue};shell.status=1;break}
        if amount==0 {
            if len(input)>0 {
                _,present:=native_shell_runtime_source_state(string(input[:]))
                if present {
                    shell.compat.current_line=first_line;syntax_error:bool
                    native_shell_execute(shell,string(input[:]),&syntax_error);executed=true
                    if syntax_error&&fatal_syntax&&!shell.interactive {shell.exiting=true;shell.exit_status=2}
                }
            }
            if !executed {shell.status=0}
            break
        }
        append(&input,byte)
        if byte=='\n' {
            line_number+=1
            incomplete,present:=native_shell_runtime_source_state(string(input[:]))
            if !incomplete {
                syntax_error:bool
                if present {shell.compat.current_line=first_line;native_shell_execute(shell,string(input[:]),&syntax_error);executed=true}
                clear(&input)
                first_line=line_number
                if syntax_error {if fatal_syntax&&!shell.interactive {shell.exiting=true;shell.exit_status=2};break}
                if present&&shell.compat.options["onecmd"] {break}
            }
        }
    }
    return shell.status
}

native_shell_run_file :: proc(shell:^Native_Shell,path:string)->int {
    name:=strings.clone_to_cstring(path,context.temp_allocator)
    fd:=posix.open(name,{.CLOEXEC})
    if fd<0 {fmt.eprintf("terminal+: cannot read %s: %v\n",path,posix.errno());shell.status=1;return 1}
    header:[128]u8
    amount:=posix.pread(fd,raw_data(header[:]),len(header),0)
    if amount>0&&strings.index_byte(string(header[:int(amount)]),0)>=0 {
        posix.close(fd);fmt.eprintf("terminal+: %s: cannot execute binary file\n",path);shell.status=126;return 126
    }
    source_path:=path
    if shell.compat.shopts["bash_source_fullpath"] {if absolute,absolute_error:=os.get_absolute_path(path,context.allocator);absolute_error==nil {source_path=absolute}}
    previous_source,previous_line:=shell.compat.current_source,shell.compat.current_line
    shell.compat.current_source=source_path;shell.compat.current_line=1
    defer {shell.compat.current_source=previous_source;shell.compat.current_line=previous_line}
    if shell.source_depth==0 {shell.compat.top_source=source_path;shell.compat.script_mode=true}
    return native_shell_run_stream(shell,fd,true,shell.source_depth==0)
}

native_shell_run_source :: proc(shell:^Native_Shell,source:string,fatal_syntax:bool=false)->int {
    fd:=native_shell_here_fd(source)
    if fd<0 {fmt.eprintln("terminal+: cannot open shell command input");shell.status=1;return 1}
    return native_shell_run_stream(shell,fd,true,fatal_syntax)
}

native_shell_protect_readers :: proc(shell:^Native_Shell,redirects:[]Native_Shell_Prepared_Redirect)->bool {
    if len(shell.script_fds)==0 {return true}
    mentioned:=make(map[int]bool)
    for redirect in redirects {
        mentioned[redirect.fd]=true
        if redirect.operator==">&"||redirect.operator=="<&" {
            target:=strings.trim_suffix(redirect.target,"-")
            if number,valid:=strconv.parse_int(target);valid&&number>=0 {mentioned[number]=true}
        }
    }
    for reader in shell.script_fds {
        if reader==nil||reader^<0||!mentioned[int(reader^)] {continue}
        minimum:=3
        for {
            candidate:=posix.fcntl(reader^,.DUPFD_CLOEXEC,c.int(minimum))
            if candidate<0 {fmt.eprintln("terminal+: cannot preserve shell script input");return false}
            if !mentioned[int(candidate)] {posix.close(reader^);reader^=posix.FD(candidate);break}
            posix.close(posix.FD(candidate));minimum=int(candidate)+1
        }
    }
    return true
}

native_shell_import_functions :: proc(shell:^Native_Shell) {
    for variable,value in shell.variables {
        if !strings.has_prefix(variable,"BASH_FUNC_")||!strings.has_suffix(variable,"%%")||!strings.has_prefix(value,"()") {continue}
        name:=variable[len("BASH_FUNC_"):len(variable)-2]
        if !native_shell_function_name(name) {continue}
        definition:=strings.concatenate([]string{name," ",value})
        program,error:=native_shell_parse(definition)
        // Import only a single definition, never a trailing command supplied
        // through the environment. Function bodies remain inert until called.
        if error!=""||len(program.pipelines)!=1||len(program.pipelines[0].commands)!=1 {continue}
        compound:=program.pipelines[0].commands[0].compound
        if compound==nil||compound.kind!="function"||compound.name!=name {continue}
        native_shell_owned_text_set(&shell.compat.functions,name,compound.source,shell.allocator)
        native_shell_attribute_set(shell,variable,NATIVE_SHELL_EXPORT)
    }
}

native_shell_startup_file :: proc(shell:^Native_Shell,path:string)->bool {
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil||info.type!=.Regular {return false}
    shell.source_depth+=1;defer {shell.source_depth-=1}
    native_shell_run_file(shell,path)
    // `return` is local to the startup file that was sourced.
    if shell.compat.returning {shell.status=shell.compat.return_status;shell.compat.returning=false}
    return true
}

native_shell_startup :: proc(shell:^Native_Shell,invocation:Native_Shell_Invocation) {
    if shell.compat.options["posix"] {
        if shell.interactive&&!shell.compat.options["privileged"] {
            if raw:=shell.variables["ENV"];raw!="" {path,error:=native_shell_expand_assignment(shell,raw);if error==""&&path!="" {native_shell_startup_file(shell,path)}}
        }
        return
    }
    home:=strings.clone(shell.variables["HOME"]);defer delete(home)
    if invocation.login&&!invocation.noprofile {
        native_shell_startup_file(shell,"/etc/profile")
        delete(home);home=strings.clone(shell.variables["HOME"])
        if home!="" {for file in ([]string{".bash_profile",".bash_login",".profile"}) {if native_shell_startup_file(shell,fmt.tprintf("%s/%s",home,file)) {break}}}
    }
    if shell.interactive&&!invocation.login&&!invocation.norc {
        native_shell_startup_file(shell,"/etc/bash.bashrc")
        delete(home);home=strings.clone(shell.variables["HOME"])
        rc:=invocation.rcfile
        if rc==""&&home!="" {rc=fmt.tprintf("%s/.bashrc",home)}
        if rc!="" {native_shell_startup_file(shell,rc)}
    }
    if !shell.interactive&&!shell.compat.options["privileged"] {
        if raw:=shell.variables["BASH_ENV"];raw!="" {
            path,error:=native_shell_expand_assignment(shell,raw)
            if error==""&&path!="" {native_shell_startup_file(shell,path)}
        }
    }
    if shell.interactive {
        if config,error:=os.user_config_dir(context.temp_allocator);error==nil {native_shell_startup_file(shell,fmt.tprintf("%s/terminal-plus/shellrc",config))}
    }
}

native_shell_prompt_command :: proc(shell:^Native_Shell) {
    saved:=shell.status
    commands:=native_shell_array_values(shell,"PROMPT_COMMAND")
    if len(commands)==0 {if command:=shell.variables["PROMPT_COMMAND"];command!="" {commands=[]string{command}}}
    owned:=make([]string,len(commands));defer delete(owned)
    for command,i in commands {owned[i]=strings.clone(command)}
    defer {for command in owned {delete(command)}}
    for command in owned {if command!=""&&!shell.exiting {native_shell_execute(shell,command)}}
    shell.status=saved
}

native_shell_readline_stream :: proc(shell:^Native_Shell)->(string,bool) {
    prompt:=native_shell_prompt(shell,shell.continuation);defer delete(prompt)
    visible:=native_shell_prompt_visible(prompt);defer delete(visible)
    bytes:=transmute([]u8)visible
    for len(bytes)>0 {count:=posix.write(2,raw_data(bytes),len(bytes));if count<0&&posix.errno()==.EINTR {continue};if count<=0 {break};bytes=bytes[int(count):]}
    input:=make([dynamic]u8);defer delete(input)
    for {
        if native_shell_cancelled() {return "",true}
        byte:u8;count:=posix.read(0,&byte,1)
        if count<0 {if posix.errno()==.EINTR {native_shell_dispatch_traps(shell);continue};return "",true}
        if count==0 {if len(input)>0 {return strings.clone(string(input[:])),false};return "",true}
        if byte=='\n' {return strings.clone(string(input[:])),false}
        append(&input,byte)
    }
}

native_shell_main :: proc(arguments:[]string)->int {
    invocation,error:=native_shell_invocation(arguments)
    if error!="" {fmt.eprintln("terminal+:",error);return 2}
    defer delete(invocation.changes)
    if invocation.help {
        fmt.println(`Terminal+ native Odin shell
Usage: terminal+ --native-shell [options] [script [arguments...]]
       terminal+ --native-shell [-ilr] [-c command [name [arguments...]]]

Options: --noprofile --norc --rcfile FILE --login --restricted --posix
         --noediting --debugger --verbose --dump-strings --dump-po-strings
         --help --version; -o OPTION and -O SHOPT; Bash-style short options.
Use the help builtin to list native shell syntax and builtins.`)
        return 0
    }
    if invocation.version {fmt.println("Terminal+ native Odin shell (Bash 5.3 language compatibility)");return 0}
    shell:Native_Shell
    native_shell_init(&shell,invocation.interactive)
    defer native_shell_destroy(&shell)
    defer native_shell_mail_destroy(&shell)
    shell.compat.arg0=invocation.arg0;shell.compat.parameters=invocation.parameters
    native_shell_set_variable(&shell,"BASH_ARGV0",invocation.arg0)
    if invocation.command_mode {native_shell_set_variable(&shell,"BASH_EXECUTION_STRING",invocation.command)}
    shell.compat.command_mode=invocation.command_mode
    shell.compat.stdin_mode=invocation.stdin||(!invocation.command_mode&&invocation.script=="")
    shell.compat.shopts["login_shell"]=invocation.login
    shell.compat.shopts["restricted_shell"]=invocation.restricted
    if raw,present:=shell.variables["BASH_COMPAT"];present {native_shell_compat_set(&shell,raw)}
    if _,present:=shell.variables["POSIXLY_CORRECT"];present {native_shell_option_set(&shell,"posix",true)}
    for change in invocation.changes {
        if change.shopt&&!native_shell_known_shopt(change.name)||!change.shopt&&!native_shell_known_option(change.name) {fmt.eprintln("terminal+: invalid shell option:",change.name);return 2}
        // Privileged startup must be decided before importing environment
        // functions/options. The remaining command-line options apply last.
        if !change.shopt&&change.name=="privileged" {native_shell_option_set(&shell,change.name,change.enabled)}
    }
    if !shell.compat.options["privileged"]&&!invocation.restricted {
        native_shell_import_functions(&shell)
        for variable in ([]string{"SHELLOPTS","BASHOPTS"}) {
            value:=shell.variables[variable]
            for name in strings.split_iterator(&value,":") {
                if variable=="SHELLOPTS"&&native_shell_known_option(name) {native_shell_option_set(&shell,name,true)}
                if variable=="BASHOPTS"&&native_shell_known_shopt(name) {native_shell_shopt_set(&shell,name,true)}
            }
        }
    }
    for change in invocation.changes {
        if change.shopt {
            if change.name=="login_shell"||change.name=="restricted_shell" {continue}
            native_shell_shopt_set(&shell,change.name,change.enabled)
        } else {native_shell_option_set(&shell,change.name,change.enabled)}
    }
    if invocation.noediting {native_shell_option_set(&shell,"emacs",false);native_shell_option_set(&shell,"vi",false)}
    if invocation.option_query!="" {
        editing_selected:=invocation.noediting
        for change in invocation.changes {if !change.shopt&&(change.name=="emacs"||change.name=="vi") {editing_selected=true}}
        was_emacs:=shell.compat.options["emacs"]
        if !editing_selected {shell.compat.options["emacs"]=true}
        name:="set";if invocation.option_query[1]=='O' {name="shopt"}
        if name=="set" {_=native_shell_builtin_set(&shell,[]string{name,invocation.option_query})} else {
            query_arguments:=[]string{name};if invocation.option_query[0]=='+' {query_arguments=[]string{name,"-p"}}
            native_shell_compat_builtin(&shell,query_arguments)
        }
        shell.compat.options["emacs"]=was_emacs
    }
    if invocation.dump_strings {
        native_shell_dump_strings_enabled=true;native_shell_dump_po_strings=invocation.dump_po_strings
        native_shell_option_set(&shell,"noexec",true)
    }
    debugger_startup:=invocation.debugger||shell.compat.shopts["extdebug"]
    native_shell_startup(&shell,invocation)
    if debugger_startup {
        // Bash's debugger is a shell profile rather than an embedded runtime.
        // Honor the same system profile and execute it through the native interpreter.
        if native_shell_startup_file(&shell,"/usr/share/bashdb/bashdb-main.inc") {
            native_shell_bool_set(&shell,&shell.compat.shopts,"extdebug",true)
            native_shell_option_set(&shell,"functrace",true);native_shell_option_set(&shell,"errtrace",true)
        } else {
            fmt.eprintln("terminal+: warning: cannot start debugger; debugging mode disabled")
            native_shell_bool_set(&shell,&shell.compat.shopts,"extdebug",false)
            native_shell_option_set(&shell,"functrace",false);native_shell_option_set(&shell,"errtrace",false)
        }
    }
    if invocation.restricted {
        shell.compat.restricted=true
        for name in ([]string{"SHELL","PATH","HISTFILE","ENV","BASH_ENV"}) {native_shell_attribute_set(&shell,name,shell.compat.attributes[name]|NATIVE_SHELL_READONLY)}
    }
    if invocation.command_mode {
        if !shell.exiting {native_shell_run_source(&shell,invocation.command,true)}
    } else if invocation.script!="" {
        if !shell.exiting {native_shell_run_file(&shell,invocation.script)}
    } else if !shell.interactive {
        if !shell.exiting {native_shell_run_stream(&shell,0,false,true)}
    } else {
        pending: [dynamic]u8
        defer delete(pending)
        verified:string
        defer delete(verified)
        line_number:=1;eof_count:=0
        for !shell.exiting {
            native_shell_dispatch_traps(&shell)
            if native_shell_cancelled() {shell.exiting=true;shell.exit_status=128+int(atomic.atomic_load(&native_shell_termination_signal));break}
            native_shell_reap(&shell,true)
            if len(pending)==0 {native_shell_mail_check(&shell);native_shell_prompt_command(&shell)}
            if shell.tty_fd>=0 {cwd:=native_shell_logical_directory(&shell);native_shell_metadata("minor-cwd",cwd);delete(cwd)}
            line:string;eof:bool
            if invocation.noediting {line,eof=native_shell_readline_stream(&shell)} else {line,eof=native_shell_readline(&shell,"",false,verified)}
            delete(verified);verified=""
            if eof {
                if shell.compat.options["ignoreeof"]&&!native_shell_cancelled()&&len(pending)==0 {
                    limit:=10;if raw,present:=shell.variables["IGNOREEOF"];present {number,valid:=strconv.parse_int(raw);if valid&&number>=0 {limit=number}}
                    if eof_count<limit {eof_count+=1;fmt.eprintln("Use \"exit\" to leave the shell.");continue}
                }
                if len(pending)>0&&!native_shell_cancelled() {native_shell_execute(&shell,string(pending[:]))}
                if !native_shell_cancelled()&&!native_shell_exit_jobs_check(&shell) {continue}
                break
            }
            eof_count=0
            if shell.input_cancelled {clear(&pending);shell.continuation=false;delete(line);continue}
            append(&pending,line);delete(line)
            incomplete,_:=native_shell_runtime_source_state(string(pending[:]))
            if incomplete {append(&pending,'\n');shell.continuation=true;continue}
            shell.continuation=false
            if strings.trim_space(string(pending[:]))!="" {
                source:=string(pending[:]);expanded:="";expansion_error:=""
                if shell.compat.options["histexpand"] {expanded,expansion_error=native_shell_history_expand(&shell,source);if expansion_error=="" {source=expanded}}
                if expansion_error!="" {
                    fmt.eprintln("terminal+:",expansion_error);shell.status=1
                    if shell.compat.shopts["histreedit"]&&!invocation.noediting {verified=strings.clone(string(pending[:]));clear(&pending);delete(expanded);continue}
                } else {
                    if shell.compat.shopts["histverify"]&&!native_shell_editor.history_print_only&&source!=string(pending[:]) {
                        // Load the expansion as editable input. Passing it as
                        // initial text also keeps embedded newlines literal.
                        verified=strings.clone(source)
                        clear(&pending);delete(expanded);continue
                    }
                    native_shell_editor.current_submission= -1
                    if shell.compat.options["history"] {native_shell_editor.current_submission=native_shell_history_submission(&shell,source)}
                    shell.compat.current_line=line_number
                    if native_shell_editor.history_print_only {fmt.println(source)} else {native_shell_execute(&shell,source)}
                    native_shell_editor.current_submission= -1
                }
                line_number+=strings.count(source,"\n")+1
                delete(expanded)
            }
            clear(&pending);free_all(context.temp_allocator)
            if shell.compat.options["onecmd"] {break}
        }
    }
    if shell.interactive&&shell.compat.shopts["login_shell"] {
        was_exiting,status:=shell.exiting,shell.exit_status
        shell.exiting=false
        if home:=shell.variables["HOME"];home!="" {native_shell_startup_file(&shell,fmt.tprintf("%s/.bash_logout",home))}
        if !shell.exiting {shell.exiting=was_exiting;shell.exit_status=status}
    }
    native_shell_run_trap(&shell,0)
    if native_shell_cancelled() {return 128+int(atomic.atomic_load(&native_shell_termination_signal))}
    if shell.exiting {return shell.exit_status}
    return shell.status
}

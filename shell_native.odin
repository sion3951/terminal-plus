#+build linux
package main

import "core:c"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import atomic "core:sync"
import posix "core:sys/posix"

// A shell is another mode of this executable, started before any GUI, GPU or
// background workers. Its process owns the PTY; application jobs never execute
// inside the UI process.
Native_Shell :: struct {
    allocator: mem.Allocator,
    variables: map[string]string,
    exported: map[string]bool,
    jobs: [dynamic]Native_Shell_Job,
    status, exit_status, source_depth: int,
    interactive, exiting, continuation, input_cancelled: bool,
    last_background: posix.pid_t,
    tty_fd: posix.FD,
    compat: ^Native_Shell_Compat,
    script_fds: [dynamic]^posix.FD,
}

native_shell_termination_signal: i32
native_shell_terminate :: proc "c" (signal:posix.Signal) {
    atomic.atomic_store(&native_shell_termination_signal,i32(signal))
}

native_shell_cli_flag :: proc(argument:string)->bool {
    switch argument {
    case "--noprofile","--norc","--login","--rcfile","--init-file","--posix","--restricted","--debugger","--debug","--pretty-print","--noediting","--verbose","--dump-strings","--dump-po-strings":return true
    }
    if len(argument)<2||(argument[0]!='-'&&argument[0]!='+') {return false}
    invocation:=false
    for flag in transmute([]u8)argument[1:] {
        if flag=='c'||flag=='i'||flag=='s'||flag=='l'||flag=='r'||flag=='D' {invocation=true}
        else if native_shell_short_option(flag)==""&&flag!='o'&&flag!='O' {return false}
    }
    return invocation
}
native_shell_cancelled :: proc()->bool {return atomic.atomic_load(&native_shell_termination_signal)!=0}

native_shell_metadata :: proc(kind,path:string) {
    // Hex encoding prevents paths containing terminal controls from becoming
    // escape sequences. The GUI already validates these OSC messages.
    if path==""||len(path)>4096||strings.contains(path,"\x00") {return}
    bytes:=make([]u8,len(path)*2)
    defer delete(bytes)
    digits:="0123456789abcdef"
    for byte,i in transmute([]u8)path {bytes[i*2]=digits[byte>>4];bytes[i*2+1]=digits[byte&15]}
    fmt.printf("\x1b]777;%s;%s\x07",kind,string(bytes))
}

native_shell_open_path :: proc(path:string)->bool {
    if document_kind(path)==.None&&media_kind(path)==.None {return false}
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil||info.type!=.Regular {return false}
    name:=strings.clone_to_cstring(path,context.temp_allocator)
    if posix.access(name,{.R_OK})!=nil {return false}
    absolute,path_error:=os.get_absolute_path(path,context.temp_allocator)
    if path_error!=nil||len(absolute)>4096 {return false}
    native_shell_metadata("minor-open",absolute)
    return true
}

native_shell_init :: proc(shell:^Native_Shell,interactive:bool) {
    shell^=Native_Shell{allocator=context.allocator,interactive=interactive,tty_fd=-1}
    shell.variables=make(map[string]string)
    shell.exported=make(map[string]bool)
    shell.jobs=make([dynamic]Native_Shell_Job)
    shell.script_fds=make([dynamic]^posix.FD)
    native_shell_compat_init(shell)
    native_shell_parser_shell=shell
    native_shell_editor.allocator=shell.allocator
    for signal in ([]posix.Signal{.SIGHUP,.SIGTERM}) {
        action:posix.sigaction_t
        action.sa_handler=native_shell_terminate
        posix.sigemptyset(&action.sa_mask)
        _=posix.sigaction(signal,&action,nil)
    }
    for i:=0;posix.environ[i]!=nil;i+=1 {
        entry:=string(posix.environ[i]);equals:=strings.index_byte(entry,'=')
        if equals>0 {native_shell_set_variable(shell,entry[:equals],entry[equals+1:],true)}
    }
    defaults:=[][2]string{{"OSTYPE","linux-gnu"},{"HOSTTYPE","x86_64"},{"MACHTYPE","x86_64-pc-linux-gnu"},{"OPTIND","1"},{"OPTERR","1"},{"MAILCHECK","60"},{"PS4","+ "}}
    for pair in defaults {if _,exists:=shell.variables[pair[0]];!exists {native_shell_set_variable(shell,pair[0],pair[1])}}
    for name in ([]string{"UID","EUID","PPID","BASHPID","BASH_SUBSHELL","LINENO","EPOCHSECONDS","EPOCHREALTIME","BASH_MONOSECONDS","RANDOM","SECONDS","SRANDOM","SHELLOPTS","BASHOPTS"}) {
        if name=="SHELLOPTS"||name=="BASHOPTS" {if _,imported:=shell.variables[name];imported {continue}}
        if value,present:=native_shell_value_get(shell,name);present {native_shell_set_variable(shell,name,value)}
    }
    if _,exists:=shell.variables["HOSTNAME"];!exists {
        host:[256]c.char
        if posix.gethostname(raw_data(host[:]),len(host)-1)==nil {native_shell_set_variable(shell,"HOSTNAME",string(cstring(raw_data(host[:]))))}
    }
    // Like Bash, do not import a field separator from the process environment.
    native_shell_set_variable(shell,"IFS"," \t\n")
    restore:=strings.clone(shell.variables["MINOR_TERMINAL_RESTORE_DIR"]);defer delete(restore)
    restored:=false
    if restore!="" {
        if os.set_working_directory(restore)==nil {restored=true} else {fmt.eprintf("terminal+: cannot restore directory: %s\n",restore)}
    }
    native_shell_unset_variable(shell,"MINOR_TERMINAL_RESTORE_DIR")
    if restored {native_shell_set_variable(shell,"PWD",restore,true)}
    cwd:=native_shell_logical_directory(shell)
    if cwd!="" {native_shell_set_variable(shell,"PWD",cwd,true)}
    delete(cwd)
    if executable,error:=os.get_executable_path(context.temp_allocator);error==nil {
        native_shell_set_variable(shell,"SHELL",executable,true)
        native_shell_set_variable(shell,"BASH",executable,false)
    }
    level,_:=strconv.parse_int(shell.variables["SHLVL"])
    if level<0||level>999 {level=0}
    native_shell_set_variable(shell,"SHLVL",fmt.tprintf("%d",level+1),true)
    native_shell_set_variable(shell,"BASH_VERSION","5.3-compatible-odin")
    if _,exists:=shell.variables["PS1"];!exists {native_shell_set_variable(shell,"PS1",`\w \$ `)}
    if _,exists:=shell.variables["PS2"];!exists {native_shell_set_variable(shell,"PS2","> ")}
    if interactive {shell.compat.options["histexpand"]=true;shell.compat.options["monitor"]=true}
    if posix.isatty(0) {
        // The line editor handles prompt keys; foreground jobs receive the
        // terminal's real signals after the executor restores defaults.
        for signal in ([]posix.Signal{.SIGINT,.SIGQUIT,.SIGTSTP,.SIGTTIN,.SIGTTOU}) {
            posix.signal(signal,auto_cast posix.SIG_IGN)
        }
        shell.tty_fd=posix.dup(0)
        if shell.tty_fd>=0 {posix.fcntl(shell.tty_fd,.SETFD,c.int(posix.FD_CLOEXEC))}
    }
}

native_shell_destroy :: proc(shell:^Native_Shell) {
    native_shell_shutdown(shell)
    native_shell_editor_destroy()
    native_shell_compat_destroy(shell)
    if native_shell_parser_shell==shell {native_shell_parser_shell=nil}
    delete(shell.script_fds)
    if shell.tty_fd>=0 {posix.close(shell.tty_fd)}
    for key,value in shell.variables {delete(key,shell.allocator);delete(value,shell.allocator)}
    delete(shell.variables);delete(shell.exported)
}

native_shell_source_state :: proc(source:string)->(incomplete,present:bool) {
    arena:vmem.Arena
    if vmem.arena_init_growing(&arena)!=nil {return false,true}
    defer vmem.arena_destroy(&arena)
    context.allocator=vmem.arena_allocator(&arena)
    program,error:=native_shell_parse(source)
    return strings.has_prefix(error,"incomplete:"),error!=""||len(program.pipelines)>0
}

native_shell_incomplete :: proc(source:string)->bool {incomplete,_:=native_shell_source_state(source);return incomplete}


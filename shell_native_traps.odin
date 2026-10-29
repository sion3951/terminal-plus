#+build linux
package main

import "core:strings"
import "core:fmt"
import atomic "core:sync"
import posix "core:sys/posix"

// Signal handlers only set atomic flags. Shell code runs traps at command/wait
// boundaries, with a live allocator and ordinary process state.
native_shell_pending_signals:[65]i32
native_shell_trap_signal :: proc "c" (signal:posix.Signal) {
    index:=int(signal)
    if index>0&&index<len(native_shell_pending_signals) {atomic.atomic_store(&native_shell_pending_signals[index],1)}
}

native_shell_trap_install :: proc(shell:^Native_Shell,signal:int,ignored:bool)->bool {
    if signal<=0 {return true}
    if signal>=len(native_shell_pending_signals)||signal==int(posix.Signal.SIGKILL)||signal==int(posix.Signal.SIGSTOP) {return false}
    action:posix.sigaction_t
    posix.sigemptyset(&action.sa_mask)
    if ignored {action.sa_handler=auto_cast posix.SIG_IGN}
    else if _,exists:=shell.compat.traps[signal];exists {action.sa_handler=native_shell_trap_signal}
    else if signal==int(posix.Signal.SIGHUP)||signal==int(posix.Signal.SIGTERM) {action.sa_handler=native_shell_terminate}
    else if shell.interactive&&(signal==int(posix.Signal.SIGINT)||signal==int(posix.Signal.SIGQUIT)||signal==int(posix.Signal.SIGTSTP)||signal==int(posix.Signal.SIGTTIN)||signal==int(posix.Signal.SIGTTOU)) {action.sa_handler=auto_cast posix.SIG_IGN}
    else {action.sa_handler=auto_cast posix.SIG_DFL}
    atomic.atomic_store(&native_shell_pending_signals[signal],0)
    if signal==int(posix.Signal.SIGCHLD) {native_shell_child_trap_count=0}
    return posix.sigaction(posix.Signal(signal),&action,nil)==nil
}

native_shell_run_trap :: proc(shell:^Native_Shell,key:int)->int {
    if shell.compat==nil||shell.compat.running_trap {return 0}
    source,exists:=shell.compat.traps[key]
    if !exists||source=="" {return 0}
    owner:=shell.compat.trap_owners[key]
    if key>0&&owner!=posix.getpid() {return 0}
    if key==0&&owner!=posix.getpid() {return 0}
    if key<0 {
        inherited:=owner!=posix.getpid()||shell.compat.function_depth>shell.compat.trap_depths[key]
        tracing:=shell.compat.options["functrace"]||native_shell_function_traced(shell)||shell.compat.shopts["extdebug"]
        if key== -3 {tracing=shell.compat.options["errtrace"]||shell.compat.shopts["extdebug"]}
        if inherited&&!tracing {return 0}
    }
    // The trap can redefine itself; execute a stable copy of its source.
    command:=strings.clone(source);defer delete(command)
    previous_signal:=native_shell_snapshot_variable(shell,"BASH_TRAPSIG")
    defer native_shell_restore_variables(shell,[]Native_Shell_Variable_Save{previous_signal})
    signal:=key
    switch key {case -1:signal=65;case -2:signal=67;case -3:signal=66}
    native_shell_set_variable(shell,"BASH_TRAPSIG",fmt.aprintf("%d",signal))
    previous_status:=shell.status
    previous_exiting,previous_exit_status:=shell.exiting,shell.exit_status
    previous_returning,previous_return_status:=shell.compat.returning,shell.compat.return_status
    shell.compat.running_trap=true
    shell.exiting=false;shell.compat.returning=false
    result:=native_shell_execute(shell,command)
    if key==int(posix.Signal.SIGCHLD) {native_shell_child_trap_count=0;atomic.atomic_store(&native_shell_pending_signals[key],0)}
    shell.compat.running_trap=false
    shell.status=previous_status
    if !shell.exiting {shell.exiting=previous_exiting;shell.exit_status=previous_exit_status}
    if !shell.compat.returning {shell.compat.returning=previous_returning;shell.compat.return_status=previous_return_status}
    return result
}

native_shell_dispatch_traps :: proc(shell:^Native_Shell) {
    if shell.compat==nil||shell.compat.running_trap {return}
    if atomic.atomic_load(&native_shell_pending_signals[int(posix.Signal.SIGCHLD)])!=0 {native_shell_reap(shell)}
    for signal:=1;signal<len(native_shell_pending_signals);signal+=1 {
        if atomic.atomic_exchange(&native_shell_pending_signals[signal],0)!=0 {
            count:=1
            if signal==int(posix.Signal.SIGCHLD) {count=max(1,native_shell_child_trap_count);native_shell_child_trap_count=0}
            for _ in 0..<count {native_shell_run_trap(shell,signal)}
        }
    }
}

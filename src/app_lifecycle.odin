#+build linux
package main

import "core:c"
import atomic "core:sync"
import "core:thread"
import posix "core:sys/posix"
import glfw "vendor:glfw"

Lifecycle_State :: struct {
    pipe:[2]posix.FD,
    worker:^thread.Thread,
    requested,stopping:bool,
    old_term,old_int:posix.sigaction_t,
    term_installed,int_installed:bool,
}
lifecycle_state:=Lifecycle_State{pipe={-1,-1}}
lifecycle_signal_fd:posix.FD= -1

// No runtime, allocation, mutex or GLFW call is allowed in a signal handler.
lifecycle_signal :: proc "c" (signal:posix.Signal) {
    saved_errno:=posix.errno()
    fd:=atomic.atomic_load(&lifecycle_signal_fd)
    if fd>=0 {byte:u8=1;posix.write(fd,&byte,1)}
    posix.errno(saved_errno)
}
lifecycle_worker :: proc(worker:^thread.Thread) {
    state:=cast(^Lifecycle_State)worker.data
    buffer:[64]u8
    for {
        if atomic.atomic_load(&state.stopping) {break}
        descriptor:=posix.pollfd{fd=state.pipe[0],events={.IN}}
        result:=posix.poll(&descriptor,1,-1)
        if result<0 {if posix.errno()==.EINTR {continue};break}
        if .IN in descriptor.revents {
            received:=false
            for {
                amount:=posix.read(state.pipe[0],raw_data(buffer[:]),len(buffer))
                if amount<=0 {break}
                for byte in buffer[:int(amount)] {if byte!=0 {received=true}}
            }
            if received {
                atomic.atomic_store(&state.requested,true)
                glfw.PostEmptyEvent()
            }
        }
        if .ERR in descriptor.revents||.HUP in descriptor.revents||.NVAL in descriptor.revents {break}
    }
}
lifecycle_init :: proc()->bool {
    state:=&lifecycle_state
    if state.worker!=nil {return true}
    state.pipe={-1,-1};atomic.atomic_store(&state.stopping,false);atomic.atomic_store(&state.requested,false)
    if pty_pipe2(&state.pipe,c.int(posix.O_CLOEXEC|posix.O_NONBLOCK))!=0 {return false}
    state.worker=thread.create(lifecycle_worker)
    if state.worker==nil {posix.close(state.pipe[0]);posix.close(state.pipe[1]);state.pipe={-1,-1};return false}
    state.worker.data=state
    thread.start(state.worker)
    action:posix.sigaction_t
    action.sa_handler=lifecycle_signal;action.sa_flags={.RESTART}
    posix.sigemptyset(&action.sa_mask)
    atomic.atomic_store(&lifecycle_signal_fd,state.pipe[1])
    if posix.sigaction(.SIGTERM,&action,&state.old_term)!=nil {lifecycle_destroy();return false}
    state.term_installed=true
    if posix.sigaction(.SIGINT,&action,&state.old_int)!=nil {lifecycle_destroy();return false}
    state.int_installed=true
    return true
}
lifecycle_should_close :: proc()->bool {return atomic.atomic_load(&lifecycle_state.requested)}
lifecycle_destroy :: proc() {
    state:=&lifecycle_state
    if state.term_installed {posix.sigaction(.SIGTERM,&state.old_term,nil);state.term_installed=false}
    if state.int_installed {posix.sigaction(.SIGINT,&state.old_int,nil);state.int_installed=false}
    atomic.atomic_store(&lifecycle_signal_fd,-1)
    if state.worker!=nil {
        atomic.atomic_store(&state.stopping,true)
        byte:u8=0;posix.write(state.pipe[1],&byte,1)
        // A create failure before start leaves a suspended thread.
        if .Started in state.worker.flags {thread.join(state.worker)}
        thread.destroy(state.worker);state.worker=nil
    }
    if state.pipe[1]>=0 {posix.close(state.pipe[1]);state.pipe[1]= -1}
    if state.pipe[0]>=0 {posix.close(state.pipe[0]);state.pipe[0]= -1}
}

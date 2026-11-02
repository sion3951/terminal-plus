#+build linux
package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"
import glfw "vendor:glfw"

// The shell sees a real controlling terminal. Only the worker touches the
// nonblocking master; the GUI exchanges bounded output and queued input.
PTY :: struct {
    master: posix.FD,
    pid: posix.pid_t,
    wake: [2]posix.FD,
    worker: ^thread.Thread,
    mutex: sync.Mutex,
    output, input: [dynamic]u8,
    input_offset: int,
    packet_end: int,
    alive, stopping, wake_events: bool,
    // Persistent sockets are clients of a headless native session host.
    // Destroying a client detaches; only an explicit End closes its shell.
    persistent: bool,
    session_state: ^Local_Session_Client,
    notify: proc(),
    exit_status: c.int,
}
PTY_BUFFER_LIMIT :: 4*1024*1024
PTY_INPUT_LIMIT :: 64*1024*1024
PTY_Winsize :: struct { rows, cols, xpixel, ypixel: u16 }
foreign import pty_lib "system:c"
foreign pty_lib {
    @(link_name="openpty") pty_openpty :: proc(master,slave:^posix.FD,name:cstring,termios:rawptr,size:^PTY_Winsize)->c.int ---
    @(link_name="ioctl") pty_ioctl :: proc(fd:posix.FD,request:c.ulong,#c_vararg args:..any)->c.int ---
    @(link_name="pipe2") pty_pipe2 :: proc(fds:^[2]posix.FD,flags:c.int)->c.int ---
}

pty_signal_worker :: proc(p:^PTY) {
    b:u8=1
    // A full nonblocking wake pipe already guarantees a wakeup.
    posix.write(p.wake[1],&b,1)
}
pty_notify :: proc(p:^PTY) { if p.notify!=nil {p.notify()} else if p.wake_events { glfw.PostEmptyEvent() } }

pty_worker :: proc(t:^thread.Thread) {
    p:=cast(^PTY)t.data
    buffer: [32768]u8
    for {
        sync.mutex_lock(&p.mutex)
        stop:=p.stopping
        space:=PTY_BUFFER_LIMIT-len(p.output)
        writing:=p.input_offset<len(p.input)
        sync.mutex_unlock(&p.mutex)
        if stop { break }
        fds: [2]posix.pollfd
        fds[0]={fd=p.wake[0],events={.IN}}
        fds[1]={fd=p.master}
        if space>0 { fds[1].events+={.IN} }
        if writing { fds[1].events+={.OUT} }
        // When output is full, leave the master out entirely: POLLHUP is
        // unconditional and otherwise spins until the GUI drains the buffer.
        count:=2
        if space==0 && !writing {count=1}
        polled:=posix.poll(raw_data(fds[:]),posix.nfds_t(count),-1)
        if polled<0 {
            if posix.errno()==.EINTR {continue}
            break
        }
        if .IN in fds[0].revents {
            for posix.read(p.wake[0],raw_data(buffer[:]),len(buffer))>0 {}
        }
        sync.mutex_lock(&p.mutex)
        stop=p.stopping
        sync.mutex_unlock(&p.mutex)
        if stop {break}
        eof:=false
        if space==0 && (.HUP in fds[1].revents || .ERR in fds[1].revents) {
            // The slave has closed: pending input cannot be delivered. Stop
            // polling it until the GUI makes room to read its final output.
            sync.mutex_lock(&p.mutex)
            clear(&p.input);p.input_offset=0
            sync.mutex_unlock(&p.mutex)
            continue
        }
        if space>0 && (.IN in fds[1].revents || .HUP in fds[1].revents || .ERR in fds[1].revents) {
            amount:=posix.read(p.master,raw_data(buffer[:]),c.size_t(min(len(buffer),space)))
            if amount>0 {
                sync.mutex_lock(&p.mutex)
                was_empty:=len(p.output)==0
                append(&p.output,..buffer[:int(amount)])
                sync.mutex_unlock(&p.mutex)
                if was_empty {pty_notify(p)}
            } else if amount==0 || (posix.errno()!=.EAGAIN && posix.errno()!=.EINTR) {eof=true}
        }
        if writing && .OUT in fds[1].revents {
            sync.mutex_lock(&p.mutex)
            end:=len(p.input)
            if p.persistent {
                if p.packet_end<=p.input_offset {p.packet_end=p.input_offset+12+int(history_u32(p.input[:],p.input_offset+4))}
                end=min(end,p.packet_end)
            }
            data:=p.input[p.input_offset:end]
            amount:c.ssize_t
            if p.persistent {amount=file_socket_send(p.master,raw_data(data),c.size_t(min(len(data),32768)),0x4000)}
            else {amount=posix.write(p.master,raw_data(data),c.size_t(min(len(data),32768)))}
            if amount>0 {
                p.input_offset+=int(amount)
                if p.input_offset==len(p.input) {clear(&p.input);p.input_offset=0;p.packet_end=0}
            } else if amount<0 && posix.errno()!=.EAGAIN && posix.errno()!=.EINTR {eof=true}
            sync.mutex_unlock(&p.mutex)
            // A session host may be waiting to admit more input even when the
            // foreground application consumes it without producing output.
            if amount>0&&p.notify!=nil {p.notify()}
        }
        if .NVAL in fds[1].revents || eof {break}
    }
    sync.mutex_lock(&p.mutex)
    p.alive=false
    sync.mutex_unlock(&p.mutex)
    pty_notify(p)
}

pty_start :: proc(p:^PTY,cols,rows:int,command:string="",wake_events:bool=true,directory:string="")->bool {
    arguments:=make([dynamic]string,context.temp_allocator)
    append(&arguments,"terminal+","--native-shell")
    if command!="" {append(&arguments,"-c",command)}
    return pty_spawn(p,cols,rows,"/proc/self/exe",arguments[:],wake_events,directory)
}

// OpenSSH owns authentication, host-key confirmation and configuration. Its
// terminal is the same real controlling PTY as a local native shell session.
pty_start_ssh :: proc(p:^PTY,cols,rows:int,target:string,port:u16=0,wake_events:bool=true,control_id:string="",directory:string="")->bool {
    checked,parsed_port,error:=device_target_parse(target)
    if error!=""||parsed_port!=0||checked!=target {return false}
    args:=make([dynamic]string,context.temp_allocator)
    append(&args,"ssh","-tt","-o","ServerAliveInterval=30","-o","ServerAliveCountMax=3")
    control:=ssh_control_path(Device_Profile{target=target,port=port,control_id=control_id})
    if control!="" {append(&args,"-o","ControlMaster=auto","-o","ControlPersist=no","-o",fmt.tprintf("ControlPath=%s",control))}
    if port>0 {append(&args,"-p",fmt.tprintf("%d",port))}
    append(&args,"--",target)
    append(&args,remote_session_command(control_id,directory))
    return pty_spawn(p,cols,rows,"/usr/bin/ssh",args[:],wake_events)
}

pty_spawn :: proc(p:^PTY,cols,rows:int,executable:string,arguments:[]string,wake_events:bool=true,directory:string="")->bool {
    p^=PTY{master=-1,wake={-1,-1},wake_events=wake_events}
    master,slave:posix.FD
    size:=PTY_Winsize{rows=u16(clamp(rows,1,65535)),cols=u16(clamp(cols,1,65535))}
    if pty_openpty(&master,&slave,nil,nil,&size)!=0 {fmt.eprintln("Cannot open PTY:",posix.errno());return false}
    p.master=master
    posix.fcntl(master,.SETFD,c.int(posix.FD_CLOEXEC))
    posix.fcntl(slave,.SETFD,c.int(posix.FD_CLOEXEC))
    if pty_pipe2(&p.wake,c.int(posix.O_CLOEXEC|posix.O_NONBLOCK))!=0 {posix.close(master);posix.close(slave);return false}
    errors:[2]posix.FD
    if pty_pipe2(&errors,c.int(posix.O_CLOEXEC))!=0 {
        posix.close(master);posix.close(slave);posix.close(p.wake[0]);posix.close(p.wake[1]);return false
    }
    // Snapshot the C environment before fork. The child does no Odin runtime
    // work or allocation before exec; this also works with live GPU threads.
    env:=make([dynamic]cstring)
    defer delete(env)
    for i:=0;posix.environ[i]!=nil;i+=1 {
        value:=string(posix.environ[i])
        if strings.has_prefix(value,"TERM=") || strings.has_prefix(value,"COLORTERM=") || strings.has_prefix(value,"TERM_PROGRAM=") || strings.has_prefix(value,"MINOR_TERMINAL_RESTORE_DIR=") {continue}
        append(&env,posix.environ[i])
    }
    append(&env,"TERM=xterm-256color","COLORTERM=truecolor","TERM_PROGRAM=terminal-plus")
    if directory!="" {append(&env,strings.clone_to_cstring(fmt.tprintf("MINOR_TERMINAL_RESTORE_DIR=%s",directory),context.temp_allocator))}
    append(&env,nil)
    // All C strings and argv storage exist before fork. The child only uses
    // async-signal-safe libc calls until exec, even with GPU/I/O threads alive.
    path:=strings.clone_to_cstring(executable)
    defer delete(path)
    args:=make([]cstring,len(arguments)+1)
    defer {for argument in args {if argument!=nil {delete(argument)}};delete(args)}
    for argument,i in arguments {args[i]=strings.clone_to_cstring(argument)}
    argv:=raw_data(args);envp:=raw_data(env[:])
    error_fd:=errors[1]
    pid:=posix.fork()
    if pid==0 {
        // POSIX async-signal-safe calls only, all pointers prepared above.
        posix.close(errors[0]);posix.close(master)
        ok:=posix.setsid()>=0
        if ok {ok=pty_ioctl(slave,0x540e,c.int(0))==0} // TIOCSCTTY
        if ok {ok=posix.dup2(slave,0)>=0 && posix.dup2(slave,1)>=0 && posix.dup2(slave,2)>=0}
        if slave>2 {posix.close(slave)}
        if ok {posix.execve(path,argv,envp)}
        failure:u8=1
        posix.write(error_fd,&failure,1)
        posix._exit(127)
    }
    posix.close(slave);posix.close(errors[1])
    if pid<0 {
        posix.close(errors[0]);posix.close(master);posix.close(p.wake[0]);posix.close(p.wake[1]);return false
    }
    p.pid=pid
    failure:u8
    amount:=posix.read(errors[0],&failure,1)
    for amount<0 && posix.errno()==.EINTR {amount=posix.read(errors[0],&failure,1)}
    posix.close(errors[0])
    if amount!=0 {
        posix.waitpid(pid,&p.exit_status,{})
        posix.close(master);posix.close(p.wake[0]);posix.close(p.wake[1]);p.pid=0;return false
    }
    flags:=posix.fcntl(master,.GETFL)
    if flags<0 || posix.fcntl(master,.SETFL,flags|c.int(posix.O_NONBLOCK))<0 {pty_destroy(p);return false}
    p.output=make([dynamic]u8,0,65536)
    p.input=make([dynamic]u8,0,4096)
    p.alive=true
    p.worker=thread.create(pty_worker)
    if p.worker==nil {pty_destroy(p);return false}
    p.worker.data=p
    thread.start(p.worker)
    return true
}

pty_alive :: proc(p:^PTY)->bool {
    sync.mutex_lock(&p.mutex);defer sync.mutex_unlock(&p.mutex)
    return p.alive
}
pty_write :: proc(p:^PTY,data:[]u8)->bool {
    if p.persistent {return local_session_write(p,data)}
    return pty_queue_write(p,data)
}
pty_queue_write :: proc(p:^PTY,data:[]u8)->bool {
    if len(data)==0 {return true}
    sync.mutex_lock(&p.mutex)
    if !p.alive || p.stopping || len(data)>PTY_INPUT_LIMIT-(len(p.input)-p.input_offset) {sync.mutex_unlock(&p.mutex);return false}
    was_empty:=p.input_offset==len(p.input)
    // Keep partial writes as a consumed prefix. Compact occasionally rather
    // than copying a large queued paste again for every following keystroke.
    if p.input_offset>0&&(p.input_offset>=len(p.input)/2||len(p.input)+len(data)>PTY_INPUT_LIMIT) {
        p.packet_end=max(0,p.packet_end-p.input_offset)
        copy(p.input[:],p.input[p.input_offset:])
        resize(&p.input,len(p.input)-p.input_offset)
        p.input_offset=0
    }
    append(&p.input,..data)
    sync.mutex_unlock(&p.mutex)
    if was_empty {pty_signal_worker(p)}
    return true
}
pty_cancel_input :: proc(p:^PTY) {
    if p.persistent {local_session_cancel(p);return}
    sync.mutex_lock(&p.mutex)
    clear(&p.input);p.input_offset=0
    if p.master>=0 {posix.tcflush(p.master,.TCIOFLUSH)}
    sync.mutex_unlock(&p.mutex)
}
pty_drain :: proc(p:^PTY,data:^[dynamic]u8)->bool {
    sync.mutex_lock(&p.mutex)
    used:=len(p.output)
    was_full:=used==PTY_BUFFER_LIMIT
    if used>0 {
        // Normal GUI drains arrive with an empty reusable buffer. Hand its
        // allocation to the worker instead of copying all pending output.
        if len(data^)==0 {data^,p.output=p.output,data^}
        else {append(data,..p.output[:]);clear(&p.output)}
    }
    sync.mutex_unlock(&p.mutex)
    // The worker only stops reading when backpressure fills the output buffer.
    if was_full {pty_signal_worker(p)}
    return used>0
}
pty_resize :: proc(p:^PTY,cols,rows:int) {
    if p.persistent {local_session_resize(p,cols,rows);return}
    if p.master<0 {return}
    size:=PTY_Winsize{rows=u16(clamp(rows,1,65535)),cols=u16(clamp(cols,1,65535))}
    pty_ioctl(p.master,0x5414,&size) // TIOCSWINSZ also sends SIGWINCH to foreground group.
}
pty_destroy :: proc(p:^PTY) {
    if p.persistent {local_session_close(p,false);return}
    if p.pid<=0 {return}
    sync.mutex_lock(&p.mutex)
    p.stopping=true
    sync.mutex_unlock(&p.mutex)
    pty_signal_worker(p)
    if p.worker!=nil {thread.join(p.worker);thread.destroy(p.worker);p.worker=nil}
    foreground:=posix.tcgetpgrp(p.master)
    if foreground>0 && foreground!=p.pid {posix.kill(-foreground,.SIGHUP)}
    posix.kill(-p.pid,.SIGHUP)
    posix.close(p.master);p.master=-1
    // Allow the native shell's bounded job cleanup to finish before killing
    // its host; otherwise a background group could outlive that cleanup.
    reaped:=false
    for _ in 0..<100 {
        result:=posix.waitpid(p.pid,&p.exit_status,{.NOHANG})
        if result==p.pid || (result<0 && posix.errno()==.ECHILD) {reaped=true;break}
        time.sleep(5*time.Millisecond)
    }
    if !reaped {
        posix.kill(-p.pid,.SIGKILL)
        posix.kill(p.pid,.SIGKILL)
        for posix.waitpid(p.pid,&p.exit_status,{})<0 && posix.errno()==.EINTR {}
    }
    // The foreground job may have ignored HUP even if its shell already exited.
    if foreground>0 && foreground!=p.pid {posix.kill(-foreground,.SIGKILL)}
    posix.close(p.wake[0]);posix.close(p.wake[1])
    delete(p.output);delete(p.input)
    p^=PTY{master=-1,wake={-1,-1}}
}

pty_selfcheck :: proc()->bool {
    p:PTY
    if !pty_start(&p,91,27,"printf '__PTY_OK__'; stty size; printf '%s:%s' \"$TERM\" \"$COLORTERM\"",false) {return false}
    defer pty_destroy(&p)
    output:=make([dynamic]u8);defer delete(output)
    for _ in 0..<400 {
        pty_drain(&p,&output)
        if !pty_alive(&p) {pty_drain(&p,&output);break}
        time.sleep(5*time.Millisecond)
    }
    data:=string(output[:])
    return strings.contains(data,"__PTY_OK__27 91") && strings.contains(data,"xterm-256color:truecolor")
}

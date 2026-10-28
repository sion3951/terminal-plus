#+build linux
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"
import glfw "vendor:glfw"

// A single UI owns a configuration's manifest and attachments. Additional
// launcher invocations ask that UI for a new native window instead of racing
// to restore the same live PTYs and overwrite the same session.json.
App_Instance_Result :: enum {Primary,Forwarded,Failed}
App_Instance_Request :: struct {command,ssh_target,directory:string}
App_Instance_State :: struct {
    worker:^thread.Thread,
    mutex:sync.Mutex,
    requests:[dynamic]App_Instance_Request,
    listener,lock:posix.FD,
    wake:[2]posix.FD,
    socket_path,lock_path:string,
    stopping,ready,owns_socket,owns_lock:bool,
}
APP_INSTANCE_MAGIC :: u32(0x3149414d)
APP_INSTANCE_VERSION :: u32(1)
APP_INSTANCE_COMMAND_LIMIT :: 128*1024
APP_INSTANCE_SSH_LIMIT :: 1024
APP_INSTANCE_DIRECTORY_LIMIT :: 4096
app_instance_state:=App_Instance_State{listener=-1,lock=-1,wake={-1,-1}}

app_instance_request_destroy :: proc(request:^App_Instance_Request) {
    delete(request.command);delete(request.ssh_target);delete(request.directory);request^={}
}

// Bounded nonblocking I/O. The worker also polls its wake pipe so shutdown
// cancels a partial peer request immediately rather than waiting for a timeout.
app_instance_transfer :: proc(fd:posix.FD,bytes:[]u8,writing:bool,timeout:int,state:^App_Instance_State=nil)->bool {
    used:=0;began:=time.tick_now()
    for used<len(bytes) {
        if state!=nil {
            sync.mutex_lock(&state.mutex);stopping:=state.stopping;sync.mutex_unlock(&state.mutex)
            if stopping {return false}
        }
        elapsed:=int(time.duration_seconds(time.tick_diff(began,time.tick_now()))*1000)
        if elapsed>=timeout {return false}
        descriptors:=[2]posix.pollfd{{fd=fd,events={.IN}},{fd=-1}}
        if writing {descriptors[0].events={.OUT}}
        count:=1
        if state!=nil {descriptors[1]={fd=state.wake[0],events={.IN}};count=2}
        result:=posix.poll(raw_data(descriptors[:]),posix.nfds_t(count),c.int(timeout-elapsed))
        if result<0 {if posix.errno()==.EINTR {continue};return false}
        if result==0 {return false}
        if count==2&&.IN in descriptors[1].revents {
            buffer:[64]u8
            for posix.read(state.wake[0],raw_data(buffer[:]),len(buffer))>0 {}
            continue
        }
        amount:c.ssize_t
        remaining:=len(bytes)-used
        if writing {amount=file_socket_send(fd,&bytes[used],c.size_t(remaining),0x4000)}
        else {amount=posix.read(fd,&bytes[used],c.size_t(remaining))}
        if amount>0 {used+=int(amount)}
        else if amount<0&&(posix.errno()==.EINTR||posix.errno()==.EAGAIN) {continue}
        else {return false}
    }
    return true
}

app_instance_connect :: proc(path:string)->posix.FD {
    address,valid:=local_session_address(path);if !valid {return -1}
    fd:=local_socket(1,1|0x80000|0x800,0);if fd<0 {return -1}
    if local_connect(fd,&address,c.uint(size_of(address)))!=0 {
        if posix.errno()!=.EINPROGRESS {posix.close(fd);return -1}
        descriptor:=posix.pollfd{fd=fd,events={.OUT}}
        error:c.int;length:=c.uint(size_of(error))
        if posix.poll(&descriptor,1,100)<=0||local_sockopt(fd,1,4,&error,&length)!=0||error!=0 {posix.close(fd);return -1}
    }
    if !local_session_same_user(fd) {posix.close(fd);return -1}
    return fd
}

app_instance_forward :: proc(path,command,ssh_target:string)->bool {
    fd:posix.FD= -1
    // Another launcher may have acquired the lock just before binding.
    for _ in 0..<100 {
        fd=app_instance_connect(path)
        if fd>=0 {break}
        time.sleep(20*time.Millisecond)
    }
    if fd<0 {return false};defer posix.close(fd)
    directory,directory_error:=os.getwd(context.temp_allocator)
    if directory_error!=nil {directory=""}
    if len(directory)>APP_INSTANCE_DIRECTORY_LIMIT {return false}
    packet:=make([dynamic]u8,context.temp_allocator)
    history_put_u32(&packet,APP_INSTANCE_MAGIC);history_put_u32(&packet,APP_INSTANCE_VERSION)
    history_put_u32(&packet,u32(len(command)));history_put_u32(&packet,u32(len(ssh_target)));history_put_u32(&packet,u32(len(directory)))
    append(&packet,..transmute([]u8)command);append(&packet,..transmute([]u8)ssh_target);append(&packet,..transmute([]u8)directory)
    if !app_instance_transfer(fd,packet[:],true,2000) {return false}
    response:[8]u8
    return app_instance_transfer(fd,response[:],false,2000)&&history_u32(response[:],0)==APP_INSTANCE_MAGIC&&history_u32(response[:],4)==1
}

app_instance_init :: proc(command,ssh_target:string)->App_Instance_Result {
    if len(command)>APP_INSTANCE_COMMAND_LIMIT||len(ssh_target)>APP_INSTANCE_SSH_LIMIT {
        session_error_set("The launcher command or SSH destination is too long.");return .Failed
    }
    directory:=local_session_directory();settings:=session_path()
    if directory==""||settings=="" {session_error_set("Cannot locate the private terminal instance directory.");return .Failed}
    hash:u64=14695981039346656037
    for byte in transmute([]u8)settings {hash=(hash~u64(byte))*1099511628211}
    path:=fmt.tprintf("%s/app-%016x.sock",directory,hash)
    address,valid:=local_session_address(path)
    if !valid {session_error_set("The terminal instance socket path is too long.");return .Failed}
    lock_path:=fmt.tprintf("%s.lock",path)
    lock:=posix.open(strings.clone_to_cstring(lock_path,context.temp_allocator),{.RDWR,.CREAT,.CLOEXEC,.NOFOLLOW},posix.mode_t{.IRUSR,.IWUSR})
    if lock<0 {session_error_set("Cannot open the terminal instance lock.");return .Failed}
    info:posix.stat_t
    if posix.fstat(lock,&info)!=.OK||!posix.S_ISREG(info.st_mode)||info.st_uid!=posix.getuid() {
        posix.close(lock);session_error_set("The terminal instance lock is not a private regular file.");return .Failed
    }
    if history_flock(lock,6)!=0 {
        lock_error:=posix.errno();posix.close(lock)
        if lock_error!=.EAGAIN {session_error_set("Cannot lock the terminal instance.");return .Failed}
        if app_instance_forward(path,command,ssh_target) {return .Forwarded}
        session_error_set("The running terminal did not accept the new window request. Its sessions were left intact.");return .Failed
    }
    state:=&app_instance_state
    state.lock=lock;state.owns_lock=true;state.lock_path=strings.clone(lock_path);state.socket_path=strings.clone(path)
    complete:=false;defer {if !complete {app_instance_destroy()}}
    state.listener=local_socket(1,1|0x80000|0x800,0)
    if state.listener<0 {session_error_set("Cannot create the terminal instance socket.");return .Failed}
    os.remove(path)
    if local_bind(state.listener,&address,c.uint(size_of(address)))!=0 {session_error_set("Cannot bind the terminal instance socket.");return .Failed}
    state.owns_socket=true
    if local_listen(state.listener,16)!=0||pty_pipe2(&state.wake,c.int(posix.O_CLOEXEC|posix.O_NONBLOCK))!=0 {
        session_error_set("Cannot initialize terminal launcher requests.");return .Failed
    }
    state.worker=thread.create(app_instance_worker)
    if state.worker==nil {session_error_set("Cannot start the terminal launcher worker.");return .Failed}
    state.worker.data=state;thread.start(state.worker);complete=true
    return .Primary
}

app_instance_accept_request :: proc(state:^App_Instance_State,fd:posix.FD) {
    if !local_session_same_user(fd) {return}
    header:[20]u8
    if !app_instance_transfer(fd,header[:],false,1500,state)||history_u32(header[:],0)!=APP_INSTANCE_MAGIC||history_u32(header[:],4)!=APP_INSTANCE_VERSION {return}
    command_len,ssh_len,directory_len:=int(history_u32(header[:],8)),int(history_u32(header[:],12)),int(history_u32(header[:],16))
    if command_len>APP_INSTANCE_COMMAND_LIMIT||ssh_len>APP_INSTANCE_SSH_LIMIT||directory_len>APP_INSTANCE_DIRECTORY_LIMIT {return}
    payload:=make([]u8,command_len+ssh_len+directory_len);defer delete(payload)
    if !app_instance_transfer(fd,payload,false,1500,state)||strings.contains(string(payload),"\x00") {return}
    command:=string(payload[:command_len]);ssh_target:=string(payload[command_len:command_len+ssh_len]);directory:=string(payload[command_len+ssh_len:])
    if ssh_target!="" {_,_,error:=device_target_parse(ssh_target);if error!="" {return}}
    if directory!=""&&directory[0]!='/' {return}
    sync.mutex_lock(&state.mutex)
    accepted:=!state.stopping&&len(state.requests)<64
    ready:=state.ready
    if accepted {append(&state.requests,App_Instance_Request{command=strings.clone(command),ssh_target=strings.clone(ssh_target),directory=strings.clone(directory)})}
    sync.mutex_unlock(&state.mutex)
    response:=make([dynamic]u8);defer delete(response)
    history_put_u32(&response,APP_INSTANCE_MAGIC);history_put_u32(&response,u32(accepted))
    app_instance_transfer(fd,response[:],true,500,state)
    if accepted&&ready {glfw.PostEmptyEvent()}
}

app_instance_worker :: proc(worker:^thread.Thread) {
    state:=cast(^App_Instance_State)worker.data
    for {
        sync.mutex_lock(&state.mutex);stopping:=state.stopping;sync.mutex_unlock(&state.mutex)
        if stopping {break}
        descriptors:=[2]posix.pollfd{{fd=state.listener,events={.IN}},{fd=state.wake[0],events={.IN}}}
        result:=posix.poll(raw_data(descriptors[:]),2,-1)
        if result<0 {if posix.errno()==.EINTR {continue};break}
        if .IN in descriptors[1].revents {
            buffer:[64]u8
            for posix.read(state.wake[0],raw_data(buffer[:]),len(buffer))>0 {}
        }
        if .IN in descriptors[0].revents {
            fd:=local_accept(state.listener,nil,nil,0x80000|0x800)
            if fd>=0 {app_instance_accept_request(state,fd);posix.close(fd)}
        }
        if .ERR in descriptors[0].revents||.HUP in descriptors[0].revents||.NVAL in descriptors[0].revents {break}
        free_all(context.temp_allocator)
    }
}

// Call only after GLFW and the restored windows are ready. Earlier requests
// stay queued without any GLFW calls from the background worker.
app_instance_ready :: proc() {
    state:=&app_instance_state
    sync.mutex_lock(&state.mutex);state.ready=true;pending:=len(state.requests)>0;sync.mutex_unlock(&state.mutex)
    if pending {glfw.PostEmptyEvent()}
}

app_instance_process :: proc() {
    state:=&app_instance_state
    sync.mutex_lock(&state.mutex);requests:=state.requests;state.requests=nil;sync.mutex_unlock(&state.mutex)
    defer delete(requests)
    for &request in requests {
        source:=workspace_focused
        if source!=nil&&!workspace_contains(source) {source=nil}
        width,height:=1200,800
        if source!=nil {w,h:=glfw.GetWindowSize(source.renderer.window);width=int(w);height=int(h)}
        window:=workspace_create_window(width,height,source)
        if window==nil {session_error_set("Could not create the requested terminal window.");app_instance_request_destroy(&request);continue}
        if !app_new_tab(window,request.command,directory=request.directory) {
            for existing,i in workspace_windows {if existing==window {ordered_remove(&workspace_windows,i);break}}
            workspace_destroy_window(window)
            session_error_set("Could not start the requested terminal session.");app_instance_request_destroy(&request);continue
        }
        if request.ssh_target!="" {
            target,port,_:=device_target_parse(request.ssh_target)
            app_open_device(window,Device_Profile{name=request.ssh_target,target=target,port=port},false)
        }
        workspace_focused=window;session_touch(window)
        glfw.ShowWindow(window.renderer.window);glfw.FocusWindow(window.renderer.window)
        app_instance_request_destroy(&request)
    }
}

// Stop accepting before the final manifest flush and GLFW teardown, retaining
// the instance lock until all old terminal attachments have been released.
app_instance_stop :: proc() {
    state:=&app_instance_state
    sync.mutex_lock(&state.mutex);state.stopping=true;state.ready=false;sync.mutex_unlock(&state.mutex)
    if state.wake[1]>=0 {byte:u8=1;posix.write(state.wake[1],&byte,1)}
    if state.worker!=nil {thread.join(state.worker);thread.destroy(state.worker);state.worker=nil}
    if state.listener>=0 {posix.close(state.listener);state.listener= -1}
    if state.owns_socket {os.remove(state.socket_path);state.owns_socket=false}
}

// Call after closing the windows and flushing the manifest. Only this
// configuration's owned socket and lock are removed.
app_instance_destroy :: proc() {
    app_instance_stop()
    state:=&app_instance_state
    for fd in state.wake {if fd>=0 {posix.close(fd)}}
    for &request in state.requests {app_instance_request_destroy(&request)}
    delete(state.requests)
    if state.owns_lock {os.remove(state.lock_path)}
    if state.lock>=0 {posix.close(state.lock)}
    delete(state.socket_path);delete(state.lock_path)
    state^=App_Instance_State{listener=-1,lock=-1,wake={-1,-1}}
}

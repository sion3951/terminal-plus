#+build linux
package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"

// The headless host owns the terminal, not merely its shell. In particular it
// answers terminal queries and archives output even when no viewer is attached.
LOCAL_SESSION_MAGIC :: u32(0x31534c4d)
LOCAL_SESSION_VERSION :: u32(1)
LOCAL_SESSION_MAX_PACKET :: TERMINAL_MAX_CELLS*(size_of(Cell)+4)+65536
Local_Session_Kind :: enum u32 {Input=1,Resize,Cancel,End,History,Clear,State,Page,Document,Attach}
Local_Session_Address :: struct {family:u16,path:[108]u8}
Local_Session_Credentials :: struct {pid:c.int,uid,gid:c.uint}
Local_Session_State :: struct {
    cols,rows,cursor_x,cursor_y:u32,
    history_count,history_epoch,history_generation:u64,
    flags:u32,
    pid:i32,
    title_len,cwd_len,error_len:u32,
    title:[256]u8,
    cwd:[4097]u8,
    error:[256]u8,
}
Local_Session_Client :: struct {
    error:[256]u8,
    error_len:int,
    socket_path:string,
    ended,loading,ready,history_pending:bool,
    screen_changed:bool,
    requested_start,requested_count,cols,rows:int,
    requested_epoch:u64,
}
local_host_wake_fd:posix.FD= -1
local_host_stopping:bool
foreign import local_session_lib "system:c"
foreign local_session_lib {
    @(link_name="socket") local_socket :: proc(domain,kind,protocol:c.int)->posix.FD ---
    @(link_name="bind") local_bind :: proc(fd:posix.FD,address:rawptr,length:c.uint)->c.int ---
    @(link_name="listen") local_listen :: proc(fd:posix.FD,count:c.int)->c.int ---
    @(link_name="connect") local_connect :: proc(fd:posix.FD,address:rawptr,length:c.uint)->c.int ---
    @(link_name="accept4") local_accept :: proc(fd:posix.FD,address:rawptr,length:rawptr,flags:c.int)->posix.FD ---
    @(link_name="getsockopt") local_sockopt :: proc(fd:posix.FD,level,name:c.int,value:rawptr,length:^c.uint)->c.int ---
    @(link_name="shutdown") local_shutdown :: proc(fd:posix.FD,how:c.int)->c.int ---
}
local_session_bytes :: proc(value:rawptr,length:int)->[]u8 {return (cast([^]u8)value)[:length]}
local_session_address :: proc(path:string)->(address:Local_Session_Address,ok:bool) {
    if len(path)>=len(address.path) {return}
    address.family=1;copy(address.path[:],transmute([]u8)path);ok=true;return
}
local_session_same_user :: proc(fd:posix.FD)->bool {
    credentials:Local_Session_Credentials;length:=c.uint(size_of(credentials))
    return local_sockopt(fd,1,17,&credentials,&length)==0&&credentials.uid==c.uint(posix.getuid())
}
local_session_directory :: proc()->string {
    runtime:=os.get_env("XDG_RUNTIME_DIR",context.temp_allocator)
    if runtime=="" {runtime="/tmp"}
    path:=fmt.tprintf("%s/minor-terminal-sessions-%d",runtime,posix.getuid())
    name:=strings.clone_to_cstring(path,context.temp_allocator)
    result:=posix.mkdir(name,{.IRUSR,.IWUSR,.IXUSR})
    if result!=.OK&&posix.errno()!=.EEXIST {return ""}
    info:posix.stat_t
    if posix.lstat(name,&info)!=.OK||!posix.S_ISDIR(info.st_mode)||info.st_uid!=posix.getuid() {return ""}
    if posix.chmod(name,{.IRUSR,.IWUSR,.IXUSR})!=.OK {return ""}
    return path
}
local_session_socket_path :: proc(id:string)->string {
    directory:=local_session_directory()
    if directory==""||!session_id_valid(id) {return ""}
    return fmt.tprintf("%s/%s.sock",directory,id)
}
local_session_packet :: proc(bytes:^[dynamic]u8,kind:Local_Session_Kind,payload:[]u8) {
    history_put_u32(bytes,LOCAL_SESSION_MAGIC);history_put_u32(bytes,u32(len(payload)));history_put_u32(bytes,u32(kind))
    append(bytes,..payload)
}
local_session_send :: proc(p:^PTY,kind:Local_Session_Kind,payload:[]u8)->bool {
    packet:=make([dynamic]u8,0,len(payload)+12);defer delete(packet)
    local_session_packet(&packet,kind,payload)
    return pty_queue_write(p,packet[:])
}
local_session_write :: proc(p:^PTY,data:[]u8)->bool {return local_session_send(p,.Input,data)}
local_session_resize :: proc(p:^PTY,cols,rows:int) {
    state:=p.session_state;if state==nil {return}
    safe_cols,safe_rows:=terminal_safe_dimensions(cols,rows)
    if state.cols==safe_cols&&state.rows==safe_rows {return}
    values:=[2]u32{u32(safe_cols),u32(safe_rows)}
    if local_session_send(p,.Resize,local_session_bytes(&values,size_of(values))) {state.cols=safe_cols;state.rows=safe_rows}
}
local_session_cancel :: proc(p:^PTY) {
    sync.mutex_lock(&p.mutex)
    // Preserve the in-flight packet and queued control messages. Dropping a
    // resize or history request would leave its client-side acknowledgement
    // state waiting forever; only queued terminal input is cancelled.
    keep:=max(p.packet_end,p.input_offset)
    position:=keep
    for position+12<=len(p.input) {
        length:=12+int(history_u32(p.input[:],position+4))
        if length>len(p.input)-position {break}
        if Local_Session_Kind(history_u32(p.input[:],position+8))!=.Input {
            copy(p.input[keep:keep+length],p.input[position:position+length]);keep+=length
        }
        position+=length
    }
    resize(&p.input,keep)
    if p.input_offset==len(p.input) {clear(&p.input);p.input_offset=0;p.packet_end=0}
    sync.mutex_unlock(&p.mutex)
    // A control connection flushes the host immediately. Its acknowledgement
    // orders the following in-stream marker after that flush, even if the
    // primary stream currently has a large paste under backpressure.
    local_session_control(p,.Cancel)
    local_session_send(p,.Cancel,nil)
}
local_session_ended :: proc(p:^PTY)->bool {return p.session_state!=nil&&p.session_state.ended}
local_session_pending :: proc(p:^PTY)->bool {
    sync.mutex_lock(&p.mutex);defer sync.mutex_unlock(&p.mutex)
    return len(p.output)>0
}
local_session_error :: proc(t:^Terminal)->string {
    if t.persistent==nil||t.persistent.session_state==nil {return ""}
    state:=t.persistent.session_state
    return strings.clone(string(state.error[:state.error_len]),context.temp_allocator)
}
local_session_loading :: proc(t:^Terminal)->bool {
    return t.persistent!=nil&&t.persistent.session_state!=nil&&(!t.persistent.session_state.ready||t.persistent.session_state.loading||t.persistent.session_state.history_pending)
}
local_session_clear :: proc(t:^Terminal) {
    if t.persistent!=nil {local_session_send(t.persistent,.Clear,nil)}
}
local_session_close :: proc(p:^PTY,end:bool) {
    if !p.persistent {return}
    if end {local_session_control(p,.End)}
    sync.mutex_lock(&p.mutex);p.stopping=true;sync.mutex_unlock(&p.mutex)
    pty_signal_worker(p)
    if p.worker!=nil {thread.join(p.worker);thread.destroy(p.worker);p.worker=nil}
    if p.master>=0 {local_shutdown(p.master,2);posix.close(p.master)}
    if p.wake[0]>=0 {posix.close(p.wake[0])};if p.wake[1]>=0 {posix.close(p.wake[1])}
    delete(p.output);delete(p.input);if p.session_state!=nil {delete(p.session_state.socket_path);free(p.session_state)}
    p^=PTY{master=-1,wake={-1,-1}}
}
local_session_read_exact :: proc(fd:posix.FD,bytes:[]u8,timeout:int)->bool {
    used:=0;began:=time.tick_now()
    for used<len(bytes) {
        elapsed:=int(time.duration_seconds(time.tick_diff(began,time.tick_now()))*1000)
        remaining:=max(0,timeout-elapsed)
        descriptor:=posix.pollfd{fd=fd,events={.IN}}
        if remaining==0||posix.poll(&descriptor,1,c.int(remaining))<=0 {return false}
        available:=len(bytes)-used
        amount:=posix.read(fd,&bytes[used],c.size_t(available))
        if amount>0 {used+=int(amount)}
        else if amount<0&&(posix.errno()==.EINTR||posix.errno()==.EAGAIN) {continue}
        else {return false}
    }
    return true
}
local_session_send_command :: proc(fd:posix.FD,kind:Local_Session_Kind)->bool {
    packet:=make([dynamic]u8);defer delete(packet);local_session_packet(&packet,kind,nil)
    position:=0
    for position<len(packet) {
        remaining:=len(packet)-position
        amount:=file_socket_send(fd,raw_data(packet[position:]),c.size_t(remaining),0x4000)
        if amount>0 {position+=int(amount)}
        else if amount<0&&posix.errno()==.EINTR {continue}
        else {return false}
    }
    return true
}
local_session_control :: proc(p:^PTY,kind:Local_Session_Kind)->bool {
    if p.session_state==nil||p.session_state.socket_path=="" {return false}
    control:=local_session_open_socket(p.session_state.socket_path)
    if control<0 {return false}
    defer posix.close(control)
    if !local_session_send_command(control,kind) {return false}
    greeting:[16]u8
    return local_session_read_exact(control,greeting[:],1000)&&history_u32(greeting[:],0)==LOCAL_SESSION_MAGIC&&history_u32(greeting[:],4)==LOCAL_SESSION_VERSION&&history_u32(greeting[:],8)==0
}
local_session_open_socket :: proc(path:string)->posix.FD {
    address,valid:=local_session_address(path);if !valid {return -1}
    fd:=local_socket(1,1|0x80000,0);if fd<0 {return -1}
    if local_connect(fd,&address,c.uint(size_of(address)))!=0||!local_session_same_user(fd) {posix.close(fd);return -1}
    return fd
}
local_session_spawn_host :: proc(id:string,cols,rows:int,command,directory:string)->bool {
    // Prepare all runtime storage before fork: the GUI may have Vulkan workers.
    arguments:=[]string{"terminal","--session-host",id,fmt.tprintf("%d",cols),fmt.tprintf("%d",rows),command,directory}
    argv:=make([]cstring,len(arguments)+1);defer {for arg in argv {if arg!=nil {delete(arg)}};delete(argv)}
    for arg,i in arguments {argv[i]=strings.clone_to_cstring(arg)}
    argv_ptr:=raw_data(argv);env_ptr:=posix.environ
    child:=posix.fork()
    if child==0 {
        if posix.setsid()<0 {posix._exit(127)}
        grandchild:=posix.fork()
        if grandchild<0 {posix._exit(127)}
        if grandchild>0 {posix._exit(0)}
        null_fd:=posix.open("/dev/null",{.RDWR})
        if null_fd>=0 {posix.dup2(null_fd,0);posix.dup2(null_fd,1);posix.dup2(null_fd,2);if null_fd>2 {posix.close(null_fd)}}
        posix.execve("/proc/self/exe",argv_ptr,env_ptr)
        posix._exit(127)
    }
    if child<0 {return false}
    status:c.int
    for posix.waitpid(child,&status,{})<0&&posix.errno()==.EINTR {}
    return status==0
}
local_session_start :: proc(p:^PTY,t:^Terminal,id:string,cols,rows:int,command,directory:string,wake_events:bool=true)->bool {
    path:=local_session_socket_path(id)
    if path=="" {session_error_set("Cannot create a private persistent-session socket directory.");return false}
    fd:=local_session_open_socket(path)
    if fd<0 {
        if !local_session_spawn_host(id,cols,rows,command,directory) {session_error_set("Cannot launch the persistent terminal service.");return false}
        for _ in 0..<400 {
            fd=local_session_open_socket(path)
            if fd>=0 {break}
            time.sleep(5*time.Millisecond)
        }
    }
    if fd<0 {session_error_set("The persistent terminal service did not start. Check session storage permissions.");return false}
    greeting:[16]u8
    handshake:=local_session_send_command(fd,.Attach)&&local_session_read_exact(fd,greeting[:],2000)
    if !handshake||history_u32(greeting[:],0)!=LOCAL_SESSION_MAGIC||history_u32(greeting[:],4)!=LOCAL_SESSION_VERSION||history_u32(greeting[:],8)!=0 {
        posix.close(fd)
        if handshake&&history_u32(greeting[:],8)==2 {session_error_set("This terminal session is already attached in another app window.")}
        else {session_error_set("Cannot attach to this terminal service version. Its running session was left intact.")}
        return false
    }
    p^=PTY{master=fd,pid=posix.pid_t(history_u32(greeting[:],12)),wake={-1,-1},persistent=true,wake_events=wake_events,alive=true}
    p.session_state=new(Local_Session_Client)
    p.session_state.socket_path=strings.clone(path)
    p.session_state.cols=cols;p.session_state.rows=rows
    flags:=posix.fcntl(fd,.GETFL)
    if flags<0||posix.fcntl(fd,.SETFL,flags|c.int(posix.O_NONBLOCK))<0||pty_pipe2(&p.wake,c.int(posix.O_CLOEXEC|posix.O_NONBLOCK))!=0 {local_session_close(p,false);return false}
    p.output=make([dynamic]u8,0,65536);p.input=make([dynamic]u8,0,4096)
    p.worker=thread.create(pty_worker)
    if p.worker==nil {local_session_close(p,false);return false}
    p.worker.data=p;t.persistent=p;thread.start(p.worker)
    // Always synchronize dimensions after attach, including a restored window.
    p.session_state.cols=0;local_session_resize(p,cols,rows)
    return true
}
local_session_history_prepare :: proc(t:^Terminal,scroll:int) {
    p:=t.persistent;if p==nil||p.session_state==nil||scroll<=0||t.alternate {return}
    state:=p.session_state
    start:=max(0,t.history_count-clamp(scroll,0,t.history_count))
    cache_cells:=max(HISTORY_VIEW_CELLS,t.cols*t.rows)
    count:=min(t.history_count-start,max(t.rows*3,128),max(1,cache_cells/t.cols))
    view:=&t.history_view
    if view.epoch==t.history_epoch&&view.start<=start&&view.start+len(view.rows)>=min(t.history_count,start+t.rows)&&view.cols>=t.cols {return}
    if state.history_pending&&state.requested_start==start&&state.requested_epoch==t.history_epoch {return}
    bytes:=make([dynamic]u8);defer delete(bytes)
    history_put_u64(&bytes,t.history_epoch);history_put_u64(&bytes,u64(start));history_put_u32(&bytes,u32(count));history_put_u32(&bytes,u32(t.cols))
    if local_session_send(p,.History,bytes[:]) {
        state.history_pending=true;state.requested_start=start;state.requested_count=count;state.requested_epoch=t.history_epoch
    }
}
local_session_apply_state :: proc(p:^PTY,t:^Terminal,payload:[]u8)->bool {
    if len(payload)<size_of(Local_Session_State) {return false}
    state:Local_Session_State;copy(local_session_bytes(&state,size_of(state)),payload[:size_of(state)])
    cols,rows:=int(state.cols),int(state.rows)
    if cols<1||rows<1||cols>TERMINAL_MAX_COLS||rows>TERMINAL_MAX_CELLS/cols||state.title_len>256||state.cwd_len>4096||state.error_len>256||state.history_count>u64(max(int)) {return false}
    if len(payload)!=size_of(state)+cols*rows*size_of(Cell) {return false}
    changed:=t.cols!=cols||t.rows!=rows||t.alternate!=(state.flags&2!=0)||t.cursor_x!=int(state.cursor_x)||t.cursor_y!=int(state.cursor_y)||t.history_epoch!=state.history_epoch||t.history_generation!=state.history_generation
    if !changed {changed=mem.compare(local_session_bytes(raw_data(t.normal_screen),len(t.normal_screen)*size_of(Cell)),payload[size_of(state):])!=0}
    p.session_state.screen_changed=p.session_state.screen_changed||changed
    if len(t.normal_screen)!=cols*rows {delete(t.normal_screen);t.normal_screen=make([]Cell,cols*rows)}
    delete(t.alternate_screen);t.alternate_screen=nil
    copy(local_session_bytes(raw_data(t.normal_screen),cols*rows*size_of(Cell)),payload[size_of(state):])
    t.screen=t.normal_screen;t.cols=cols;t.rows=rows
    t.cursor_x=clamp(int(state.cursor_x),0,cols-1);t.cursor_y=clamp(int(state.cursor_y),0,rows-1)
    if t.history_epoch!=state.history_epoch {history_page_destroy(&t.history_view);p.session_state.history_pending=false}
    t.history_count=int(state.history_count);t.history_epoch=state.history_epoch;t.history_generation=state.history_generation
    t.title=state.title;t.title_len=int(state.title_len)
    if t.cwd!=state.cwd||t.cwd_len!=int(state.cwd_len) {t.cwd=state.cwd;t.cwd_len=int(state.cwd_len);t.cwd_changed=true}
    t.cursor_visible=state.flags&1!=0;t.alternate=state.flags&2!=0;t.bracketed_paste=state.flags&4!=0;t.application_cursor=state.flags&8!=0
    client:=p.session_state;client.ended=state.flags&16!=0;client.loading=state.flags&32!=0;client.ready=true;client.error=state.error;client.error_len=int(state.error_len)
    t.dirty=true
    return true
}
local_session_apply_page :: proc(p:^PTY,t:^Terminal,payload:[]u8)->bool {
    if len(payload)<24 {return false}
    epoch:=history_u64(payload,0);start:=history_u64(payload,8);count:=int(history_u32(payload,16));cols:=int(history_u32(payload,20))
    if start>u64(max(int))||count<0||count>TERMINAL_MAX_CELLS||cols<1||cols>TERMINAL_MAX_COLS {return false}
    page:=History_Page{epoch=epoch,start=int(start),cols=cols};offset:=24;cells:=0
    for _ in 0..<count {
        if offset>len(payload)-4 {history_page_destroy(&page);return false}
        length:=int(history_u32(payload,offset));offset+=4
        if length>cols||length<0||length>TERMINAL_MAX_CELLS-cells||length*size_of(Cell)>len(payload)-offset {history_page_destroy(&page);return false}
        row:=make([]Cell,length);copy(local_session_bytes(raw_data(row),length*size_of(Cell)),payload[offset:offset+length*size_of(Cell)]);offset+=length*size_of(Cell)
        append(&page.rows,row);cells+=length
    }
    if offset!=len(payload) {history_page_destroy(&page);return false}
    if epoch==t.history_epoch {history_page_destroy(&t.history_view);t.history_view=page;t.dirty=true}
    else {history_page_destroy(&page)}
    if p.session_state.requested_start==int(start)&&p.session_state.requested_epoch==epoch {p.session_state.history_pending=false}
    return true
}
local_session_poll :: proc(p:^PTY,t:^Terminal,output:^[dynamic]u8,offset:^int)->bool {
    p.session_state.screen_changed=false
    pty_drain(p,output)
    changed:=false
    for len(output^)-offset^>=12 {
        bytes:=output^[offset^:]
        length:=int(history_u32(bytes,4));kind:=Local_Session_Kind(history_u32(bytes,8))
        if history_u32(bytes,0)!=LOCAL_SESSION_MAGIC||length>LOCAL_SESSION_MAX_PACKET {
            state:=p.session_state;state.error_len=copy(state.error[:],"Invalid persistent terminal message.");local_shutdown(p.master,2);break
        }
        if len(bytes)<12+length {break}
        payload:=bytes[12:12+length];valid:=true
        #partial switch kind {
        case .State:valid=local_session_apply_state(p,t,payload);changed=true
        case .Page:valid=local_session_apply_page(p,t,payload);changed=true
        case .Document:
            if len(payload)>0&&len(payload)<=8192&&payload[0]=='/'&&!strings.contains(string(payload),"\x00")&&len(t.document_requests)<MAX_TABS {append(&t.document_requests,strings.clone(string(payload)))}
        case:valid=false
        }
        offset^+=12+length
        if !valid {state:=p.session_state;state.error_len=copy(state.error[:],"Unsupported persistent terminal state.");local_shutdown(p.master,2);break}
    }
    if offset^>0 {copy(output^[:],output^[offset^:]);resize(output,len(output^)-offset^);offset^=0}
    return changed
}

local_session_host_signal :: proc "c" (signal:posix.Signal) {
    saved_errno:=posix.errno()
    sync.atomic_store(&local_host_stopping,true)
    if local_host_wake_fd>=0 {byte:u8=1;posix.write(local_host_wake_fd,&byte,1)}
    posix.errno(saved_errno)
}
local_session_host_wake :: proc() {
    if local_host_wake_fd>=0 {byte:u8=1;posix.write(local_host_wake_fd,&byte,1)}
}
local_session_host_state :: proc(bytes:^[dynamic]u8,t:^Terminal,p:^PTY,ended:bool) {
    state:=Local_Session_State{cols=u32(t.cols),rows=u32(t.rows),cursor_x=u32(t.cursor_x),cursor_y=u32(t.cursor_y),history_count=u64(t.history_count),history_epoch=t.history_epoch,history_generation=t.history_generation,pid=i32(p.pid),title=t.title,title_len=u32(t.title_len),cwd=t.cwd,cwd_len=u32(t.cwd_len)}
    if t.cursor_visible {state.flags|=1};if t.alternate {state.flags|=2};if t.bracketed_paste {state.flags|=4};if t.application_cursor {state.flags|=8};if ended {state.flags|=16};if terminal_history_is_restoring(t) {state.flags|=32}
    error:=terminal_history_error(t);state.error_len=u32(copy(state.error[:],transmute([]u8)error))
    payload:=make([dynamic]u8,0,size_of(state)+len(t.screen)*size_of(Cell));defer delete(payload)
    append(&payload,..local_session_bytes(&state,size_of(state)));append(&payload,..local_session_bytes(raw_data(t.screen),len(t.screen)*size_of(Cell)))
    local_session_packet(bytes,.State,payload[:])
}
local_session_host_page :: proc(bytes:^[dynamic]u8,t:^Terminal,epoch:u64,start,wanted_count,cols:int)->bool {
    if epoch!=t.history_epoch {return true}
    count:=min(wanted_count,t.history_count-start)
    if start<0||count<=0||cols<1 {return true}
    payload:=make([dynamic]u8);defer delete(payload)
    history_put_u64(&payload,epoch);history_put_u64(&payload,u64(start));history_put_u32(&payload,u32(count));history_put_u32(&payload,u32(cols))
    first:=t.history_count-t.history_recent_count
    for index in start..<start+count {
        row:[]Cell
        if index>=first {row=t.history[(t.history_start+index-first)%TERMINAL_HISTORY_LIMIT]}
        else if t.history_view.epoch==epoch&&index>=t.history_view.start&&index<t.history_view.start+len(t.history_view.rows) {row=t.history_view.rows[index-t.history_view.start]}
        else {
            h:=t.archive;if h==nil {return false}
            sync.mutex_lock(&h.mutex)
            if !h.read_pending {
                h.request_start=start;h.request_count=min(count,first-start);h.request_cols=cols;h.request_cache_cells=max(HISTORY_VIEW_CELLS,t.cols*t.rows)
                h.request_serial+=1;h.read_pending=true;sync.cond_signal(&h.cond)
            }
            sync.mutex_unlock(&h.mutex)
            return false
        }
        row=row[:min(len(row),cols)]
        history_put_u32(&payload,u32(len(row)));append(&payload,..local_session_bytes(raw_data(row),len(row)*size_of(Cell)))
    }
    local_session_packet(bytes,.Page,payload[:]);return true
}

local_session_host :: proc(args:[]string)->int {
    if len(args)!=5||!session_id_valid(args[0]) {return 2}
    cols,cols_ok:=strconv.parse_int(args[1]);rows,rows_ok:=strconv.parse_int(args[2])
    if !cols_ok||!rows_ok||cols<1||rows<1||cols>TERMINAL_MAX_COLS||rows>TERMINAL_MAX_CELLS/cols {return 2}
    path:=strings.clone(local_session_socket_path(args[0]));if path=="" {return 1};defer delete(path)
    lock_path:=fmt.aprintf("%s.lock",path);defer delete(lock_path)
    lock_fd:=posix.open(strings.clone_to_cstring(lock_path,context.temp_allocator),{.RDWR,.CREAT,.CLOEXEC,.NOFOLLOW},posix.mode_t{.IRUSR,.IWUSR})
    if lock_fd<0 {return 1}
    defer posix.close(lock_fd)
    if history_flock(lock_fd,6)!=0 {return 0}
    defer os.remove(lock_path)
    address,valid:=local_session_address(path);if !valid {return 1}
    listener:=local_socket(1,1|0x80000|0x800,0);if listener<0 {return 1}
    defer posix.close(listener)
    os.remove(path)
    if local_bind(listener,&address,c.uint(size_of(address)))!=0||local_listen(listener,8)!=0 {return 1}
    defer os.remove(path)
    wake:[2]posix.FD
    if pty_pipe2(&wake,c.int(posix.O_CLOEXEC|posix.O_NONBLOCK))!=0 {return 1}
    local_host_wake_fd=wake[1]
    old_term:=posix.signal(.SIGTERM,local_session_host_signal)
    old_int:=posix.signal(.SIGINT,local_session_host_signal)
    defer {posix.signal(.SIGTERM,old_term);posix.signal(.SIGINT,old_int)}
    defer {local_host_wake_fd= -1;posix.close(wake[0]);posix.close(wake[1])}
    t:Terminal;terminal_init(&t,cols,rows)
    terminal_set_notify(&t,local_session_host_wake)
    if !terminal_history_restore(&t,args[0]) {terminal_destroy(&t);return 1}
    defer terminal_destroy(&t)
    defer explorer_backend_destroy()
    p:PTY
    if !pty_start(&p,cols,rows,args[3],false,args[4]) {return 1}
    p.notify=local_session_host_wake
    defer pty_destroy(&p)
    client:posix.FD= -1
    defer {if client>=0 {posix.close(client)}}
    outgoing,incoming,output:=make([dynamic]u8),make([dynamic]u8),make([dynamic]u8)
    defer {delete(outgoing);delete(incoming);delete(output)}
    sent,consumed:=0,0
    ended,ending,history_pending,ever_attached,input_blocked,discard_input:=false,false,false,false,false,false
    requested_epoch:u64;requested_start,requested_count,requested_cols:int
    pending_cols,pending_rows:=cols,rows
    last_state:=time.tick_now()
    host_started:=last_state
    last_error:[256]u8;last_error_len:=0
    read_buffer:[65536]u8
    for !ending&&!sync.atomic_load(&local_host_stopping) {
        history_changed:=terminal_history_poll(&t)
        if history_changed {t.dirty=true}
        archive_error:=terminal_history_error(&t)
        if archive_error!=string(last_error[:last_error_len]) {last_error_len=copy(last_error[:],transmute([]u8)archive_error);t.dirty=true}
        if consumed==len(output) {clear(&output);consumed=0;pty_drain(&p,&output)}
        progressed:=false
        replies_ready:=true
        if len(t.replies)>0 {
            if pty_write(&p,t.replies[:]) {clear(&t.replies)} else {replies_ready=false}
        }
        if consumed<len(output)&&replies_ready {
            used:=terminal_feed(&t,output[consumed:min(len(output),consumed+65536)]);consumed+=used;progressed=used>0
        }
        if len(t.replies)>0&&pty_write(&p,t.replies[:]) {clear(&t.replies)}
        if (pending_cols!=t.cols||pending_rows!=t.rows)&&terminal_resize(&t,pending_cols,pending_rows) {pty_resize(&p,t.cols,t.rows)}
        if !pty_alive(&p)&&consumed==len(output) {
            pty_drain(&p,&output)
            if consumed==len(output)&&!ended {ended=true;t.dirty=true}
        }
        if client<0 {
            for document in t.document_requests {delete(document)};clear(&t.document_requests)
            clear(&outgoing);clear(&incoming);sent=0;history_pending=false
            if ended&&(ever_attached||time.duration_seconds(time.tick_diff(host_started,time.tick_now()))>5) {break}
        } else if sent==len(outgoing) {
            clear(&outgoing);sent=0
            if t.dirty&&time.duration_seconds(time.tick_diff(last_state,time.tick_now()))>=0.016 {
                local_session_host_state(&outgoing,&t,&p,ended);t.dirty=false;last_state=time.tick_now()
            }
            if history_pending {if local_session_host_page(&outgoing,&t,requested_epoch,requested_start,requested_count,requested_cols) {history_pending=false}}
            for document in t.document_requests {local_session_packet(&outgoing,.Document,transmute([]u8)document);delete(document)};clear(&t.document_requests)
            if ended&&!t.dirty&&len(outgoing)==0 {break}
        }
        descriptors:=[3]posix.pollfd{{fd=listener,events={.IN}},{fd=wake[0],events={.IN}},{fd=client}}
        if !input_blocked {descriptors[2].events+={.IN}}
        if client>=0&&sent<len(outgoing) {descriptors[2].events+={.OUT}}
        timeout:c.int= -1
        if client>=0&&t.dirty {timeout=16}
        if progressed {timeout=0}
        if ended {timeout=16 if client>=0 else 250}
        result:=posix.poll(raw_data(descriptors[:]),3,timeout)
        if result<0 {if posix.errno()==.EINTR {continue};break}
        if .IN in descriptors[1].revents {for posix.read(wake[0],raw_data(read_buffer[:]),len(read_buffer))>0 {}}
        // Retire disconnected viewers before accepting a replacement.
        disconnected:=false
        if client>=0&&(.HUP in descriptors[2].revents||.ERR in descriptors[2].revents||.NVAL in descriptors[2].revents) {disconnected=true}
        if client>=0&&.IN in descriptors[2].revents {
            amount:=posix.read(client,raw_data(read_buffer[:]),len(read_buffer))
            if amount>0 {append(&incoming,..read_buffer[:int(amount)])}
            else if amount==0||(posix.errno()!=.EAGAIN&&posix.errno()!=.EINTR) {disconnected=true}
        }
        offset:=0;input_blocked=false
        for client>=0&&len(incoming)-offset>=12 {
            bytes:=incoming[offset:];length:=int(history_u32(bytes,4));kind:=Local_Session_Kind(history_u32(bytes,8))
            if history_u32(bytes,0)!=LOCAL_SESSION_MAGIC||length>PTY_INPUT_LIMIT {posix.close(client);client= -1;break}
            if len(bytes)<12+length {break}
            payload:=bytes[12:12+length];accepted:=true
            #partial switch kind {
            case .Input:if !discard_input {accepted=pty_write(&p,payload)}
            case .Resize:
                if length==8 {pending_cols,pending_rows=terminal_safe_dimensions(int(history_u32(payload,0)),int(history_u32(payload,4)))}
            case .Cancel:pty_cancel_input(&p);discard_input=false
            case .End:ending=true
            case .Clear:terminal_clear_history(&t)
            case .History:
                if length==24 {
                    requested_epoch=history_u64(payload,0);start:=history_u64(payload,8)
                    requested_cols=clamp(int(history_u32(payload,20)),1,TERMINAL_MAX_COLS)
                    requested_count=min(int(history_u32(payload,16)),max(1,max(HISTORY_VIEW_CELLS,t.cols*t.rows)/requested_cols))
                    if start<=u64(max(int)) {requested_start=int(start);history_pending=true}
                }
            case:posix.close(client);client= -1
            }
            if !accepted {input_blocked=true;break}
            offset+=12+length
        }
        if offset>0 {copy(incoming[:],incoming[offset:]);resize(&incoming,len(incoming)-offset)}
        if disconnected&&client>=0 {posix.close(client);client= -1}
        if .IN in descriptors[0].revents {
            next:=local_accept(listener,nil,nil,0x80000|0x800)
            if next>=0 {
                if !local_session_same_user(next) {posix.close(next)}
                else {
                    request:[12]u8
                    if !local_session_read_exact(next,request[:],500)||history_u32(request[:],0)!=LOCAL_SESSION_MAGIC||history_u32(request[:],4)!=0 {posix.close(next);continue}
                    requested_kind:=Local_Session_Kind(history_u32(request[:],8))
                    control_request:=requested_kind==.End||requested_kind==.Cancel
                    if requested_kind==.End {ending=true}
                    if requested_kind==.Cancel {pty_cancel_input(&p);discard_input=true;input_blocked=false}
                    status:=u32(0)
                    if !control_request&&requested_kind!=.Attach {status=1}
                    else if !control_request&&client>=0 {status=2}
                    greeting:=make([dynamic]u8);history_put_u32(&greeting,LOCAL_SESSION_MAGIC);history_put_u32(&greeting,LOCAL_SESSION_VERSION);history_put_u32(&greeting,status);history_put_u32(&greeting,u32(p.pid))
                    amount:=file_socket_send(next,raw_data(greeting[:]),c.size_t(len(greeting)),0x4000);delete(greeting)
                    if amount!=16||status!=0||control_request {posix.close(next)}
                    else {client=next;ever_attached=true;clear(&incoming);clear(&outgoing);sent=0;t.dirty=true;last_state=time.Tick{};history_pending=false;input_blocked=false;discard_input=false}
                }
            }
        }
        if len(incoming)>PTY_INPUT_LIMIT+12 {if client>=0 {posix.close(client);client= -1}}
        if client>=0&&sent<len(outgoing)&&.OUT in descriptors[2].revents {
            amount:=file_socket_send(client,raw_data(outgoing[sent:]),c.size_t(min(len(outgoing)-sent,1024*1024)),0x4000)
            if amount>0 {sent+=int(amount)}
            else if amount<0&&posix.errno()!=.EAGAIN&&posix.errno()!=.EINTR {posix.close(client);client= -1}
        }
        free_all(context.temp_allocator)
    }
    return 0
}

local_session_selfcheck_cleanup :: proc(id:string) {
    path:=strings.clone(local_session_socket_path(id));defer delete(path)
    fd:=local_session_open_socket(path)
    if fd>=0 {
        local_session_send_command(fd,.End)
        greeting:[16]u8;local_session_read_exact(fd,greeting[:],1000)
        posix.close(fd)
    }
    for _ in 0..<200 {if _,error:=os.stat(path,context.temp_allocator);error==.Not_Exist {break};time.sleep(5*time.Millisecond)}
    state_root,_:=os.user_state_dir(context.temp_allocator)
    if state_root!="" {os.remove(fmt.tprintf("%s/minor-terminal/history/%s.data",state_root,id));os.remove(fmt.tprintf("%s/minor-terminal/history/%s.index",state_root,id))}
}

local_session_selfcheck :: proc()->bool {
    id:=session_new_id();defer delete(id)
    defer local_session_selfcheck_cleanup(id)
    p:PTY;t:Terminal;terminal_init(&t,80,24)
    defer terminal_destroy(&t)
    output:=make([dynamic]u8);defer delete(output);offset:=0
    if !local_session_start(&p,&t,id,80,24,"printf '\\033[?1049hPERSIST_ONE'; sleep 0.2; printf '\\rPERSIST_TWO'; sleep 20","",false) {return false}
    shell_pid:=p.pid
    for _ in 0..<200 {local_session_poll(&p,&t,&output,&offset);if p.session_state.ready&&t.alternate&&t.screen[0].ch=='P' {break};time.sleep(5*time.Millisecond)}
    first:=p.session_state.ready&&t.alternate
    local_session_close(&p,false);t.persistent=nil
    time.sleep(300*time.Millisecond)
    if !local_session_start(&p,&t,id,80,24,"exit 99","",false) {return false}
    defer {local_session_close(&p,true);t.persistent=nil}
    for _ in 0..<200 {local_session_poll(&p,&t,&output,&offset);if p.session_state.ready&&t.alternate&&t.screen[8].ch=='T'&&t.screen[9].ch=='W'&&t.screen[10].ch=='O' {break};time.sleep(5*time.Millisecond)}
    second:=p.pid==shell_pid&&t.alternate&&t.screen[8].ch=='T'&&t.screen[9].ch=='W'&&t.screen[10].ch=='O'
    // End the isolated session and verify cleanup before reporting success.
    path:=strings.clone(local_session_socket_path(id));defer delete(path)
    local_session_close(&p,true);t.persistent=nil
    cleaned:=false
    for _ in 0..<200 {if _,error:=os.stat(path,context.temp_allocator);error==.Not_Exist {cleaned=true;break};time.sleep(5*time.Millisecond)}
    second=second&&cleaned
    fmt.printf("Persistent local session: detached, reattached PID %d, alternate screen and detached output retained: %v\n",shell_pid,first&&second)
    return first&&second
}

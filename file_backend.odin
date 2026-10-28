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

File_Entry :: struct {name:string,size:i64,directory,symlink:bool}
File_Request_Kind :: enum {List,Page,Preview}
File_Result :: struct {
    kind:File_Request_Kind,
    path,error:string,
    entries:[dynamic]File_Entry,
    page_offset,total_entries,matched_entries:int,
    query:string,
    show_hidden:bool,
    preview:[]u8,
    truncated:bool,
}
File_Browser :: struct {
    mutex:sync.Mutex,
    cond:sync.Cond,
    worker:^thread.Thread,
    remote,stopping,pending,busy,ready:bool,
    device:Device_Profile,
    request_path,request_query:string,
    request_hidden:bool,
    request_offset,request_limit,indexed:int,
    catalog:File_Catalog,
    wake_events:bool,
    request_kind:File_Request_Kind,
    generation:u64,
    result:File_Result,
}
FILE_PREVIEW_LIMIT :: 128*1024
FILE_PACKET_LIMIT :: 4*1024*1024
file_runtime_directory:string
foreign import file_lib "system:c"
foreign file_lib {
    @(link_name="socketpair") file_socketpair :: proc(domain,kind,protocol:c.int,fds:^[2]posix.FD)->c.int ---
    @(link_name="send") file_socket_send :: proc(fd:posix.FD,data:rawptr,length:c.size_t,flags:c.int)->c.ssize_t ---
    @(link_name="realpath") file_realpath :: proc(path:cstring,resolved:rawptr)->cstring ---
    @(link_name="free") file_cfree :: proc(data:rawptr) ---
    @(link_name="chmod") file_chmod :: proc(path:cstring,mode:c.uint)->c.int ---
}

explorer_backend_init :: proc()->bool {
    if file_runtime_directory!="" {return true}
    path,error:=os.make_directory_temp("/tmp","minor-terminal-*",context.allocator)
    if error!=nil {return false}
    if file_chmod(strings.clone_to_cstring(path,context.temp_allocator),0o700)!=0 {os.remove(path);delete(path);return false}
    file_runtime_directory=path
    return true
}
explorer_backend_destroy :: proc() {
    if file_runtime_directory=="" {return}
    // Only this instance's private socket directory is owned here. SSH normally
    // unlinks its sockets; remove any stale owned names after all clients stop.
    entries,error:=os.read_directory_by_path(file_runtime_directory,1024,context.temp_allocator)
    if error==nil {for entry in entries {if entry.name!="."&&entry.name!=".." {os.remove(entry.fullpath)}}}
    os.remove(file_runtime_directory)
    delete(file_runtime_directory);file_runtime_directory=""
}
ssh_control_path :: proc(profile:Device_Profile)->string {
    if file_runtime_directory=="" {return ""}
    hash:u64=14695981039346656037
    for byte in transmute([]u8)profile.target {hash=(hash~u64(byte))*1099511628211}
    hash=(hash~u64(profile.port))*1099511628211
    for byte in transmute([]u8)profile.control_id {hash=(hash~u64(byte))*1099511628211}
    return fmt.tprintf("%s/s-%016x",file_runtime_directory,hash)
}
explorer_remote_ready :: proc(profile:Device_Profile)->bool {
    path:=ssh_control_path(profile)
    if path=="" {return false}
    info,error:=os.lstat(path,context.temp_allocator)
    return error==nil&&info.type==.Socket
}
explorer_result_destroy :: proc(result:^File_Result) {
    delete(result.path);delete(result.error);delete(result.preview);delete(result.query)
    for entry in result.entries {delete(entry.name)}
    delete(result.entries);result^={}
}
explorer_browser_init :: proc(b:^File_Browser,remote:bool,device:Device_Profile)->bool {
    b.remote=remote;b.device=device;b.wake_events=true
    b.device.name=strings.clone(device.name);b.device.target=strings.clone(device.target)
    b.worker=thread.create(file_browser_worker)
    if b.worker==nil {delete(b.device.name);delete(b.device.target);b.device={};return false}
    b.worker.data=b;thread.start(b.worker)
    return true
}
explorer_request :: proc(b:^File_Browser,path:string,kind:File_Request_Kind=.List) {
    sync.mutex_lock(&b.mutex)
    if b.stopping||b.worker==nil {sync.mutex_unlock(&b.mutex);return}
    delete(b.request_path);b.request_path=strings.clone(path)
    b.request_kind=kind;b.pending=true;b.busy=true;b.generation+=1
    if kind==.List {b.indexed=0}
    // A superseded completed result must not be delivered after this request.
    if b.ready {explorer_result_destroy(&b.result);b.ready=false}
    sync.mutex_unlock(&b.mutex);sync.cond_signal(&b.cond)
}
explorer_query :: proc(b:^File_Browser,query:string,show_hidden:bool,offset:int=0,limit:int=512) {
    sync.mutex_lock(&b.mutex)
    if b.stopping||b.worker==nil {sync.mutex_unlock(&b.mutex);return}
    delete(b.request_path);b.request_path=""
    delete(b.request_query);b.request_query=strings.clone(query)
    b.request_hidden=show_hidden;b.request_offset=max(0,offset);b.request_limit=max(1,limit)
    b.request_kind=.Page;b.pending=true;b.busy=true;b.generation+=1
    if b.ready {explorer_result_destroy(&b.result);b.ready=false}
    sync.mutex_unlock(&b.mutex);sync.cond_signal(&b.cond)
}
explorer_progress :: proc(b:^File_Browser)->(indexed:int,busy:bool) {
    sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
    return b.indexed,b.busy
}
explorer_take :: proc(b:^File_Browser,result:^File_Result)->bool {
    sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
    if !b.ready {return false}
    result^=b.result;b.result={};b.ready=false
    return true
}
explorer_busy :: proc(b:^File_Browser)->bool {
    sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
    return b.busy
}
explorer_browser_destroy :: proc(b:^File_Browser) {
    if b.worker==nil {return}
    sync.mutex_lock(&b.mutex);b.stopping=true;b.generation+=1;sync.mutex_unlock(&b.mutex)
    sync.cond_signal(&b.cond)
    thread.join(b.worker);thread.destroy(b.worker);b.worker=nil
    delete(b.request_path);delete(b.request_query);delete(b.device.name);delete(b.device.target)
    explorer_result_destroy(&b.result)
}
file_request_cancelled :: proc(b:^File_Browser,generation:u64)->bool {
    sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
    return b.stopping||generation!=b.generation
}
file_browser_worker :: proc(worker:^thread.Thread) {
    b:=cast(^File_Browser)worker.data
    defer file_catalog_destroy(&b.catalog)
    for {
        sync.mutex_lock(&b.mutex)
        for !b.stopping&&!b.pending {sync.cond_wait(&b.cond,&b.mutex)}
        if b.stopping {sync.mutex_unlock(&b.mutex);break}
        path:=b.request_path;b.request_path=""
        query:=b.request_query;b.request_query=""
        kind,generation:=b.request_kind,b.generation;b.pending=false
        hidden,offset,limit:=b.request_hidden,b.request_offset,b.request_limit
        sync.mutex_unlock(&b.mutex)
        result:=File_Result{kind=kind,path=strings.clone(path)}
        if kind==.Page {file_catalog_query(&b.catalog,generation,query,hidden,offset,limit,&result)}
        else {
            ready:=true
            if kind==.List {ready=file_catalog_begin(&b.catalog,b,generation)}
            if !ready {file_set_error(&result,b.catalog.error)}
            else {
                if b.remote {file_remote_request(b,generation,path,&result)} else {file_local_request(b,generation,path,&result)}
                if kind==.List&&result.error=="" {
                    if file_catalog_finish(&b.catalog,result.path) {file_catalog_query(&b.catalog,generation,"",false,0,FILE_PAGE_LIMIT,&result)}
                    else {file_set_error(&result,b.catalog.error)}
                }
            }
        }
        delete(path);delete(query)
        sync.mutex_lock(&b.mutex)
        publish:= !b.stopping&&b.generation==generation
        if publish {explorer_result_destroy(&b.result);b.result=result;b.ready=true;b.busy=false}
        sync.mutex_unlock(&b.mutex)
        if publish {if b.wake_events {glfw.PostEmptyEvent()}} else {explorer_result_destroy(&result)}
        free_all(context.temp_allocator)
    }
}
file_set_error :: proc(result:^File_Result,message:string) {delete(result.error);result.error=strings.clone(message)}
file_local_request :: proc(b:^File_Browser,generation:u64,path:string,result:^File_Result) {
    requested:=path
    if requested=="" {requested="."}
    resolved:=file_realpath(strings.clone_to_cstring(requested,context.temp_allocator),nil)
    if resolved==nil {file_set_error(result,fmt.tprintf("Cannot access path: %v",posix.errno()));return}
    delete(result.path);result.path=strings.clone(string(resolved));file_cfree(rawptr(resolved))
    if result.kind==.Preview {
        info,error:=os.stat(result.path,context.temp_allocator)
        if error!=nil {file_set_error(result,fmt.tprintf("Cannot read file: %v",error));return}
        if info.type!=.Regular {file_set_error(result,"Preview supports regular files only.");return}
        file,open_error:=os.open(result.path)
        if open_error!=nil {file_set_error(result,fmt.tprintf("Cannot open file: %v",open_error));return}
        defer os.close(file)
        data:=make([]u8,min(int(max(info.size,0)),FILE_PREVIEW_LIMIT)+1)
        used:=0
        for used<len(data)&&!file_request_cancelled(b,generation) {
            n,read_error:=os.read(file,data[used:]);used+=n
            if n<=0||read_error!=nil {break}
        }
        result.truncated=used>FILE_PREVIEW_LIMIT||info.size>FILE_PREVIEW_LIMIT
        result.preview=make([]u8,min(used,FILE_PREVIEW_LIMIT));copy(result.preview,data[:len(result.preview)]);delete(data)
        return
    }
    directory:=posix.opendir(strings.clone_to_cstring(result.path,context.temp_allocator))
    if directory==nil {file_set_error(result,fmt.tprintf("Cannot open directory: %v",posix.errno()));return}
    defer posix.closedir(directory)
    for {
        if file_request_cancelled(b,generation) {return}
        posix.errno(.NONE)
        info:=posix.readdir(directory)
        if info==nil {
            if posix.errno()!=.NONE {file_set_error(result,fmt.tprintf("Cannot read directory: %v",posix.errno()))}
            break
        }
        name:=string(cast(cstring)&info.d_name[0])
        if name=="."||name==".." {continue}
        entry:=File_Entry{name=name,size= -1,directory=info.d_type==.DIR,symlink=info.d_type==.LNK}
        if entry.symlink||info.d_type==.UNKNOWN {
            full:=fmt.tprintf("%s/%s",result.path,name)
            target,follow_error:=os.stat(full,context.temp_allocator)
            if follow_error==nil {entry.directory=target.type==.Directory;entry.size=target.size}
        }
        if !file_catalog_add(&b.catalog,entry) {file_set_error(result,b.catalog.error);return}
        if b.catalog.total%2048==0 {free_all(context.temp_allocator)}
    }
}

// Each remote request opens a short SFTP channel on the existing authenticated
// master. Binary filenames/attributes never pass through a shell or `ls` text.
File_SFTP :: struct {
    browser:^File_Browser,
    generation:u64,
    pid:posix.pid_t,
    io,stderr:posix.FD,
    sequence:u32,
    deadline:time.Tick,
    diagnostic:[dynamic]u8,
    error:string,
}
file_sftp_spawn :: proc(s:^File_SFTP,profile:Device_Profile)->bool {
    s.io= -1;s.stderr= -1
    if !explorer_remote_ready(profile) {s.error="Finish SSH login in the terminal, then refresh Files.";return false}
    control:=ssh_control_path(profile)
    arguments:=make([dynamic]string,context.temp_allocator)
    append(&arguments,"ssh","-S",control,"-o","ControlMaster=no","-o","BatchMode=yes","-o","ProxyCommand=false","-o","PermitLocalCommand=no","-o","RemoteCommand=none","-T","-s")
    if profile.port>0 {append(&arguments,"-p",fmt.tprintf("%d",profile.port))}
    append(&arguments,"--",profile.target,"sftp")
    args:=make([]cstring,len(arguments)+1)
    defer {for argument in args {if argument!=nil {delete(argument)}};delete(args)}
    for arg,i in arguments {args[i]=strings.clone_to_cstring(arg)}
    socket:[2]posix.FD
    if file_socketpair(1,1|0x80000,0,&socket)!=0 {s.error="Cannot create SFTP channel.";return false}
    errors:[2]posix.FD
    if pty_pipe2(&errors,c.int(posix.O_CLOEXEC))!=0 {posix.close(socket[0]);posix.close(socket[1]);s.error="Cannot create SFTP error pipe.";return false}
    argv:=raw_data(args);env:=posix.environ
    pid:=posix.fork()
    if pid==0 {
        posix.close(socket[0]);posix.close(errors[0])
        posix.dup2(socket[1],0);posix.dup2(socket[1],1);posix.dup2(errors[1],2)
        if socket[1]>2 {posix.close(socket[1])};if errors[1]>2 {posix.close(errors[1])}
        posix.execve("/usr/bin/ssh",argv,env);posix._exit(127)
    }
    posix.close(socket[1]);posix.close(errors[1])
    if pid<0 {posix.close(socket[0]);posix.close(errors[0]);s.error="Cannot start SFTP channel.";return false}
    s.pid=pid;s.io=socket[0];s.stderr=errors[0]
    descriptors:=[2]posix.FD{s.io,s.stderr}
    for fd in descriptors {flags:=posix.fcntl(fd,.GETFL);posix.fcntl(fd,.SETFL,flags|c.int(posix.O_NONBLOCK))}
    s.deadline=time.tick_now()
    return true
}
file_sftp_destroy :: proc(s:^File_SFTP) {
    if s.io>=0 {posix.close(s.io);s.io= -1};if s.stderr>=0 {posix.close(s.stderr);s.stderr= -1}
    if s.pid>0 {
        status:c.int
        reaped:=false
        for _ in 0..<10 {
            ret:=posix.waitpid(s.pid,&status,{.NOHANG})
            if ret==s.pid||(ret<0&&posix.errno()==.ECHILD) {reaped=true;break}
            time.sleep(time.Millisecond)
        }
        if !reaped {posix.kill(s.pid,.SIGKILL);for posix.waitpid(s.pid,&status,{})<0&&posix.errno()==.EINTR {}}
    }
    delete(s.diagnostic)
}
file_sftp_check :: proc(s:^File_SFTP)->bool {
    if file_request_cancelled(s.browser,s.generation) {s.error="Cancelled.";return false}
    if time.duration_seconds(time.tick_diff(s.deadline,time.tick_now()))>20 {s.error="SFTP channel made no progress for 20 seconds.";return false}
    return true
}
file_sftp_poll :: proc(s:^File_SFTP,writing:bool)->bool {
    if !file_sftp_check(s) {return false}
    fds:=[2]posix.pollfd{{fd=s.io,events={.IN}},{fd=s.stderr,events={.IN}}}
    if writing {fds[0].events={.OUT}}
    result:=posix.poll(raw_data(fds[:]),2,100)
    if result<0 {if posix.errno()==.EINTR {return true};s.error="SFTP channel polling failed.";return false}
    if .IN in fds[1].revents||.HUP in fds[1].revents {
        bytes:[1024]u8
        amount:=posix.read(s.stderr,raw_data(bytes[:]),len(bytes))
        if amount>0&&len(s.diagnostic)<4096 {append(&s.diagnostic,..bytes[:min(int(amount),4096-len(s.diagnostic))])}
        if amount==0 {posix.close(s.stderr);s.stderr= -1}
    }
    return true
}
file_sftp_write :: proc(s:^File_SFTP,data:[]u8)->bool {
    offset:=0
    for offset<len(data) {
        if !file_sftp_check(s) {return false}
        remaining:=len(data)-offset
        amount:=file_socket_send(s.io,&data[offset],c.size_t(remaining),0x4000) // MSG_NOSIGNAL
        if amount>0 {offset+=int(amount);s.deadline=time.tick_now()}
        else if amount<0&&posix.errno()==.EAGAIN {if !file_sftp_poll(s,true) {return false}}
        else if amount<0&&posix.errno()==.EINTR {continue}
        else {s.error="SFTP channel closed.";return false}
    }
    return true
}
file_sftp_read :: proc(s:^File_SFTP,data:[]u8)->bool {
    offset:=0
    for offset<len(data) {
        if !file_sftp_check(s) {return false}
        remaining:=len(data)-offset
        amount:=posix.read(s.io,&data[offset],c.size_t(remaining))
        if amount>0 {offset+=int(amount);s.deadline=time.tick_now()}
        else if amount<0&&posix.errno()==.EAGAIN {if !file_sftp_poll(s,false) {return false}}
        else if amount<0&&posix.errno()==.EINTR {continue}
        else {s.error="SFTP channel closed. The server may not offer SFTP.";return false}
    }
    return true
}
file_put_u32 :: proc(data:^[dynamic]u8,v:u32) {append(data,u8(v>>24),u8(v>>16),u8(v>>8),u8(v))}
file_put_u64 :: proc(data:^[dynamic]u8,v:u64) {file_put_u32(data,u32(v>>32));file_put_u32(data,u32(v))}
file_put_string :: proc(data:^[dynamic]u8,value:string) {file_put_u32(data,u32(len(value)));append(data,value)}
file_sftp_send :: proc(s:^File_SFTP,kind:u8,payload:[]u8)->bool {
    packet:=make([dynamic]u8,0,len(payload)+9);defer delete(packet)
    file_put_u32(&packet,u32(len(payload)+5));append(&packet,kind);s.sequence+=1;file_put_u32(&packet,s.sequence);append(&packet,..payload)
    return file_sftp_write(s,packet[:])
}
file_sftp_packet :: proc(s:^File_SFTP)->[]u8 {
    header:[4]u8
    if !file_sftp_read(s,header[:]) {return nil}
    count:=u32(header[0])<<24|u32(header[1])<<16|u32(header[2])<<8|u32(header[3])
    if count<1||count>FILE_PACKET_LIMIT {s.error="Invalid SFTP packet length.";return nil}
    packet:=make([]u8,int(count))
    if !file_sftp_read(s,packet) {delete(packet);return nil}
    return packet
}
File_Decoder :: struct {data:[]u8,offset:int,valid:bool}
file_take :: proc(d:^File_Decoder,n:int)->[]u8 {
    if !d.valid||n<0||n>len(d.data)-d.offset {d.valid=false;return nil}
    data:=d.data[d.offset:d.offset+n];d.offset+=n;return data
}
file_u32 :: proc(d:^File_Decoder)->u32 {bytes:=file_take(d,4);if !d.valid {return 0};return u32(bytes[0])<<24|u32(bytes[1])<<16|u32(bytes[2])<<8|u32(bytes[3])}
file_u64 :: proc(d:^File_Decoder)->u64 {hi:=file_u32(d);lo:=file_u32(d);return (u64(hi)<<32)|u64(lo)}
file_string :: proc(d:^File_Decoder)->string {n:=file_u32(d);return string(file_take(d,int(n)))}
file_attrs :: proc(d:^File_Decoder)->(size:i64,mode:u32) {
    flags:=file_u32(d)
    if flags&1!=0 {size=i64(min(file_u64(d),u64(0x7fffffffffffffff)))}
    if flags&2!=0 {file_take(d,8)}
    if flags&4!=0 {mode=file_u32(d)}
    if flags&8!=0 {file_take(d,8)}
    if flags&0x80000000!=0 {count:=file_u32(d);if count>100000 {d.valid=false;return};for _ in 0..<count {file_string(d);file_string(d)}}
    if flags&0x7ffffff0!=0 {d.valid=false}
    return
}
file_sftp_response :: proc(s:^File_SFTP,packet:[]u8)->(kind:u8,d:File_Decoder) {
    id:u32
    kind,id,d=file_sftp_response_any(s,packet)
    if d.valid&&id!=s.sequence {d.valid=false;s.error="SFTP response ID mismatch."}
    return
}
file_sftp_response_any :: proc(s:^File_SFTP,packet:[]u8)->(kind:u8,id:u32,d:File_Decoder) {
    d=File_Decoder{data=packet,valid=len(packet)>=5}
    bytes:=file_take(&d,1);if !d.valid {s.error="Invalid SFTP response.";return}
    kind=bytes[0]
    id=file_u32(&d)
    return
}
file_sftp_status :: proc(s:^File_SFTP,d:^File_Decoder)->u32 {
    code:=file_u32(d);message:=file_string(d)
    if !d.valid {s.error="Invalid SFTP status.";return 0xffffffff}
    if code!=0&&code!=1 {s.error=strings.clone(fmt.tprintf("SFTP: %s",message),context.temp_allocator)}
    return code
}
file_sftp_close_handle :: proc(s:^File_SFTP,handle:string) {
    payload:=make([dynamic]u8,context.temp_allocator);file_put_string(&payload,handle)
    if file_sftp_send(s,4,payload[:]) {packet:=file_sftp_packet(s);delete(packet)}
}
file_remote_request :: proc(b:^File_Browser,generation:u64,path:string,result:^File_Result) {
    s:=File_SFTP{browser=b,generation=generation,io= -1,stderr= -1}
    defer file_sftp_destroy(&s)
    defer {
        if s.error!="" {
            diagnostic:=strings.trim_space(string(s.diagnostic[:]))
            if diagnostic!="" {file_set_error(result,fmt.tprintf("%s\n%s",s.error,diagnostic))} else {file_set_error(result,s.error)}
        }
    }
    if !file_sftp_spawn(&s,b.device) {return}
    initial:=[9]u8{0,0,0,5,1,0,0,0,3}
    if !file_sftp_write(&s,initial[:]) {return}
    version:=file_sftp_packet(&s)
    valid_version:=len(version)>=5&&version[0]==2&&version[1]==0&&version[2]==0&&version[3]==0&&version[4]==3
    delete(version)
    if !valid_version {if s.error=="" {s.error="The server does not support SFTP version 3."};return}
    requested:=path;if requested=="" {requested="."}
    payload:=make([dynamic]u8,context.temp_allocator)
    file_put_string(&payload,requested)
    if !file_sftp_send(&s,16,payload[:]) {return}
    packet:=file_sftp_packet(&s);if packet==nil {return}
    kind,d:=file_sftp_response(&s,packet)
    if kind==101 {file_sftp_status(&s,&d);delete(packet);return}
    if kind!=104||file_u32(&d)<1 {delete(packet);s.error="Invalid SFTP path response.";return}
    resolved:=file_string(&d)
    if !d.valid||resolved=="" {delete(packet);s.error="Invalid remote path.";return}
    delete(result.path);result.path=strings.clone(resolved);delete(packet)
    clear(&payload);file_put_string(&payload,result.path)
    if result.kind==.Preview {file_put_u32(&payload,1);file_put_u32(&payload,0)}
    operation:u8=11;if result.kind==.Preview {operation=3}
    if !file_sftp_send(&s,operation,payload[:]) {return}
    packet=file_sftp_packet(&s);if packet==nil {return}
    kind,d=file_sftp_response(&s,packet)
    if kind==101 {file_sftp_status(&s,&d);delete(packet);return}
    if kind!=102 {delete(packet);s.error="Invalid SFTP handle response.";return}
    handle:=strings.clone(file_string(&d));defer delete(handle)
    if !d.valid {delete(packet);s.error="Invalid SFTP handle.";return}
    delete(packet)
    if result.kind==.Preview {file_sftp_preview(&s,handle,result)} else {file_sftp_list(&s,handle,result)}
    if s.error=="" {file_sftp_close_handle(&s,handle)}
}

// At most five reads cover the bounded preview. Issue them together so network
// latency is paid once rather than once per 32 KiB block. Short reads are filled
// with a new request for the remaining range; replies may arrive out of order.
File_SFTP_Read :: struct {id:u32,offset,length:int,done:bool}
file_sftp_preview :: proc(s:^File_SFTP,handle:string,result:^File_Result) {
    CHUNK :: 32768
    LIMIT :: FILE_PREVIEW_LIMIT+1
    slots:[(LIMIT+CHUNK-1)/CHUNK]File_SFTP_Read
    bytes:=make([]u8,LIMIT);defer delete(bytes)
    payload:=make([dynamic]u8,0,len(handle)+24);defer delete(payload)
    for &slot,i in slots {
        slot.offset=i*CHUNK;slot.length=min(CHUNK,LIMIT-slot.offset)
        clear(&payload);file_put_string(&payload,handle);file_put_u64(&payload,u64(slot.offset));file_put_u32(&payload,u32(slot.length))
        if !file_sftp_send(s,5,payload[:]) {return};slot.id=s.sequence
    }
    pending:=len(slots);size:=LIMIT
    for pending>0 {
        packet:=file_sftp_packet(s);if packet==nil {return}
        kind,id,d:=file_sftp_response_any(s,packet)
        index:= -1
        for slot,i in slots {if !slot.done&&slot.id==id {index=i;break}}
        if !d.valid||index<0 {delete(packet);s.error="SFTP read response ID mismatch.";return}
        slot:=&slots[index]
        if kind==101 {
            code:=file_sftp_status(s,&d);delete(packet)
            if code!=1 {if s.error=="" {s.error="Unexpected SFTP file status."};return}
            size=min(size,slot.offset);slot.done=true;pending-=1
        } else if kind==103 {
            data:=file_string(&d)
            if !d.valid||len(data)==0||len(data)>slot.length {delete(packet);s.error="Invalid SFTP file data.";return}
            copy(bytes[slot.offset:slot.offset+len(data)],transmute([]u8)data)
            slot.offset+=len(data);slot.length-=len(data);delete(packet)
            if slot.length==0 {slot.done=true;pending-=1}
            else {
                clear(&payload);file_put_string(&payload,handle);file_put_u64(&payload,u64(slot.offset));file_put_u32(&payload,u32(slot.length))
                if !file_sftp_send(s,5,payload[:]) {return};slot.id=s.sequence
            }
        } else {delete(packet);s.error="Invalid SFTP file data response.";return}
    }
    result.truncated=size>FILE_PREVIEW_LIMIT
    result.preview=make([]u8,min(size,FILE_PREVIEW_LIMIT));copy(result.preview,bytes[:len(result.preview)])
}

// Classify symlink targets in a bounded window, retaining the same directory
// behavior without a separate network round trip for every symbolic link.
file_sftp_classify_links :: proc(s:^File_SFTP,result:^File_Result) {
    WINDOW :: 32
    indices:[WINDOW]int
    ids:[WINDOW]u32
    done:[WINDOW]bool
    next:=0
    payload:=make([dynamic]u8,0,256);defer delete(payload)
    for next<len(result.entries) {
        count:=0
        for next<len(result.entries)&&count<WINDOW {
            index:=next;next+=1
            if !result.entries[index].symlink {continue}
            entry:=result.entries[index]
            clear(&payload)
            separator:="/";if strings.has_suffix(result.path,"/") {separator=""}
            file_put_string(&payload,fmt.tprintf("%s%s%s",result.path,separator,entry.name))
            if !file_sftp_send(s,17,payload[:]) {return}
            indices[count]=index;ids[count]=s.sequence;done[count]=false;count+=1
        }
        for _ in 0..<count {
            packet:=file_sftp_packet(s);if packet==nil {return}
            kind,id,d:=file_sftp_response_any(s,packet)
            slot:= -1
            for i in 0..<count {if !done[i]&&ids[i]==id {slot=i;break}}
            if !d.valid||slot<0 {delete(packet);s.error="SFTP stat response ID mismatch.";return}
            done[slot]=true
            if kind==105 {
                size,mode:=file_attrs(&d)
                if !d.valid {delete(packet);s.error="Invalid SFTP link attributes.";return}
                entry:=&result.entries[indices[slot]]
                entry.directory=mode&0o170000==0o040000;entry.size=size
            } else if kind!=101 {delete(packet);s.error="Invalid SFTP stat response.";return}
            // Inaccessible/broken targets remain listed as symlinks.
            delete(packet)
        }
    }
}

file_sftp_list :: proc(s:^File_SFTP,handle:string,result:^File_Result) {
    for {
        payload:=make([dynamic]u8,context.temp_allocator);file_put_string(&payload,handle)
        if !file_sftp_send(s,12,payload[:]) {return}
        packet:=file_sftp_packet(s);if packet==nil {return}
        kind,d:=file_sftp_response(s,packet)
        if kind==101 {code:=file_sftp_status(s,&d);delete(packet);if code==1 {return};if s.error=="" {s.error="Unexpected SFTP directory status."};return}
        if kind!=104 {delete(packet);s.error="Invalid SFTP directory data.";return}
        count:=file_u32(&d)
        // Count is bounded by the already validated packet bytes, not the size
        // of the directory. Every encoded entry needs at least 12 bytes.
        if count==0||u64(count)>u64(len(packet))/12 {delete(packet);s.error="Invalid SFTP directory entry count.";return}
        batch:=File_Result{}
        for _ in 0..<count {
            name:=file_string(&d);file_string(&d)
            size,mode:=file_attrs(&d)
            if !d.valid {s.error="Invalid SFTP directory attributes.";break}
            if name=="."||name==".." {continue}
            if strings.contains(name,"/")||strings.contains(name,"\x00") {s.error="Invalid SFTP filename.";break}
            append(&batch.entries,File_Entry{name=strings.clone(name),size=size,directory=mode&0o170000==0o040000,symlink=mode&0o170000==0o120000})
        }
        delete(packet)
        if s.error=="" {
            batch.path=strings.clone(result.path)
            file_sftp_classify_links(s,&batch)
            if s.error=="" {
                for entry in batch.entries {
                    if !file_catalog_add(&s.browser.catalog,entry) {s.error=strings.clone(s.browser.catalog.error,context.temp_allocator);break}
                }
            }
        }
        explorer_result_destroy(&batch)
        if s.error!="" {return}
        free_all(context.temp_allocator)
    }
}

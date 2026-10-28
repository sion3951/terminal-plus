#+build linux
package main

import "core:c"
import "core:encoding/json"
import "core:encoding/base64"
import "core:math"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import posix "core:sys/posix"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"

// Chromium's private inherited pipes control the live page without exposing a
// debugging port, reloading the document, or changing its DOM and image colors.
Document_Command :: struct {method,params:string,clipboard:bool}
Document_Viewport :: struct {width,height:int,scale,zoom:f64,visible:bool}
document_control_identity:u64
Document_Control :: struct {
    initialized:bool,
    child_in,child_out,parent_in,parent_out:posix.FD,
    wake:[2]posix.FD,
    worker,decoder:^thread.Thread,
    stopping,dark,closed:bool,
    mutex:sync.Mutex,
    decode_cond:sync.Cond,
    error:[256]u8,
    error_length:int,
    sequence:i64,
    identity,generation,revision:u64,
    viewport:Document_Viewport,
    commands:[dynamic]Document_Command,
    encoded:[]u8,
    pixels:rawptr,
    pixel_width,pixel_height:int,
    clipboard:string,
    clipboard_ready:bool,
}

document_control_fail :: proc(control:^Document_Control,message:string) {
    if sync.atomic_load(&control.stopping) {return}
    sync.mutex_lock(&control.mutex)
    control.error_length=copy(control.error[:],transmute([]u8)message)
    sync.mutex_unlock(&control.mutex)
    glfw.PostEmptyEvent()
}
document_control_error :: proc(control:^Document_Control)->string {
    if !control.initialized {return ""}
    sync.mutex_lock(&control.mutex);defer sync.mutex_unlock(&control.mutex)
    return strings.clone(string(control.error[:control.error_length]),context.temp_allocator)
}

document_control_pipe :: proc(fds:^[2]posix.FD,nonblocking:bool=false)->bool {
    flags:=c.int(posix.O_CLOEXEC)
    if nonblocking {flags|=c.int(posix.O_NONBLOCK)}
    if pty_pipe2(fds,flags)!=0 {return false}
    // None of the original pipe ends may collide with Chrome's reserved 3/4.
    for &fd in fds^ {
        if fd<=4 {
            replacement:=posix.fcntl(fd,.DUPFD_CLOEXEC,c.int(5))
            if replacement<0 {posix.close(fds[0]);posix.close(fds[1]);fds^={-1,-1};return false}
            posix.close(fd);fd=posix.FD(replacement)
        }
    }
    return true
}
document_control_init :: proc(control:^Document_Control)->bool {
    control.initialized=true
    document_control_identity+=1;control.identity=document_control_identity
    control.viewport={width=800,height=600,scale=1,zoom=1};control.revision=1
    control.child_in= -1;control.child_out= -1;control.parent_in= -1;control.parent_out= -1;control.wake={-1,-1}
    input,output:[2]posix.FD
    if !document_control_pipe(&input) {return false}
    control.child_in=input[0];control.parent_in=input[1]
    if !document_control_pipe(&output) {return false}
    control.parent_out=output[0];control.child_out=output[1]
    if !document_control_pipe(&control.wake,true) {return false}
    for fd in ([2]posix.FD{control.parent_in,control.parent_out}) {
        flags:=posix.fcntl(fd,.GETFL)
        if flags<0||posix.fcntl(fd,.SETFL,flags|c.int(posix.O_NONBLOCK))<0 {return false}
    }
    return true
}

// This function runs between fork and exec: only async-signal-safe C calls.
document_control_child_setup :: proc "contextless" (control:^Document_Control) {
    posix.dup2(control.child_in,3);posix.dup2(control.child_out,4)
    posix.close(control.child_in);posix.close(control.child_out)
    posix.close(control.parent_in);posix.close(control.parent_out)
    posix.close(control.wake[0]);posix.close(control.wake[1])
}
document_control_parent_started :: proc(control:^Document_Control)->bool {
    if !control.initialized {return false}
    if control.child_in>=0 {posix.close(control.child_in);control.child_in= -1}
    if control.child_out>=0 {posix.close(control.child_out);control.child_out= -1}
    control.decoder=thread.create(document_decode_worker)
    if control.decoder==nil {document_control_fail(control,"Could not start document image decoding.");return false}
    control.decoder.data=control;thread.start(control.decoder)
    control.worker=thread.create(document_control_worker)
    if control.worker==nil {document_control_fail(control,"Could not start document renderer.");return false}
    control.worker.data=control;thread.start(control.worker)
    return true
}
document_control_toggle :: proc(control:^Document_Control,enabled:bool) {
    if !control.initialized||control.worker==nil {return}
    sync.atomic_store(&control.dark,enabled)
    byte:u8=1;posix.write(control.wake[1],&byte,1)
}
document_control_destroy :: proc(control:^Document_Control) {
    if !control.initialized {return}
    sync.atomic_store(&control.stopping,true)
    if control.wake[1]>=0 {byte:u8=1;posix.write(control.wake[1],&byte,1)}
    sync.mutex_lock(&control.mutex);sync.cond_signal(&control.decode_cond);sync.mutex_unlock(&control.mutex)
    if control.worker!=nil {thread.join(control.worker);thread.destroy(control.worker)}
    if control.decoder!=nil {thread.join(control.decoder);thread.destroy(control.decoder)}
    delete(control.encoded);if control.pixels!=nil {stbi.image_free(control.pixels)}
    for command in control.commands {delete(command.method);delete(command.params)};delete(control.commands)
    delete(control.clipboard)
    for fd in ([6]posix.FD{control.child_in,control.child_out,control.parent_in,control.parent_out,control.wake[0],control.wake[1]}) {
        if fd>=0 {posix.close(fd)}
    }
    control^={}
}

document_control_write :: proc(control:^Document_Control,bytes:[]u8)->bool {
    offset:=0
    for offset<len(bytes)&&!sync.atomic_load(&control.stopping) {
        count:=posix.write(control.parent_in,&bytes[offset],c.size_t(int(len(bytes))-offset))
        if count>0 {offset+=int(count);continue}
        if count<0&&posix.errno()==.EINTR {continue}
        if count<0&&posix.errno()==.EAGAIN {
            descriptor:=posix.pollfd{fd=control.parent_in,events={.OUT}}
            result:=posix.poll(&descriptor,1,100)
            if result<0&&posix.errno()!=.EINTR {break}
            if .ERR in descriptor.revents||.HUP in descriptor.revents||.NVAL in descriptor.revents {break}
            continue
        }
        break
    }
    if offset==len(bytes) {return true}
    document_control_fail(control,"document renderer disconnected.");return false
}
document_control_command :: proc(control:^Document_Control,method,params:string,session:string="")->bool {
    control.sequence+=1
    suffix:=""
    if session!="" {
        quoted,error:=json.marshal(session,allocator=context.temp_allocator)
        if error!=nil {document_control_fail(control,"Could not encode document renderer.");return false}
        suffix=fmt.tprintf(",\"sessionId\":%s",string(quoted))
    }
    // Odin fmt also recognizes brace placeholders. Supply JSON's outer braces
    // as data so the format parser cannot consume the opening object as one.
    message:=fmt.tprintf("%s\"id\":%d,\"method\":\"%s\",\"params\":%s%s%s","{",control.sequence,method,params,suffix,"}\x00")
    return document_control_write(control,transmute([]u8)message)
}
document_control_apply :: proc(control:^Document_Control,session:string)->bool {
    dark:=sync.atomic_load(&control.dark)
    params:="{}";media:=`{"features":[]}`
    if dark {params=`{"enabled":true}`;media=`{"features":[{"name":"prefers-color-scheme","value":"dark"}]}`}
    return document_control_command(control,"Emulation.setAutoDarkModeOverride",params,session)&&
        document_control_command(control,"Emulation.setEmulatedMedia",media,session)
}

// The UI only queues commands and viewport changes; browser I/O and image
// decoding run independently. Only the latest decoded frame is retained.
document_control_queue :: proc(control:^Document_Control,method:string,params:any,clipboard:bool=false) {
    bytes,error:=json.marshal(params,allocator=context.allocator)
    if error!=nil {return}
    command:=Document_Command{strings.clone(method),string(bytes),clipboard}
    sync.mutex_lock(&control.mutex);append(&control.commands,command);sync.mutex_unlock(&control.mutex)
    byte:u8=1;posix.write(control.wake[1],&byte,1)
}
document_control_viewport :: proc(control:^Document_Control,viewport:Document_Viewport) {
    sync.mutex_lock(&control.mutex)
    changed:=control.viewport!=viewport
    if changed {control.viewport=viewport;control.revision+=1}
    sync.mutex_unlock(&control.mutex)
    if changed {byte:u8=1;posix.write(control.wake[1],&byte,1)}
}
document_decode_worker :: proc(worker:^thread.Thread) {
    control:=cast(^Document_Control)worker.data
    for {
        sync.mutex_lock(&control.mutex)
        for control.encoded==nil&&!sync.atomic_load(&control.stopping) {sync.cond_wait(&control.decode_cond,&control.mutex)}
        if sync.atomic_load(&control.stopping) {sync.mutex_unlock(&control.mutex);return}
        png:=control.encoded;control.encoded=nil
        sync.mutex_unlock(&control.mutex)
        width,height,channels:c.int
        pixels:=stbi.load_from_memory(raw_data(png),c.int(len(png)),&width,&height,&channels,4)
        delete(png)
        if pixels==nil {document_control_fail(control,"Could not decode the document frame.");continue}
        sync.mutex_lock(&control.mutex)
        previous:=control.pixels;control.pixels=pixels
        control.pixel_width=int(width);control.pixel_height=int(height);control.generation+=1
        sync.mutex_unlock(&control.mutex)
        if previous!=nil {stbi.image_free(previous)}
        glfw.PostEmptyEvent()
    }
}
Document_Control_Header :: struct {id:i64,method:string,error:struct {code:int,message:string}}
Document_Control_Attach :: struct {params:struct {
    session:string `json:"sessionId"`,
    target:struct {kind:string `json:"type"`,id:string `json:"targetId"`,url:string} `json:"targetInfo"`,
}}
Document_Control_Frame :: struct {params:struct {data:string,session:int `json:"sessionId"`}}
Document_Control_Copy :: struct {result:struct {result:struct {value:string}}}
DOCUMENT_CONTROL_ATTACH :: `{"autoAttach":true,"waitForDebuggerOnStart":false,"flatten":true,"filter":[{"type":"page","exclude":false},{"type":"iframe","exclude":false},{"exclude":true}]}`

document_control_worker :: proc(worker:^thread.Thread) {
    control:=cast(^Document_Control)worker.data
    signals:posix.sigset_t;posix.sigemptyset(&signals);posix.sigaddset(&signals,.SIGPIPE)
    if posix.pthread_sigmask(.BLOCK,&signals,nil)!=.NONE {document_control_fail(control,"Could not initialize the document renderer.");return}
    sessions:=make([dynamic]string);defer {for session in sessions {delete(session)};delete(sessions)}
    main_session:string
    pending:=make([dynamic]u8);defer delete(pending)
    commands:[dynamic]Document_Command
    defer {for command in commands {delete(command.method);delete(command.params)};delete(commands)}
    applied,pending_revision:u64
    metrics_id,visible_id,clipboard_id:i64
    pending_view:Document_Viewport
    streaming:=false;last_dark:=false
    if !document_control_command(control,"Target.setAutoAttach",DOCUMENT_CONTROL_ATTACH) {return}
    if !document_control_command(control,"SystemInfo.getInfo","{}") {return}
    gpu_id:=control.sequence
    buffer:[65536]u8
    for !sync.atomic_load(&control.stopping) {
        sync.mutex_lock(&control.mutex)
        view,revision:=control.viewport,control.revision
        if main_session!="" {append(&commands,..control.commands[:]);clear(&control.commands)}
        sync.mutex_unlock(&control.mutex)
        if main_session!="" {
            dark:=sync.atomic_load(&control.dark)
            if dark!=last_dark {
                for session in sessions {if !document_control_apply(control,session) {return}}
                last_dark=dark
            }
            if metrics_id==0&&visible_id==0&&revision!=applied {
                pending_view=view;pending_revision=revision
                if !view.visible {
                    if streaming {if !document_control_command(control,"Page.stopScreencast","{}",main_session) {return};streaming=false}
                    applied=revision
                } else {
                    params:=struct {width,height:int,deviceScaleFactor,scale:f64,mobile,dontSetVisibleSize:bool}{
                        max(1,int(math.round(f64(view.width)/view.zoom))),max(1,int(math.round(f64(view.height)/view.zoom))),view.scale*view.zoom,view.scale*view.zoom,false,true}
                    bytes,_:=json.marshal(params,allocator=context.temp_allocator)
                    if !document_control_command(control,"Emulation.setDeviceMetricsOverride",string(bytes),main_session) {return}
                    metrics_id=control.sequence
                    if !document_control_command(control,"Emulation.setFocusEmulationEnabled",`{"enabled":true}`,main_session) {return}
                }
            }
            for command in commands {
                okay:=document_control_command(control,command.method,command.params,main_session)
                if command.clipboard {clipboard_id=control.sequence}
                if !okay {return}
            }
            for command in commands {delete(command.method);delete(command.params)}
            clear(&commands)
        }
        descriptors:=[2]posix.pollfd{{fd=control.parent_out,events={.IN}},{fd=control.wake[0],events={.IN}}}
        result:=posix.poll(raw_data(descriptors[:]),2,-1)
        if result<0 {if posix.errno()==.EINTR {continue};document_control_fail(control,"Could not read the document renderer.");return}
        if sync.atomic_load(&control.stopping) {return}
        if .IN in descriptors[1].revents {for posix.read(control.wake[0],raw_data(buffer[:]),len(buffer))>0 {}}
        if .IN in descriptors[0].revents {
            for {
                count:=posix.read(control.parent_out,raw_data(buffer[:]),len(buffer))
                if count<0&&posix.errno()==.EINTR {continue}
                if count<0&&posix.errno()==.EAGAIN {break}
                if count<=0 {document_control_fail(control,"The document renderer disconnected.");return}
                for byte in buffer[:int(count)] {
                    if byte!=0 {
                        if len(pending)>=128*1024*1024 {document_control_fail(control,"The document renderer returned an oversized frame.");return}
                        append(&pending,byte);continue
                    }
                    if len(pending)==0 {continue}
                    header:Document_Control_Header
                    if json.unmarshal(pending[:],&header,allocator=context.temp_allocator)!=nil {document_control_fail(control,"The document renderer returned invalid data.");return}
                    closed:=header.error.code== -32001||strings.contains(header.error.message,"Session with given id not found")||strings.contains(header.error.message,"Target closed")||strings.contains(header.error.message,"No target with given id found")
                    if header.error.message!=""&&!closed {document_control_fail(control,fmt.tprintf("Document renderer: %s",header.error.message))}
                    if header.method=="Target.attachedToTarget" {
                        message:Document_Control_Attach
                        if json.unmarshal(pending[:],&message,allocator=context.temp_allocator)==nil {
                            session:=strings.clone(message.params.session);append(&sessions,session)
                            if main_session==""&&message.params.target.kind=="page" {
                                main_session=session
                                if !document_control_command(control,"Page.enable","{}",session) {return}
                            }
                            if !document_control_apply(control,session) {return}
                        }
                    } else if header.method=="Target.detachedFromTarget" {
                        message:Document_Control_Attach
                        if json.unmarshal(pending[:],&message,allocator=context.temp_allocator)==nil {
                            for session,i in sessions {
                                if session!=message.params.session {continue}
                                if session==main_session {
                                    main_session=""
                                    sync.mutex_lock(&control.mutex);control.closed=true;sync.mutex_unlock(&control.mutex)
                                    glfw.PostEmptyEvent()
                                }
                                delete(session);ordered_remove(&sessions,i);break
                            }
                        }
                    } else if header.method=="Page.screencastFrame" {
                        message:Document_Control_Frame
                        if json.unmarshal(pending[:],&message,allocator=context.temp_allocator)==nil {
                            png,error:=base64.decode(message.params.data)
                            if error==nil {
                                sync.mutex_lock(&control.mutex)
                                delete(control.encoded);control.encoded=png;sync.cond_signal(&control.decode_cond)
                                sync.mutex_unlock(&control.mutex)
                            }
                            ack:=struct {sessionId:int}{message.params.session};encoded,_:=json.marshal(ack,allocator=context.temp_allocator)
                            if !document_control_command(control,"Page.screencastFrameAck",string(encoded),main_session) {return}
                        }
                    } else if header.id==metrics_id&&metrics_id!=0 {
                        metrics_id=0
                        size:=struct {width,height:int}{int(math.round(f64(pending_view.width)*pending_view.scale)),int(math.round(f64(pending_view.height)*pending_view.scale))}
                        bytes,_:=json.marshal(size,allocator=context.temp_allocator)
                        if !document_control_command(control,"Emulation.setVisibleSize",string(bytes),main_session) {return}
                        visible_id=control.sequence
                    } else if header.id==visible_id&&visible_id!=0 {
                        visible_id=0
                        if streaming {if !document_control_command(control,"Page.stopScreencast","{}",main_session) {return}}
                        capture:=struct {format:string,maxWidth,maxHeight,everyNthFrame:int}{"png",int(math.round(f64(pending_view.width)*pending_view.scale)),int(math.round(f64(pending_view.height)*pending_view.scale)),1}
                        bytes,_:=json.marshal(capture,allocator=context.temp_allocator)
                        if !document_control_command(control,"Page.startScreencast",string(bytes),main_session) {return}
                        applied=pending_revision;streaming=true
                    } else if header.id==clipboard_id&&clipboard_id!=0 {
                        response:Document_Control_Copy
                        if json.unmarshal(pending[:],&response,allocator=context.temp_allocator)==nil {
                            sync.mutex_lock(&control.mutex);delete(control.clipboard);control.clipboard=strings.clone(response.result.result.value);control.clipboard_ready=true;sync.mutex_unlock(&control.mutex)
                            glfw.PostEmptyEvent()
                        }
                        clipboard_id=0
                    } else if header.id==gpu_id {
                        response:struct {result:struct {gpu:struct {devices:[]struct {deviceString:string},featureStatus:map[string]string}}}
                        if json.unmarshal(pending[:],&response,allocator=context.temp_allocator)==nil {
                            if !strings.has_prefix(response.result.gpu.featureStatus["gpu_compositing"],"enabled") {document_control_fail(control,"Chromium GPU compositing is unavailable.")}
                            for device in response.result.gpu.devices {fmt.printf("Document GPU • %s\n",device.deviceString)}
                        }
                    }
                    clear(&pending);free_all(context.temp_allocator)
                }
            }
        }
        if .ERR in descriptors[0].revents||.HUP in descriptors[0].revents||.NVAL in descriptors[0].revents {document_control_fail(control,"The document renderer disconnected.");return}
    }
}

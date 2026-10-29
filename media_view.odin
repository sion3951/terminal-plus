#+build linux
package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"
import glfw "vendor:glfw"

Media_Kind :: enum {None,Image,Video,Audio}
media_kind :: proc(path:string)->Media_Kind {
    resource:=native_url_without_fragment(path);if query:=strings.index_byte(resource,'?');query>=0 {resource=resource[:query]}
    switch strings.to_lower(filepath.ext(resource),context.temp_allocator) {
    case ".png",".jpg",".jpeg",".jpe",".webp",".gif",".bmp",".tif",".tiff",".avif",".heic",".heif",".jxl",".ico",".ppm",".pgm",".pbm",".pam",".tga",".exr",".apng",".svg",".svgz":return .Image
    case ".mp4",".m4v",".mkv",".webm",".mov",".avi",".mpeg",".mpg",".mpe",".ts",".mts",".m2ts",".ogv",".ogg",".flv",".wmv",".vob",".3gp",".mxf":return .Video
    case ".mp3",".aac",".m4a",".wav",".flac",".opus",".oga",".aiff",".aif",".wma":return .Audio
    }
    return .None
}
MEDIA_BUFFER_SECONDS :: 0.12
MEDIA_QUEUE_BYTES :: 256*1024*1024
Media_Frame :: struct {pixels:[dynamic]u8,width,height:int,pts,position:f64}
Media_View :: struct {
    worker:^thread.Thread,
    source:Document_Source,
    frame:Renderer_Pixels,
    path:string,
    profile:Device_Profile,
    remote,stopping,done,wake_events:bool,
    cancellation:^bool,
    mutex:sync.Mutex,
    message:[1024]u8,
    message_length:int,
    revision,seen,frame_seen:u64,
    // Playback state is shared by the UI and decoder under mutex.
    playable,has_audio,paused,finished,muted:bool,
    duration,position,volume:f64,
    command_revision,audio_revision,audio_applied:u64,
    drag:Media_Control,
    drag_fraction:f64,
    frames:[16]Media_Frame,
    queue_head,queue_count:int,
    queue_cond:sync.Cond,
    clock_active:bool,
    clock_tick:time.Tick,
    clock_pts,clock_delay:f64,
    trace:bool,
    decoded,presented,skipped:u64,
    worst_lateness:f64,
}
Media_Process :: struct {
    pid:posix.pid_t,
    output,errors,control:posix.FD,
    buffer:[65536]u8,
    offset,used:int,
    diagnostic:[dynamic]u8,
    view:^Media_View,
    command_revision:u64,
    start_position:f64,
    progress_line:[2048]u8,
    progress_length:int,
    timed_video,looping:bool,
    timestamps:[dynamic]f64,
    timestamp_head:int,
    audio_revision,pending_audio_revision:u64,
    audio_pending:bool,
    audio_command:[128]u8,
    audio_command_length,audio_command_sent:int,
}
media_notify :: proc(view:^Media_View) {if view.wake_events {glfw.PostEmptyEvent()}}
media_stopping :: proc(view:^Media_View)->bool {
    return sync.atomic_load(&view.stopping)||(view.cancellation!=nil&&sync.atomic_load(view.cancellation))
}
media_message :: proc(view:^Media_View,message:string) {
    sync.mutex_lock(&view.mutex)
    view.message_length=copy(view.message[:],transmute([]u8)message);view.revision+=1
    sync.mutex_unlock(&view.mutex);media_notify(view)
}
media_ffmpeg :: proc()->string {
    path:=os.get_env("PATH",context.temp_allocator)
    for directory in strings.split_iterator(&path,":") {
        if directory=="" {continue}
        candidate:=fmt.tprintf("%s/ffmpeg",directory)
        if posix.access(strings.clone_to_cstring(candidate,context.temp_allocator),{.X_OK})==nil {return candidate}
    }
    return ""
}
// Arguments and environment are prepared before fork. No shell evaluates a path.
media_spawn :: proc(process:^Media_Process,arguments:[]string,interactive:bool=false)->bool {
    process^=Media_Process{output=-1,errors=-1,control=-1}
    argv:=make([]cstring,len(arguments)+1);defer {for arg in argv {if arg!=nil {delete(arg)}};delete(argv)}
    for argument,i in arguments {argv[i]=strings.clone_to_cstring(argument)}
    environment:=make([dynamic]cstring);defer delete(environment)
    for i:=0;posix.environ[i]!=nil;i+=1 {
        entry:=string(posix.environ[i])
        // Hardware auto-detection must never connect to an X11/XWayland server.
        if strings.has_prefix(entry,"DISPLAY=")||strings.has_prefix(entry,"XAUTHORITY=") {continue}
        append(&environment,posix.environ[i])
    }
    append(&environment,cstring(nil))
    output,errors:[2]posix.FD
    if pty_pipe2(&output,c.int(posix.O_CLOEXEC))!=0 {return false}
    if pty_pipe2(&errors,c.int(posix.O_CLOEXEC))!=0 {posix.close(output[0]);posix.close(output[1]);return false}
    // A larger pipe absorbs the decoder's writes without thousands of tiny
    // producer/consumer handoffs for each physical-resolution frame.
    _=posix.fcntl(output[0],cast(posix.FCNTL_Cmd)1031,c.int(1024*1024)) // F_SETPIPE_SZ
    channel:=[2]posix.FD{-1,-1}
    input:posix.FD= -1
    if interactive {
        if file_socketpair(1,1|0x80000,0,&channel)==0 {input=channel[0]}
    } else {input=posix.open("/dev/null",{.CLOEXEC})}
    if input<0 {for fd in ([4]posix.FD{output[0],output[1],errors[0],errors[1]}) {posix.close(fd)};return false}
    command,env:=raw_data(argv),raw_data(environment)
    pid:=posix.fork()
    if pid==0 {
        posix.dup2(input,0);posix.dup2(output[1],1);posix.dup2(errors[1],2)
        if channel[1]>=0 {posix.close(channel[1])}
        posix.close(input);posix.close(output[0]);posix.close(output[1]);posix.close(errors[0]);posix.close(errors[1])
        posix.execve(command[0],command,env);posix._exit(127)
    }
    posix.close(input);posix.close(output[1]);posix.close(errors[1])
    if pid<0 {if channel[1]>=0 {posix.close(channel[1])};posix.close(output[0]);posix.close(errors[0]);return false}
    process.pid=pid;process.output=output[0];process.errors=errors[0];process.control=channel[1]
    for fd in ([2]posix.FD{process.output,process.errors}) {flags:=posix.fcntl(fd,.GETFL);posix.fcntl(fd,.SETFL,flags|c.int(posix.O_NONBLOCK))}
    return true
}
media_command_changed :: proc(process:^Media_Process)->bool {
    if process.view==nil {return false}
    sync.mutex_lock(&process.view.mutex)
    changed:=process.command_revision!=process.view.command_revision
    sync.mutex_unlock(&process.view.mutex)
    return changed
}
// FFmpeg's live filter command changes only the audio gain. Coalesce updates
// until its reply arrives, so rapid slider/key changes cannot merge commands.
media_audio_update :: proc(process:^Media_Process) {
    view:=process.view
    if view==nil||process.control<0 {return}
    if !process.audio_pending {
        sync.mutex_lock(&view.mutex)
        revision:=view.audio_revision;volume:=view.volume;if view.muted {volume=0}
        sync.mutex_unlock(&view.mutex)
        if revision==process.audio_revision {return}
        command:=fmt.bprintf(process.audio_command[:],"cvolume@minor_volume -1 volume %.6f\n",volume)
        process.audio_command_length=len(command);process.audio_command_sent=0
        process.pending_audio_revision=revision;process.audio_pending=true
    }
    if process.audio_command_sent<process.audio_command_length {
        data:=process.audio_command[process.audio_command_sent:process.audio_command_length]
        count:=file_socket_send(process.control,raw_data(data),c.size_t(len(data)),0x4000|0x40) // MSG_NOSIGNAL | MSG_DONTWAIT
        if count>0 {process.audio_command_sent+=int(count)}
        else if count<0&&posix.errno()!=.EINTR&&posix.errno()!=.EAGAIN {
            // The decoder can close stdin at EOF while the last frame is visible.
            posix.close(process.control);process.control=-1
        }
    }
}
media_error_line :: proc(process:^Media_Process,line:string) {
    if process.view!=nil&&process.view.trace&&(strings.contains(line,"command")||strings.contains(line,"Command reply")) {fmt.printf("FFmpeg audio control: %s\n",line)}
    if process.audio_pending&&strings.has_prefix(line,"Command reply for stream ") {
        // FFmpeg broadcasts to every filter graph. The video graph replies
        // ENOSYS before the audio graph acknowledges its named volume filter.
        if strings.contains(line,": ret:-38 ") {return}
        process.audio_pending=false;process.audio_revision=process.pending_audio_revision
        if strings.contains(line,": ret:0 ") {
            view:=process.view
            sync.mutex_lock(&view.mutex);view.audio_applied=process.audio_revision;sync.mutex_unlock(&view.mutex)
        } else {media_message(process.view,"FFmpeg could not update audio volume.")}
        return
    }
    if process.timed_video&&strings.contains(line,"Parsed_showinfo_") {
        if at:=strings.index(line," pts_time:");at>=0 {
            text:=strings.trim_space(line[at+len(" pts_time:"):])
            end:=strings.index_byte(text,' ');if end>=0 {text=text[:end]}
            if pts,okay:=strconv.parse_f64(text);okay {append(&process.timestamps,pts)}
        }
        return
    }
    if process.view!=nil {
        if strings.has_prefix(line,"out_time_us=") {
            // Video position follows the displayed frame, not decoder progress.
            if process.timed_video {return}
            micros,okay:=strconv.parse_f64(line[len("out_time_us="):])
            if okay&&micros>=0 {
                view:=process.view
                sync.mutex_lock(&view.mutex)
                if process.command_revision==view.command_revision {
                    view.position=process.start_position+micros/1e6
                    if view.duration>0 {view.position=min(view.position,view.duration)}
                    view.revision+=1
                }
                sync.mutex_unlock(&view.mutex);media_notify(view)
            }
            return
        }
        // FFmpeg progress records share stderr with actionable diagnostics.
        if equal:=strings.index_byte(line,'=');equal>0&&!strings.contains(line[:equal]," ") {return}
    }
    if len(process.diagnostic)+len(line)>16384 {clear(&process.diagnostic)}
    append(&process.diagnostic,..transmute([]u8)line);append(&process.diagnostic,'\n')
}
media_errors :: proc(process:^Media_Process) {
    buffer:[4096]u8
    for {
        count:=posix.read(process.errors,raw_data(buffer[:]),len(buffer))
        if count<=0 {break}
        for ch in buffer[:int(count)] {
            if ch==10||ch==13 {
                if process.progress_length>0 {media_error_line(process,string(process.progress_line[:process.progress_length]));process.progress_length=0}
            } else if process.progress_length<len(process.progress_line) {
                process.progress_line[process.progress_length]=ch;process.progress_length+=1
            }
        }
    }
}
media_read :: proc(view:^Media_View,process:^Media_Process,destination:[]u8)->bool {
    used:=0
    for used<len(destination) {
        if media_stopping(view)||media_command_changed(process) {return false}
        if process.offset<process.used {
            count:=min(process.used-process.offset,len(destination)-used)
            copy(destination[used:used+count],process.buffer[process.offset:process.offset+count])
            process.offset+=count;used+=count;continue
        }
        media_errors(process);media_audio_update(process)
        // PAM headers use the small buffer. Frame bodies go straight into their
        // reusable destination instead of copying through a 64 KiB scratch pad.
        direct:=len(destination)-used>=len(process.buffer)
        target:=process.buffer[:]
        if direct {target=destination[used:]}
        count:=posix.read(process.output,raw_data(target),len(target))
        if count>0 {
            if direct {used+=int(count)} else {process.offset=0;process.used=int(count)}
            continue
        }
        if count==0 {media_errors(process);return false}
        if posix.errno()==.EINTR {continue}
        if posix.errno()!=.EAGAIN {return false}
        descriptors:=[2]posix.pollfd{{fd=process.output,events={.IN}},{fd=process.errors,events={.IN}}}
        if posix.poll(raw_data(descriptors[:]),2,50)<0&&posix.errno()!=.EINTR {return false}
    }
    return true
}
media_process_finish :: proc(view:^Media_View,process:^Media_Process)->int {
    status:c.int
    if process.pid>0 {
        reaped:=false
        for _ in 0..<10 {
            result:=posix.waitpid(process.pid,&status,{.NOHANG})
            if result==process.pid||(result<0&&posix.errno()==.ECHILD) {reaped=true;break}
            if media_stopping(view)||media_command_changed(process) {break}
            media_errors(process);time.sleep(10*time.Millisecond)
        }
        if !reaped {posix.kill(process.pid,.SIGKILL);for posix.waitpid(process.pid,&status,{})<0&&posix.errno()==.EINTR {}}
        process.pid=0
    }
    if process.control>=0 {posix.close(process.control);process.control=-1}
    if process.errors>=0 {media_errors(process);posix.close(process.errors);process.errors=-1}
    if process.output>=0 {posix.close(process.output);process.output=-1}
    delete(process.timestamps);process.timestamps=nil
    return int(status)
}
media_line :: proc(view:^Media_View,process:^Media_Process,buffer:[]u8)->(string,bool) {
    for i in 0..<len(buffer) {
        if !media_read(view,process,buffer[i:i+1]) {return "",false}
        if buffer[i]==10 {return strings.trim_space(string(buffer[:i])),true}
    }
    return "",false
}
// PAM is a binary RGBA frame stream, with a small header on every frame. It
// preserves transparency and resolution changes without ffprobe or PNG copies.
media_frame :: proc(view:^Media_View,process:^Media_Process,pixels:^[dynamic]u8)->(width,height:int,okay:bool) {
    header:[512]u8
    first,valid:=media_line(view,process,header[:]);if !valid||first!="P7" {return}
    depth,maximum:=0,0;ended:=false
    for _ in 0..<16 {
        line,line_valid:=media_line(view,process,header[:]);if !line_valid {return}
        if line=="ENDHDR" {ended=true;break}
        space:=strings.index_byte(line,' ');if space<0 {continue}
        number,parsed:=strconv.parse_int(strings.trim_space(line[space+1:]));if !parsed {continue}
        switch line[:space] {
        case "WIDTH":width=number
        case "HEIGHT":height=number
        case "DEPTH":depth=number
        case "MAXVAL":maximum=number
        }
    }
    if !ended||width<1||height<1||width>16384||height>16384||depth!=4||maximum!=255||width*height>128*1024*1024 {return}
    resize(pixels,width*height*4)
    okay=media_read(view,process,pixels^[:]);return
}
media_audio_output :: proc()->string {
    if os.get_env("PULSE_SERVER",context.temp_allocator)!="" {return "pulse"}
    runtime:=os.get_env("XDG_RUNTIME_DIR",context.temp_allocator)
    if runtime!="" {if _,error:=os.stat(fmt.tprintf("%s/pulse/native",runtime),context.temp_allocator);error==nil {return "pulse"}}
    return "alsa"
}
media_queue_frame :: proc(view:^Media_View,process:^Media_Process,pixels:^[dynamic]u8,width,height:int)->bool {
    media_errors(process)
    if process.timestamp_head>=len(process.timestamps) {
        media_message(view,"FFmpeg did not provide a video frame timestamp.");return false
    }
    pts:=process.timestamps[process.timestamp_head];process.timestamp_head+=1
    if process.timestamp_head==len(process.timestamps) {clear(&process.timestamps);process.timestamp_head=0}
    limit:=clamp(MEDIA_QUEUE_BYTES/(width*height*4),2,len(view.frames))
    sync.mutex_lock(&view.mutex);defer sync.mutex_unlock(&view.mutex)
    for view.queue_count>=limit {
        if media_stopping(view)||view.command_revision!=process.command_revision {return false}
        sync.cond_wait_with_timeout(&view.queue_cond,&view.mutex,10*time.Millisecond)
    }
    if media_stopping(view)||view.command_revision!=process.command_revision {return false}
    slot:=&view.frames[(view.queue_head+view.queue_count)%len(view.frames)]
    slot.pixels,pixels^=pixels^,slot.pixels
    slot.width=width;slot.height=height;slot.pts=pts;slot.position=process.start_position+pts
    if process.looping&&view.duration>0 {slot.position-=math.floor(slot.position/view.duration)*view.duration}
    if !view.clock_active {
        view.clock_active=true;view.clock_tick=time.tick_now();view.clock_pts=pts
        view.clock_delay=MEDIA_BUFFER_SECONDS
        if view.paused||!view.playable {view.clock_delay=0}
    }
    view.queue_count+=1;view.decoded+=1
    media_notify(view)
    return true
}
// Present by media timestamp. If the desktop missed a deadline, discard only
// overdue frames and retain the newest due frame, rather than slowing the clock.
media_present :: proc(view:^Media_View)->bool {
    sync.mutex_lock(&view.mutex);defer sync.mutex_unlock(&view.mutex)
    if view.queue_count==0||!view.clock_active {return false}
    now:=time.duration_seconds(time.tick_diff(view.clock_tick,time.tick_now()))-view.clock_delay+view.clock_pts
    selected:= -1
    for view.queue_count>0 {
        slot:=view.queue_head
        if view.frames[slot].pts>now {break}
        if selected>=0 {view.skipped+=1}
        selected=slot;view.queue_head=(view.queue_head+1)%len(view.frames);view.queue_count-=1
    }
    if selected<0 {return false}
    frame:=&view.frames[selected]
    renderer_pixels_exchange(&view.frame,&frame.pixels,frame.width,frame.height)
    view.position=frame.position;view.revision+=1;view.presented+=1
    view.worst_lateness=max(view.worst_lateness,max(0,now-frame.pts))
    sync.cond_signal(&view.queue_cond)
    return true
}
media_wait_delay :: proc(a:^App)->f64 {
    delay:f64=60
    for tab in a.tabs {
        view:=tab.media;if view==nil {continue}
        sync.mutex_lock(&view.mutex)
        if view.queue_count>0&&view.clock_active {
            elapsed:=time.duration_seconds(time.tick_diff(view.clock_tick,time.tick_now()))
            due:=view.frames[view.queue_head].pts-view.clock_pts+view.clock_delay
            delay=min(delay,max(0.001,due-elapsed))
        }
        sync.mutex_unlock(&view.mutex)
    }
    return delay
}
media_restart_locked :: proc(view:^Media_View) {
    view.command_revision+=1;view.queue_head=0;view.queue_count=0;view.clock_active=false
    sync.cond_signal(&view.queue_cond)
}
media_worker :: proc(worker:^thread.Thread) {
    view:=cast(^Media_View)worker.data
    defer {sync.atomic_store(&view.done,true);media_notify(view)}
    executable:=media_ffmpeg()
    if executable=="" {media_message(view,"Install FFmpeg to view images and videos.");return}
    input:=view.path
    remote_input,remote_error:string
    defer delete(remote_input);defer delete(remote_error)
    if view.remote {
        remote_input,remote_error=document_prepare(&view.source,view.path,true,view.profile,"")
        input=remote_input
        if remote_error!="" {media_message(view,remote_error);return}
    }
    input_args:=make([dynamic]string,context.temp_allocator)
    if view.remote {append(&input_args,"-rw_timeout","10000000","-headers",fmt.tprintf("Cookie: minor_document=%s\r\n",view.source.token))}
    // FFmpeg's own stream inspection avoids requiring ffprobe as another tool.
    probe_args:=make([dynamic]string,context.temp_allocator)
    append(&probe_args,executable,"-nostdin","-hide_banner")
    append(&probe_args,..input_args[:]);append(&probe_args,"-i",input)
    probe:Media_Process
    if !media_spawn(&probe,probe_args[:]) {media_message(view,"Could not start FFmpeg.");return}
    byte:[1]u8
    for media_read(view,&probe,byte[:]) {}
    media_process_finish(view,&probe)
    has_audio:=strings.contains(string(probe.diagnostic[:]),"Audio:")
    has_video:=strings.contains(string(probe.diagnostic[:]),"Video:")
    duration:=media_duration(string(probe.diagnostic[:]))
    loop_video:=has_video&&media_kind(view.path)!=.Image
    delete(probe.diagnostic)
    if media_stopping(view) {return}
    sync.mutex_lock(&view.mutex)
    view.has_audio=has_audio;view.duration=duration
    view.playable=has_audio||media_kind(view.path)==.Video
    view.revision+=1
    sync.mutex_unlock(&view.mutex);media_notify(view)
    if !has_audio&&!has_video {media_message(view,"FFmpeg found no playable audio or video stream.");return}
    pixels:[dynamic]u8;defer delete(pixels)
    audio_output:=media_audio_output()
    audio,hardware:=has_audio,true
    warning:=""
    last_command:=u64(0);holding:=false
    for !media_stopping(view) {
        sync.mutex_lock(&view.mutex)
        command:=view.command_revision;paused:=view.paused;finished:=view.finished
        position:=view.position;volume:=view.volume;audio_revision:=view.audio_revision;if view.muted {volume=0}
        sync.mutex_unlock(&view.mutex)
        // Keep the final frame and wait for replay, or hold a paused preview.
        if finished||(holding&&command==last_command) {time.sleep(20*time.Millisecond);continue}
        last_command=command;holding=false
        arguments:=make([dynamic]string)
        interactive:=audio&&(!paused||!has_video)
        append(&arguments,executable,("-stdin" if interactive else "-nostdin"),"-hide_banner","-loglevel",("info" if has_video||interactive else "error"),"-nostats","-threads","0")
        if has_video&&hardware {append(&arguments,"-hwaccel","auto")}
        append(&arguments,"-stats_period","0.1","-progress","pipe:2")
        // Audio shares the input clock; silent video can decode ahead freely.
        if audio {append(&arguments,"-re")}
        append(&arguments,..input_args[:])
        seek_arg:=fmt.aprintf("%.6f",position);defer delete(seek_arg)
        volume_arg:=fmt.aprintf("volume@minor_volume=%.6f",volume);defer delete(volume_arg)
        audio_filter:=volume_arg
        if has_video {audio_filter=fmt.aprintf("%s,adelay=%d:all=1",volume_arg,int(MEDIA_BUFFER_SECONDS*1000))}
        defer {if has_video {delete(audio_filter)}}
        // Let the demuxer loop inside the same process. Frame timestamps keep
        // increasing, preserving the video clock and live audio filter settings.
        if loop_video {append(&arguments,"-stream_loop","-1")}
        if position>0 {append(&arguments,"-ss",seek_arg)}
        append(&arguments,"-i",input)
        if has_video {
            append(&arguments,"-map","0:v:0","-an","-sn","-dn","-vf","scale=ceil(iw*sar):ih,setsar=1,setpts=PTS-STARTPTS,showinfo=checksum=0",
                "-c:v","pam","-pix_fmt","rgba","-fps_mode","passthrough","-flush_packets","1","-f","image2pipe","pipe:1")
        }
        if audio&&(!paused||!has_video) {
            append(&arguments,"-map","0:a:0","-vn","-sn","-dn","-af",audio_filter,
                "-c:a","pcm_s16le","-ac","2","-ar","48000")
            if audio_output=="pulse" {append(&arguments,"-buffer_duration","120","-prebuf","0")}
            append(&arguments,"-f",audio_output,"default")
        }
        if paused&&!has_video {delete(arguments);holding=true;continue}
        process:Media_Process
        spawned:=media_spawn(&process,arguments[:],interactive);delete(arguments)
        if !spawned {media_message(view,"Could not start FFmpeg playback.");return}
        process.view=view;process.command_revision=command;process.start_position=position;process.timed_video=has_video;process.looping=loop_video
        process.audio_revision=audio_revision
        sync.mutex_lock(&view.mutex);view.audio_applied=audio_revision;sync.mutex_unlock(&view.mutex)
        count:=0
        if has_video {
            for {
                width,height,okay:=media_frame(view,&process,&pixels)
                if !okay {break}
                if media_command_changed(&process) {break}
                if !media_queue_frame(view,&process,&pixels,width,height) {break};count+=1
                if count==1 {media_message(view,warning)}
                media_notify(view)
                if paused {holding=true;break}
            }
        } else {
            media_message(view,"Playing audio")
            for media_read(view,&process,byte[:]) {}
        }
        // Paused previews need only one frame. Finish the owned child immediately.
        if holding {posix.kill(process.pid,.SIGKILL)}
        status:=media_process_finish(view,&process)
        diagnostic:=strings.trim_space(string(process.diagnostic[:]))
        if media_stopping(view) {delete(process.diagnostic);return}
        if media_command_changed(&process)||holding {delete(process.diagnostic);continue}
        if count==0&&status!=0&&audio&&has_video {
            audio=false;warning="Audio output unavailable; video continues."
            delete(process.diagnostic);continue
        }
        if count==0&&status!=0&&hardware&&has_video {
            hardware=false;delete(process.diagnostic);continue
        }
        if (has_video&&count==0)||status!=0 {
            if diagnostic=="" {diagnostic="FFmpeg could not play this media file."}
            media_message(view,diagnostic)
        } else if warning!="" {media_message(view,warning)}
        else {media_message(view,"Finished")}
        delete(process.diagnostic)
        sync.mutex_lock(&view.mutex)
        for view.queue_count>0&&view.command_revision==command&&!media_stopping(view) {
            sync.cond_wait_with_timeout(&view.queue_cond,&view.mutex,10*time.Millisecond)
        }
        if view.command_revision==command {
            view.finished=true
            if status==0&&view.duration>0 {view.position=view.duration}
            view.revision+=1
        }
        playable:=view.playable
        sync.mutex_unlock(&view.mutex);media_notify(view)
        if !playable {return}
    }
}
media_duration :: proc(diagnostic:string)->f64 {
    start:=strings.index(diagnostic,"Duration: ");if start<0 {return 0}
    text:=diagnostic[start+len("Duration: "):]
    end:=strings.index_byte(text,',');if end<0 {return 0}
    parts:=strings.split(text[:end],":",context.temp_allocator);if len(parts)!=3 {return 0}
    hours,h_ok:=strconv.parse_f64(parts[0]);minutes,m_ok:=strconv.parse_f64(parts[1]);seconds,s_ok:=strconv.parse_f64(parts[2])
    if !h_ok||!m_ok||!s_ok {return 0}
    return max(0,hours*3600+minutes*60+seconds)
}
media_view_open :: proc(a:^App,tab:^Tab,path:string) {
    media_view_destroy(tab.media)
    view:=new(Media_View);tab.media=view
    view.volume=1;view.trace=os.get_env("MINOR_MEDIA_TRACE",context.temp_allocator)=="1"
    view.path=strings.clone(path);view.profile=profile_clone(tab.device);view.remote=tab.remote&&!native_http_url(path);view.wake_events=true
    if tab.files {view.profile.control_id=tab.source_id}
    renderer_pixels_init(&view.frame)
    media_message(view,"Opening media…")
    view.worker=thread.create(media_worker)
    if view.worker==nil {media_message(view,"Could not start the media worker.");view.done=true}
    else {view.worker.data=view;thread.start(view.worker)}
    a.selected=false;a.selecting=false;a.menu.open=false;a.picker.open=false;tab_group_close(a);a.dirty=true
}
media_view_destroy :: proc(view:^Media_View) {
    if view==nil {return}
    sync.atomic_store(&view.stopping,true);sync.cond_signal(&view.queue_cond);document_source_cancel(&view.source)
    if view.worker!=nil {thread.join(view.worker);thread.destroy(view.worker)}
    document_source_close(&view.source);renderer_pixels_destroy(&view.frame)
    for &frame in view.frames {delete(frame.pixels)}
    if view.trace {fmt.printf("Media playback: decoded=%d presented=%d skipped=%d worst_lateness=%.2fms\n",view.decoded,view.presented,view.skipped,view.worst_lateness*1000)}
    delete(view.path);delete(view.profile.name);delete(view.profile.target);free(view)
}
media_close :: proc(a:^App) {
    tab:=active_tab(a);if tab==nil||tab.media==nil {return}
    media_view_destroy(tab.media);tab.media=nil;a.dirty=true
    if tab.files {explorer_return_terminal(a)}
}
Media_Control :: enum {None,Play,Back,Forward,Mute,Volume,Seek,Close}
Media_Controls :: struct {bar:Explorer_Rect,items:[Media_Control]Explorer_Rect,time:Explorer_Rect}
media_controls :: proc(a:^App,playable:bool)->Media_Controls {
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    h:f32=54;if playable {h=126}
    box:=Media_Controls{bar={0,max(HEADER,height-h),width,h}}
    y:=box.bar.y
    box.items[.Close]={max(0,width-76),y+8,64,26}
    if playable {
        box.items[.Seek]={16,y+37,max(1,width-32),20}
        box.items[.Play]={16,y+64,64,28}
        box.items[.Back]={88,y+64,44,28};box.items[.Forward]={140,y+64,44,28}
        box.time={196,y+72,max(0,width-440),16}
        box.items[.Mute]={max(196,width-212),y+64,64,28}
        box.items[.Volume]={max(268,width-136),y+64,112,28}
        // Stack the time beneath the transport on narrow windows.
        if width<620 {box.time={196,y+103,max(0,width-212),16}}
    }
    return box
}
media_control_at :: proc(box:Media_Controls,x,y:f32)->Media_Control {
    for control in Media_Control {if control!=.None&&explorer_contains(box.items[control],x,y) {return control}}
    return .None
}
media_seek_locked :: proc(view:^Media_View,position:f64) {
    if view.duration<=0 {return}
    // Leave a decodable frame at the end of the timeline.
    view.position=clamp(position,0,max(0,view.duration-0.05))
    view.finished=false;media_restart_locked(view);view.revision+=1
}
media_control_locked :: proc(view:^Media_View,control:Media_Control) {
    #partial switch control {
    case .Play:
        if view.finished {view.position=0;view.finished=false;view.paused=false} else {view.paused=!view.paused}
        media_restart_locked(view)
    case .Back:media_seek_locked(view,view.position-10)
    case .Forward:media_seek_locked(view,view.position+10)
    case .Mute:view.muted=!view.muted;view.audio_revision+=1
    case: return
    }
    view.revision+=1
}
media_view_key :: proc(a:^App,key,mods:c.int,action:c.int=glfw.PRESS)->bool {
    tab:=active_tab(a);if tab==nil||tab.media==nil {return false}
    if key==glfw.KEY_ESCAPE||(key==glfw.KEY_C&&mods&glfw.MOD_CONTROL!=0) {media_close(a);return true}
    view:=tab.media
    if action==glfw.REPEAT&&(key==glfw.KEY_SPACE||key==glfw.KEY_K||key==glfw.KEY_M) {return true}
    sync.mutex_lock(&view.mutex)
    if view.playable {
        switch key {
        case glfw.KEY_SPACE,glfw.KEY_K:media_control_locked(view,.Play)
        case glfw.KEY_LEFT:media_seek_locked(view,view.position-5)
        case glfw.KEY_RIGHT:media_seek_locked(view,view.position+5)
        case glfw.KEY_J:media_control_locked(view,.Back)
        case glfw.KEY_L:media_control_locked(view,.Forward)
        case glfw.KEY_HOME:media_seek_locked(view,0)
        case glfw.KEY_END:media_seek_locked(view,view.duration)
        case glfw.KEY_M:media_control_locked(view,.Mute)
        case glfw.KEY_UP,glfw.KEY_DOWN:
            delta:f64=0.05;if key==glfw.KEY_DOWN {delta= -delta}
            view.volume=clamp(view.volume+delta,0,1);view.muted=false;view.audio_revision+=1;view.revision+=1
        }
    }
    sync.mutex_unlock(&view.mutex);a.dirty=true
    return true
}
media_view_mouse :: proc(a:^App,button,action:c.int,x,y:f32)->bool {
    tab:=active_tab(a);if tab==nil||tab.media==nil {return false}
    view:=tab.media
    if y<HEADER&&view.drag==.None {return false}
    if button!=glfw.MOUSE_BUTTON_LEFT {return true}
    sync.mutex_lock(&view.mutex)
    box:=media_controls(a,view.playable)
    control:=media_control_at(box,x,y)
    if action==glfw.RELEASE&&view.drag!=.None {
        rect:=box.items[view.drag];fraction:=clamp(f64((x-rect.x)/rect.w),0,1)
        if view.drag==.Seek {media_seek_locked(view,fraction*view.duration)}
        else {view.volume=fraction;view.muted=false;view.audio_revision+=1;view.revision+=1}
        view.drag=.None
    } else if action==glfw.PRESS {
        if control==.Seek||control==.Volume {
            if control==.Volume||view.duration>0 {
                view.drag=control;rect:=box.items[control];view.drag_fraction=clamp(f64((x-rect.x)/rect.w),0,1)
            }
        } else if control!=.Close&&view.playable {media_control_locked(view,control)}
    }
    sync.mutex_unlock(&view.mutex)
    if action==glfw.PRESS&&control==.Close {media_close(a)}
    a.dirty=true;return true
}
media_view_cursor :: proc(a:^App,x,y:f32)->bool {
    tab:=active_tab(a);if tab==nil||tab.media==nil {return false}
    view:=tab.media
    if view.drag==.None&&y<HEADER {return false}
    if view.drag!=.None {
        box:=media_controls(a,true);rect:=box.items[view.drag]
        view.drag_fraction=clamp(f64((x-rect.x)/rect.w),0,1)
    }
    a.dirty=true;return true
}
media_view_update :: proc(a:^App) {
    // Keep background tabs draining, so their audio cannot stall on a full queue.
    for tab in a.tabs {
        view:=tab.media;if view==nil {continue}
        media_present(view)
        if tab!=active_tab(a) {continue}
        sync.mutex_lock(&view.frame.mutex);generation:=view.frame.generation;sync.mutex_unlock(&view.frame.mutex)
        sync.mutex_lock(&view.mutex);revision:=view.revision;sync.mutex_unlock(&view.mutex)
        if view.frame_seen!=generation||view.seen!=revision {view.frame_seen=generation;view.seen=revision;a.dirty=true}
    }
}
media_time :: proc(seconds:f64)->string {
    total:=int(max(0,seconds))
    if total>=3600 {return fmt.tprintf("%d:%02d:%02d",total/3600,total/60%60,total%60)}
    return fmt.tprintf("%d:%02d",total/60,total%60)
}
media_view_render :: proc(a:^App,view:^Media_View) {
    r:=&a.renderer
    width,height:=f32(r.width)/a.scale,f32(r.height)/a.scale
    sync.mutex_lock(&view.mutex)
    message:=strings.clone(string(view.message[:view.message_length]),context.temp_allocator)
    playable,paused,finished,muted:=view.playable,view.paused,view.finished,view.muted
    position,duration,volume:=view.position,view.duration,view.volume
    sync.mutex_unlock(&view.mutex)
    if view.drag==.Seek {position=view.drag_fraction*duration}
    if view.drag==.Volume {volume=view.drag_fraction}
    box:=media_controls(a,playable)
    ui_rect(a,0,HEADER,width,max(0,height-HEADER),Color{0,0,0,1})
    sync.mutex_lock(&view.frame.mutex);ready:=view.frame.pixels!=nil;sync.mutex_unlock(&view.frame.mutex)
    if ready {
        r.page_source=&view.frame
        if !renderer_page_prepare(r) {glfw.SetWindowShouldClose(r.window,true);return}
        available:=max(1,(box.bar.y-HEADER)*a.scale)
        fit:=min(f32(r.width)/f32(r.page.width),available/f32(r.page.height))
        w,h:=math.round(f32(r.page.width)*fit),math.round(f32(r.page.height)*fit)
        x,y:=math.round((f32(r.width)-w)/2),math.round(HEADER*a.scale+(available-h)/2)
        start:=len(a.vertices)
        renderer_quad(&a.vertices,x,y,x+w,y+h,0,0,1,1,Color{1,1,1,1})
        for &vertex in a.vertices[start:] {vertex.texture=1}
    }
    if !ready {ui_fit_text(a,message,20,HEADER+32,14,width-40,TEXT)}
    ui_rect(a,box.bar.x,box.bar.y,box.bar.w,box.bar.h,PANEL)
    ui_fit_text(a,view.path,16,box.bar.y+14,13,max(0,width-108),TEXT)
    mx,my:=glfw.GetCursorPos(r.window);hover:=media_control_at(box,f32(mx),f32(my))
    for control in ([5]Media_Control{.Play,.Back,.Forward,.Mute,.Close}) {
        if !playable&&control!=.Close {continue}
        rect:=box.items[control]
        ui_rect(a,rect.x,rect.y,rect.w,rect.h,(HOVER if hover==control else BG))
        label:="Close"
        #partial switch control {
        case .Play:label="Play";if finished {label="Replay"} else if !paused {label="Pause"}
        case .Back:label="-10s"
        case .Forward:label="+10s"
        case .Mute:label="Mute";if muted||volume==0 {label="Unmute"}
        }
        ui_fit_text(a,label,rect.x+7,rect.y+8,12,rect.w-14,(ACCENT if hover==control else TEXT))
    }
    if playable {
        seek:=box.items[.Seek];fraction:f32=0
        if duration>0 {fraction=clamp(f32(position/duration),0,1)}
        ui_rect(a,seek.x,seek.y+8,seek.w,4,LINE)
        ui_rect(a,seek.x,seek.y+8,seek.w*fraction,4,ACCENT)
        if duration>0 {ui_rect(a,seek.x+seek.w*fraction-3,seek.y+4,6,12,TEXT)}
        end:="LIVE";if duration>0 {end=media_time(duration)}
        ui_fit_text(a,fmt.tprintf("%s / %s",media_time(position),end),box.time.x,box.time.y,12,box.time.w,TEXT)
        rect:=box.items[.Volume];amount:=f32(volume);if muted {amount=0}
        ui_rect(a,rect.x,rect.y+12,rect.w,4,LINE);ui_rect(a,rect.x,rect.y+12,rect.w*amount,4,ACCENT)
        ui_rect(a,rect.x+rect.w*amount-3,rect.y+8,6,12,TEXT)
        hint:="Space: play/pause · ←/→: seek · ↑/↓: volume · M: mute · Esc: close"
        if message!="" {hint=fmt.tprintf("%s · %s",message,hint)}
        ui_fit_text(a,hint,16,box.bar.y+104,11,(180 if width<620 else width-32),MUTED)
    } else {ui_fit_text(a,"Esc or Ctrl+C · Return to terminal",16,box.bar.y+35,12,width-32,MUTED)}
}

// Uses the real FFmpeg worker without requiring a desktop or touching a session.
media_sanity :: proc(path:string)->bool {
    view:=new(Media_View);view.path=strings.clone(path);view.volume=1;view.trace=os.get_env("MINOR_MEDIA_TRACE",context.temp_allocator)=="1"
    renderer_pixels_init(&view.frame)
    view.worker=thread.create(media_worker)
    if view.worker==nil {media_view_destroy(view);return false}
    view.worker.data=view;thread.start(view.worker)
    started:=time.tick_now();ready:=false;audio_only:=media_kind(path)==.Audio
    for time.tick_diff(started,time.tick_now())<10*time.Second {
        media_present(view)
        sync.mutex_lock(&view.frame.mutex);frames:=view.frame.generation;sync.mutex_unlock(&view.frame.mutex)
        done:=sync.atomic_load(&view.done)
        ready=frames>0
        if audio_only {
            sync.mutex_lock(&view.mutex)
            playing:=strings.has_prefix(string(view.message[:view.message_length]),"Playing audio")
            sync.mutex_unlock(&view.mutex)
            ready=playing&&time.tick_diff(started,time.tick_now())>=500*time.Millisecond
            if ready {break}
        }
        if frames>=2||done {break}
        time.sleep(10*time.Millisecond)
    }
    sync.mutex_lock(&view.mutex);message:=strings.clone(string(view.message[:view.message_length]),context.temp_allocator);sync.mutex_unlock(&view.mutex)
    tab:=new(Tab);tab.media=view;a:=new(App)
    defer free(tab);defer free(a)
    append(&a.tabs,tab)
    controls_ok:=true
    if ready&&audio_only {
        media_view_key(a,glfw.KEY_M,0);controls_ok=media_wait_audio(view)
        media_view_key(a,glfw.KEY_M,0);media_view_key(a,glfw.KEY_DOWN,0)
        controls_ok=media_wait_audio(view)&&controls_ok
    }
    if ready&&media_kind(path)==.Video {
        sync.mutex_lock(&view.mutex);duration:=view.duration;sync.mutex_unlock(&view.mutex)
        if duration>0 {
            sync.mutex_lock(&view.mutex)
            command:=view.command_revision;clock:=view.clock_tick
            sync.mutex_unlock(&view.mutex)
            media_view_key(a,glfw.KEY_M,0)
            controls_ok=media_wait_audio(view)
            sync.mutex_lock(&view.frame.mutex);muted_frame:=view.frame.generation;sync.mutex_unlock(&view.frame.mutex)
            controls_ok=media_wait_frames(view,muted_frame+2)&&controls_ok
            media_view_key(a,glfw.KEY_M,0)
            media_view_key(a,glfw.KEY_DOWN,0)
            controls_ok=media_wait_audio(view)&&controls_ok
            sync.mutex_lock(&view.frame.mutex);muted_frame=view.frame.generation;sync.mutex_unlock(&view.frame.mutex)
            controls_ok=media_wait_frames(view,muted_frame+2)&&controls_ok
            sync.mutex_lock(&view.mutex)
            controls_ok=controls_ok&&view.command_revision==command&&view.clock_tick==clock&&!view.paused
            sync.mutex_unlock(&view.mutex)
            if !controls_ok {fmt.eprintln("Live mute/unmute/volume failed to preserve advancing playback.")}
            // Seek while paused must display the requested frame and stay still.
            media_view_key(a,glfw.KEY_SPACE,0)
            sync.mutex_lock(&view.frame.mutex);before:=view.frame.generation;sync.mutex_unlock(&view.frame.mutex)
            sync.mutex_lock(&view.mutex);media_seek_locked(view,duration*0.5);sync.mutex_unlock(&view.mutex)
            controls_ok=media_wait_frames(view,before+1)&&controls_ok
            time.sleep(100*time.Millisecond)
            sync.mutex_lock(&view.frame.mutex);held:=view.frame.generation;sync.mutex_unlock(&view.frame.mutex)
            time.sleep(150*time.Millisecond)
            sync.mutex_lock(&view.frame.mutex);still:=view.frame.generation==held;sync.mutex_unlock(&view.frame.mutex)
            sync.mutex_lock(&view.mutex);at_target:=abs(view.position-duration*0.5)<0.25;sync.mutex_unlock(&view.mutex)
            controls_ok=controls_ok&&still&&at_target
            media_view_key(a,glfw.KEY_M,0)
            media_view_key(a,glfw.KEY_SPACE,0)
            controls_ok=media_wait_frames(view,held+2)&&controls_ok
            // Replay from a held end state must produce fresh frames at the start.
            sync.mutex_lock(&view.frame.mutex);before=view.frame.generation;sync.mutex_unlock(&view.frame.mutex)
            sync.mutex_lock(&view.mutex);view.finished=true;view.position=duration;sync.mutex_unlock(&view.mutex)
            media_view_key(a,glfw.KEY_SPACE,0)
            controls_ok=media_wait_frames(view,before+2)&&controls_ok
            // Crossing the end must show new frames from the beginning while
            // preserving audio settings and keeping playback active.
            sync.mutex_lock(&view.mutex)
            muted,volume:=view.muted,view.volume
            media_seek_locked(view,max(duration-0.2,duration*0.75))
            sync.mutex_unlock(&view.mutex)
            sync.mutex_lock(&view.frame.mutex);before=view.frame.generation;sync.mutex_unlock(&view.frame.mutex)
            began:=time.tick_now();looped:=false
            for time.tick_diff(began,time.tick_now())<3*time.Second {
                media_present(view)
                sync.mutex_lock(&view.mutex)
                wrapped:=view.position<duration*0.5&&!view.finished&&!view.paused
                preserved:=view.muted==muted&&view.volume==volume
                sync.mutex_unlock(&view.mutex)
                sync.mutex_lock(&view.frame.mutex);fresh:=view.frame.generation>before;sync.mutex_unlock(&view.frame.mutex)
                if wrapped&&fresh {looped=preserved;break}
                time.sleep(5*time.Millisecond)
            }
            controls_ok=looped&&controls_ok
            if controls_ok {fmt.println("FFmpeg pause, seek, mute, resume, replay and default looping: OK")}
        }
    }
    key:c.int=glfw.KEY_ESCAPE;if media_kind(path)==.Video||audio_only {key=glfw.KEY_C}
    handled:=media_view_key(a,key,glfw.MOD_CONTROL)
    delete(a.tabs)
    okay:=ready&&controls_ok&&handled&&tab.media==nil
    if okay {fmt.printf("FFmpeg frames and %s cleanup: OK (%s)\n",("Esc" if key==glfw.KEY_ESCAPE else "Ctrl+C"),path)}
    else {fmt.eprintf("Media check failed: %s (%s)\n",message,path)}
    return okay
}

media_wait_frames :: proc(view:^Media_View,target:u64)->bool {
    began:=time.tick_now()
    for time.tick_diff(began,time.tick_now())<3*time.Second {
        media_present(view)
        sync.mutex_lock(&view.frame.mutex);ready:=view.frame.generation>=target;sync.mutex_unlock(&view.frame.mutex)
        if ready {return true}
        if sync.atomic_load(&view.done) {return false}
        time.sleep(10*time.Millisecond)
    }
    return false
}

media_wait_audio :: proc(view:^Media_View)->bool {
    began:=time.tick_now()
    for time.tick_diff(began,time.tick_now())<time.Second {
        media_present(view)
        sync.mutex_lock(&view.mutex)
        ready:=!view.has_audio||view.audio_applied==view.audio_revision
        sync.mutex_unlock(&view.mutex)
        if ready {return true}
        if sync.atomic_load(&view.done) {return false}
        time.sleep(5*time.Millisecond)
    }
    sync.mutex_lock(&view.mutex)
    fmt.eprintf("Audio control timed out: wanted %d, applied %d\n",view.audio_revision,view.audio_applied)
    sync.mutex_unlock(&view.mutex)
    return false
}

// Document assets can use the same FFmpeg decoder for formats outside stb's
// built-in set (WebP, AVIF, animated formats, and SVG when FFmpeg supports it).
media_decode_still :: proc(source:^Document_Source,bytes:[]u8)->(pixels:[]u8,width,height:int,error:string) {
    view:=Media_View{cancellation=&source.stopping}
    executable:=media_ffmpeg();if executable=="" {return nil,0,0,"FFmpeg is required for this image format."}
    directory,temp_error:=os.mkdir_temp("","minor-media-asset-*",context.allocator)
    if temp_error!=nil {return nil,0,0,"Could not prepare the image asset."}
    defer os.remove_all(directory)
    path:=fmt.tprintf("%s/image",directory)
    if os.write_entire_file(path,bytes,{.Read_User,.Write_User})!=nil {return nil,0,0,"Could not prepare the image asset."}
    process:Media_Process
    args:=[]string{executable,"-nostdin","-hide_banner","-loglevel","error","-threads","0","-i",path,
        "-map","0:v:0","-frames:v","1","-c:v","pam","-pix_fmt","rgba","-f","image2pipe","pipe:1"}
    if !media_spawn(&process,args) {return nil,0,0,"Could not start the image decoder."}
    output:[dynamic]u8
    w,h,okay:=media_frame(&view,&process,&output)
    // A single-frame asset decoder owns no output files and can be stopped now.
    sync.atomic_store(&view.stopping,true);media_process_finish(&view,&process)
    delete(process.diagnostic)
    if !okay {delete(output);return nil,0,0,"FFmpeg could not decode this image asset."}
    return output[:],w,h,""
}

#+build linux
package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import atomic "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"
import glfw "vendor:glfw"

// The terminal and its chrome remain Vulkan/GLFW. A browser process exists only
// for an open document; it owns standards-compliant page layout and compositing.
Document_View :: struct {
    worker: ^thread.Thread,
    source: Document_Source,
    control: Document_Control,
    path, workdir, url, error, control_error_seen: string,
    profile: Device_Profile,
    kind: Document_Kind,
    pid: posix.pid_t,
    exit_status: c.int,
    remote, done, finished, cancelled: bool,
    source_mode, exit_seen, ready_seen, dark_mode: bool,
    frame_seen:u64,
    zoom:f64,
    buttons:int,
    find_open,find_focused:bool,
    last_click:time.Tick,
    last_button,clicks:int,
    last_x,last_y:f32,
    find_text:[dynamic]u8,
    find_cursor,find_anchor:int,
    find_selecting,find_all:bool,
}

document_set_error :: proc(view:^Document_View,message:string) {
    delete(view.error);view.error=strings.clone(message)
}

document_spawn :: proc(view:^Document_View)->bool {
    executable:=""
    for candidate in ([]string{"/usr/bin/chromium","/usr/bin/chromium-browser","/usr/bin/google-chrome-stable","/usr/bin/google-chrome","/opt/google/chrome/chrome"}) {
        if posix.access(strings.clone_to_cstring(candidate,context.temp_allocator),{.X_OK})==nil {executable=candidate;break}
    }
    if executable=="" {document_set_error(view,"Install Chromium or Google Chrome to render Markdown and HTML.");return false}
    arguments:=make([dynamic]string,context.temp_allocator)
    append(&arguments,executable,"--headless=new","--enable-gpu","--use-angle=vulkan","--ozone-platform=headless",
        "--remote-debugging-pipe",fmt.tprintf("--user-data-dir=%s/profile",view.workdir),"--no-first-run","--no-default-browser-check",
        "--disable-background-networking","--disable-sync","--disable-component-update","--password-store=basic")
    append(&arguments,view.url)
    argv:=make([]cstring,len(arguments)+1)
    defer {for argument in argv {if argument!=nil {delete(argument)}};delete(argv)}
    for argument,i in arguments {argv[i]=strings.clone_to_cstring(argument)}
    log_path:=strings.clone_to_cstring(fmt.tprintf("%s/browser.log",view.workdir),context.temp_allocator)
    log:=posix.open(log_path,{.WRONLY,.CREAT,.TRUNC,.CLOEXEC},{.IRUSR,.IWUSR})
    if log<0 {document_set_error(view,"Could not open the document renderer log.");return false}
    defer posix.close(log)
    input:=posix.open("/dev/null",{.CLOEXEC})
    if input<0 {document_set_error(view,"Could not prepare the document renderer input.");return false}
    defer posix.close(input)
    errors:[2]posix.FD
    if pty_pipe2(&errors,c.int(posix.O_CLOEXEC))!=0 {document_set_error(view,"Could not start the document renderer.");return false}
    executable_c:=argv[0];arguments_c:=raw_data(argv);environment:=posix.environ
    pid:=posix.fork()
    if pid==0 {
        posix.close(errors[0]);posix.setsid()
        posix.dup2(input,0);posix.dup2(log,1);posix.dup2(log,2)
        document_control_child_setup(&view.control)
        // No allocations or runtime calls after fork in this multithreaded app.
        posix.execve(executable_c,arguments_c,environment)
        failed:u8=1;posix.write(errors[1],&failed,1);posix._exit(127)
    }
    posix.close(errors[1])
    if pid<0 {posix.close(errors[0]);document_set_error(view,"Could not fork the document renderer.");return false}
    failed:u8
    amount:=posix.read(errors[0],&failed,1);posix.close(errors[0])
    if amount>0 {
        status:c.int
        for posix.waitpid(pid,&status,{})<0&&posix.errno()==.EINTR {}
        document_set_error(view,"Could not execute the document renderer.");return false
    }
    view.pid=pid
    document_control_parent_started(&view.control)
    return true
}

document_view_worker :: proc(worker:^thread.Thread) {
    view:=cast(^Document_View)worker.data
    defer {atomic.atomic_store(&view.finished,true);glfw.PostEmptyEvent()}
    view.url,view.error=document_prepare(&view.source,view.path,view.remote,view.profile,view.workdir)
    if !atomic.atomic_load(&view.cancelled)&&view.error=="" {
        document_spawn(view)
    }
    atomic.atomic_store(&view.done,true);glfw.PostEmptyEvent()
    if view.pid>0 {
        for posix.waitpid(view.pid,&view.exit_status,{})<0&&posix.errno()==.EINTR {}
    }
}

document_view_open :: proc(path:string,remote:bool,profile:Device_Profile)->^Document_View {
    view:=new(Document_View)
    view.path=strings.clone(path);view.remote=remote;view.kind=document_kind(path)
    view.profile=profile;view.profile.name=strings.clone(profile.name);view.profile.target=strings.clone(profile.target)
    view.zoom=1
    if !document_control_init(&view.control) {document_set_error(view,"Could not initialize the document renderer.");view.done=true;view.finished=true;return view}
    directory,error:=os.mkdir_temp("","minor-document-*",context.allocator)
    if error!=nil {document_set_error(view,"Could not create a private document directory.");view.done=true;view.finished=true;return view}
    view.workdir=directory
    if os.chmod(directory,{.Read_User,.Write_User,.Execute_User})!=nil {document_set_error(view,"Could not protect the document directory.");view.done=true;view.finished=true;return view}
    view.worker=thread.create(document_view_worker)
    if view.worker==nil {document_set_error(view,"Could not start the document worker.");view.done=true;view.finished=true;return view}
    view.worker.data=view
    thread.start(view.worker)
    return view
}

document_view_destroy :: proc(view:^Document_View) {
    if view==nil {return}
    atomic.atomic_store(&view.cancelled,true)
    document_source_cancel(&view.source)
    // done publishes the PID. Cancellation during prepare prevents a launch.
    if view.worker!=nil {
        for !atomic.atomic_load(&view.done)&&!atomic.atomic_load(&view.finished) {time.sleep(time.Millisecond)}
        if view.pid>0&&!atomic.atomic_load(&view.finished) {
            posix.kill(-view.pid,.SIGTERM)
            start:=time.tick_now()
            for !atomic.atomic_load(&view.finished)&&time.tick_diff(start,time.tick_now())<500*time.Millisecond {time.sleep(time.Millisecond)}
            if !atomic.atomic_load(&view.finished) {posix.kill(-view.pid,.SIGKILL)}
        }
        thread.join(view.worker);thread.destroy(view.worker)
    }
    // Chromium helpers inherit this private process group. Reap/terminate any
    // remaining helpers before deleting their profile, even after window close.
    if view.pid>0 {posix.kill(-view.pid,.SIGKILL)}
    document_control_destroy(&view.control)
    document_source_close(&view.source)
    if view.workdir!="" {os.remove_all(view.workdir)}
    delete(view.path);delete(view.workdir);delete(view.url);delete(view.error);delete(view.control_error_seen);delete(view.find_text)
    delete(view.profile.name);delete(view.profile.target);free(view)
}

document_view_toggle_dark :: proc(a:^App,view:^Document_View) {
    if view==nil||view.kind!=.HTML||!atomic.atomic_load(&view.done)||view.pid<=0||view.exit_seen {return}
    view.dark_mode= !view.dark_mode
    document_control_toggle(&view.control,view.dark_mode)
    a.dirty=true
}

document_view_update :: proc(a:^App) {
    active:=active_tab(a)
    for tab in a.tabs {
        e:=&tab.explorer;view:=e.document
        if view==nil {continue}
        if !e.preview_open {document_view_destroy(view);e.document=nil;a.dirty=true;glfw.FocusWindow(a.renderer.window);continue}
        box:=explorer_preview_layout(a)
        visible:=a.explorer_visible&&tab==active&&!view.source_mode&&!a.picker.open&&!a.menu.open&&a.group_hover==0
        document_control_viewport(&view.control,{width=max(1,int(box.w)),height=max(1,int(box.h-98)),scale=f64(a.scale),zoom=view.zoom,visible=visible})
        atomic.mutex_lock(&view.control.mutex)
        generation:=view.control.generation
        closed:=view.control.closed
        clipboard:=view.control.clipboard;copy_ready:=view.control.clipboard_ready
        if copy_ready {view.control.clipboard="";view.control.clipboard_ready=false}
        atomic.mutex_unlock(&view.control.mutex)
        if closed {
            if copy_ready {delete(clipboard)}
            e.preview_open=false;e.document=nil;document_view_destroy(view);a.dirty=true;continue
        }
        if copy_ready {glfw.SetClipboardString(a.renderer.window,strings.clone_to_cstring(clipboard,context.temp_allocator));delete(clipboard)}
        if generation!=view.frame_seen {view.frame_seen=generation;if tab==active {a.dirty=true}}
        if !atomic.atomic_load(&view.done) {continue}
        if !view.ready_seen {view.ready_seen=true;a.dirty=true}
        control_error:=document_control_error(&view.control)
        if control_error!=view.control_error_seen {delete(view.control_error_seen);view.control_error_seen=strings.clone(control_error);a.dirty=true}
        if atomic.atomic_load(&view.finished)&&view.pid>0&&!view.exit_seen {
            view.exit_seen=true
            if view.exit_status==0 {
                e.preview_open=false;e.document=nil;document_view_destroy(view)
                a.dirty=true;glfw.FocusWindow(a.renderer.window);continue
            }
            document_set_error(view,"The document renderer exited. Check that Chromium can run in this desktop session.")
            a.dirty=true
        }

    }
    for index:=len(a.tabs)-1;index>=0;index-=1 {
        tab:=a.tabs[index]
        if tab.document_path!=""&&tab.explorer.loaded&&!tab.explorer.preview_open {app_close_tab(a,index)}
    }
}

document_view_render_status :: proc(a:^App,view:^Document_View,box:Preview_Layout) {
    message:="Preparing document...";color:=MUTED
    if atomic.atomic_load(&view.done) {
        message="Rendering document..."
        if view.error!="" {message=view.error;color=Color{0.96,0.36,0.36,1}}
        else if view.control_error_seen!="" {message=view.control_error_seen;color=Color{0.96,0.36,0.36,1}}
        else {
            atomic.mutex_lock(&view.control.mutex);ready:=view.control.pixels!=nil;atomic.mutex_unlock(&view.control.mutex)
            if ready {
                r:=&a.renderer;r.page_source=&view.control
                // app_render runs after acquiring a signalled frame fence.
                if !renderer_page_prepare(r) {glfw.SetWindowShouldClose(r.window,true);return}
                x0,y0:=math.round(box.x*a.scale),math.round((box.y+68)*a.scale)
                width:=min(f32(r.page.width),math.round(box.w*a.scale))
                height:=min(f32(r.page.height),math.round((box.h-98)*a.scale))
                start:=len(a.vertices)
                renderer_quad(&a.vertices,x0,y0,x0+width,y0+height,0,0,width/f32(r.page.width),height/f32(r.page.height),Color{1,1,1,1})
                for &vertex in a.vertices[start:] {vertex.texture=1}
                document_find_render(a,view,box)
                return
            }
        }
    }
    ui_fit_text(a,message,box.x+20,box.y+88,14,box.w-40,color)
    document_find_render(a,view,box)
}

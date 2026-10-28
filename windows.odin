package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import glfw "vendor:glfw"

workspace_windows:[dynamic]^App
workspace_focused:^App
workspace_loading,workspace_dirty,workspace_save_allowed:bool
Workspace_Action_Kind :: enum {New_Window,Detach,Move,Drop}
Workspace_Action :: struct {
    kind:Workspace_Action_Kind,source,target:^App,tab,onto:^Tab,index:int,x,y:i32,
    drop_mode:Tab_Drop_Mode,group_id,to_group,onto_group:u64,
}
workspace_actions:[dynamic]Workspace_Action
// Closing a window detaches its sessions. Keep its manifest until the next
// launch so closing one of several windows cannot orphan those sessions.
workspace_detached:[dynamic]Session_Window

workspace_request_window :: proc(source:^App) {append(&workspace_actions,Workspace_Action{kind=.New_Window,source=source});glfw.PostEmptyEvent()}
workspace_request_move :: proc(source:^App,tab:^Tab,target:^App,index:int) {
    append(&workspace_actions,Workspace_Action{kind=.Move,source=source,tab=tab,target=target,index=index});glfw.PostEmptyEvent()
}
workspace_request_detach :: proc(source:^App,tab:^Tab,x,y:i32,group_id:u64=0) {
    append(&workspace_actions,Workspace_Action{kind=.Detach,source=source,tab=tab,x=x,y=y,group_id=group_id});glfw.PostEmptyEvent()
}
workspace_contains :: proc(a:^App)->bool {for window in workspace_windows {if window==a {return true}};return false}

// GLFW window creation/destruction is not reentrant. Input callbacks enqueue
// operations; execute them after event dispatch, while their owners still live.
workspace_process_actions :: proc() {
    actions:=workspace_actions;workspace_actions=nil;defer delete(actions)
    for action in actions {
        source:=action.source
        if !workspace_contains(source)||glfw.WindowShouldClose(source.renderer.window) {continue}
        if action.kind==.New_Window {
            if workspace_new_window(source)==nil {workspace_window_error(source)}
            continue
        }
        found:=false
        for tab in source.tabs {if tab==action.tab {found=true;break}}
        if !found {continue}
        if action.kind==.Drop {
            if workspace_contains(action.target)&&!glfw.WindowShouldClose(action.target.renderer.window) {workspace_drop_tabs(action)}
            continue
        }
        if action.kind==.Move {
            if workspace_contains(action.target)&&!glfw.WindowShouldClose(action.target.renderer.window) {
                workspace_move_tab(source,action.tab,action.target,action.index)
            }
            continue
        }
        width,height:=glfw.GetWindowSize(source.renderer.window)
        target:=workspace_create_window(int(width),int(height),source)
        if target==nil {
            workspace_window_error(source)
            continue
        }
        glfw.SetWindowPos(target.renderer.window,action.x,action.y)
        drop:=action;drop.kind=.Drop;drop.target=target;drop.index=0;drop.drop_mode=.Insert
        if workspace_drop_tabs(drop) {
            glfw.ShowWindow(target.renderer.window);glfw.FocusWindow(target.renderer.window)
        } else {glfw.SetWindowShouldClose(target.renderer.window,true)}
    }
}

workspace_window_error :: proc(a:^App) {
    tab:=active_tab(a)
    if tab!=nil {delete(tab.input_error);tab.input_error=strings.clone("Could not create a terminal window.");a.dirty=true}
}

workspace_create_window :: proc(width,height:int,copy_from:^App=nil)->^App {
    a:=new(App)
    a.font_index=4;a.scale=1;a.cols=100;a.rows=30;a.dirty=true;a.blink=true
    a.explorer_visible=false;a.explorer_width=300;a.session_loading=true
    a.session_save_allowed=workspace_save_allowed
    a.started=time.tick_now();a.blink_tick=a.started
    if copy_from!=nil {
        a.font_index=copy_from.font_index
        a.explorer_visible=copy_from.explorer_visible;a.explorer_width=copy_from.explorer_width
        a.explorer_width_custom=copy_from.explorer_width_custom
    }
    if !renderer_init(&a.renderer,max(440,width),max(200,height),"Terminal+") {free(a);return nil}
    a.vertices=make([dynamic]Vertex,0,65536)
    w:=a.renderer.window
    glfw.SetWindowUserPointer(w,a)
    glfw.SetKeyCallback(w,key_callback);glfw.SetCharCallback(w,char_callback)
    glfw.SetMouseButtonCallback(w,mouse_callback);glfw.SetCursorPosCallback(w,cursor_callback)
    glfw.SetScrollCallback(w,scroll_callback);glfw.SetWindowRefreshCallback(w,refresh_callback)
    glfw.SetWindowFocusCallback(w,focus_callback)
    glfw.SetWindowPosCallback(w,window_position_callback);glfw.SetWindowSizeCallback(w,window_size_callback)
    glfw.SetWindowMaximizeCallback(w,window_maximize_callback)
    glfw.SetWindowCloseCallback(w,window_close_callback)
    glfw.SetWindowSizeLimits(w,440,200,glfw.DONT_CARE,glfw.DONT_CARE)
    app_metrics(a)
    a.profiles=device_profiles_load()
    append(&workspace_windows,a)
    tab_drag_wayland_init()
    if workspace_focused==nil {workspace_focused=a}
    a.session_loading=false
    return a
}

app_dispose_tab :: proc(tab:^Tab) {
    if tab.remote_end!=nil {remote_session_end_destroy(tab.remote_end);tab.remote_end=nil}
    explorer_state_destroy(&tab.explorer)
    if !tab.files {
        if tab.pty.persistent {local_session_close(&tab.pty,false)} else {pty_destroy(&tab.pty)}
        terminal_destroy(&tab.terminal)
    };delete(tab.output)
    delete(tab.device.name);delete(tab.device.target);delete(tab.session_id);delete(tab.restore_path)
    for parent in tab.group_parents {delete(parent.label)};delete(tab.group_parents)
    delete(tab.history_error_seen);delete(tab.source_id);delete(tab.document_path);delete(tab.label);delete(tab.group_label);delete(tab.pending_input);delete(tab.input_error);free(tab)
}

workspace_destroy_window :: proc(a:^App) {
    tab_drag_cancel()
    for tab in a.tabs {app_dispose_tab(tab)}
    delete(a.tabs);delete(a.vertices);delete(a.window_title);delete(a.session_error_seen);delete(a.group_menus)
    for profile in a.profiles {delete(profile.name);delete(profile.target)}
    delete(a.profiles)
    if workspace_focused==a {workspace_focused=nil}
    renderer_destroy(&a.renderer);free(a)
}

workspace_destroy_all :: proc() {
    for a in workspace_windows {workspace_destroy_window(a)}
    delete(workspace_windows);workspace_windows=nil
    delete(workspace_actions);workspace_actions=nil
    for window in workspace_detached {session_window_destroy(window)}
    delete(workspace_detached);workspace_detached=nil
}

workspace_new_window :: proc(source:^App)->^App {
    width,height:=glfw.GetWindowSize(source.renderer.window)
    a:=workspace_create_window(int(width),int(height),source)
    if a==nil {return nil}
    if !app_new_tab(a) {
        ordered_remove(&workspace_windows,len(workspace_windows)-1);workspace_destroy_window(a);return nil
    }
    if glfw.GetPlatform()==glfw.PLATFORM_X11 {
        x,y:=glfw.GetWindowPos(source.renderer.window);glfw.SetWindowPos(a.renderer.window,x+32,y+32)
    }
    glfw.ShowWindow(a.renderer.window);glfw.FocusWindow(a.renderer.window)
    workspace_focused=a;session_touch(a)
    return a
}

workspace_move_tab :: proc(source:^App,tab:^Tab,target:^App,index:int,pack:bool=true)->bool {
    if source==nil||target==nil||tab==nil {return false}
    from:= -1
    for existing,i in source.tabs {if existing==tab {from=i;break}}
    if from<0||(source!=target&&len(target.tabs)>=MAX_TABS) {return false}
    at:=clamp(index,0,len(target.tabs))
    if source==target {
        if at>from {at-=1}
        if at==from {return true}
    }
    // Move the pointer, keeping the PTY, archive writer, pending input and file
    // workers alive. The source loses ownership before the destination gains it.
    ordered_remove(&source.tabs,from)
    if from<source.active {source.active-=1}
    source.active=clamp(source.active,0,max(0,len(source.tabs)-1));source.output_next=0
    append(&target.tabs,tab)
    for i:=len(target.tabs)-1;i>at;i-=1 {target.tabs[i]=target.tabs[i-1]}
    target.tabs[at]=tab;target.active=at;target.output_next=0
    if source!=target {tab_set_group(tab,0,"")}
    if pack {
        tab_groups_pack(source)
        if source!=target {tab_groups_pack(target)}
    }
    target.next_number=max(target.next_number,tab.number)
    for a in ([2]^App{source,target}) {a.selected=false;a.selecting=false;app_sync_tab_view(a);session_touch(a)}
    if source!=target {
        if view:=tab.explorer.document;view!=nil {
            view.frame_seen=0
        }
        if len(source.tabs)==0 {glfw.SetWindowShouldClose(source.renderer.window,true)}
        glfw.SetWindowShouldClose(target.renderer.window,false)
    }
    workspace_focused=target
    if glfw.GetWindowAttrib(target.renderer.window,glfw.VISIBLE)!=0 {glfw.FocusWindow(target.renderer.window)}
    return true
}

// Defer destruction until callbacks have returned. Closing a native window
// detaches its sessions and preserves its layout alongside the remaining ones.
workspace_prune_windows :: proc()->bool {
    for i:=len(workspace_windows)-1;i>=0;i-=1 {
        a:=workspace_windows[i]
        if !glfw.WindowShouldClose(a.renderer.window) {continue}
        if len(workspace_windows)==1 {return false}
        if len(a.tabs)>0 {append(&workspace_detached,session_capture_window(a,true))}
        ordered_remove(&workspace_windows,i);workspace_destroy_window(a)
        if workspace_focused==nil {workspace_focused=workspace_windows[0]}
        session_touch(workspace_focused)
    }
    return len(workspace_windows)>0
}

window_position_callback :: proc "c" (w:glfw.WindowHandle,x,y:c.int) {
    context=runtime.default_context();if workspace_save_allowed {session_touch(app_from(w))}
}
window_size_callback :: proc "c" (w:glfw.WindowHandle,width,height:c.int) {
    context=runtime.default_context();a:=app_from(w);a.dirty=true;if workspace_save_allowed {session_touch(a)}
}
window_maximize_callback :: proc "c" (w:glfw.WindowHandle,maximized:c.int) {
    context=runtime.default_context();a:=app_from(w);a.dirty=true;if workspace_save_allowed {session_touch(a)}
}
window_close_callback :: proc "c" (w:glfw.WindowHandle) {
    context=runtime.default_context();tab_rename_finish(app_from(w),true)
}

workspace_step_window :: proc(a:^App,elapsed:f64,hold_local:bool)->f64 {
    if len(a.tabs)==0 {return 0.001}
    previous_w,previous_h:=a.renderer.width,a.renderer.height
    if !renderer_prepare_frame(&a.renderer) {glfw.SetWindowShouldClose(a.renderer.window,true);return 0.001}
    if a.renderer.width!=previous_w||a.renderer.height!=previous_h {a.dirty=true}
    r:=&a.renderer;w:=r.window
    wx,wy:=glfw.GetWindowSize(w)
    dpi:=max(f32(r.width)/f32(max(wx,1)),f32(r.height)/f32(max(wy,1)))
    if !renderer_set_scale(r,max(0.5,dpi)) {glfw.SetWindowShouldClose(w,true);return 0.001}
    old_cols,old_rows,old_size:=a.cols,a.rows,a.font_size
    app_metrics(a)
    if old_cols!=a.cols||old_rows!=a.rows||old_size!=a.font_size {a.dirty=true}
    app_process_input(a)
    app_process_output(a,hold_local,0.006/f64(max(1,len(workspace_windows))))
    tab:=active_tab(a);if tab==nil {return 0.001}
    explorer_update(a);document_view_update(a)
    // Closing a document can dispose the previously active tab.
    tab=active_tab(a);if tab==nil {return 0.001}
    session_error:=session_status_error()
    if session_error!=a.session_error_seen {delete(a.session_error_seen);a.session_error_seen=strings.clone(session_error);a.dirty=true}
    if tab.unread {tab.unread=false;a.dirty=true}
    if tab.terminal.dirty {a.dirty=true;tab.terminal.dirty=false}
    now:=time.tick_now()
    animate:=a.focused&&!a.picker.open&&!a.menu.open&&!a.explorer_visible&&tab.scroll==0&&tab.terminal.cursor_visible&&(!tab.remote||(tab.started&&!tab.exited))
    if time.duration_seconds(time.tick_diff(a.blink_tick,now))>=0.6 {
        a.blink= !a.blink;a.blink_tick=now;if animate {a.dirty=true}
    }
    if a.capture!=""&&elapsed>=a.capture_after {r.capture_path=a.capture;a.capture="";a.dirty=true}
    if a.dirty&&r.width>0&&r.height>0 {
        index,ready,ok:=renderer_acquire_frame(r)
        if !ok {glfw.SetWindowShouldClose(w,true);return 0.001}
        if ready {
            app_render(a)
            if !renderer_draw(r,a.vertices[:],index) {glfw.SetWindowShouldClose(w,true);return 0.001}
            a.dirty=false
            title:="Terminal+"
            if tab.label!=""||tab.files {title=fmt.tprintf("%s — Terminal+",tab_title(tab))}
            else if tab.remote {title=fmt.tprintf("%s — Terminal+",tab.device.name)}
            else if tab.terminal.title_len>0 {title=fmt.tprintf("%s — Terminal+",string(tab.terminal.title[:tab.terminal.title_len]))}
            if title!=a.window_title {delete(a.window_title);a.window_title=strings.clone(title);glfw.SetWindowTitle(w,strings.clone_to_cstring(title,context.temp_allocator))}
        }
    }
    wait:=min(explorer_search_delay(a),a.input_delay,renderer_frame_wait_delay(r))
    if animate {wait=min(wait,max(0.001,0.6-time.duration_seconds(time.tick_diff(a.blink_tick,time.tick_now()))))}
    if a.output_work {wait=min(wait,0.001)}
    if a.capture!="" {wait=min(wait,max(0.001,a.capture_after-elapsed))}
    return wait
}

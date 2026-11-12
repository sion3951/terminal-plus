package main

import "core:time"
import glfw "vendor:glfw"

// macOS has no Wayland data device. A dragged tab keeps the source window's
// implicit mouse grab, and Cocoa reports global window positions, so other
// Terminal+ windows are hit-tested directly instead of via drag-and-drop.
Drag_Wayland :: struct {
    active,resolving:bool,
    // Wayland drop-resolution state; never set on macOS.
    entered:^App,
    enter_x,enter_y:f64,
    enters,drag_enters:u64,
    resolve_started:time.Tick,
}
drag_wayland:Drag_Wayland

tab_drag_wayland_init :: proc() {}
tab_drag_wayland_cancel :: proc() {}
tab_drag_wayland_destroy :: proc() {}
tab_drag_wayland_start :: proc()->bool {return false}

// Map a source-window cursor position to another visible workspace window.
tab_drag_window_at :: proc(source:^App,px,py:f64)->(target:^App,x,y:f64,found:bool) {
    sx,sy:=glfw.GetWindowPos(source.renderer.window)
    gx,gy:=f64(sx)+px,f64(sy)+py
    // The focused window is frontmost; prefer it where windows overlap.
    candidates:=make([dynamic]^App,0,len(workspace_windows),context.temp_allocator)
    if workspace_focused!=nil&&workspace_focused!=source {append(&candidates,workspace_focused)}
    for window in workspace_windows {if window!=source&&window!=workspace_focused {append(&candidates,window)}}
    for window in candidates {
        handle:=window.renderer.window
        if handle==nil||glfw.GetWindowAttrib(handle,glfw.ICONIFIED)!=0||glfw.GetWindowAttrib(handle,glfw.VISIBLE)==0 {continue}
        wx,wy:=glfw.GetWindowPos(handle)
        w,h:=glfw.GetWindowSize(handle)
        lx,ly:=gx-f64(wx),gy-f64(wy)
        if lx>=0&&ly>=0&&lx<f64(w)&&ly<f64(h) {return window,lx,ly,true}
    }
    return
}

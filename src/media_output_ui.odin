#+build linux
package main

import "core:c"
import "core:math"
import "core:strings"
import "core:sync"
import "core:thread"
import glfw "vendor:glfw"

// Discovery is independent of decoding so opening the picker never stalls video.
media_output_worker :: proc(worker:^thread.Thread) {
    view:=cast(^Media_View)worker.data
    sync.mutex_lock(&view.mutex);backend:=view.output_backend;sync.mutex_unlock(&view.mutex)
    devices,error:=media_audio_devices(view,backend)
    sync.mutex_lock(&view.mutex)
    media_audio_devices_destroy(&view.output_devices);delete(view.output_error)
    view.output_devices=devices;view.output_error=strings.clone(error)
    view.output_scroll=0
    view.output_selection=0
    target:=string(view.output_name[:view.output_length])
    for device,i in devices {if device.name==target {view.output_selection=i;break}}
    sync.atomic_store(&view.output_done,true);view.revision+=1
    sync.mutex_unlock(&view.mutex)
    media_notify(view)
}
media_output_refresh :: proc(view:^Media_View) {
    if view.output_worker!=nil {
        if !sync.atomic_load(&view.output_done) {return}
        thread.join(view.output_worker);thread.destroy(view.output_worker);view.output_worker=nil
    }
    sync.atomic_store(&view.output_done,false)
    view.output_worker=thread.create(media_output_worker)
    if view.output_worker!=nil {view.output_worker.data=view;thread.start(view.output_worker)}
    else {
        sync.atomic_store(&view.output_done,true)
        sync.mutex_lock(&view.mutex)
        delete(view.output_error);view.output_error=strings.clone("Could not load audio outputs.")
        sync.mutex_unlock(&view.mutex)
    }
}
media_output_open :: proc(a:^App,view:^Media_View) {
    sync.mutex_lock(&view.mutex)
    if !view.has_audio {sync.mutex_unlock(&view.mutex);return}
    view.output_open=!view.output_open;opened:=view.output_open
    view.output_scroll=0
    sync.mutex_unlock(&view.mutex)
    if opened {media_output_refresh(view)}
    a.dirty=true
}
Media_Output_Layout :: struct {panel:Explorer_Rect,rows_y:f32,rows:int}
// Called with view.mutex held; constrain the list to the available viewer height.
media_output_layout :: proc(a:^App,view:^Media_View,controls:Media_Controls)->Media_Output_Layout {
    w:=min(controls.bar.w,f32(360))
    rows:=min(max(1,len(view.output_devices)),max(1,int((controls.bar.y-HEADER-88)/32)))
    h:=f32(rows)*32+76
    return {panel={controls.bar.x+controls.bar.w-w,max(HEADER+4,controls.bar.y-h-8),w,h},
        rows_y=max(HEADER+4,controls.bar.y-h-8)+40,rows=rows}
}
media_output_reveal :: proc(view:^Media_View,rows:int) {
    if view.output_selection<view.output_scroll {view.output_scroll=view.output_selection}
    if view.output_selection>=view.output_scroll+rows {view.output_scroll=view.output_selection-rows+1}
    view.output_scroll=clamp(view.output_scroll,0,max(0,len(view.output_devices)-rows))
}
media_output_choose_locked :: proc(view:^Media_View,index:int) {
    if index<0||index>=len(view.output_devices) {return}
    name:=view.output_devices[index].name
    if len(name)>len(view.output_name) {return}
    // Reopening even the current output can recover a reconnected device.
    view.output_length=copy(view.output_name[:],transmute([]u8)name)
    media_restart_locked(view);view.revision+=1
    view.output_selection=index;view.output_open=false
}
media_output_key :: proc(a:^App,view:^Media_View,key,action:c.int)->bool {
    sync.mutex_lock(&view.mutex);defer sync.mutex_unlock(&view.mutex)
    if !view.output_open {return false}
    switch key {
    case glfw.KEY_ESCAPE:view.output_open=false
    case glfw.KEY_UP,glfw.KEY_DOWN:
        delta:=1;if key==glfw.KEY_UP {delta= -1}
        view.output_selection=clamp(view.output_selection+delta,0,max(0,len(view.output_devices)-1))
        box:=media_output_layout(a,view,media_controls(a,view.playable));media_output_reveal(view,box.rows)
    case glfw.KEY_HOME:view.output_selection=0;view.output_scroll=0
    case glfw.KEY_END:
        view.output_selection=max(0,len(view.output_devices)-1)
        box:=media_output_layout(a,view,media_controls(a,view.playable));media_output_reveal(view,box.rows)
    case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:
        if action!=glfw.REPEAT {media_output_choose_locked(view,view.output_selection)}
    }
    a.dirty=true;return true
}
media_output_mouse :: proc(a:^App,view:^Media_View,button,action:c.int,x,y:f32)->bool {
    sync.mutex_lock(&view.mutex)
    if !view.output_open {sync.mutex_unlock(&view.mutex);return false}
    controls:=media_controls(a,view.playable);box:=media_output_layout(a,view,controls)
    refresh:=false
    if button==glfw.MOUSE_BUTTON_LEFT&&action==glfw.PRESS {
        if explorer_contains(box.panel,x,y) {
            if y>=box.rows_y&&y<box.rows_y+f32(box.rows)*32 {
                media_output_choose_locked(view,view.output_scroll+int((y-box.rows_y)/32))
            } else if y<box.rows_y&&x>=box.panel.x+box.panel.w-40 {refresh=true}
        } else {view.output_open=false}
    }
    sync.mutex_unlock(&view.mutex)
    if refresh {media_output_refresh(view)}
    a.dirty=true;return true
}
media_output_scroll :: proc(a:^App,view:^Media_View,delta:f64) {
    sync.mutex_lock(&view.mutex);defer sync.mutex_unlock(&view.mutex)
    if !view.output_open {return}
    box:=media_output_layout(a,view,media_controls(a,view.playable))
    view.output_scroll=clamp(view.output_scroll-int(math.round(delta))*3,0,max(0,len(view.output_devices)-box.rows))
    a.dirty=true
}
media_output_render :: proc(a:^App,view:^Media_View,controls:Media_Controls) {
    sync.mutex_lock(&view.mutex);defer sync.mutex_unlock(&view.mutex)
    if !view.output_open {return}
    box:=media_output_layout(a,view,controls);panel:=box.panel
    mx,my:=glfw.GetCursorPos(a.renderer.window);x,y:=f32(mx),f32(my)
    ui_glass(a,panel.x,panel.y,panel.w,panel.h)
    ui_title(a,"Audio output",panel.x+14,panel.y+20,13,panel.w-60)
    refresh_hover:=x>=panel.x+panel.w-38&&x<panel.x+panel.w-6&&y>=panel.y+5&&y<panel.y+35
    ui_control(a,panel.x+panel.w-38,panel.y+5,30,30,.Ghost,refresh_hover)
    explorer_icon(a,.Reload,panel.x+panel.w-31,panel.y+12,SOFT)
    target:=string(view.output_name[:view.output_length]);if target=="" {target="default"}
    for row in 0..<box.rows {
        index:=view.output_scroll+row;if index>=len(view.output_devices) {break}
        device:=view.output_devices[index];py:=box.rows_y+f32(row)*32
        hover:=x>=panel.x+4&&x<panel.x+panel.w-4&&y>=py&&y<py+32
        ui_row(a,panel.x+4,py,panel.w-8,30,index==view.output_selection,hover)
        if device.name==target {ui_dot(a,panel.x+16,py+15,5,TEXT)}
        ui_text_mid(a,device.label,panel.x+28,py+15,12,panel.w-44,TEXT if device.name==target else SOFT)
    }
    footer:="↑/↓ choose · Enter select · Esc dismiss"
    if !sync.atomic_load(&view.output_done) {footer="Loading audio outputs…"}
    else if view.output_error!="" {footer=view.output_error}
    else if len(view.output_devices)>box.rows {footer="Scroll for more · Enter select · Esc dismiss"}
    ui_text_mid(a,footer,panel.x+14,panel.y+panel.h-18,11,panel.w-28,MUTED)
}

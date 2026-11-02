package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import glfw "vendor:glfw"

Updater_Box :: struct {x,y,w,h:f32}
UPDATER_HEADER_SPACE :: 44
updater_header_box :: proc(a:^App)->Updater_Box {
    return {f32(a.renderer.width)/a.scale-UPDATER_HEADER_SPACE,8,32,32}
}
updater_box :: proc(a:^App)->Updater_Box {
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    w,h:=min(560,width-16),min(310,height-16)
    return {(width-w)/2,(height-h)/2,w,h}
}
updater_contains :: proc(x,y,bx,by,w,h:f32)->bool {return x>=bx&&x<bx+w&&y>=by&&y<by+h}
updater_button :: proc(a:^App,label:string,x,y,w:f32,enabled:bool=true,style:Control_Style=.Outline) {
    mx,my:=glfw.GetCursorPos(a.renderer.window)
    ui_button(a,label,x,y,w,30,style,updater_contains(f32(mx),f32(my),x,y,w,30),enabled)
}
// task_master-style switch followed by its label.
updater_switch :: proc(a:^App,label:string,x,y:f32,on,hover:bool) {
    track:=Color{0.204,0.42,0.945,1} if on else Color{1,1,1,0.12 if hover else 0.09}
    ui_round(a,x,y+6,32,18,9,track)
    if !on {ui_round_border(a,x,y+6,32,18,9,Color{1,1,1,0.10})}
    knob_x:=x+16 if on else x+2
    ui_shadow(a,knob_x,y+8,14,14,7,2,1,Color{0,0,0,0.4})
    ui_round(a,knob_x,y+8,14,14,7,Color{1,1,1,1} if on else SOFT)
    ui_text_mid(a,label,x+42,y+15,13,240,TEXT if hover else SOFT)
}
updater_draw :: proc(a:^App) {
    u:=update_instance
    if u==nil {return}
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    color:=MUTED
    if u.state==.Checking||u.state==.Downloading {color=SOFT}
    icon:=updater_header_box(a)
    mx,my:=glfw.GetCursorPos(a.renderer.window)
    icon_hover:=updater_contains(f32(mx),f32(my),icon.x,icon.y,icon.w,icon.h)
    ui_control(a,icon.x+1,icon.y+1,icon.w-2,icon.h-2,.Ghost,icon_hover,true,a.update_dialog)
    if icon_hover {color=TEXT}
    explorer_icon(a,.Reload,icon.x+8,icon.y+8,color)
    if u.state==.Ready {ui_dot(a,icon.x+icon.w-8,icon.y+8,7,GREEN)}
    if !a.update_dialog {return}
    box:=updater_box(a);x,y,w,h:=box.x,box.y,box.w,box.h
    ui_rect(a,0,0,width,height,SCRIM)
    ui_glass(a,x,y,w,h,14)
    ui_title(a,"Updates",x+20,y+26,16,w-80)
    ui_text_mid(a,fmt.tprintf("Terminal+ %s installed",UPDATER_VERSION),x+20,y+50,12,w-80,MUTED)
    close_hover:=updater_contains(f32(mx),f32(my),x+w-40,y+10,30,30)
    ui_control(a,x+w-40,y+10,30,30,.Ghost,close_hover)
    ui_icon_close(a,x+w-25,y+25,8,TEXT if close_hover else MUTED)
    status:=MUTED;state:="Up to date"
    switch u.state {
    case .Ready:status=GREEN;state="Ready to install"
    case .Checking:status=SOFT;state="Checking for updates…"
    case .Downloading:status=SOFT;state="Downloading…"
    case .Error:status=DANGER;state="Update failed"
    case .Current:status=GREEN
    case .Idle:state="Waiting for the next check"
    }
    ui_rect(a,x+1,y+72,w-2,1,Color{1,1,1,0.06})
    ui_dot(a,x+24,y+95,7,status)
    ui_text_mid(a,state,x+36,y+95,13,w-60,TEXT)
    message:=u.message
    if message=="" {message="Updates download automatically; install when you are ready."}
    if h>=260 {
        words:=strings.fields(message,context.temp_allocator)
        line:="";row:=0
        for word in words {
            candidate:=fmt.tprintf("%s%s%s",line," " if line!="" else "",word)
            if line!=""&&renderer_text_width(&a.renderer,candidate,13*a.scale)/a.scale>w-56 {
                ui_fit_text(a,line,x+36,y+112+f32(row)*21,13,w-56,SOFT)
                row+=1
                if row>=4 {line="…";break}
                line=word
            } else {line=candidate}
        }
        ui_fit_text(a,line,x+36,y+112+f32(row)*21,13,w-56,SOFT)
    } else {ui_fit_text(a,message,x+36,y+112,13,w-56,SOFT)}
    switch_hover:=updater_contains(f32(mx),f32(my),x+16,y+h-98,240,30)
    updater_switch(a,"Download automatically",x+20,y+h-98,u.automatic,switch_hover)
    ui_rect(a,x+1,y+h-56,w-2,1,Color{1,1,1,0.06})
    busy:=u.state==.Checking||u.state==.Downloading
    updater_button(a,"Check now",x+16,y+h-42,104,!busy)
    updater_button(a,"Update and restart",x+w-180,y+h-42,164,u.state==.Ready,.Primary)
}
updater_mouse :: proc(a:^App,button,action:c.int,x,y:f32)->bool {
    if !a.update_dialog {
        icon:=updater_header_box(a)
        if update_instance!=nil&&updater_contains(x,y,icon.x,icon.y,icon.w,icon.h)&&button==glfw.MOUSE_BUTTON_LEFT&&action==glfw.PRESS {
            a.update_dialog=true;a.menu.open=false;a.picker.open=false;a.selecting=false;tab_rename_finish(a,true);tab_group_close(a);a.dirty=true
            return true
        }
        return false
    }
    if action!=glfw.PRESS||button!=glfw.MOUSE_BUTTON_LEFT {return true}
    box:=updater_box(a);bx,by,w,h:=box.x,box.y,box.w,box.h
    u:=update_instance
    // Like the device picker, a click on the scrim dismisses the dialog.
    if !updater_contains(x,y,bx,by,w,h)||updater_contains(x,y,bx+w-40,by+10,30,30) {a.update_dialog=false;a.dirty=true;return true}
    if u==nil {return true}
    if updater_contains(x,y,bx+16,by+h-98,240,30) {updater_set_automatic(a,!u.automatic)}
    if updater_contains(x,y,bx+16,by+h-42,104,30) {updater_check(a)}
    if u.state==.Ready&&updater_contains(x,y,bx+w-180,by+h-42,164,30) {
        success,message:=updater_platform_install(&u.target,u.package_path,u.stage,i32(os.get_pid()))
        if success {u.handed_off=true;updater_restart_requested=true}
        else {updater_message(u,message);a.dirty=true}
    }
    return true
}
// Keep the idle event loop asleep until the next automatic check. Workers post
// a native GLFW event when results are ready.
updater_wait_delay :: proc()->f64 {
    u:=update_instance
    if u==nil||!u.allow_automatic||!u.automatic||u.job!=nil||u.state==.Ready {return 60}
    now:=updater_wall_time()
    return clamp(max(u.created_at+10,u.last_checked+UPDATER_INTERVAL)-now,0.01,59)
}
updater_cli_check :: proc() {
    updater_headless=true
    updater_init(nil,automatic=false)
    defer updater_destroy(nil)
    updater_check(nil)
    for update_instance!=nil&&update_instance.job!=nil {
        updater_poll(nil)
        time.sleep(50*time.Millisecond)
        free_all(context.temp_allocator)
    }
    if update_instance==nil {fmt.eprintln("Could not initialize the updater.");os.exit(1)}
    fmt.println(update_instance.message)
    if update_instance.state==.Error {updater_destroy(nil);os.exit(1)}
}

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
updater_button :: proc(a:^App,label:string,x,y,w:f32,enabled:bool=true) {
    mx,my:=glfw.GetCursorPos(a.renderer.window)
    hover:=updater_contains(f32(mx),f32(my),x,y,w,30)
    ui_rect(a,x,y,w,30,LINE if enabled&&hover else PANEL)
    ui_fit_text(a,label,x+9,y+8,12,w-18,TEXT if enabled else MUTED)
}
updater_draw :: proc(a:^App) {
    u:=update_instance
    if u==nil {return}
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    color:=MUTED
    if u.state==.Ready {color=GREEN}
    if u.state==.Checking||u.state==.Downloading {color=SOFT}
    icon:=updater_header_box(a)
    mx,my:=glfw.GetCursorPos(a.renderer.window)
    if updater_contains(f32(mx),f32(my),icon.x,icon.y,icon.w,icon.h) {
        ui_rect(a,icon.x,icon.y,icon.w,icon.h,HOVER)
        if u.state!=.Ready {color=TEXT}
    }
    explorer_icon(a,.Reload,icon.x+8,icon.y+8,color)
    if !a.update_dialog {return}
    box:=updater_box(a);x,y,w,h:=box.x,box.y,box.w,box.h
    ui_rect(a,0,0,width,height,Color{0,0,0,0.85})
    ui_rect(a,x,y,w,h,LINE);ui_rect(a,x+1,y+1,w-2,h-2,BG)
    ui_text(a,"Terminal+ updates",x+16,y+18,18,TEXT)
    updater_button(a,"Close",x+w-76,y+12,60)
    ui_text(a,fmt.tprintf("Installed version %s",UPDATER_VERSION),x+16,y+51,12,MUTED)
    message:=u.message
    if message=="" {message="Updates download automatically; install when you are ready."}
    if h>=260 {
        words:=strings.fields(message,context.temp_allocator)
        line:="";row:=0
        for word in words {
            candidate:=fmt.tprintf("%s%s%s",line," " if line!="" else "",word)
            if line!=""&&renderer_text_width(&a.renderer,candidate,12*a.scale)/a.scale>w-32 {
                ui_fit_text(a,line,x+16,y+82+f32(row)*19,12,w-32,SOFT)
                row+=1
                if row>=5 {line="…";break}
                line=word
            } else {line=candidate}
        }
        ui_fit_text(a,line,x+16,y+82+f32(row)*19,12,w-32,SOFT)
    } else {ui_fit_text(a,message,x+16,y+76,12,w-32,SOFT)}
    updater_button(a,"Automatic downloads: on" if u.automatic else "Automatic downloads: off",x+16,y+h-82,220)
    busy:=u.state==.Checking||u.state==.Downloading
    updater_button(a,"Check now",x+16,y+h-42,104,!busy)
    updater_button(a,"Update and restart",x+w-180,y+h-42,164,u.state==.Ready)
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
    if updater_contains(x,y,bx+w-76,by+12,60,30) {a.update_dialog=false;a.dirty=true;return true}
    if u==nil {return true}
    if updater_contains(x,y,bx+16,by+h-82,220,30) {updater_set_automatic(a,!u.automatic)}
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

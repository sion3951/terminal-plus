package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import glfw "vendor:glfw"

Device_Picker :: struct {
    open, select_all: bool,
    input: [512]u8,
    used, cursor, scroll, selection: int,
    input_anchor: int,
    input_selecting: bool,
    error: string,
}
Device_Picker_Layout :: struct {x,y,w,h,rows_y:f32,rows:int}

string_from_rune :: proc(ch:rune)->string {
    bytes,n:=utf8.encode_rune(ch)
    return strings.clone(string(bytes[:n]),context.temp_allocator)
}
profile_clone :: proc(p:Device_Profile)->Device_Profile {
    next:=p;next.name=strings.clone(p.name);next.target=strings.clone(p.target);return next
}
app_device_tab :: proc(a:^App,profile:Device_Profile,session_id:string="")->int {
    if session_id=="" {for tab,i in a.tabs {if !tab.files&&tab.remote&&device_profile_equal(tab.device,profile) {return i}}}
    if len(a.tabs)>=MAX_TABS {return -1}
    tab:=new(Tab)
    tab.remote=true;tab.device=profile_clone(profile)
    terminal_init(&tab.terminal,max(a.cols,2),max(a.rows,1))
    terminal_set_notify(&tab.terminal,terminal_wake)
    tab.session_id=session_new_id()
    if session_id!="" {delete(tab.session_id);tab.session_id=strings.clone(session_id)}
    tab.device.control_id=tab.session_id
    terminal_history_restore(&tab.terminal,tab.session_id)
    a.next_number+=1;tab.number=a.next_number
    message:=fmt.tprintf("\x1b[35m%s\x1b[0m\r\n\r\nSelect this device or press Enter to open its SSH terminal.\r\n",profile.name)
    terminal_feed(&tab.terminal,transmute([]u8)message)
    append(&a.tabs,tab);session_touch(a);a.dirty=true
    return len(a.tabs)-1
}
app_start_device :: proc(a:^App,tab:^Tab)->bool {
    if tab.files||!tab.remote {return true}
    if tab.started&&!tab.exited {return true}
    pty_destroy(&tab.pty)
    delete(tab.pending_input);tab.pending_input=nil;tab.input_offset=0;delete(tab.input_error);tab.input_error=""
    tab.scroll=0;tab.exited=false;tab.output_eof=false;tab.end_notice=false;tab.output_offset=0;clear(&tab.output)
    tab.terminal.parser=.Ground;tab.terminal.utf_remaining=0
    tab.terminal.origin=false;tab.terminal.insert_mode=false
    tab.terminal.autowrap=true;tab.terminal.application_cursor=false;tab.terminal.dec_graphics=false
    tab.terminal.scroll_top=0;tab.terminal.scroll_bottom=tab.terminal.rows-1
    terminal_feed(&tab.terminal,transmute([]u8)string("\x1b[?1049l\x1b[?25h\x1b[?2004l\x1b[0m\r\n"))
    terminal_feed(&tab.terminal,transmute([]u8)fmt.tprintf("Opening SSH session to %s...\r\n",device_display(tab.device)))
    tab.started=true;tab.session_owned=true;session_touch(a)
    if !pty_start_ssh(&tab.pty,a.cols,a.rows,tab.device.target,tab.device.port,control_id=tab.session_id,directory=tab.restore_path) {
        tab.exited=true
        terminal_feed(&tab.terminal,transmute([]u8)string("Could not start OpenSSH. Check that /usr/bin/ssh is installed.\r\nPress Enter to retry.\r\n"))
    }
    a.selected=false;a.selecting=false;a.blink=true;a.blink_tick=time.tick_now();a.dirty=true
    return !tab.exited
}
app_select_device :: proc(a:^App,index:int) {
    if index<0||index>=len(a.tabs) {return}
    a.active=index;session_touch(a);a.selected=false;a.selecting=false;a.menu.open=false;app_sync_tab_view(a)
    tab:=a.tabs[index]
    if tab.files {
        owner,source,_:=explorer_find_terminal(tab)
        if source!=nil&&source.remote {app_start_device(owner,source)}
    } else if tab.remote {app_start_device(a,tab)}
}
app_open_device :: proc(a:^App,profile:Device_Profile,save:bool=true)->bool {
    index:=app_device_tab(a,profile)
    if index<0 {a.picker.error="Close a device tab before opening another (16 maximum).";a.dirty=true;return false}
    if save {
        if !device_profile_save(profile) {fmt.eprintln("Could not save SSH device; the session is still available.")}
        device_profile_add(&a.profiles,profile)
    }
    a.picker.open=false
    app_select_device(a,index)
    return true
}
device_display :: proc(profile:Device_Profile)->string {
    if profile.port==0 {return profile.target}
    if strings.contains(profile.target,":") {
        at:=strings.last_index(profile.target,"@")
        if at>=0 {return fmt.tprintf("%s@[%s]:%d",profile.target[:at],profile.target[at+1:],profile.port)}
        return fmt.tprintf("[%s]:%d",profile.target,profile.port)
    }
    return fmt.tprintf("%s:%d",profile.target,profile.port)
}

device_picker_open :: proc(a:^App) {
    a.menu.open=false
    a.picker=Device_Picker{open=true,selection= -1}
    a.selected=false;a.selecting=false;a.dirty=true
}
device_picker_layout :: proc(a:^App)->Device_Picker_Layout {
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    box:=Device_Picker_Layout{w=min(560,width-24),h=min(480,height-24)}
    box.x=(width-box.w)/2;box.y=(height-box.h)/2
    box.rows_y=box.y+88
    box.rows=max(0,int((box.h-148)/32))
    return box
}
// -1 is the local machine; nonnegative entries index the discovered profiles.
device_picker_matches :: proc(a:^App)->[]int {
    matches:=make([dynamic]int,context.temp_allocator)
    query:=strings.to_lower(strings.trim_space(string(a.picker.input[:a.picker.used])),context.temp_allocator)
    if query==""||strings.contains("local",query) {append(&matches,-1)}
    for p,i in a.profiles {
        name:=strings.to_lower(p.name,context.temp_allocator)
        target:=strings.to_lower(device_display(p),context.temp_allocator)
        if query==""||strings.contains(name,query)||strings.contains(target,query) {append(&matches,i)}
    }
    return matches[:]
}
device_picker_reveal :: proc(a:^App,matches:[]int) {
    box:=device_picker_layout(a)
    a.picker.scroll=clamp(a.picker.scroll,0,max(0,len(matches)-box.rows))
    if a.picker.selection>=0 {
        a.picker.selection=min(a.picker.selection,max(0,len(matches)-1))
        if a.picker.selection<a.picker.scroll {a.picker.scroll=a.picker.selection}
        if a.picker.selection>=a.picker.scroll+box.rows {a.picker.scroll=max(0,a.picker.selection-box.rows+1)}
    }
}
device_picker_insert :: proc(a:^App,text:string) {
    picker:=&a.picker
    first,last:=text_edit_selection(picker.input[:picker.used],picker.cursor,picker.input_anchor,picker.input_selecting,picker.select_all)
    if last>first {picker.used=text_edit_remove(picker.input[:picker.used],first,last);picker.cursor=first}
    picker.select_all=false;picker.input_selecting=false
    for ch in text {
        if ch<32||ch==127 {continue}
        bytes,n:=utf8.encode_rune(ch)
        if picker.used+n>len(picker.input) {break}
        for i:=picker.used-1;i>=picker.cursor;i-=1 {picker.input[i+n]=picker.input[i]}
        copy(picker.input[picker.cursor:picker.cursor+n],bytes[:n])
        picker.cursor+=n;picker.used+=n
    }
    picker.selection= -1;picker.scroll=0;picker.error="";a.dirty=true
}
device_picker_choose :: proc(a:^App,match:int) {
    if match<0 {
        for tab,i in a.tabs {if !tab.files&&!tab.remote {a.picker.open=false;app_select_device(a,i);return}}
        if app_new_tab(a) {a.picker.open=false} else {a.picker.error="Could not open a local terminal."}
        return
    }
    if match>=len(a.profiles) {return}
    // The array can grow while opening a profile; use a value copy first.
    profile:=a.profiles[match]
    app_open_device(a,profile)
}
device_picker_connect :: proc(a:^App) {
    picker:=&a.picker
    matches:=device_picker_matches(a)
    if picker.selection>=0&&picker.selection<len(matches) {device_picker_choose(a,matches[picker.selection]);return}
    text:=strings.trim_space(string(picker.input[:picker.used]))
    if strings.equal_fold(text,"local") {device_picker_choose(a,-1);return}
    target,port,error:=device_target_parse(text)
    if error!="" {picker.error=error;a.dirty=true;return}
    // Preserve the configured alias's label and port when it was entered exactly.
    for profile in a.profiles {
        if device_profile_equal(profile,Device_Profile{target=target,port=port}) {app_open_device(a,profile);return}
    }
    app_open_device(a,Device_Profile{name=text,target=target,port=port,saved=true})
}
device_picker_key :: proc(a:^App,key,mods:c.int) {
    picker:=&a.picker
    ctrl:=mods&glfw.MOD_CONTROL!=0
    a.dirty=true
    if ctrl&&key==glfw.KEY_V {device_picker_insert(a,glfw.GetClipboardString(a.renderer.window));return}
    handled,first,last:=text_edit_key(a,picker.input[:picker.used],&picker.cursor,&picker.input_anchor,&picker.input_selecting,&picker.select_all,key,mods)
    if handled {
        if last>first {picker.used=text_edit_remove(picker.input[:picker.used],first,last);picker.error="";picker.selection= -1;picker.scroll=0}
        return
    }
    switch key {
    case glfw.KEY_ESCAPE:picker.open=false
    case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:device_picker_connect(a)
    case glfw.KEY_UP,glfw.KEY_DOWN,glfw.KEY_TAB:
        matches:=device_picker_matches(a)
        if len(matches)==0 {return}
        if key==glfw.KEY_UP {picker.selection=max(0,picker.selection-1)} else {picker.selection=min(len(matches)-1,picker.selection+1)}
        picker.select_all=false;picker.input_selecting=false;device_picker_reveal(a,matches)
    }

}
device_picker_scroll :: proc(a:^App,delta:int) {
    box:=device_picker_layout(a);matches:=device_picker_matches(a)
    a.picker.selection= -1
    a.picker.scroll=clamp(a.picker.scroll-delta*3,0,max(0,len(matches)-box.rows));a.dirty=true
}
device_picker_click :: proc(a:^App,x,y:f32) {
    box:=device_picker_layout(a)
    if x<box.x||x>=box.x+box.w||y<box.y||y>=box.y+box.h {a.picker.open=false;a.dirty=true;return}
    if x>=box.x+box.w-38&&y<box.y+36 {a.picker.open=false;a.dirty=true;return}
    if y>=box.y+box.h-44&&y<box.y+box.h-14&&x>=box.x+box.w-126&&x<box.x+box.w-16 {device_picker_connect(a);return}
    if y>=box.y+42&&y<box.y+76 {
        a.picker.cursor=a.picker.used;a.picker.select_all=false;a.picker.input_selecting=false;a.dirty=true;return
    }
    if y>=box.rows_y&&y<box.rows_y+f32(box.rows)*32 {
        matches:=device_picker_matches(a);index:=a.picker.scroll+int((y-box.rows_y)/32)
        if index<len(matches) {device_picker_choose(a,matches[index])}
    }
}

ui_fit_text :: proc(a:^App,input_text:string,x,y,size,width:f32,color:Color,kind:Font_Kind=.UI) {
    if width<=0 {return}
    text:=input_text
    font:=renderer_font_size(&a.renderer,size*a.scale,kind)
    limit:=width*a.scale
    ellipsis:=renderer_glyph(&a.renderer,font,'…').advance
    advance:f32
    last:=0
    // Stop at the first overflow; never measure successively longer prefixes
    // or rasterize offscreen suffixes of long filenames and preview lines.
    for ch,offset in text {
        if advance+ellipsis<=limit {last=offset}
        advance+=renderer_glyph(&a.renderer,font,ch).advance
        if advance>limit {
            if ellipsis>limit {return}
            text=fmt.tprintf("%s…",text[:last])
            break
        }
    }
    ui_text(a,text,x,y,size,color,kind)
}
device_picker_render :: proc(a:^App) {
    box:=device_picker_layout(a);picker:=&a.picker
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    mouse_x,mouse_y:=glfw.GetCursorPos(a.renderer.window)
    mx,my:=f32(mouse_x),f32(mouse_y)
    ui_rect(a,0,0,width,height,SCRIM)
    ui_glass(a,box.x,box.y,box.w,box.h,14)
    ui_title(a,"Connect to a device",box.x+18,box.y+21,15,box.w-80)
    close_hover:=mx>=box.x+box.w-38&&my>=box.y&&my<box.y+36
    ui_control(a,box.x+box.w-34,box.y+7,26,26,.Ghost,close_hover)
    ui_icon_close(a,box.x+box.w-21,box.y+20,7,TEXT if close_hover else MUTED)
    ui_field(a,box.x+16,box.y+42,box.w-32,34,true,false)
    explorer_icon(a,.Search,box.x+27,box.y+51,MUTED)
    input:=string(picker.input[:picker.used])
    font:=renderer_font_size(&a.renderer,14*a.scale)
    char_w:=font.glyphs['M'-32].advance/a.scale
    capacity:=max(1,int((box.w-76)/char_w))
    start:=0
    if picker.cursor>capacity {start=picker.cursor-capacity}
    for start<picker.used&&!utf8.rune_start(picker.input[start]) {start+=1}
    text_x:=box.x+48
    if input=="" {ui_text_mid(a,"user@host:port or SSH alias",text_x,box.y+59,14,box.w-76,MUTED)}
    else {
        text_edit_selection_render(a,picker.input[:picker.used],start,picker.cursor,picker.input_anchor,picker.input_selecting,picker.select_all,text_x,box.y+47,14,box.w-76,24)
        ui_text_mid(a,input[start:],text_x,box.y+59,14,box.w-76,TEXT)
    }
    prefix:=string(picker.input[start:max(start,picker.cursor)])
    caret_x:=text_x+renderer_text_width(&a.renderer,prefix,14*a.scale)/a.scale
    if a.blink||!a.focused {ui_caret(a,min(caret_x,box.x+box.w-26),box.y+50,18)}
    matches:=device_picker_matches(a)
    device_picker_reveal(a,matches)
    for row in 0..<box.rows {
        index:=picker.scroll+row
        if index>=len(matches) {break}
        py:=box.rows_y+f32(row)*32
        hover:=mx>=box.x+16&&mx<box.x+box.w-16&&my>=py&&my<py+32
        ui_row(a,box.x+10,py+1,box.w-20,30,index==picker.selection,hover)
        match:=matches[index]
        label,kind:="Local terminal","Local"
        icon:UI_Icon=.Terminal
        if match>=0 {
            p:=a.profiles[match];label=p.name;kind="SSH";icon=.Server
            if p.configured {kind="SSH config"} else if p.saved {kind="Saved"}
        }
        lit:=index==picker.selection||hover
        ui_icon(a,icon,box.x+22,py+8,SOFT if lit else MUTED)
        kind_w:=renderer_text_width(&a.renderer,kind,11*a.scale)/a.scale
        ui_text_mid(a,label,box.x+48,py+16,14,box.w-kind_w-96,TEXT)
        ui_text_mid(a,kind,box.x+box.w-26-kind_w,py+16,11,kind_w+2,MUTED)
    }
    if len(matches)==0&&box.rows>0 {
        ui_icon(a,.Link,box.x+22,box.rows_y+8,MUTED)
        ui_text_mid(a,"New device. Press Enter to connect.",box.x+48,box.rows_y+16,13,box.w-80,SOFT)
    }
    footer_y:=box.y+box.h-54
    ui_rect(a,box.x+1,footer_y,box.w-2,1,Color{1,1,1,0.06})
    if picker.error!="" {ui_text_mid(a,picker.error,box.x+18,footer_y-16,12,box.w-36,DANGER)}
    ui_text_mid(a,"Enter to connect · Esc to close",box.x+18,box.y+box.h-29,12,box.w-170,MUTED)
    connect_hover:=my>=box.y+box.h-44&&my<box.y+box.h-14&&mx>=box.x+box.w-126&&mx<box.x+box.w-16
    ui_button(a,"Connect",box.x+box.w-126,box.y+box.h-44,110,30,.Primary,connect_hover)
}

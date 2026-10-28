package main

import "core:c"
import glfw "vendor:glfw"

Tab_Menu :: struct {
    open: bool,
    selected, scroll: int,
    error: string, // Static messages; the dropdown owns no allocations.
}
Tab_Menu_Layout :: struct {x,y,w,h:f32,visible,total:int}
TAB_MENU_ROW :: f32(32)

tab_menu_count :: proc(a:^App)->int {return len(a.profiles)+4}
tab_menu_visual_row :: proc(index:int)->int {if index>=3 {return index+1};return index}
tab_menu_item_at :: proc(row:int)->int {if row==3 {return -1};if row>3 {return row-1};return row}

tab_menu_layout :: proc(a:^App)->Tab_Menu_Layout {
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    box:=Tab_Menu_Layout{w=min(284,width-16),y=HEADER+4,total=tab_menu_count(a)+1}
    available:=max(32,height-box.y-8)
    box.visible=min(box.total,max(1,min(11,int((available-16)/TAB_MENU_ROW))))
    box.h=min(available,f32(box.visible)*TAB_MENU_ROW+16)
    box.x=clamp(tab_bar_layout(a).new_x,8,max(8,width-box.w-8))
    a.menu.scroll=clamp(a.menu.scroll,0,max(0,box.total-box.visible))
    return box
}

tab_menu_toggle :: proc(a:^App) {
    opening:= !a.menu.open
    a.menu=Tab_Menu{open=opening}
    a.selected=false;a.selecting=false;a.dirty=true
}

tab_menu_hit :: proc(a:^App,x,y:f32)->int {
    box:=tab_menu_layout(a)
    if x<box.x+4||x>=box.x+box.w-4||y<box.y+8||y>=box.y+8+f32(box.visible)*TAB_MENU_ROW {return -1}
    row:=a.menu.scroll+int((y-box.y-8)/TAB_MENU_ROW)
    index:=tab_menu_item_at(row)
    if index<0||index>=tab_menu_count(a) {return -1}
    return index
}

tab_menu_reveal :: proc(a:^App) {
    box:=tab_menu_layout(a)
    row:=tab_menu_visual_row(a.menu.selected)
    if row<a.menu.scroll {a.menu.scroll=row}
    if row>=a.menu.scroll+box.visible {a.menu.scroll=row-box.visible+1}
}

tab_menu_choose :: proc(a:^App,index:int) {
    if index<0||index>=tab_menu_count(a) {return}
    a.menu.error="";a.dirty=true
    switch index {
    case 0:
        if len(a.tabs)>=MAX_TABS {a.menu.error="Close a tab before opening another.";return}
        if !app_new_tab(a) {a.menu.error="Could not start a local terminal.";return}
        a.menu.open=false
    case 1:
        a.menu.open=false;explorer_open_tab(a)
    case 2:
        a.menu.open=false;workspace_request_window(a)
    case:
        profile_index:=index-3
        if profile_index==len(a.profiles) {
            a.menu.open=false;device_picker_open(a)
        } else {
            // app_open_device may grow profiles; borrow no slice elements
            // across that call and preserve the existing device-tab behavior.
            profile:=a.profiles[profile_index]
            if app_open_device(a,profile) {a.menu.open=false}
            else {a.menu.error="Close a tab before opening another."}
        }
    }
}

tab_menu_mouse :: proc(a:^App,button,action:c.int,x,y:f32)->bool {
    if !a.menu.open {return false}
    if action!=glfw.PRESS {return true}
    if button!=glfw.MOUSE_BUTTON_LEFT {return true}
    bar:=tab_bar_layout(a)
    if x>=bar.new_x&&x<bar.new_x+32&&y>=8&&y<40 {tab_menu_toggle(a);return true}
    box:=tab_menu_layout(a)
    if x<box.x||x>=box.x+box.w||y<box.y||y>=box.y+box.h {a.menu.open=false;a.dirty=true;return true}
    if index:=tab_menu_hit(a,x,y);index>=0 {a.menu.selected=index;tab_menu_choose(a,index)}
    return true
}

tab_menu_key :: proc(a:^App,key,mods:c.int)->bool {
    if !a.menu.open {return false}
    if mods&(glfw.MOD_CONTROL|glfw.MOD_ALT|glfw.MOD_SUPER)!=0 {
        a.menu.open=false;a.dirty=true;return false
    }
    count:=tab_menu_count(a)
    switch key {
    case glfw.KEY_ESCAPE,glfw.KEY_LEFT:a.menu.open=false
    case glfw.KEY_UP:a.menu.selected=(a.menu.selected+count-1)%count
    case glfw.KEY_DOWN:a.menu.selected=(a.menu.selected+1)%count
    case glfw.KEY_TAB:
        if mods&glfw.MOD_SHIFT!=0 {a.menu.selected=(a.menu.selected+count-1)%count}
        else {a.menu.selected=(a.menu.selected+1)%count}
    case glfw.KEY_HOME:a.menu.selected=0
    case glfw.KEY_END:a.menu.selected=count-1
    case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:tab_menu_choose(a,a.menu.selected)
    }
    if a.menu.open {tab_menu_reveal(a)}
    a.dirty=true
    return true
}

tab_menu_hover :: proc(a:^App,x,y:f32)->u64 {
    if !a.menu.open {return 0}
    index:=tab_menu_hit(a,x,y)
    if index>=0 {a.menu.selected=index;return (u64(8)<<32)|u64(index+1)}
    return u64(8)<<32
}

tab_menu_scroll :: proc(a:^App,delta:int)->bool {
    if !a.menu.open {return false}
    box:=tab_menu_layout(a)
    a.menu.scroll=clamp(a.menu.scroll-delta,0,max(0,box.total-box.visible))
    a.dirty=true
    return true
}

tab_menu_render :: proc(a:^App) {
    if !a.menu.open {return}
    box:=tab_menu_layout(a)
    ui_rect(a,box.x+3,box.y+4,box.w,box.h,Color{0,0,0,0.4})
    ui_rect(a,box.x-1,box.y-1,box.w+2,box.h+2,LINE)
    ui_rect(a,box.x,box.y,box.w,box.h,PANEL)
    for visible in 0..<box.visible {
        row:=a.menu.scroll+visible
        py:=box.y+8+f32(visible)*TAB_MENU_ROW
        index:=tab_menu_item_at(row)
        if index<0 {
            ui_rect(a,box.x+12,py+3,box.w-24,1,LINE)
            ui_text(a,"REMOTE MACHINES",box.x+14,py+12,10,MUTED)
            continue
        }
        if index>=tab_menu_count(a) {break}
        if index==a.menu.selected {ui_rect(a,box.x+5,py,box.w-10,TAB_MENU_ROW,LINE)}
        label,shortcut:="",""
        color:=TEXT
        switch index {
        case 0:label="New terminal"
        case 1:
            label="Files";shortcut="Ctrl+B"
            if a.explorer_visible {color=ACCENT;ui_rect(a,box.x+box.w-88,py+14,4,4,ACCENT)}
        case 2:label="New window";shortcut="Ctrl+Shift+N"
        case:
            profile_index:=index-3
            if profile_index==len(a.profiles) {label="Connect via SSH…"}
            else {label=a.profiles[profile_index].name}
        }
        label_width:=box.w-28
        if shortcut!="" {
            sw:=renderer_text_width(&a.renderer,shortcut,11*a.scale)/a.scale
            ui_text(a,shortcut,box.x+box.w-14-sw,py+11,11,MUTED)
            label_width-=sw+18
        }
        ui_fit_text(a,label,box.x+14,py+10,13,label_width,color)
    }
    if box.total>box.visible {
        track:=f32(box.visible)*TAB_MENU_ROW
        thumb:=max(16,track*f32(box.visible)/f32(box.total))
        position:=(track-thumb)*f32(a.menu.scroll)/f32(max(1,box.total-box.visible))
        ui_rect(a,box.x+box.w-3,box.y+8+position,2,thumb,MUTED)
    }
    if a.menu.error!="" {
        ui_rect(a,box.x+1,box.y+box.h-30,box.w-2,29,BG)
        ui_fit_text(a,a.menu.error,box.x+12,box.y+box.h-20,11,box.w-24,Color{0.96,0.36,0.36,1})
    }
}

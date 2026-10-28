package main

import "core:math"
import "core:time"
import glfw "vendor:glfw"
import x "vendor:x11/xlib"

Tab_Drag :: struct {
    source, target, occupied: ^App,
    tab, onto: ^Tab,
    group_id, to_group, onto_group: u64,
    drop_mode: Tab_Drop_Mode,
    list_scroll: bool,
    list_depth: int,
    armed, dragging, desktop: bool,
    press_x, press_y, screen_x, screen_y, grab_x, grab_y: f64,
    target_x, target_y: f64,
    insertion, scroll_direction: int,
    scroll_tick: time.Tick,
}
tab_drag: Tab_Drag

tab_drag_desktop_supported :: proc()->bool {return glfw.GetPlatform()==glfw.PLATFORM_X11}
tab_drag_active :: proc()->bool {return tab_drag.armed}
tab_drag_scroll_override :: proc(a:^App)->bool {return tab_drag.dragging&&tab_drag.target==a}

tab_drag_mark :: proc() {
    if tab_drag.source!=nil {tab_drag.source.dirty=true}
    if tab_drag.target!=nil {tab_drag.target.dirty=true}
}
tab_drag_cancel :: proc() {tab_drag_mark();tab_drag_wayland_cancel();tab_drag={}}

tab_drag_index :: proc(a:^App,tab:^Tab)->int {
    if a!=nil {for candidate,i in a.tabs {if candidate==tab {return i}}}
    return -1
}
tab_drag_press :: proc(a:^App,tab:^Tab,px,py:f64,group_id:u64=0) {
    tab_drag_cancel()
    index:=tab_drag_index(a,tab)
    if index<0 {return}
    desktop:=tab_drag_desktop_supported()
    sx,sy:=px,py
    if desktop {wx,wy:=glfw.GetWindowPos(a.renderer.window);sx+=f64(wx);sy+=f64(wy)}
    bar:=tab_bar_layout(a)
    tab_drag=Tab_Drag{source=a,tab=tab,group_id=group_id,armed=true,desktop=desktop,press_x=sx,press_y=sy,screen_x=sx,screen_y=sy,
        grab_x=clamp(px-f64(bar.start)-f64(tab_bar_slot(a,bar,tab)-bar.first)*f64(bar.tab_width),8,f64(bar.tab_width)-8),grab_y=py,scroll_tick=time.tick_now()}
}

// The root pointer's top-level child identifies the visible window, including
// under overlapping window-manager frames. Geometry alone would target a
// covered terminal. Every queried client still belongs to our live workspace.
tab_drag_desktop_hit :: proc()->(sx,sy:f64,hit:^App) {
    display:=glfw.GetX11Display()
    if display==nil {return}
    root,child:x.Window;rx,ry,px,py:i32;mask:x.KeyMask
    if !x.QueryPointer(display,x.DefaultRootWindow(display),&root,&child,&rx,&ry,&px,&py,&mask) {return}
    sx,sy=f64(rx),f64(ry)
    if child==0 {return}
    for a in workspace_windows {
        window:=a.renderer.window
        if window==nil||glfw.WindowShouldClose(window)||glfw.GetWindowAttrib(window,glfw.ICONIFIED)!=0||glfw.GetWindowAttrib(window,glfw.VISIBLE)==0 {continue}
        ancestor:=glfw.GetX11Window(window)
        for _ in 0..<8 {
            if ancestor==child {return sx,sy,a}
            parent,window_root:x.Window;children:[^]x.Window;count:u32
            if x.QueryTree(display,ancestor,&window_root,&parent,&children,&count)==cast(x.Status)0 {break}
            if children!=nil {x.Free(children)}
            if parent==0||parent==ancestor||parent==window_root {break}
            ancestor=parent
        }
    }
    return
}

tab_drag_update_target :: proc(sx,sy:f64,occupied:^App) {
    previous:=tab_drag.target
    previous_insertion:=tab_drag.insertion;previous_onto:=tab_drag.onto;previous_mode:=tab_drag.drop_mode
    previous_scroll:=tab_drag.scroll_direction
    tab_drag.occupied=occupied;tab_drag.target=nil;tab_drag.onto=nil;tab_drag.to_group=0;tab_drag.onto_group=0
    tab_drag.drop_mode=.Insert;tab_drag.scroll_direction=0;tab_drag.list_scroll=false
    if occupied!=nil&&!occupied.picker.open&&!occupied.menu.open {
        local_x,local_y:=sx,sy
        if tab_drag.desktop {wx,wy:=glfw.GetWindowPos(occupied.renderer.window);local_x-=f64(wx);local_y-=f64(wy)}
        width,height:=glfw.GetWindowSize(occupied.renderer.window)
        tab_group_hover(occupied,f32(local_x),f32(local_y))
        moving:=1;if tab_drag.group_id!=0 {moving=tab_group_count(tab_drag.source,tab_drag.group_id)}
        allowed:=occupied==tab_drag.source||len(occupied.tabs)+moving<=MAX_TABS
        if local_x>=0&&local_y>=0&&local_x<f64(width)&&local_y<f64(height)&&allowed {
            box,row,item,item_group:=tab_group_hit(occupied,f32(local_x),f32(local_y))
            if local_y>=f64(HEADER)&&box.valid {
                tab_drag.target=occupied;tab_drag.target_x=local_x;tab_drag.target_y=local_y
                tab_drag.drop_mode=.List;tab_drag.to_group=box.group;tab_drag.list_depth=box.depth
                scroll:=occupied.group_menus[box.depth].scroll
                before:=scroll+int(math.floor((f32(local_y)-box.y-6)/GROUP_ROW_HEIGHT+0.5))
                before=clamp(before,0,box.count)
                tab_drag.insertion=len(occupied.tabs)
                if before<box.count {tab_drag.insertion=box.items[before]}
                else {tab_drag.insertion=tab_group_end(occupied,tab_group_first(occupied,box.group),box.group)}
                if row>=0&&item>=0 {
                    top:=box.y+6+f32(row-scroll)*GROUP_ROW_HEIGHT
                    own:=occupied==tab_drag.source&&((tab_drag.group_id==0&&item_group==0&&occupied.tabs[item]==tab_drag.tab)||(tab_drag.group_id!=0&&item_group==tab_drag.group_id))
                    if !own&&f32(local_y)>=top+GROUP_ROW_HEIGHT*0.25&&f32(local_y)<top+GROUP_ROW_HEIGHT*0.75&&f32(local_x)>=box.x+box.w*0.25&&f32(local_x)<box.x+box.w*0.75 {
                        tab_drag.drop_mode=.Group;tab_drag.onto=occupied.tabs[item];tab_drag.onto_group=item_group
                    }
                }
                tab_drag.list_scroll=true
                if f32(local_y)<box.y+14&&scroll>0 {tab_drag.scroll_direction= -1}
                else if f32(local_y)>box.y+box.h-14&&scroll+box.rows<box.count {tab_drag.scroll_direction=1}
            } else if local_y<f64(HEADER) {
                tab_drag.target=occupied;tab_drag.target_x=local_x;tab_drag.target_y=local_y
                bar:=tab_bar_layout(occupied)
                slot:=clamp(bar.first+int((f32(local_x)-bar.start)/bar.tab_width),bar.first,bar.first+bar.visible-1)
                index:=bar.items[slot]
                left:=bar.start+f32(slot-bar.first)*bar.tab_width
                tab_drag.insertion=index
                if f32(local_x)>=left+bar.tab_width/2 {tab_drag.insertion=tab_group_end(occupied,index,bar.groups[slot])}
                own_group:=occupied==tab_drag.source&&tab_drag.group_id!=0&&tab_root_group(occupied.tabs[index])==tab_drag.group_id
                own_tab:=occupied==tab_drag.source&&tab_drag.group_id==0&&occupied.tabs[index]==tab_drag.tab&&tab_root_group(occupied.tabs[index])==0
                if !own_group&&!own_tab&&f32(local_x)>=left+bar.tab_width*0.25&&f32(local_x)<left+bar.tab_width*0.75 {
                    tab_drag.drop_mode=.Group;tab_drag.onto=occupied.tabs[index];tab_drag.onto_group=bar.groups[slot]
                }
                if f32(local_x)>=bar.start+f32(bar.visible)*bar.tab_width {tab_drag.insertion=len(occupied.tabs)}
                if bar.overflow {
                    right:=f64(bar.start)+f64(bar.visible)*f64(bar.tab_width)
                    if local_x<f64(bar.start+14)&&bar.first>0 {tab_drag.scroll_direction= -1}
                    else if local_x>right-14&&bar.first+bar.visible<bar.count {tab_drag.scroll_direction=1}
                }
            }
        }
    }
    if previous!=nil&&previous!=occupied {tab_group_hover(previous,-100,-100)}
    if previous!=tab_drag.target||previous_insertion!=tab_drag.insertion||previous_onto!=tab_drag.onto||previous_mode!=tab_drag.drop_mode||previous_scroll!=tab_drag.scroll_direction {
        if previous!=nil {previous.dirty=true}
        tab_drag_mark();tab_drag.scroll_tick=time.tick_now()
    }
}

tab_drag_motion :: proc(a:^App,px,py:f64)->bool {
    if !tab_drag.armed {return false}
    if drag_wayland.active {return true}
    if tab_drag_index(tab_drag.source,tab_drag.tab)<0 {tab_drag_cancel();return false}
    sx,sy:=px,py
    occupied:=tab_drag.source
    if tab_drag.desktop {sx,sy,occupied=tab_drag_desktop_hit()}
    else if a!=tab_drag.source {return true}
    else {
        width,height:=glfw.GetWindowSize(a.renderer.window)
        if px<0||py<0||px>=f64(width)||py>=f64(height) {occupied=nil}
    }
    dx,dy:=sx-tab_drag.press_x,sy-tab_drag.press_y
    if !tab_drag.dragging&&dx*dx+dy*dy>=36 {a.last_tab_click=nil;tab_drag.dragging=true;tab_drag_mark()}
    if !tab_drag.dragging {return true}
    if glfw.GetPlatform()==glfw.PLATFORM_WAYLAND&&tab_drag_wayland_start() {return true}
    moved:=sx!=tab_drag.screen_x||sy!=tab_drag.screen_y
    tab_drag.screen_x=sx;tab_drag.screen_y=sy
    tab_drag_update_target(sx,sy,occupied)
    if moved {tab_drag_mark()}
    return true
}

tab_drag_release :: proc(a:^App,px,py:f64)->bool {
    if !tab_drag.armed {return false}
    if drag_wayland.active {return true}
    tab_drag_motion(a,px,py)
    if !tab_drag.armed {return true}
    drag:=tab_drag
    tab_drag_cancel()
    if !drag.dragging {return true}
    if drag.target!=nil {
        workspace_request_drop(drag.source,drag.tab,drag.target,drag.insertion,drag.drop_mode,drag.onto,drag.group_id,drag.to_group,drag.onto_group)
    } else if drag.desktop {
        // Leaving a tab strip detaches the tab, including a drop over terminal
        // content. Native decorations and unavailable/full tab strips cancel.
        if drag.occupied!=nil {
            wx,wy:=glfw.GetWindowPos(drag.occupied.renderer.window)
            width,height:=glfw.GetWindowSize(drag.occupied.renderer.window)
            lx,ly:=drag.screen_x-f64(wx),drag.screen_y-f64(wy)
            if lx<0||lx>=f64(width)||ly<f64(HEADER)||ly>=f64(height) {return true}
        }
        // Place the new tab under the hand at the same offset within its bar.
        workspace_request_detach(drag.source,drag.tab,i32(drag.screen_x-f64(TAB_BAR_START)-drag.grab_x),i32(drag.screen_y-drag.grab_y),drag.group_id)
    }
    return true
}

tab_drag_poll :: proc() {
    if !tab_drag.armed {return}
    source:=tab_drag.source
    if !drag_wayland.active {
        px,py:=glfw.GetCursorPos(source.renderer.window)
        if glfw.GetMouseButton(source.renderer.window,glfw.MOUSE_BUTTON_LEFT)==glfw.RELEASE {tab_drag_release(source,px,py);return}
        tab_drag_motion(source,px,py)
    }
    if tab_drag.scroll_direction!=0&&tab_drag.target!=nil&&time.tick_diff(tab_drag.scroll_tick,time.tick_now())>=80*time.Millisecond {
        target:=tab_drag.target
        bar:=tab_bar_layout(target)
        if tab_drag.list_scroll {
            box:=tab_group_popup(target,tab_drag.list_depth)
            if box.valid {state:=&target.group_menus[box.depth];state.scroll=clamp(state.scroll+tab_drag.scroll_direction,0,max(0,box.count-box.rows))}
        } else {target.header_scroll=clamp(bar.first+tab_drag.scroll_direction,0,max(0,bar.count-bar.visible))}
        target.dirty=true;tab_drag.scroll_tick=time.tick_now()
        tab_drag_update_target(tab_drag.screen_x,tab_drag.screen_y,target)
    }
}
tab_drag_wait_delay :: proc()->f64 {
    if tab_drag.armed&&tab_drag.dragging&&tab_drag.scroll_direction!=0 {return 0.08}
    return 60
}

tab_drag_render :: proc(a:^App) {
    if !tab_drag.dragging {return}
    bar:=tab_bar_layout(a)
    if a==tab_drag.source {
        slot:=tab_bar_slot(a,bar,tab_drag.tab)
        if slot>=bar.first&&slot<bar.first+bar.visible {
            left:=bar.start+f32(slot-bar.first)*bar.tab_width
            ui_rect(a,left+3,4,bar.tab_width-6,1,ACCENT)
            ui_rect(a,left+3,HEADER-5,bar.tab_width-6,1,ACCENT)
        }
    }
    if a==tab_drag.target&&tab_drag.drop_mode==.Group&&tab_drag.onto!=nil&&tab_drag.target_y<f64(HEADER) {
        slot:=tab_bar_slot(a,bar,tab_drag.onto)
        left:=bar.start+f32(slot-bar.first)*bar.tab_width
        x:=left+bar.tab_width/2-14
        ui_rect(a,x,10,28,28,ACCENT);ui_rect(a,x+1,11,26,26,BG)
        ui_text(a,"+",x+8,15,20,ACCENT)
    } else if a==tab_drag.target&&tab_drag.drop_mode==.Insert {
        slot:=bar.count
        for i in 0..<bar.count {if bar.items[i]>=tab_drag.insertion {slot=i;break}}
        marker:=clamp(bar.start+f32(slot-bar.first)*bar.tab_width,bar.start,bar.start+f32(bar.visible)*bar.tab_width)
        ui_rect(a,marker-1,7,3,HEADER-14,ACCENT)
        ui_rect(a,marker-5,6,11,2,ACCENT)
        ui_rect(a,marker-5,HEADER-8,11,2,ACCENT)
    }
}

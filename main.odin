package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:math"
import "core:time"
import "core:unicode/utf8"
import glfw "vendor:glfw"

Color :: [4]f32
// Neutral surfaces and text match the neighboring task_master theme.
BG :: Color{0,0,0,1}
PANEL :: Color{0.040,0.040,0.040,1}
LINE :: Color{0.13,0.13,0.13,1}
HOVER :: Color{0.08,0.08,0.08,1}
SELECTION :: Color{0.22,0.22,0.22,1}
TEXT :: Color{0.93,0.93,0.93,1}
MUTED :: Color{0.49,0.49,0.49,1}
SOFT :: Color{0.74,0.74,0.74,1}
ACCENT :: TEXT
GREEN :: Color{0.43,0.83,0.64,1}
TAB_WIDTH :: 210
TAB_BAR_START :: 8
HEADER :: 48
PAD :: 18
MAX_TABS :: 16

Tab :: struct {
    terminal: Terminal,
    pty: PTY,
    output: [dynamic]u8,
    output_offset: int,
    pending_input: [dynamic]u8,
    input_offset: int,
    input_error: string,
    output_eof, end_notice: bool,
    scroll: int,
    unread: bool,
    number: int,
    device: Device_Profile,
    session_id, restore_path, history_error_seen: string,
    remote, started, exited, files: bool,
    remote_end: ^Remote_Session_End,
    session_owned: bool,
    source_id, document_path: string,
    label: string,
    group_id: u64,
    group_label: string,
    group_parents: [dynamic]Tab_Group_Ref,
    explorer: Explorer_State,
}
App :: struct {
    renderer: Renderer,
    vertices: [dynamic]Vertex,
    tabs: [dynamic]^Tab,
    profiles: [dynamic]Device_Profile,
    picker: Device_Picker,
    menu: Tab_Menu,
    tab_rename: Tab_Rename,
    last_tab_click: ^Tab,
    last_tab_click_group: u64,
    last_tab_click_time: time.Tick,
    last_tab_click_x, last_tab_click_y: f64,
    group_hover: u64,
    group_menus: [dynamic]Group_Menu_State,
    explorer_visible, explorer_focus, explorer_pointer: bool,
    explorer_width: f32,
    explorer_width_custom: bool,
    active, next_number: int,
    output_next: int,
    output_work: bool,
    input_delay: f64,
    session_dirty, session_loading, session_save_allowed: bool,
    session_error_seen: string,
    dirty, focused, selecting, selected: bool,
    anchor, endpoint: [2]int,
    selection_last_row: int,
    font_index: int,
    scale, font_size, cell_w, cell_h, origin_x, origin_y: f32,
    cols, rows: int,
    header_scroll: int,
    tab_wheel: f64,
    zoom_wheel: f64,
    hover_key: u64,
    window_title: string,
    update_dialog: bool,
    blink: bool,
    blink_tick: time.Tick,
    capture: string,
    capture_after: f64,
    exit_after: f64,
    started: time.Tick,
}

rgb :: proc(v:u32)->Color {return {f32((v>>16)&255)/255,f32((v>>8)&255)/255,f32(v&255)/255,1}}
app_from :: proc(w:glfw.WindowHandle)->^App {return cast(^App)glfw.GetWindowUserPointer(w)}
terminal_wake :: proc() {glfw.PostEmptyEvent()}

active_tab :: proc(a:^App)->^Tab {if len(a.tabs)==0 {return nil};return a.tabs[a.active]}
app_metrics :: proc(a:^App) {
    r:=&a.renderer
    wx,wy:=glfw.GetWindowSize(r.window)
    a.scale=clamp(max(f32(r.width)/f32(max(wx,1)),f32(r.height)/f32(max(wy,1))),0.5,4)
    sizes:=FONT_SIZES
    a.font_size=sizes[a.font_index]*a.scale
    font:=renderer_font_size(r,a.font_size,.Terminal)
    a.font_size=font.pixels
    a.cell_w=max(1,font.cell_width)
    a.cell_h=max(math.ceil(a.font_size*1.40),font.ascent+font.descent)
    a.origin_x=math.round(PAD*a.scale)
    a.origin_y=math.round((HEADER+12)*a.scale)
    a.cols=max(2,int((f32(r.width)-a.origin_x-PAD*a.scale)/a.cell_w))
    a.rows=max(1,int((f32(r.height)-a.origin_y-10*a.scale)/a.cell_h))
    for tab in a.tabs {
        if tab.files {continue}
        if tab.terminal.cols!=a.cols || tab.terminal.rows!=a.rows {
            if tab.pty.persistent {
                pty_resize(&tab.pty,a.cols,a.rows)
                continue
            }
            if terminal_resize(&tab.terminal,a.cols,a.rows) {
                if tab.started&&!tab.exited {pty_resize(&tab.pty,tab.terminal.cols,tab.terminal.rows)}
                tab.scroll=min(tab.scroll,terminal_history_count(&tab.terminal));a.selected=false
            }
        }
    }
    if tab:=active_tab(a);tab!=nil&&!tab.files {a.cols=tab.terminal.cols;a.rows=tab.terminal.rows}
}
app_new_tab :: proc(a:^App,command:string="",session_id:string="",directory:string="")->bool {
    if len(a.tabs)>=MAX_TABS {return false}
    tab:=new(Tab)
    terminal_init(&tab.terminal,max(a.cols,80),max(a.rows,24))
    terminal_set_notify(&tab.terminal,terminal_wake)
    tab.session_id=session_new_id()
    if session_id!="" {delete(tab.session_id);tab.session_id=strings.clone(session_id)}
    tab.restore_path=strings.clone(directory)
    if !local_session_start(&tab.pty,&tab.terminal,tab.session_id,tab.terminal.cols,tab.terminal.rows,command,directory) {
        fmt.eprintln(session_status_error())
        terminal_destroy(&tab.terminal);delete(tab.session_id);delete(tab.restore_path);free(tab);return false
    }
    a.next_number+=1;tab.number=a.next_number
    tab.started=true;tab.device.name=strings.clone("Local")
    append(&a.tabs,tab);a.active=len(a.tabs)-1
    app_sync_tab_view(a)
    session_touch(a)
    a.selected=false;a.dirty=true
    return true
}
app_reattach_local :: proc(a:^App,tab:^Tab) {
    local_session_close(&tab.pty,false)
    tab.terminal.persistent=nil
    clear(&tab.output);tab.output_offset=0;tab.output_eof=false
    delete(tab.pending_input);tab.pending_input=nil;tab.input_offset=0
    if local_session_start(&tab.pty,&tab.terminal,tab.session_id,a.cols,a.rows,"",tab.restore_path) {
        tab.exited=false
        delete(tab.input_error);tab.input_error=""
    } else {
        // Keep the last screen and allow another attach attempt with Enter.
        tab.pty.persistent=true;tab.terminal.persistent=&tab.pty
        delete(tab.input_error);tab.input_error=strings.clone(session_status_error())
    }
    a.dirty=true
}
app_close_tab :: proc(a:^App,index:int) {
    tab:=a.tabs[index]
    if !tab.files&&!tab.remote&&tab.pty.persistent&&!local_session_ended(&tab.pty) {
        path:=local_session_socket_path(tab.session_id)
        state:=Local_Session_Client{socket_path=path}
        client:=PTY{session_state=&state}
        if !local_session_control(&client,.End) {
            _,error:=os.stat(path,context.temp_allocator)
            if error!=.Not_Exist {
                delete(tab.input_error);tab.input_error=strings.clone("Could not end the local session. The tab was kept open; try again.")
                a.dirty=true;return
            }
        }
    }
    if !tab.files&&tab.remote {
        if tab.remote_end!=nil {return}
        // A configured device that has never connected owns no remote session.
        // Restored devices can still own one after a local reboot.
        if tab.started||tab.session_owned||tab.restore_path!="" {
            tab.remote_end=remote_session_end_start(tab.device)
            if tab.remote_end==nil {
                delete(tab.input_error);tab.input_error=strings.clone("Could not start ending the remote session. The tab was kept open.")
            } else {
                delete(tab.input_error);tab.input_error=strings.clone("Ending remote session…")
            }
            a.dirty=true;return
        }
    }
    app_finish_close_tab(a,index)
}
app_finish_close_tab :: proc(a:^App,index:int) {
    tab_rename_finish(a,true)
    a.last_tab_click=nil
    tab:=a.tabs[index]
    owner,source,_:=explorer_find_terminal(tab)
    return_to_source:=tab.files&&index==a.active&&owner==a
    tab_drag_cancel()
    app_dispose_tab(tab)
    ordered_remove(&a.tabs,index)
    session_touch(a)
    if index<a.active {a.active-=1}
    a.active=clamp(a.active,0,max(0,len(a.tabs)-1))
    if return_to_source {for other,i in a.tabs {if other==source {a.active=i;break}}}
    tab_groups_pack(a)
    app_sync_tab_view(a)
    a.selected=false;a.selecting=false;a.dirty=true
    if len(a.tabs)==0 {glfw.SetWindowShouldClose(a.renderer.window,true)}
}
app_send :: proc(a:^App,data:[]u8) {
    tab:=active_tab(a);if tab==nil {return}
    if tab.files {return}
    if !pty_alive(&tab.pty) {delete(tab.input_error);tab.input_error=strings.clone("The terminal is not running.");a.dirty=true;return}
    if len(data)==1&&(data[0]==3||data[0]==26) {
        delete(tab.pending_input);tab.pending_input=nil;tab.input_offset=0
        pty_cancel_input(&tab.pty)
    }
    if tab.input_offset==len(tab.pending_input)&&len(data)<=32768&&pty_write(&tab.pty,data) {
        delete(tab.pending_input);tab.pending_input=nil;tab.input_offset=0
    } else {
        if tab.input_offset>0&&tab.input_offset>=len(tab.pending_input)/2 {
            copy(tab.pending_input[:],tab.pending_input[tab.input_offset:]);resize(&tab.pending_input,len(tab.pending_input)-tab.input_offset);tab.input_offset=0
        }
        append(&tab.pending_input,..data)
        a.input_delay=0.001
    }
    delete(tab.input_error);tab.input_error=""
    tab.scroll=0;a.selected=false;a.blink=true;a.blink_tick=time.tick_now();a.dirty=true
}
app_send_text :: proc(a:^App,s:string) {app_send(a,transmute([]u8)s)}
app_paste :: proc(a:^App) {
    tab:=active_tab(a);if tab==nil {return}
    text:=glfw.GetClipboardString(a.renderer.window)
    if text=="" {return}
    bytes:=make([dynamic]u8,0,len(text)+16);defer delete(bytes)
    if tab.terminal.bracketed_paste {append(&bytes,"\x1b[200~")}
    for ch in transmute([]u8)text {if ch==0 || ch==27 {continue};if ch==10 {append(&bytes,13)} else {append(&bytes,ch)}}
    if tab.terminal.bracketed_paste {append(&bytes,"\x1b[201~")}
    if tab.input_offset==len(tab.pending_input)&&pty_alive(&tab.pty)&&len(bytes)>32768 {
        delete(tab.pending_input);tab.pending_input=bytes;bytes=nil;tab.input_offset=0
        a.input_delay=0.001;tab.scroll=0;a.selected=false;a.dirty=true
    } else {app_send(a,bytes[:])}
}
selection_bounds :: proc(a:^App)->(lo,hi:int) {
    last:=max(0,min(a.rows-1,a.selection_last_row))*a.cols+a.cols-1
    lo=clamp(a.anchor[1]*a.cols+a.anchor[0],0,last);hi=clamp(a.endpoint[1]*a.cols+a.endpoint[0],0,last)
    if lo>hi {lo,hi=hi,lo}
    return
}
app_copy :: proc(a:^App) {
    tab:=active_tab(a);if tab==nil||!a.selected {return}
    lo,hi:=selection_bounds(a)
    bytes:=make([dynamic]u8);defer delete(bytes)
    for y in lo/a.cols..=hi/a.cols {
        start:=0;end:=a.cols-1
        if y==lo/a.cols {start=lo%a.cols};if y==hi/a.cols {end=hi%a.cols}
        last:=len(bytes)
        for x in start..=end {
            cell:=terminal_cell(&tab.terminal,x,y,tab.scroll)
            if cell.width==0 {continue}
            ch:=cell.ch;if ch==0 {ch=' '}
            encoded,n:=utf8.encode_rune(ch);append(&bytes,..encoded[:n])
            for mark in cell.combining {if mark!=0 {mb,mn:=utf8.encode_rune(mark);append(&bytes,..mb[:mn])}}
            if ch!=' ' {last=len(bytes)}
        }
        resize(&bytes,last)
        if y<hi/a.cols {append(&bytes,'\n')}
    }
    glfw.SetClipboardString(a.renderer.window,strings.clone_to_cstring(string(bytes[:]),context.temp_allocator))
}
tab_number_key :: proc(key:c.int)->int {
    if key>=glfw.KEY_1&&key<=glfw.KEY_9 {return int(key-glfw.KEY_1)}
    if key>=glfw.KEY_KP_1&&key<=glfw.KEY_KP_9 {return int(key-glfw.KEY_KP_1)}
    return -1
}
key_callback :: proc "c" (w:glfw.WindowHandle,key,scan,action,mods:c.int) {
    context=runtime.default_context()
    if action==glfw.RELEASE {
        if a:=app_from(w);a!=nil {
            if view:=document_active_view(a);view!=nil {document_send_key(view,key,document_modifiers(a),action)}
        }
    }
    if action==glfw.RELEASE&&(key==glfw.KEY_LEFT_CONTROL||key==glfw.KEY_RIGHT_CONTROL) {
        if a:=app_from(w);a!=nil {a.zoom_wheel=0}
        return
    }
    if action!=glfw.PRESS&&action!=glfw.REPEAT {return}
    a:=app_from(w)
    if a.update_dialog {if action==glfw.PRESS&&key==glfw.KEY_ESCAPE {a.update_dialog=false;a.dirty=true};return}
    tab:=active_tab(a);if tab==nil {return}
    if tab_rename_key(a,key,mods) {return}
    if key==glfw.KEY_F2&&mods&(glfw.MOD_CONTROL|glfw.MOD_SHIFT|glfw.MOD_ALT|glfw.MOD_SUPER)==0&&!a.menu.open&&!a.picker.open {tab_rename_begin(a,tab);return}
    if key==glfw.KEY_ESCAPE&&tab_drag_active() {tab_drag_cancel();return}
    if key==glfw.KEY_ESCAPE&&a.group_hover!=0 {tab_group_close(a);return}
    if action==glfw.PRESS&&mods&glfw.MOD_CONTROL!=0&&mods&glfw.MOD_SHIFT!=0&&key==glfw.KEY_N {workspace_request_window(a);return}
    if document_zoom_key(a,key,mods) {return}
    if document_active_view(a)==nil&&app_zoom_key(a,key,mods) {return}
    if tab_menu_key(a,key,mods) {return}
    if a.picker.open {device_picker_key(a,key,mods);return}
    ctrl:=mods&glfw.MOD_CONTROL!=0;shift:=mods&glfw.MOD_SHIFT!=0;alt:=mods&glfw.MOD_ALT!=0
    if ctrl&&!shift&&!alt {
        index:=tab_number_key(key)
        if index>=0 {
            if action==glfw.PRESS&&index<len(a.tabs) {app_select_device(a,index)}
            return
        }
    }
    if explorer_handle_key(a,key,mods) {return}
    if ctrl&&shift {
        switch key {
        case glfw.KEY_T:if action==glfw.PRESS {device_picker_open(a)};return
        case glfw.KEY_HOME:tab.scroll=terminal_history_count(&tab.terminal);a.selected=false;a.dirty=true;return
        case glfw.KEY_END:tab.scroll=0;a.selected=false;a.dirty=true;return
        case glfw.KEY_K:
            if action==glfw.PRESS {terminal_clear_history(&tab.terminal);tab.scroll=0;a.selected=false;a.dirty=true}
            return
        case glfw.KEY_W:if action==glfw.PRESS {app_close_tab(a,a.active)};return
        case glfw.KEY_C:app_copy(a);return
        case glfw.KEY_V:app_paste(a);return
        case glfw.KEY_UP:tab.scroll=min(terminal_history_count(&tab.terminal),tab.scroll+1);a.selected=false;a.dirty=true;return
        case glfw.KEY_DOWN:tab.scroll=max(0,tab.scroll-1);a.selected=false;a.dirty=true;return
        case glfw.KEY_PAGE_UP:
            if action==glfw.PRESS&&a.active>0 {workspace_request_move(a,tab,a,a.active-1)};return
        case glfw.KEY_PAGE_DOWN:
            if action==glfw.PRESS&&a.active+1<len(a.tabs) {workspace_request_move(a,tab,a,a.active+2)};return
        }
    }
    if ctrl&&!alt&&(key==glfw.KEY_PAGE_UP||key==glfw.KEY_PAGE_DOWN) {
        if key==glfw.KEY_PAGE_UP {app_select_device(a,(a.active+len(a.tabs)-1)%len(a.tabs))}
        else {app_select_device(a,(a.active+1)%len(a.tabs))};return
    }
    if alt&&key>=glfw.KEY_1&&key<=glfw.KEY_9 {
        if i:=int(key-glfw.KEY_1);i<len(a.tabs) {app_select_device(a,i)};return
    }
    if ctrl&&key==glfw.KEY_TAB {
        if shift {app_select_device(a,(a.active+len(a.tabs)-1)%len(a.tabs))} else {app_select_device(a,(a.active+1)%len(a.tabs))}
        return
    }
    if tab.remote&&(!tab.started||tab.exited) {
        if key==glfw.KEY_ENTER||key==glfw.KEY_KP_ENTER {app_start_device(a,tab)}
        return
    }
    if !tab.remote&&tab.exited&&tab.pty.persistent {
        if key==glfw.KEY_ENTER||key==glfw.KEY_KP_ENTER {app_reattach_local(a,tab)}
        return
    }
    if shift&&(key==glfw.KEY_PAGE_UP||key==glfw.KEY_PAGE_DOWN) {
        delta:=a.rows-1;if key==glfw.KEY_PAGE_DOWN {delta= -delta}
        tab.scroll=clamp(tab.scroll+delta,0,terminal_history_count(&tab.terminal));a.selected=false;a.dirty=true;return
    }
    if shift&&key==glfw.KEY_INSERT {app_paste(a);return}
    if ctrl&&key==glfw.KEY_INSERT {app_copy(a);return}
    if ctrl&&key>=glfw.KEY_A&&key<=glfw.KEY_Z {bytes:=[1]u8{u8(key-glfw.KEY_A+1)};app_send(a,bytes[:]);return}
    if ctrl {
        switch key {
        case glfw.KEY_SPACE,glfw.KEY_2:app_send_text(a,"\x00");return
        case glfw.KEY_LEFT_BRACKET:app_send_text(a,"\x1b");return
        case glfw.KEY_BACKSLASH:app_send_text(a,"\x1c");return
        case glfw.KEY_RIGHT_BRACKET:app_send_text(a,"\x1d");return
        case glfw.KEY_6:app_send_text(a,"\x1e");return
        case glfw.KEY_MINUS:app_send_text(a,"\x1f");return
        }
    }
    sequence:=terminal_key_sequence(key,mods,tab.terminal.application_cursor)
    if sequence!="" {app_send_text(a,sequence)}
}
char_callback :: proc "c" (w:glfw.WindowHandle,ch:rune) {
    context=runtime.default_context();a:=app_from(w)
    if a.update_dialog {return}
    if a.tab_rename.tab!=nil {tab_rename_insert(a,string_from_rune(ch));return}
    if a.menu.open {return}
    if a.picker.open {device_picker_insert(a,string_from_rune(ch));return}
    if explorer_handle_char(a,ch) {return}
    tab:=active_tab(a)
    if tab==nil||(tab.remote&&(!tab.started||tab.exited)) {return}
    if glfw.GetKey(w,glfw.KEY_LEFT_ALT)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_ALT)==glfw.PRESS {app_send_text(a,"\x1b")}
    bytes,n:=utf8.encode_rune(ch);app_send(a,bytes[:n])
}
mouse_cell :: proc(a:^App,x,y:f64)->[2]int {
    row:=int((f32(y)*a.scale-a.origin_y)/a.cell_h)
    last:=clamp(a.selection_last_row,0,a.rows-1)
    if row>last {return {a.cols-1,last}}
    return {clamp(int((f32(x)*a.scale-a.origin_x)/a.cell_w),0,a.cols-1),clamp(row,0,last)}
}
Tab_Bar_Layout :: struct {
    first, visible, count: int,
    items: [MAX_TABS]int,
    groups: [MAX_TABS]u64,
    start, tab_width, new_x, navigation_x: f32,
    overflow: bool,
}
// Rendering and mouse input use the same logical coordinates, including DPI.
tab_bar_layout :: proc(a:^App)->Tab_Bar_Layout {
    width:=f32(a.renderer.width)/a.scale
    bar:=Tab_Bar_Layout{start=TAB_BAR_START}
    roots:=tab_group_children(a,0)
    bar.count=roots.count;bar.items=roots.items;bar.groups=roots.groups
    available:=max(1,width-bar.start-12-40-84)
    bar.visible=max(1,int(available/140))
    bar.overflow=bar.count>bar.visible
    if bar.overflow {
        available=max(1,available-64)
        bar.visible=max(1,int(available/140))
    }
    bar.visible=min(bar.visible,bar.count)
    bar.tab_width=min(f32(TAB_WIDTH),available/f32(max(1,bar.visible)))
    bar.first=clamp(a.header_scroll,0,max(0,bar.count-bar.visible))
    if bar.visible>0&&!tab_drag_scroll_override(a) {
        slot:=tab_bar_slot(a,bar,active_tab(a))
        if slot<bar.first {bar.first=slot}
        if slot>=bar.first+bar.visible {bar.first=slot-bar.visible+1}
    }
    a.header_scroll=bar.first
    bar.new_x=bar.start+f32(bar.visible)*bar.tab_width+4
    bar.navigation_x=bar.new_x+40
    return bar
}
tab_bar_hit :: proc(bar:Tab_Bar_Layout,x:f32)->int {
    if x<bar.start||x>=bar.start+f32(bar.visible)*bar.tab_width {return -1}
    return bar.items[bar.first+int((x-bar.start)/bar.tab_width)]
}
mouse_callback :: proc "c" (w:glfw.WindowHandle,button,action,mods:c.int) {
    context=runtime.default_context();a:=app_from(w)
    x,y:=glfw.GetCursorPos(w)
    if updater_mouse(a,button,action,f32(x),f32(y)) {return}
    if tab_rename_mouse(a,button,action,f32(x),f32(y)) {return}
    if button==glfw.MOUSE_BUTTON_LEFT&&action==glfw.RELEASE&&tab_drag_release(a,x,y) {return}
    if tab_menu_mouse(a,button,action,f32(x),f32(y)) {return}
    if a.picker.open {
        if action==glfw.PRESS&&button==glfw.MOUSE_BUTTON_LEFT {device_picker_click(a,f32(x),f32(y))}
        return
    }
    if button==glfw.MOUSE_BUTTON_LEFT&&action==glfw.RELEASE {a.selecting=false}
    if tab_group_mouse(a,button,action,f32(x),f32(y)) {return}
    if explorer_handle_mouse(a,button,action,f32(x),f32(y)) {return}
    if button==glfw.MOUSE_BUTTON_MIDDLE&&action==glfw.PRESS {
        if y<HEADER {
            index:=tab_bar_hit(tab_bar_layout(a),f32(x))
            if index>=0&&tab_root_group(a.tabs[index])==0 {app_close_tab(a,index)}
        } else {app_paste(a)}
        return
    }
    if button!=glfw.MOUSE_BUTTON_LEFT {return}
    if action==glfw.RELEASE {a.selecting=false;return}
    if y<HEADER {
        bar:=tab_bar_layout(a)
        if f32(x)>=bar.new_x&&f32(x)<bar.new_x+32&&y>=8&&y<40 {
            tab_menu_toggle(a)
        } else if bar.overflow&&f32(x)>=bar.navigation_x&&f32(x)<bar.navigation_x+64&&y>=10&&y<38 {
            if f32(x)<bar.navigation_x+32 {app_select_device(a,max(0,a.active-1))} else {app_select_device(a,min(len(a.tabs)-1,a.active+1))}
        } else if index:=tab_bar_hit(bar,f32(x));index>=0 {
            slot:=tab_bar_slot(a,bar,a.tabs[index])
            local_x:=f32(x)-bar.start-f32(slot-bar.first)*bar.tab_width
            group:=tab_root_group(a.tabs[index])!=0
            if !group&&local_x>=bar.tab_width-30&&y>=10&&y<38 {app_close_tab(a,index)}
            else {tab_click(a,index,x,y,group)}
        }
        return
    }
    tab:=active_tab(a);if tab==nil {return}
    a.selection_last_row=terminal_selection_last_row(&tab.terminal,tab.scroll)
    row:=int((f32(y)*a.scale-a.origin_y)/a.cell_h)
    if f32(y)*a.scale<a.origin_y||row>a.selection_last_row {
        a.selected=false;a.selecting=false;a.dirty=true;return
    }
    a.anchor=mouse_cell(a,x,y);a.endpoint=a.anchor;a.selected=true;a.selecting=true;a.dirty=true
}
app_hover_key :: proc(a:^App,x,y:f32)->u64 {
    if a.menu.open {return tab_menu_hover(a,x,y)}
    if a.picker.open {
        box:=device_picker_layout(a)
        if x>=box.x+16&&x<box.x+box.w-16&&y>=box.rows_y&&y<box.rows_y+f32(box.rows)*32 {
            return (u64(1)<<32)|u64(a.picker.scroll+int((y-box.rows_y)/32)+1)
        }
        return 0
    }
    if index:=tab_group_popup_hit(a,x,y);index>=0 {return (u64(9)<<32)|u64(index+1)}
    tab:=active_tab(a)
    if tab==nil {return 0}
    if y>=0&&y<HEADER {
        bar:=tab_bar_layout(a)
        if x>=bar.new_x&&x<bar.new_x+32&&y>=8&&y<40 {return u64(2)<<32}
        index:=tab_bar_hit(bar,x)
        if index>=0 {
            local_x:=x-bar.start-f32(tab_bar_slot(a,bar,a.tabs[index])-bar.first)*bar.tab_width
            close:u64
            if tab_root_group(a.tabs[index])==0&&local_x>=bar.tab_width-30 {close=1}
            return (u64(3)<<32)|(u64(index+1)<<1)|close
        }
    }
    if a.explorer_visible&&!tab.explorer.preview_open {
        return explorer_hover_key(a,x,y)
    }
    return 0
}
cursor_callback :: proc "c" (w:glfw.WindowHandle,x,y:f64) {
    context=runtime.default_context();a:=app_from(w)
    if a.update_dialog {a.dirty=true;return}
    tab_group_hover(a,f32(x),f32(y))
    if tab_drag_motion(a,x,y) {return}
    if y<0||y>=HEADER {a.tab_wheel=0}
    hover:=app_hover_key(a,f32(x),f32(y))
    if hover!=a.hover_key {a.hover_key=hover;a.dirty=true}
    if a.picker.open||a.menu.open {return}
    if explorer_handle_cursor(a,f32(x),f32(y)) {return}
    if a.selecting {
        endpoint:=mouse_cell(a,x,y)
        if endpoint!=a.endpoint {a.endpoint=endpoint;a.dirty=true}
    }
}
scroll_callback :: proc "c" (w:glfw.WindowHandle,x,y:f64) {
    context=runtime.default_context();a:=app_from(w);tab:=active_tab(a);if tab==nil {return}
    if a.update_dialog {return}
    ctrl:=glfw.GetKey(w,glfw.KEY_LEFT_CONTROL)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_CONTROL)==glfw.PRESS
    if document_input_scroll(a,x,y,ctrl) {return}
    if ctrl {
        a.zoom_wheel+=y
        steps:=int(a.zoom_wheel)
        if steps!=0 {a.zoom_wheel-=f64(steps);app_zoom(a,steps)}
        return
    }
    a.zoom_wheel=0
    if tab_group_scroll(a,int(math.round(y))) {return}
    if tab_menu_scroll(a,int(math.round(y))) {return}
    if a.picker.open {device_picker_scroll(a,int(math.round(y)));return}
    {
        _,mouse_y:=glfw.GetCursorPos(w)
        if mouse_y>=0&&mouse_y<HEADER {
            // Accumulate smooth trackpad deltas as well as wheel notches.
            delta:=y
            if abs(x)>abs(y) {delta=x}
            a.tab_wheel+=delta
            steps:=int(a.tab_wheel)
            if steps!=0 {
                a.tab_wheel-=f64(steps)
                next:=clamp(a.active-steps,0,len(a.tabs)-1)
                if next!=a.active {app_select_device(a,next)}
            }
            return
        }
    }
    a.tab_wheel=0
    if explorer_handle_scroll(a,int(math.round(y))) {return}
    tab.scroll=clamp(tab.scroll+int(math.round(y*3)),0,terminal_history_count(&tab.terminal));a.selected=false;a.dirty=true
}
refresh_callback :: proc "c" (w:glfw.WindowHandle) {context=runtime.default_context();app_from(w).dirty=true}
focus_callback :: proc "c" (w:glfw.WindowHandle,focused:c.int) {
    context=runtime.default_context();a:=app_from(w);a.focused=focused!=0;a.dirty=true
    if !a.focused {tab_rename_finish(a,true);a.menu.open=false;tab_group_close(a)}
    if a.focused {workspace_focused=a;if workspace_save_allowed {session_touch(a)}}
}

ui_rect :: proc(a:^App,x,y,w,h:f32,color:Color) {renderer_rect(&a.vertices,x*a.scale,y*a.scale,w*a.scale,h*a.scale,color)}
ui_text :: proc(a:^App,text:string,x,y,size:f32,color:Color) {renderer_text(&a.renderer,&a.vertices,text,x*a.scale,y*a.scale,size*a.scale,color)}
app_render :: proc(a:^App) {
    clear(&a.vertices)
    a.renderer.page_source=nil
    r:=&a.renderer;tab:=active_tab(a);if tab==nil {return}
    width:=f32(r.width)/a.scale;height:=f32(r.height)/a.scale
    ui_rect(a,0,0,width,height,BG)
    ui_rect(a,0,0,width,HEADER,PANEL)
    ui_rect(a,0,HEADER-1,width,1,LINE)
    bar:=tab_bar_layout(a)
    mouse_x,mouse_y:=glfw.GetCursorPos(r.window)
    hovered:= -1
    if mouse_y>=0&&mouse_y<HEADER {hovered=tab_bar_hit(bar,f32(mouse_x))}
    for slot:=bar.first;slot<bar.first+bar.visible;slot+=1 {
        i:=bar.items[slot];other:=a.tabs[i];x:=bar.start+f32(slot-bar.first)*bar.tab_width
        group_id:=bar.groups[slot];group:=group_id!=0
        selected:=i==a.active||(group&&tab_group_level(tab,group_id)>=0)
        if selected {ui_rect(a,x,0,bar.tab_width,HEADER-1,BG);ui_rect(a,x,HEADER-2,bar.tab_width,2,ACCENT)}
        else if i==hovered {ui_rect(a,x,0,bar.tab_width,HEADER-1,HOVER)}
        dot_color:=GREEN
        if group||other.files {dot_color=ACCENT}
        else if other.remote {dot_color=ACCENT;if !other.started||other.exited {dot_color=MUTED}}
        if group {
            ui_rect(a,x+10,18,9,9,dot_color);ui_rect(a,x+12,20,9,9,PANEL);ui_rect(a,x+12,20,9,1,dot_color);ui_rect(a,x+20,20,1,9,dot_color)
        } else {ui_rect(a,x+12,22,4,4,dot_color)}
        title_color:=SOFT;if selected||i==hovered {title_color=TEXT}
        if group {
            if !tab_rename_render_box(a,other,x,0,bar.tab_width,HEADER,group_id) {ui_fit_text(a,tab_group_name(other,group_id),x+25,16,14,bar.tab_width-65,title_color)}
            ui_text(a,fmt.tprintf("%d",tab_group_count(a,group_id)),x+bar.tab_width-29,17,12,MUTED)
        } else {
            if !tab_rename_render(a,other,x,bar.tab_width) {ui_fit_text(a,tab_title(other),x+25,16,14,bar.tab_width-57,title_color)}
            close_color:=MUTED
            if i==hovered&&f32(mouse_x)>=x+bar.tab_width-30 {close_color=TEXT}
            if selected||i==hovered {ui_text(a,"×",x+bar.tab_width-23,16,14,close_color)}
        }
        unread:=other.unread
        if group {for member in a.tabs {if tab_group_level(member,group_id)>=0&&member.unread {unread=true}}}
        if unread {ui_rect(a,x+13,34,3,3,GREEN)}
        ui_rect(a,x+bar.tab_width-1,12,1,24,LINE)
    }
    if bar.overflow {
        previous_color,next_color:=MUTED,MUTED
        if a.active>0 {previous_color=TEXT}
        if a.active<len(a.tabs)-1 {next_color=TEXT}
        ui_text(a,"‹",bar.navigation_x+10,14,18,previous_color)
        ui_text(a,"›",bar.navigation_x+42,14,18,next_color)
    }
    button_color:=PANEL
    button_text:=TEXT
    if a.menu.open||(f32(mouse_x)>=bar.new_x&&f32(mouse_x)<bar.new_x+32&&mouse_y>=8&&mouse_y<40) {button_color=LINE;button_text=ACCENT}
    ui_rect(a,bar.new_x,8,32,32,button_color)
    ui_text(a,"+",bar.new_x+10,14,20,button_text)
    tab_drag_render(a)
    if a.explorer_visible {
        if tab.explorer.preview_open {explorer_preview_render(a)} else {explorer_render(a)}
    } else {app_render_terminal(a)}
    // Surface actionable failures only; ordinary terminal use has no status bar.
    error_message:=a.session_error_seen
    if tab.input_error!="" {error_message=tab.input_error}
    if error:=terminal_history_error(&tab.terminal);error!="" {
        error_message=fmt.tprintf("Scrollback storage: %s — output paused",error)
    }
    if error_message!="" {
        x:=a.origin_x/a.scale
        available:=max(0,width-x-12)
        notice_width:=min(available,renderer_text_width(r,error_message,12*a.scale)/a.scale+24)
        ui_rect(a,x,HEADER+6,notice_width,28,PANEL)
        ui_rect(a,x,HEADER+6,2,28,Color{0.96,0.36,0.36,1})
        ui_fit_text(a,error_message,x+10,HEADER+14,12,notice_width-20,Color{0.96,0.36,0.36,1})
    }
    tab_group_render(a)
    if a.picker.open {device_picker_render(a)}
    tab_menu_render(a)
    updater_draw(a)
}

app_render_terminal :: proc(a:^App) {
    r:=&a.renderer;tab:=active_tab(a);if tab==nil {return}
    lo,hi:=selection_bounds(a)
    t:=&tab.terminal
    terminal_history_prepare(t,tab.scroll)
    blank:=terminal_default_style()
    for y in 0..<a.rows {
        row:=terminal_row(t,y,tab.scroll)
        py:=a.origin_y+f32(y)*a.cell_h
        for x in 0..<a.cols {
            cell:=blank
            if x<len(row) {cell=row[x]}
            px:=a.origin_x+f32(x)*a.cell_w
            fg,bg:=rgb(cell.fg),rgb(cell.bg)
            // Saved scrollback retains the previous theme's default colors.
            if cell.bg==0x0b0d12 {bg=BG}
            if cell.fg==0xd7dce5 {fg=TEXT}
            if cell.inverse {fg,bg=bg,fg}
            if a.selected&&y*a.cols+x>=lo&&y*a.cols+x<=hi {bg=SELECTION}
            if bg!=BG {renderer_rect(&a.vertices,px,py,a.cell_w,a.cell_h,bg)}
            if cell.width==0 {continue}
            ch:=cell.ch
            if ch==0||ch==' ' {
                if cell.underline {renderer_rect(&a.vertices,px,py+a.cell_h-3*a.scale,a.cell_w,a.scale,fg)}
                continue
            }
            kind:Font_Kind=.Terminal
            if cell.bold&&cell.italic {kind=.Terminal_Bold_Italic}
            else if cell.bold {kind=.Terminal_Bold}
            else if cell.italic {kind=.Terminal_Italic}
            font:=&r.fonts[int(kind)*len(FONT_SIZES)+a.font_index]
            glyph:=renderer_glyph(r,font,ch)
            // The face owns its fixed advance. Preserve its hinted bitmap at
            // 1:1 physical pixels, including native bold and italic shapes.
            span:=a.cell_w*f32(max(cell.width,1))
            glyph_origin:=math.round(px+(span-glyph.advance)/2)
            baseline:=py+math.floor((a.cell_h-font.ascent-font.descent)/2)+font.ascent
            if glyph.width>0&&glyph.height>0 {
                gx:=glyph_origin+f32(glyph.left)
                gy:=baseline-f32(glyph.top)
                x0,y0,x1,y1:=gx,max(gy,a.origin_y),gx+f32(glyph.width),min(gy+f32(glyph.height),a.origin_y+f32(a.rows)*a.cell_h)
                if y1>y0 {
                    u0,v0:=f32(glyph.x)/ATLAS_SIZE,(f32(glyph.y)+y0-gy)/f32(r.atlas_height)
                    u1,v1:=f32(glyph.x+glyph.width)/ATLAS_SIZE,(f32(glyph.y)+y1-gy)/f32(r.atlas_height)
                    renderer_quad(&a.vertices,x0,y0,x1,y1,u0,v0,u1,v1,fg)
                }
            }
            for mark in cell.combining {
                if mark==0 {continue}
                mg:=renderer_glyph(r,font,mark)
                mx:=glyph_origin+glyph.advance+f32(mg.left)
                my:=baseline-f32(mg.top)
                if mg.width>0&&mg.height>0 {renderer_quad(&a.vertices,mx,my,mx+f32(mg.width),my+f32(mg.height),f32(mg.x)/ATLAS_SIZE,f32(mg.y)/f32(r.atlas_height),f32(mg.x+mg.width)/ATLAS_SIZE,f32(mg.y+mg.height)/f32(r.atlas_height),fg)}
            }
            if cell.underline {renderer_rect(&a.vertices,px,py+a.cell_h-3*a.scale,a.cell_w,a.scale,fg)}
        }
    }
    if tab.scroll==0&&t.cursor_visible {
        px:=a.origin_x+f32(t.cursor_x)*a.cell_w;py:=a.origin_y+f32(t.cursor_y)*a.cell_h
        if a.focused&&!a.explorer_focus {
            if a.blink {renderer_rect(&a.vertices,px,py+2*a.scale,2*a.scale,a.cell_h-4*a.scale,ACCENT)}
        } else {
            renderer_rect(&a.vertices,px,py+2*a.scale,a.cell_w,a.scale,MUTED)
            renderer_rect(&a.vertices,px,py+a.cell_h-2*a.scale,a.cell_w,a.scale,MUTED)
            renderer_rect(&a.vertices,px,py+2*a.scale,a.scale,a.cell_h-4*a.scale,MUTED)
            renderer_rect(&a.vertices,px+a.cell_w-a.scale,py+2*a.scale,a.scale,a.cell_h-4*a.scale,MUTED)
        }
    }
    count:=terminal_history_count(t)
    if count>0 {
        track:=f32(a.rows)*a.cell_h;thumb:=max(20*a.scale,track*f32(a.rows)/f32(count+a.rows))
        position:=(track-thumb)*(1-f32(tab.scroll)/f32(count))
        renderer_rect(&a.vertices,f32(r.width)-6*a.scale,a.origin_y+position,2*a.scale,thumb,LINE)
    }
}

main :: proc() {
    args:=os.args
    if len(args)>1&&args[1]=="--session-host" {os.exit(local_session_host(args[2:]))}
    if len(args)>1&&args[1]=="--persistence-check" {
        if local_session_selfcheck() {fmt.println("Persistent local session detach/reattach: OK");return}
        fmt.eprintln("Persistent local session check failed");os.exit(1)
    }
    command:string
    ssh_target:string
    capture:string
    exit_after:f64
    capture_after:f64=0.7
    self_check:=false
    for i:=1;i<len(args);i+=1 {
        switch args[i] {
        case "--help","-h":
            fmt.println("Terminal+ — Odin + Vulkan + GLFW\nUsage: terminal+ [-e 'bash command'] [--ssh user@host[:port]] [--wayland | --x11] [--startup-profile]\n       terminal+ --self-check\n       terminal+ --capture image.png [--capture-after seconds] [--exit-after seconds]\n\n+ menu: files, new terminals/windows, remote machines. Ctrl+Shift+T: SSH picker. Ctrl+Shift+W: close device.\nCtrl+Tab: next device. Ctrl+1…9 / Alt+1…9: select device. Enter: reconnect SSH.\nDrag tabs to reorder, detach, or move between windows. Ctrl+Shift+N: new window.\nMouse wheel over the top bar: previous/next device.\n+ menu > Files / Ctrl+B: toggle explorer. Ctrl+Shift+E: focus. Ctrl+Shift+F: search files.\nExplorer: Ctrl+L path, Ctrl+F search, Ctrl+H hidden, F5 refresh, Enter open.\nCtrl+Shift+C/V: copy/paste. Shift+PageUp/Down: history. Ctrl+Shift+Home/End: first/last.\nCtrl+Left/Right: word movement. Ctrl+Backspace/Delete: delete words.\nclear / Ctrl+Shift+K: clear history. Ctrl+wheel or Ctrl +/-/0: font size. Tabs and scrollback restore on restart.")
            return
        case "--version":fmt.println("Terminal+",UPDATER_VERSION);return
        case "--check-updates":updater_cli_check();return
        case "--self-check":self_check=true
        case "--startup-profile":startup_profile=true
        case "--wayland":renderer_platform=glfw.PLATFORM_WAYLAND
        case "--x11":renderer_platform=glfw.PLATFORM_X11
        case "-e","--command":if i+1<len(args) {i+=1;command=args[i]} else {fmt.eprintln("-e requires a command");os.exit(1)}
        case "--ssh":if i+1<len(args) {i+=1;ssh_target=args[i]} else {fmt.eprintln("--ssh requires a destination");os.exit(1)}
        case "--capture":if i+1<len(args) {i+=1;capture=args[i]}
        case "--exit-after":if i+1<len(args) {i+=1;exit_after,_=strconv.parse_f64(args[i])}
        case "--capture-after":if i+1<len(args) {i+=1;capture_after,_=strconv.parse_f64(args[i])}
        case:fmt.eprintf("Unknown argument: %s\n",args[i]);os.exit(1)
        }
    }
    if ssh_target!="" {_,_,error:=device_target_parse(ssh_target);if error!="" {fmt.eprintln(error);os.exit(1)}}
    if self_check {
        if terminal_selfcheck()&&pty_selfcheck() {fmt.println("Terminal parser and real Bash PTY: OK");return}
        fmt.eprintln("Self-check failed");os.exit(1)
    }
    instance:=app_instance_init(command,ssh_target)
    if instance==.Forwarded {return}
    if instance==.Failed {fmt.eprintln(session_status_error());return}
    defer {
        app_instance_stop()
        lifecycle_destroy()
        workspace_destroy_all()
        session_writer_destroy()
        explorer_backend_destroy()
        app_instance_destroy()
    }
    if !explorer_backend_init() {fmt.eprintln("Could not create the private SSH runtime directory.");return}
    if !session_writer_init() {fmt.eprintln("Could not start saved-session writer.");return}
    if !workspace_restore_session(command) {fmt.eprintln("Could not restore terminal windows. Start in a desktop session with a Vulkan-capable GPU.");return}
    if !lifecycle_init() {fmt.eprintln("Could not initialize graceful shutdown.");return}
    app_instance_ready()
    primary:=workspace_focused
    updater_init(primary)
    defer updater_destroy(primary)
    primary.capture=capture;primary.capture_after=capture_after
    if ssh_target!="" {
        target,port,_:=device_target_parse(ssh_target)
        app_open_device(primary,Device_Profile{name=ssh_target,target=target,port=port},false)
    }
    fmt.printf("Terminal+ • %s • %s\n",renderer_backend_name(),primary.renderer.device_name)
    for a in workspace_windows {glfw.ShowWindow(a.renderer.window)}
    if workspace_focused!=nil {glfw.FocusWindow(workspace_focused.renderer.window)}
    started:=time.tick_now()
    for len(workspace_windows)>0&&!lifecycle_should_close() {
        glfw.PollEvents()
        app_instance_process()
        tab_drag_poll()
        workspace_process_actions()
        if !workspace_prune_windows() {break}
        elapsed:=time.duration_seconds(time.tick_diff(started,time.tick_now()))
        if exit_after>0&&elapsed>=exit_after {break}
        updater_poll(workspace_focused)
        if updater_restart_requested {break}
        wait:=min(tab_drag_wait_delay(),updater_wait_delay())
        for a in workspace_windows {
            wait=min(wait,workspace_step_window(a,elapsed,capture!=""))
            if a.session_dirty&&a.session_save_allowed {workspace_dirty=true}
            free_all(context.temp_allocator)
        }
        // A shell may have exited while processing output. Remove its empty
        // window before serializing the new window/tab ownership.
        if !workspace_prune_windows() {break}
        if workspace_dirty&&len(workspace_windows)>0 {session_schedule(workspace_windows[0])}
        if exit_after>0 {wait=min(wait,max(0.001,exit_after-elapsed))}
        free_all(context.temp_allocator)
        if wait<60 {glfw.WaitEventsTimeout(max(0.001,wait))} else {glfw.WaitEvents()}
    }
    app_instance_stop()
    for a in workspace_windows {tab_rename_finish(a,true)}
    if workspace_save_allowed&&len(workspace_windows)>0 {session_schedule(workspace_windows[0])}
}

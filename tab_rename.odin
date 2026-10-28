package main

import "core:c"
import "core:strings"
import "core:unicode/utf8"
import glfw "vendor:glfw"

Tab_Rename :: struct {
    tab: ^Tab,
    group_id: u64,
    input: [512]u8,
    used, cursor, anchor: int,
    selecting, select_all: bool,
}

tab_rename_begin :: proc(a:^App,tab:^Tab) {
    tab_rename_finish(a,true)
    tab_drag_cancel();a.last_tab_click=nil
    a.tab_rename=Tab_Rename{tab=tab}
    tab_rename_insert(a,tab_title(tab))
    if tab.group_id!=0 {
        tab_group_open_to(a,tab.group_id)
        depth:=len(a.group_menus)-1;box:=tab_group_popup(a,depth)
        index:=tab_drag_index(a,tab)
        for row in 0..<box.count {
            if box.items[row]!=index||box.groups[row]!=0 {continue}
            if row<a.group_menus[depth].scroll {a.group_menus[depth].scroll=row}
            else if row>=a.group_menus[depth].scroll+box.rows {a.group_menus[depth].scroll=row-box.rows+1}
            break
        }
    }
    a.tab_rename.select_all=true
    a.selected=false;a.selecting=false;a.dirty=true
}
tab_rename_begin_group :: proc(a:^App,tab:^Tab,id:u64=0) {
    tab_rename_finish(a,true)
    tab_drag_cancel();a.last_tab_click=nil
    target:=id;if target==0 {target=tab_root_group(tab)}
    a.tab_rename=Tab_Rename{tab=tab,group_id=target}
    tab_rename_insert(a,tab_group_name(tab,target))
    a.tab_rename.select_all=true;tab_group_open_to(a,target)
    a.selected=false;a.selecting=false;a.dirty=true
}

tab_rename_finish :: proc(a:^App,commit:bool) {
    if a.tab_rename.tab==nil {return}
    edit:=a.tab_rename
    a.tab_rename={};a.last_tab_click=nil;a.dirty=true
    if !commit {return}
    if edit.group_id!=0 {
        label:=strings.trim_space(string(edit.input[:edit.used]))
        tab_group_rename(a,edit.group_id,label)
        session_touch(a)
        return
    }
    // A closing or transferred tab must not leave a dangling editor target.
    for tab in a.tabs {
        if tab!=edit.tab {continue}
        label:=strings.trim_space(string(edit.input[:edit.used]))
        if label==tab_title(tab) {return}
        delete(tab.label);tab.label=strings.clone(label)
        session_touch(a)
        return
    }
}

tab_rename_insert :: proc(a:^App,text:string) {
    e:=&a.tab_rename
    if e.tab==nil {return}
    first,last:=text_edit_selection(e.input[:e.used],e.cursor,e.anchor,e.selecting,e.select_all)
    if last>first {e.used=text_edit_remove(e.input[:e.used],first,last);e.cursor=first}
    e.selecting=false;e.select_all=false
    for ch in text {
        if ch<32||ch==127 {continue}
        bytes,n:=utf8.encode_rune(ch)
        if e.used+n>len(e.input) {break}
        for i:=e.used-1;i>=e.cursor;i-=1 {e.input[i+n]=e.input[i]}
        copy(e.input[e.cursor:e.cursor+n],bytes[:n]);e.cursor+=n;e.used+=n
    }
    a.dirty=true
}

tab_rename_key :: proc(a:^App,key,mods:c.int)->bool {
    e:=&a.tab_rename
    if e.tab==nil {return false}
    switch key {
    case glfw.KEY_ESCAPE:tab_rename_finish(a,false);return true
    case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:tab_rename_finish(a,true);return true
    }
    if mods&glfw.MOD_CONTROL!=0&&key==glfw.KEY_V {tab_rename_insert(a,glfw.GetClipboardString(a.renderer.window));return true}
    handled,first,last:=text_edit_key(a,e.input[:e.used],&e.cursor,&e.anchor,&e.selecting,&e.select_all,key,mods)
    if handled {
        if last>first {e.used=text_edit_remove(e.input[:e.used],first,last)}
        a.dirty=true
    }
    // While editing, text and shortcuts belong to the name, not the PTY.
    return true
}

tab_rename_mouse :: proc(a:^App,button,action:c.int,x,y:f32)->bool {
    if a.tab_rename.tab==nil {return false}
    if action!=glfw.PRESS {return true}
    bar:=tab_bar_layout(a)
    box,_,item,group:=tab_group_hit(a,x,y)
    if box.valid&&item>=0&&button==glfw.MOUSE_BUTTON_LEFT&&x<box.x+box.w-29 {
        if (group!=0&&group==a.tab_rename.group_id)||(group==0&&a.tab_rename.group_id==0&&a.tabs[item]==a.tab_rename.tab) {return true}
    }
    index:=tab_bar_hit(bar,x)
    if button==glfw.MOUSE_BUTTON_LEFT&&y>=9&&y<39&&index>=0&&((a.tab_rename.group_id!=0&&tab_root_group(a.tabs[index])==a.tab_rename.group_id)||(a.tabs[index]==a.tab_rename.tab&&tab_root_group(a.tabs[index])==0)) {
        left:=bar.start+f32(tab_bar_slot(a,bar,a.tabs[index])-bar.first)*bar.tab_width
        if x>=left+20&&x<left+bar.tab_width-29 {return true}
    }
    tab_rename_finish(a,true)
    return false
}

tab_rename_render :: proc(a:^App,tab:^Tab,x,width:f32)->bool {
    return tab_rename_render_box(a,tab,x,0,width,HEADER,0)
}
tab_rename_render_box :: proc(a:^App,tab:^Tab,x,y,width,height:f32,group_id:u64)->bool {
    e:=&a.tab_rename
    if e.group_id!=group_id||e.tab==nil {return false}
    if group_id==0&&e.tab!=tab {return false}
    available:=max(1,width-57)
    top:=y+max(1,(height-30)/2)
    ui_rect(a,x+20,top,width-49,30,ACCENT)
    ui_rect(a,x+21,top+1,width-51,28,BG)
    start:=explorer_input_start(a,e.input[:e.used],e.cursor,14,available)
    text_edit_selection_render(a,e.input[:e.used],start,e.cursor,e.anchor,e.selecting,e.select_all,x+25,top+3,14,available,24)
    ui_fit_text(a,string(e.input[start:e.used]),x+25,top+7,14,available,TEXT)
    caret:=renderer_text_width(&a.renderer,string(e.input[start:e.cursor]),14*a.scale)/a.scale
    ui_rect(a,x+25+min(caret,available),top+4,1,22,TEXT)
    return true
}

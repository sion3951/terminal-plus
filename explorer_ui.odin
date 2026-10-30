package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import glfw "vendor:glfw"

Explorer_State :: struct {
    browser: File_Browser,
    ready, waiting, loaded, show_hidden: bool,
    listing, preview: File_Result,
    error, home, requested_directory: string,
    scroll, selected: int,
    input: [4096]u8,
    used, cursor: int,
    input_anchor: int,
    input_selecting: bool,
    editing, select_all, preview_open, binary: bool,
    preview_scroll: int,
    document: ^Document_View,
    lines: [dynamic]int,
    last_click: time.Tick,
    last_row: int,
    search: [dynamic]u8,
    search_cursor: int,
    search_anchor: int,
    search_selecting: bool,
    search_editing, search_select_all, search_dirty, page_pending, open_pending, select_first: bool,
    search_changed: time.Tick,
    requested_offset: int,
    requested_query: string,
    requested_hidden: bool,
}
Preview_Layout :: struct {x,y,w,h:f32,rows:int}

explorer_panel_width :: proc(a:^App)->f32 {
    if !a.explorer_visible {return 0}
    return f32(a.renderer.width)/a.scale
}
explorer_preview_layout :: proc(a:^App)->Preview_Layout {
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    box:=Preview_Layout{x=0,y=HEADER,w=width,h=height-HEADER}
    box.rows=max(1,int((box.h-112)/22))
    return box
}
explorer_state_destroy :: proc(e:^Explorer_State) {
    document_view_destroy(e.document)
    if e.ready {explorer_browser_destroy(&e.browser)}
    explorer_result_destroy(&e.listing);explorer_result_destroy(&e.preview)
    delete(e.error);delete(e.home);delete(e.lines);delete(e.search);delete(e.requested_query);delete(e.requested_directory)
    e^={}
}
explorer_set_error :: proc(e:^Explorer_State,text:string) {delete(e.error);e.error=strings.clone(text)}
explorer_path_text :: proc(e:^Explorer_State,path:string) {
    e.used=copy(e.input[:],transmute([]u8)path)
    e.cursor=e.used;e.editing=false;e.select_all=false;e.input_selecting=false
}
explorer_ensure :: proc(a:^App,tab:^Tab) {
    e:=&tab.explorer
    if !e.ready {
        if tab.remote&&!explorer_remote_ready(tab.device) {return}
        e.ready=explorer_browser_init(&e.browser,tab.remote,tab.device)
        e.selected= -1;e.last_row= -1
        if !e.ready {explorer_set_error(e,"Could not start file browser.");return}
    }
    if tab.document_path!="" {
        if !e.loaded {
            if tab.remote&&!explorer_remote_ready(tab.device) {return}
            e.loaded=true
            explorer_open_preview(a,tab,tab.document_path)
        }
        return
    }
    if !e.loaded&&!e.waiting {
        if tab.remote&&!explorer_remote_ready(tab.device) {return}
        e.waiting=true;explorer_set_error(e,"")
        delete(e.requested_directory);e.requested_directory=strings.clone(tab.restore_path)
        explorer_request(&e.browser,tab.restore_path,.List)
    }
}
explorer_page_matches :: proc(e:^Explorer_State)->bool {
    return e.listing.query==string(e.search[:])&&e.listing.show_hidden==e.show_hidden
}
explorer_count :: proc(e:^Explorer_State)->int {
    // The listing is the displayed snapshot. A pending filter must not blank it.
    if !e.loaded {return 0}
    return e.listing.matched_entries
}
explorer_page_entry :: proc(e:^Explorer_State,row:int)->^File_Entry {
    if !e.loaded {return nil}
    index:=row-e.listing.page_offset
    if index<0||index>=len(e.listing.entries) {return nil}
    return &e.listing.entries[index]
}
explorer_query_page :: proc(a:^App,tab:^Tab,offset:int) {
    e:=&tab.explorer
    if !e.ready||!e.loaded||e.listing.path=="" {return}
    query:=string(e.search[:])
    if e.page_pending&&e.requested_offset==offset&&e.requested_query==query&&e.requested_hidden==e.show_hidden {return}
    delete(e.requested_query);e.requested_query=strings.clone(query)
    e.requested_offset=offset;e.requested_hidden=e.show_hidden;e.page_pending=true;e.waiting=true;e.search_dirty=false
    box:=explorer_layout(a)
    explorer_query(&e.browser,query,e.show_hidden,offset,max(512,box.rows*box.columns+256))
    a.dirty=true
}
explorer_search_changed :: proc(a:^App) {
    e:=&active_tab(a).explorer
    e.search_dirty=true;e.search_changed=time.tick_now();e.last_row= -1;e.open_pending=false
    explorer_set_error(e,"");a.dirty=true
}
explorer_toggle_hidden :: proc(a:^App) {
    tab:=active_tab(a);e:=&tab.explorer
    e.show_hidden= !e.show_hidden
    explorer_search_changed(a)
    // Button presses need no typing debounce. Keep the displayed page intact.
    if e.loaded {explorer_query_page(a,tab,0)}
}
explorer_search_delay :: proc(a:^App)->f64 {
    tab:=active_tab(a)
    if tab==nil||!tab.explorer.search_dirty||!tab.explorer.loaded {return 60}
    return max(0.001,0.04-time.duration_seconds(time.tick_diff(tab.explorer.search_changed,time.tick_now())))
}
explorer_update :: proc(a:^App) {
    tab:=active_tab(a)
    if a.explorer_visible&&tab!=nil {explorer_ensure(a,tab)}
    for other in a.tabs {
        e:=&other.explorer
        if !e.ready {continue}
        result:File_Result
        if explorer_take(&e.browser,&result) {
            if result.kind==.Page&&(result.query!=string(e.search[:])||result.show_hidden!=e.show_hidden) {
                explorer_result_destroy(&result)
                continue
            }
            e.waiting=false;e.page_pending=false
            if result.kind==.List||result.kind==.Page {
                navigation:=result.kind==.List
                if navigation {e.loaded=true}
                if result.error!="" {explorer_set_error(e,result.error);explorer_result_destroy(&result)}
                else {
                    explorer_set_error(e,"")
                    filter_changed:=result.query!=e.listing.query||result.show_hidden!=e.listing.show_hidden
                    explorer_result_destroy(&e.listing);e.listing=result
                    if filter_changed {
                        e.scroll=0;e.selected= -1;e.last_row= -1;e.open_pending=false
                    }
                    if e.select_first {e.selected= -1;if result.matched_entries>0 {e.selected=0};e.select_first=false}
                    if navigation {
                        explorer_path_text(e,e.listing.path);e.scroll=0;e.selected= -1
                        if e.home=="" {
                            if other.remote&&e.requested_directory=="" {e.home=strings.clone(e.listing.path)}
                            else if !other.remote {e.home=strings.clone(os.get_env("HOME",context.temp_allocator))}
                        }
                        delete(other.restore_path);other.restore_path=strings.clone(e.listing.path)
                        if a.session_save_allowed {a.session_dirty=true}
                        if !explorer_page_matches(e) {e.search_dirty=true;e.search_changed={}}
                    }
                }
            } else {
                if e.document!=nil&&e.document.source_published {explorer_result_destroy(&result);continue}
                explorer_result_destroy(&e.preview);e.preview=result
                clear(&e.lines);e.preview_scroll=0;e.binary=false
                append(&e.lines,0)
                for b,i in result.preview {
                    if b==0||(b<32&&b!=9&&b!=10&&b!=13&&b!=27) {e.binary=true}
                    if b==10&&i+1<len(result.preview) {append(&e.lines,i+1)}
                }
            }
            if other==tab {a.dirty=true}
        }
        if other!=tab||!a.explorer_visible||!e.loaded||e.preview_open {continue}
        if e.search_dirty {
            if time.duration_seconds(time.tick_diff(e.search_changed,time.tick_now()))>=0.04 {explorer_query_page(a,other,0)}
            continue
        }
        if !explorer_page_matches(e) {
            if !e.page_pending&&e.error=="" {explorer_query_page(a,other,0)}
            continue
        }
        count:=explorer_count(e);box:=explorer_layout(a)
        e.scroll=explorer_grid_scroll(box,e.scroll,count)
        visible:=box.rows*box.columns
        end:=e.listing.page_offset+len(e.listing.entries)
        missing:=e.scroll<e.listing.page_offset||e.scroll+min(visible,count-e.scroll)>end
        prefetch:=e.scroll+visible+64>end&&end<count
        if (missing||prefetch)&&e.error=="" {explorer_query_page(a,other,max(0,e.scroll-64))}
        if e.open_pending&&explorer_page_entry(e,e.selected)!=nil {e.open_pending=false;explorer_open_entry(a,other,e.selected)}
    }
}
explorer_navigate :: proc(a:^App,tab:^Tab,path:string) {
    e:=&tab.explorer
    explorer_ensure(a,tab)
    if !e.ready {return}
    if tab.remote&&!explorer_remote_ready(tab.device) {explorer_set_error(e,"Finish SSH login, then refresh files.");a.dirty=true;return}
    target:=path
    if path=="~" {target=e.home}
    else if strings.has_prefix(path,"~/")&&e.home!="" {target=fmt.tprintf("%s/%s",e.home,path[2:])}
    else if path!=""&&!strings.has_prefix(path,"/")&&e.listing.path!="" {target=fmt.tprintf("%s/%s",e.listing.path,path)}
    e.waiting=true;e.loaded=false;e.page_pending=false;e.search_dirty=false;e.open_pending=false
    e.selected= -1;e.scroll=0;e.last_row= -1
    clear(&e.search);e.search_cursor=0;e.search_editing=false;e.search_select_all=false
    e.editing=false;e.select_all=false;e.preview_open=false
    explorer_set_error(e,"")
    delete(e.requested_directory);e.requested_directory=strings.clone(target)
    explorer_request(&e.browser,target,.List);session_touch(a);a.dirty=true
}
explorer_entry_path :: proc(e:^Explorer_State,entry:File_Entry)->string {
    if e.listing.path=="/" {return fmt.tprintf("/%s",entry.name)}
    return fmt.tprintf("%s/%s",e.listing.path,entry.name)
}
explorer_open_entry :: proc(a:^App,tab:^Tab,index:int) {
    e:=&tab.explorer
    if index<0||index>=explorer_count(e) {return}
    pointer:=explorer_page_entry(e,index)
    if pointer==nil {
        if explorer_page_matches(e) {e.open_pending=true;explorer_query_page(a,tab,(index/256)*256)}
        return
    }
    entry:=pointer^;path:=explorer_entry_path(e,entry)
    if entry.directory {explorer_navigate(a,tab,path)}
    else if media_kind(path)!=.None {media_view_open(a,tab,path)}
    else if document_kind(path)!=.None {document_open_tab(a,tab,path)}
    else {explorer_open_preview(a,tab,path)}
}
explorer_open_preview :: proc(a:^App,tab:^Tab,path:string) {
    e:=&tab.explorer
    if tab.remote&&!explorer_remote_ready(tab.device) {explorer_set_error(e,"Reconnect SSH before opening a file.");a.dirty=true;return}
    explorer_result_destroy(&e.preview)
    e.preview_open=true;e.preview_scroll=0;e.waiting=true
    document_view_destroy(e.document);e.document=nil
    if document_kind(path)!=.None {e.document=document_view_open(path,tab.remote,tab.device)}
    explorer_request(&e.browser,path,.Preview);a.dirty=true
}
explorer_close_preview :: proc(a:^App) {
    tab:=active_tab(a)
    if tab.document_path!="" {app_close_tab(a,a.active);return}
    tab.explorer.preview_open=false;a.dirty=true
}
explorer_copy_path :: proc(a:^App,tab:^Tab) {
    e:=&tab.explorer;path:=e.listing.path
    if e.selected>=0 {
        entry:=explorer_page_entry(e,e.selected)
        if entry==nil {explorer_set_error(e,"The selected item is loading.");a.dirty=true;return}
        path=explorer_entry_path(e,entry^)
    }
    glfw.SetClipboardString(a.renderer.window,strings.clone_to_cstring(path,context.temp_allocator))
}
explorer_quote :: proc(path:string)->string {
    escaped,_:=strings.replace_all(path,"'","'\\''",context.temp_allocator)
    return fmt.tprintf("'%s'",escaped)
}
explorer_insert_cd :: proc(a:^App,tab:^Tab) {
    e:=&tab.explorer
    owner,source,_:=explorer_find_terminal(tab)
    if source!=nil&&source.terminal.alternate {explorer_set_error(e,"Return to the shell before inserting a command.");a.dirty=true;return}
    if e.listing.path=="" {return}
    for ch in e.listing.path {
        if ch<32||ch==127 {explorer_set_error(e,"This path contains controls; use Copy path.");a.dirty=true;return}
    }
    owner=explorer_return_terminal(a)
    if owner!=nil {app_send_text(owner,fmt.tprintf("cd -- %s",explorer_quote(e.listing.path)))}
    e.editing=false
}
explorer_home :: proc(tab:^Tab)->string {
    if tab.remote {return ""}
    return os.get_env("HOME",context.temp_allocator)
}
explorer_input_insert :: proc(a:^App,text:string) {
    tab:=active_tab(a);if tab==nil {return};e:=&tab.explorer
    first,last:=text_edit_selection(e.input[:e.used],e.cursor,e.input_anchor,e.input_selecting,e.select_all)
    if last>first {e.used=text_edit_remove(e.input[:e.used],first,last);e.cursor=first}
    e.select_all=false;e.input_selecting=false
    for ch in text {
        if ch<32||ch==127 {continue}
        b,n:=utf8.encode_rune(ch)
        if e.used+n>len(e.input) {break}
        for i:=e.used-1;i>=e.cursor;i-=1 {e.input[i+n]=e.input[i]}
        copy(e.input[e.cursor:e.cursor+n],b[:n]);e.cursor+=n;e.used+=n
    }
    a.dirty=true
}
explorer_search_insert :: proc(a:^App,text:string) {
    e:=&active_tab(a).explorer
    first,last:=text_edit_selection(e.search[:],e.search_cursor,e.search_anchor,e.search_selecting,e.search_select_all)
    if last>first {used:=text_edit_remove(e.search[:],first,last);resize(&e.search,used);e.search_cursor=first}
    e.search_select_all=false;e.search_selecting=false
    incoming:=make([dynamic]u8,context.temp_allocator)
    remaining:=65536-len(e.search)
    for ch in text {
        if ch<32||ch==127 {continue}
        bytes,n:=utf8.encode_rune(ch)
        if len(incoming)+n>remaining {break}
        append(&incoming,..bytes[:n])
    }
    used,n:=len(e.search),len(incoming)
    if n>0 {
        resize(&e.search,used+n)
        for i:=used-1;i>=e.search_cursor;i-=1 {e.search[i+n]=e.search[i]}
        copy(e.search[e.search_cursor:e.search_cursor+n],incoming[:]);e.search_cursor+=n
    }
    explorer_search_changed(a)
}
explorer_input_start :: proc(a:^App,bytes:[]u8,cursor:int,size,width:f32)->int {
    start:=clamp(cursor,0,len(bytes));advance:f32
    font:=renderer_font_size(&a.renderer,size*a.scale)
    for start>0 {
        ch,n:=utf8.decode_last_rune(bytes[:start])
        next:=renderer_glyph(&a.renderer,font,ch).advance
        if advance+next>width*a.scale {break}
        start-=n;advance+=next
    }
    return start
}
explorer_handle_key :: proc(a:^App,key,mods:c.int)->bool {
    tab:=active_tab(a);if tab==nil {return false};e:=&tab.explorer
    ctrl:=mods&glfw.MOD_CONTROL!=0;shift:=mods&glfw.MOD_SHIFT!=0;alt:=mods&glfw.MOD_ALT!=0
    if ctrl&&!shift&&key==glfw.KEY_B {explorer_toggle(a);return true}
    if ctrl&&shift&&key==glfw.KEY_E {explorer_set_visible(a,true);return true}
    // Device and window controls remain available throughout the Files view.
    if ctrl&&(key==glfw.KEY_TAB||key==glfw.KEY_PAGE_UP||key==glfw.KEY_PAGE_DOWN) {return false}
    if ctrl&&shift&&(key==glfw.KEY_T||key==glfw.KEY_W) {return false}
    if alt&&key>=glfw.KEY_1&&key<=glfw.KEY_9 {return false}
    if a.explorer_visible&&e.preview_open {
        if e.document!=nil&&!e.document.source_mode {
            if document_input_key(a,e.document,key,mods) {return true}
        }
        if key==glfw.KEY_ESCAPE||(ctrl&&key==glfw.KEY_W) {explorer_close_preview(a);return true}
        box:=explorer_preview_layout(a)
        if e.document!=nil&&!e.document.source_mode {
            return true
        }
        if ctrl&&key==glfw.KEY_C&&!e.binary&&!e.waiting {
            glfw.SetClipboardString(a.renderer.window,strings.clone_to_cstring(string(e.preview.preview),context.temp_allocator))
            return true
        }
        switch key {
        case glfw.KEY_Q:explorer_close_preview(a);return true
        case glfw.KEY_DOWN,glfw.KEY_J:e.preview_scroll+=1
        case glfw.KEY_UP,glfw.KEY_K:e.preview_scroll-=1
        case glfw.KEY_PAGE_DOWN,glfw.KEY_SPACE:e.preview_scroll+=box.rows
        case glfw.KEY_PAGE_UP:e.preview_scroll-=box.rows
        case glfw.KEY_HOME:e.preview_scroll=0
        case glfw.KEY_END:e.preview_scroll=max(0,len(e.lines)-box.rows)
        }
        e.preview_scroll=clamp(e.preview_scroll,0,max(0,len(e.lines)-box.rows));a.dirty=true;return true
    }
    if ctrl&&shift&&key==glfw.KEY_F {
        explorer_set_visible(a,true);e=&active_tab(a).explorer;e.editing=false;e.search_editing=true
        e.search_select_all=true;e.search_cursor=len(e.search);session_touch(a);a.dirty=true;return true
    }
    if !a.explorer_visible {return false}
    if ctrl&&key==glfw.KEY_W {app_close_tab(a,a.active);return true}
    if ctrl&&key==glfw.KEY_L {e.search_editing=false;e.editing=true;e.select_all=true;e.cursor=e.used;a.dirty=true;return true}
    if ctrl&&key==glfw.KEY_F {e.editing=false;e.search_editing=true;e.search_select_all=true;e.search_cursor=len(e.search);a.dirty=true;return true}
    if e.search_editing {
        if ctrl&&key==glfw.KEY_V {explorer_search_insert(a,glfw.GetClipboardString(a.renderer.window));return true}
        handled,first,last:=text_edit_key(a,e.search[:],&e.search_cursor,&e.search_anchor,&e.search_selecting,&e.search_select_all,key,mods)
        if handled {
            if last>first {used:=text_edit_remove(e.search[:],first,last);resize(&e.search,used);explorer_search_changed(a)}
            a.dirty=true;return true
        }
        switch key {
        case glfw.KEY_ESCAPE:
            e.search_selecting=false;e.search_select_all=false
            if len(e.search)>0 {clear(&e.search);e.search_cursor=0;explorer_search_changed(a)} else {e.search_editing=false}
        case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:
            e.search_editing=false;e.select_first=e.search_dirty||e.page_pending||!explorer_page_matches(e)
            if e.search_dirty {explorer_query_page(a,tab,0)}
            if explorer_count(e)>0 {e.selected=0}
        case glfw.KEY_DOWN:e.search_editing=false;if explorer_count(e)>0 {e.selected=0}
        }
        a.dirty=true;return true
    }
    if e.editing {
        if ctrl&&key==glfw.KEY_V {explorer_input_insert(a,glfw.GetClipboardString(a.renderer.window));return true}
        handled,first,last:=text_edit_key(a,e.input[:e.used],&e.cursor,&e.input_anchor,&e.input_selecting,&e.select_all,key,mods)
        if handled {if last>first {e.used=text_edit_remove(e.input[:e.used],first,last)};a.dirty=true;return true}
        switch key {
        case glfw.KEY_ESCAPE:explorer_path_text(e,e.listing.path)
        case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:explorer_navigate(a,tab,string(e.input[:e.used]))
        }
        a.dirty=true;return true
    }
    if ctrl&&key==glfw.KEY_H {explorer_toggle_hidden(a);return true}
    if ctrl&&key==glfw.KEY_C {explorer_copy_path(a,tab);return true}
    count:=explorer_count(e);box:=explorer_layout(a)
    selected_row:=e.selected
    switch key {
    case glfw.KEY_ESCAPE:explorer_set_visible(a,false);return true
    case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:explorer_open_entry(a,tab,e.selected);return true
    case glfw.KEY_BACKSPACE:
        if e.listing.path!="" {explorer_navigate(a,tab,filepath.dir(e.listing.path))}
        return true
    case glfw.KEY_F5:explorer_navigate(a,tab,e.listing.path);return true
    case glfw.KEY_LEFT:selected_row=max(0,selected_row-1)
    case glfw.KEY_RIGHT:selected_row=min(count-1,selected_row+1)
    case glfw.KEY_UP:selected_row=max(0,selected_row-box.columns)
    case glfw.KEY_DOWN:
        if selected_row<0 {selected_row=0} else {selected_row=min(count-1,selected_row+box.columns)}
    case glfw.KEY_PAGE_UP:selected_row=max(0,selected_row-max(1,box.rows)*box.columns)
    case glfw.KEY_PAGE_DOWN:selected_row=min(count-1,selected_row+max(1,box.rows)*box.columns)
    case glfw.KEY_HOME:selected_row=0
    case glfw.KEY_END:selected_row=count-1
    }
    if selected_row>=0&&selected_row<count {
        e.selected=selected_row
        selected_start:=selected_row/box.columns*box.columns
        if selected_start<e.scroll {e.scroll=selected_start}
        if selected_start>=e.scroll+box.rows*box.columns {e.scroll=max(0,selected_start-(box.rows-1)*box.columns)}
        e.scroll=explorer_grid_scroll(box,e.scroll,count)
    }
    a.dirty=true;return true
}
explorer_handle_char :: proc(a:^App,ch:rune)->bool {
    tab:=active_tab(a);if tab==nil {return false}
    if a.explorer_visible&&tab.explorer.preview_open {
        if view:=tab.explorer.document;view!=nil&&!view.source_mode {document_input_char(a,view,ch)}
        return true
    }
    if a.explorer_visible {
        if tab.explorer.editing {explorer_input_insert(a,string_from_rune(ch))}
        else if tab.explorer.search_editing {explorer_search_insert(a,string_from_rune(ch))}
        return true
    }
    return false
}
explorer_handle_mouse :: proc(a:^App,button,action:c.int,x,y:f32)->bool {
    tab:=active_tab(a);if tab==nil {return false};e:=&tab.explorer
    if !a.explorer_visible||y<HEADER {return false}
    if e.preview_open {
        box:=explorer_preview_layout(a)
        if action==glfw.PRESS&&button==glfw.MOUSE_BUTTON_LEFT {
            if x<box.x||x>=box.x+box.w||y<box.y||y>=box.y+box.h||(x>=box.x+box.w-40&&y<box.y+40) {explorer_close_preview(a);return true}
            else if e.document!=nil&&e.document.kind==.HTML&&y>=box.y+5&&y<box.y+33&&x>=box.x+box.w-278&&x<box.x+box.w-208 {
                document_view_toggle_dark(a,e.document)
            }
            else if e.document!=nil&&y<box.y+33&&x>=box.x+box.w-200&&x<box.x+box.w-40 {
                e.document.source_mode=x>=box.x+box.w-120
                a.dirty=true
            }
        }
        if e.document!=nil&&!e.document.source_mode&&(y>=box.y+68&&y<box.y+box.h-30||e.document.buttons!=0) {document_input_mouse(a,e.document,button,action,x,y)}
        return true
    }
    box:=explorer_layout(a)
    if x<0||x>=box.width||y>=box.bottom {return true}
    if button==glfw.MOUSE_BUTTON_LEFT&&action==glfw.RELEASE {return true}
    if action!=glfw.PRESS {return true}
    a.explorer_focus=true;a.selecting=false;a.selected=false;a.dirty=true
    control:=explorer_control_at(box,e,x,y)
    if control!=.None&&button!=glfw.MOUSE_BUTTON_LEFT {return true}
    if control==.Path {
        e.search_editing=false
        if !e.editing {
            for crumb in explorer_breadcrumbs(a,e,box.controls[.Path]) {
                if explorer_contains(crumb.rect,x,y) {
                    if !crumb.current {explorer_navigate(a,tab,crumb.path)}
                    return true
                }
            }
        }
        e.editing=true;e.select_all=true;e.cursor=e.used;return true
    }
    if e.editing {explorer_path_text(e,e.listing.path)}
    e.search_editing=false
    switch control {
    case .Close:app_close_tab(a,a.active);return true
    case .Up:if e.loaded&&e.listing.path!="/" {explorer_navigate(a,tab,filepath.dir(e.listing.path))};return true
    case .Home:explorer_navigate(a,tab,explorer_home(tab));return true
    case .Reload:explorer_navigate(a,tab,e.listing.path);return true
    case .Search:e.search_editing=true;e.search_select_all=true;e.search_cursor=len(e.search);return true
    case .Clear_Search:
        clear(&e.search);e.search_cursor=0;e.search_select_all=false;e.search_selecting=false
        e.search_editing=true;explorer_search_changed(a);return true
    case .Hidden:explorer_toggle_hidden(a);return true
    case .Copy:explorer_copy_path(a,tab);return true
    case .Insert:explorer_insert_cd(a,tab);return true
    case .None,.Path:
    }
    if y>=box.rows_y&&y<box.footer_y {
        index:=explorer_grid_hit(box,e,x,y)
        if index>=0&&explorer_page_entry(e,index)!=nil {
            if button==glfw.MOUSE_BUTTON_RIGHT {e.selected=index;explorer_copy_path(a,tab);return true}
            if button==glfw.MOUSE_BUTTON_LEFT {
                now:=time.tick_now()
                double:=e.last_row==index&&time.duration_seconds(time.tick_diff(e.last_click,now))<0.4
                e.selected=index;e.last_row=index;e.last_click=now
                if double {e.last_row= -1;explorer_open_entry(a,tab,index)}
            }
        } else if button==glfw.MOUSE_BUTTON_LEFT {e.selected= -1;e.last_row= -1}
    }
    return true
}
explorer_handle_cursor :: proc(a:^App,x,y:f32)->bool {
    if view:=document_active_view(a);view!=nil {return document_input_cursor(a,view,x,y)}
    over:=a.explorer_visible&&x<explorer_panel_width(a)&&y>=HEADER
    a.explorer_pointer=over
    return false
}
explorer_handle_scroll :: proc(a:^App,delta:int)->bool {
    tab:=active_tab(a);if tab==nil {return false};e:=&tab.explorer
    if !a.explorer_visible {return false}
    if e.preview_open {
        if e.document!=nil&&!e.document.source_mode {return true}
        box:=explorer_preview_layout(a);e.preview_scroll=clamp(e.preview_scroll-delta*3,0,max(0,len(e.lines)-box.rows));a.dirty=true;return true
    }
    x,y:=glfw.GetCursorPos(a.renderer.window)
    if a.explorer_visible&&x< f64(explorer_panel_width(a))&&y>=HEADER {
        box:=explorer_layout(a)
        e.scroll=explorer_grid_scroll(box,e.scroll-delta*box.columns,explorer_count(e));a.dirty=true;return true
    }
    return false
}

explorer_size :: proc(size:i64)->string {
    if size<0 {return "—"}
    if size<1024 {return fmt.tprintf("%d B",size)}
    if size<1024*1024 {return fmt.tprintf("%.0f KiB",f64(size)/1024)}
    if size<1024*1024*1024 {return fmt.tprintf("%.1f MiB",f64(size)/(1024*1024))}
    return fmt.tprintf("%.1f GiB",f64(size)/(1024*1024*1024))
}
explorer_tile_label :: proc(a:^App,name:string,rect:Explorer_Rect,color:Color) {
    width:=rect.w-16
    if width<=0 {return}
    font:=renderer_font_size(&a.renderer,13*a.scale)
    advance:f32;end:=len(name);separator:=0
    // Wrap at a filename boundary when possible; byte offsets stay on UTF-8 runes.
    for ch,offset in name {
        next:=renderer_glyph(&a.renderer,font,ch).advance/a.scale
        if advance+next>width {end=offset;break}
        advance+=next
        if ch==' '||ch=='_'||ch=='-'||ch=='.' {separator=offset+1}
    }
    if end==0 {_,length:=utf8.decode_rune_in_string(name);end=length}
    if end<len(name)&&separator>0&&separator>=end/2 {end=separator}
    lines:=[2]string{name[:end],name[end:]}
    for line,i in lines {
        if line=="" {continue}
        text_width:=min(width,renderer_text_width(&a.renderer,line,13*a.scale)/a.scale)
        ui_fit_text(a,line,rect.x+(rect.w-text_width)/2,rect.y+74+f32(i)*18,13,width,color)
    }
}
explorer_render :: proc(a:^App) {
    if !a.explorer_visible {return}
    tab:=active_tab(a);if tab==nil {return};e:=&tab.explorer;box:=explorer_layout(a)
    ui_rect(a,0,HEADER,box.width,box.bottom-HEADER,BG)
    mouse_x,mouse_y:=glfw.GetCursorPos(a.renderer.window)
    mx,my:=f32(mouse_x),f32(mouse_y)
    hover:=explorer_control_at(box,e,mx,my)
    explorer_toolbar_render(a,tab,box,hover)
    if box.table_y<=box.footer_y {ui_rect(a,box.margin,box.table_y,box.width-2*box.margin,1,LINE)}
    count:=explorer_count(e)
    e.scroll=explorer_grid_scroll(box,e.scroll,count)
    visible:=box.rows*box.columns
    for slot in 0..<visible {
        index:=e.scroll+slot
        if index>=count {break}
        rect:=explorer_tile_rect(box,slot)
        pointer:=explorer_page_entry(e,index)
        if pointer==nil {
            // Keep tile positions stable while the next catalog page arrives.
            explorer_round_rect(a,{rect.x+rect.w/2-20,rect.y+22,40,32},HOVER,4)
            explorer_round_rect(a,{rect.x+16,rect.y+78,max(0,rect.w-32),6},HOVER,3)
            continue
        }
        entry:=pointer^
        over:=explorer_contains(rect,mx,my)
        // Opaque surfaces so icon badges can sit on top of the tile.
        surface:=BG
        if index==e.selected {surface=Color{0.135,0.135,0.14,1}}
        else if over {surface=Color{0.085,0.085,0.09,1}}
        if surface!=BG {explorer_round_rect(a,rect,surface,10)}
        if index==e.selected {ui_round_border(a,rect.x,rect.y,rect.w,rect.h,10,Color{1,1,1,0.10},Color{1,1,1,0.04})}
        color:=SOFT;icon_color:=MUTED
        if index==e.selected {color=TEXT}
        if index==e.selected||over {icon_color=SOFT}
        if strings.has_prefix(entry.name,".")&&index!=e.selected&&!over {
            color=MUTED;icon_color=FAINT
        }
        explorer_tile_icon(a,entry,rect.x+(rect.w-48)/2,rect.y+18,icon_color,surface)
        explorer_tile_label(a,entry.name,rect,color)
    }
    total_rows:=(count+box.columns-1)/box.columns
    if total_rows>box.rows&&box.rows>0 {
        track:=f32(box.rows)*EXPLORER_TILE_HEIGHT
        thumb:=max(24,track*f32(box.rows)/f32(total_rows))
        position:=(track-thumb)*f32(e.scroll)/f32(max(1,explorer_max_scroll(box,count)))
        ui_scrollbar(a,box.width-8,box.rows_y+position,thumb)
    }
    if box.rows>=1&&((!e.loaded)||count==0) {
        title,detail:="This folder is empty","Files and folders will appear here."
        if e.error!="" {title="Could not load files";detail="Check the message below, then try refreshing."}
        else if !e.loaded {
            title="Loading files…";detail="Reading this folder in the background."
            if len(e.search)>0 {title="Searching this folder…";detail="Looking for matching filenames."}
            if tab.remote&&!explorer_remote_ready(tab.device) {title="Waiting for SSH";detail="Return to the terminal to finish signing in."}
        } else if e.listing.query!="" {title="No matching files";detail="Try another name or clear the search."}
        text_width:=min(420,box.width-2*box.margin)
        x:=(box.width-text_width)/2
        y:=box.rows_y+max(12,(box.footer_y-box.rows_y-100)/2)
        explorer_folder_icon(a,box.width/2-9,y,MUTED,BG)
        title_width:=renderer_text_width(&a.renderer,title,15*a.scale)/a.scale
        ui_fit_text(a,title,max(x,(box.width-title_width)/2),y+32,15,text_width,TEXT,.UI_Bold)
        detail_width:=renderer_text_width(&a.renderer,detail,12*a.scale)/a.scale
        ui_fit_text(a,detail,max(x,(box.width-detail_width)/2),y+60,12,text_width,MUTED)
    } else if box.rows==0&&box.footer_y>box.rows_y {
        ui_fit_text(a,"Enlarge the window to browse files.",box.margin,box.rows_y+8,12,box.width-2*box.margin,MUTED)
    }
    ui_rect(a,0,box.footer_y,box.width,1,LINE)
    explorer_button(a,box.controls[.Copy],.Copy,"Copy path",hover==.Copy,e.listing.path!="")
    explorer_button(a,box.controls[.Insert],.Insert,"Insert cd",hover==.Insert,e.listing.path!="")
    status:=fmt.tprintf("%d items",count);color:=MUTED
    if count==1 {status="1 item"}
    if e.listing.query!="" {status=fmt.tprintf("%d of %d items",count,e.listing.total_entries)}
    if entry:=explorer_page_entry(e,e.selected);entry!=nil {
        detail:=explorer_kind_label(entry^);if !entry.directory {detail=fmt.tprintf("%s · %s",detail,explorer_size(entry.size))}
        status=fmt.tprintf("%s  ·  %s  ·  %s",status,entry.name,detail)
    }
    switch hover {
    case .Up:status="Parent folder · Backspace"
    case .Home:status="Open home folder"
    case .Reload:status="Refresh folder · F5"
    case .Path:status="Edit path · Ctrl+L"
    case .Search:status="Search filenames · Ctrl+F"
    case .Clear_Search:status="Clear search · Esc"
    case .Hidden:status="Toggle hidden files · Ctrl+H"
    case .Close:status="Close Files · Ctrl+W"
    case .Copy:status="Copy selected path · Ctrl+C"
    case .Insert:status="Insert cd command into terminal"
    case .None:
    }
    if e.error!="" {status=e.error;color=DANGER}
    else if !e.loaded&&(e.waiting||e.search_dirty) {
        status="Loading…"
        if !e.loaded&&e.ready {indexed,_:=explorer_progress(&e.browser);status=fmt.tprintf("Indexing %d files…",indexed)}
        else if e.search_dirty||e.page_pending {status="Searching…"}
        color=SOFT
    }
    ui_text_mid(a,status,box.margin,box.footer_y+28,12,box.controls[.Copy].x-box.margin-12,color)
}
explorer_preview_line :: proc(bytes:[]u8)->string {
    text:=make([dynamic]u8,context.temp_allocator)
    for b in bytes[:min(len(bytes),2048)] {
        if b==10||b==13 {continue}
        if b==9 {append(&text,"    ")}
        else if b<32||b==127 {append(&text,'?')}
        else {append(&text,b)}
    }
    return string(text[:])
}
explorer_preview_render :: proc(a:^App) {
    tab:=active_tab(a);if tab==nil||!tab.explorer.preview_open {return}
    e:=&tab.explorer;box:=explorer_preview_layout(a)
    ui_rect(a,box.x,box.y,box.w,box.h,BG)
    ui_rect(a,box.x,box.y+67,box.w,1,LINE)
    title:="Text";path:=e.preview.path
    view:=e.document
    if view!=nil {
        title="HTML";if view.kind==.Markdown {title="Markdown"}
        path=view.path
    }
    mouse_x,mouse_y:=glfw.GetCursorPos(a.renderer.window)
    mx,my:=f32(mouse_x),f32(mouse_y)
    controls_x:=box.x+box.w-48
    if view!=nil {controls_x=box.x+box.w-(286 if view.kind==.HTML else 208)}
    badge_w:=ui_badge(a,title,box.x+16,box.y+10,SOFT)
    ui_title(a,filepath.base(path),box.x+24+badge_w,box.y+20,14,controls_x-box.x-badge_w-36)
    ui_text_mid(a,path,box.x+16,box.y+48,12,box.w-32,MUTED)
    if view!=nil {
        // Segmented Render/Source control sharing the existing hit zones.
        sx:=box.x+box.w-198;sy:=box.y+6
        ui_round(a,sx,sy,156,28,RADIUS_CONTROL,Color{1,1,1,0.04})
        ui_round_border(a,sx,sy,156,28,RADIUS_CONTROL,Color{1,1,1,0.08})
        selected_x:=sx+2 if !view.source_mode else sx+78
        ui_round_gradient(a,selected_x,sy+2,76,24,RADIUS_CONTROL-2,Color{1,1,1,0.12},Color{1,1,1,0.08})
        render_hover:=my<box.y+33&&mx>=box.x+box.w-200&&mx<box.x+box.w-120
        source_hover:=my<box.y+33&&mx>=box.x+box.w-120&&mx<box.x+box.w-40
        ui_control_label(a,"Render",sx+2,sy+2,76,24,12,TEXT if !view.source_mode||render_hover else MUTED)
        ui_control_label(a,"Source",sx+78,sy+2,76,24,12,TEXT if view.source_mode||source_hover else MUTED)
        if view.kind==.HTML {
            dark_hover:=my>=box.y+5&&my<box.y+33&&mx>=box.x+box.w-278&&mx<box.x+box.w-208
            ui_control(a,box.x+box.w-278,sy,70,28,.Outline,dark_hover,true,view.dark_mode)
            ui_dot(a,box.x+box.w-262,sy+14,6,ACCENT if view.dark_mode else FAINT)
            ui_text_mid(a,"Dark",box.x+box.w-252,sy+14,12,40,TEXT if view.dark_mode||dark_hover else MUTED)
        }
    }
    close_hover:=mx>=box.x+box.w-40&&my>=box.y&&my<box.y+40
    ui_control(a,box.x+box.w-36,box.y+6,28,28,.Ghost,close_hover)
    ui_icon_close(a,box.x+box.w-22,box.y+20,8,TEXT if close_hover else MUTED)
    e.preview_scroll=clamp(e.preview_scroll,0,max(0,len(e.lines)-box.rows))
    if view!=nil&&!view.source_mode {
        document_view_render_status(a,view,box)
    }
    else if e.waiting {ui_text(a,"Reading file...",box.x+20,box.y+88,14,MUTED)}
    else if e.preview.error!="" {ui_fit_text(a,e.preview.error,box.x+20,box.y+88,14,box.w-40,DANGER)}
    else if e.binary {ui_text(a,"Binary file — text preview unavailable.",box.x+20,box.y+88,14,MUTED)}
    else {
        for row in 0..<box.rows {
            line:=e.preview_scroll+row
            if line>=len(e.lines) {break}
            start:=e.lines[line];end:=len(e.preview.preview)
            if line+1<len(e.lines) {end=e.lines[line+1]}
            py:=box.y+83+f32(row)*22
            ui_text(a,fmt.tprintf("%4d",line+1),box.x+12,py+1,12,FAINT)
            ui_fit_text(a,explorer_preview_line(e.preview.preview[start:end]),box.x+64,py,14,box.w-84,TEXT)
        }
    }
    ui_rect(a,box.x,box.y+box.h-30,box.w,30,BG)
    ui_rect(a,box.x,box.y+box.h-30,box.w,1,LINE)
    label:="Read-only · Esc to close · Scroll to browse"
    if e.preview.truncated {label="Read-only · First 128 KiB · Esc to close"}
    if view!=nil&&!view.source_mode {label="Esc to close · Ctrl+F to find · Ctrl+scroll to zoom"}
    if view!=nil&&view.kind==.HTML {
        if view.control_error_seen!="" {label=view.control_error_seen}
    }
    ui_text_mid(a,label,box.x+16,box.y+box.h-15,12,box.w-32,MUTED)
}

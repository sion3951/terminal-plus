package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import atomic "core:sync"
import "core:time"
import "core:unicode/utf8"
import vmem "core:mem/virtual"
import glfw "vendor:glfw"

document_active_view :: proc(a:^App)->^Document_View {
    tab:=active_tab(a)
    if tab==nil||!a.explorer_visible||!tab.explorer.preview_open {return nil}
    view:=tab.explorer.document
    if view==nil||view.source_mode {return nil}
    return view
}
document_modifiers :: proc(a:^App)->int {
    w:=a.renderer.window;mods:=0
    if glfw.GetKey(w,glfw.KEY_LEFT_ALT)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_ALT)==glfw.PRESS {mods|=int(glfw.MOD_ALT)}
    if glfw.GetKey(w,glfw.KEY_LEFT_CONTROL)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_CONTROL)==glfw.PRESS {mods|=int(glfw.MOD_CONTROL)}
    if glfw.GetKey(w,glfw.KEY_LEFT_SUPER)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_SUPER)==glfw.PRESS {mods|=int(glfw.MOD_SUPER)}
    if glfw.GetKey(w,glfw.KEY_LEFT_SHIFT)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_SHIFT)==glfw.PRESS {mods|=int(glfw.MOD_SHIFT)}
    return mods
}
document_send_key :: proc(view:^Document_View,key:c.int,mods:int,action:c.int)->bool {
    if !atomic.atomic_load(&view.done)||!view.native.initialized {return false}
    name:="";code:=""
    if key>=glfw.KEY_A&&key<=glfw.KEY_Z {name=fmt.tprintf("%c",rune(key+32));code=fmt.tprintf("Key%c",rune(key));if mods&int(glfw.MOD_SHIFT)!=0 {name=fmt.tprintf("%c",rune(key))}}
    else if key>=glfw.KEY_0&&key<=glfw.KEY_9 {name=fmt.tprintf("%c",rune(key));code=fmt.tprintf("Digit%c",rune(key))}
    else {switch key {case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:name="Enter";case glfw.KEY_ESCAPE:name="Escape";case glfw.KEY_TAB:name="Tab";case glfw.KEY_SPACE:name=" ";case glfw.KEY_LEFT:name="ArrowLeft";case glfw.KEY_RIGHT:name="ArrowRight";case glfw.KEY_UP:name="ArrowUp";case glfw.KEY_DOWN:name="ArrowDown";case glfw.KEY_BACKSPACE:name="Backspace";case glfw.KEY_DELETE:name="Delete";case glfw.KEY_HOME:name="Home";case glfw.KEY_END:name="End";case glfw.KEY_PAGE_UP:name="PageUp";case glfw.KEY_PAGE_DOWN:name="PageDown"};code=name}
    view.event_key=name;view.event_code=code;view.event_shift=mods&int(glfw.MOD_SHIFT)!=0;view.event_ctrl=mods&int(glfw.MOD_CONTROL)!=0;view.event_alt=mods&int(glfw.MOD_ALT)!=0;view.event_meta=mods&int(glfw.MOD_SUPER)!=0
    node:=view.focused_node;if node<0 {node=native_query(&view.native,"body");if node<0 {node=0}}
    event:="keydown";if action==glfw.RELEASE {event="keyup"}
    return native_dispatch_event(view,node,event)
}
document_find :: proc(view:^Document_View,backwards:bool=false,restart:bool=false) {
    if !atomic.atomic_load(&view.done)||!view.native.initialized||len(view.find_text)==0 {return}
    original:=view.native.text
    folded:=make([dynamic]u8,context.temp_allocator);positions:=make([dynamic]int,context.temp_allocator)
    for ch,index in original {lower:=strings.to_lower(string_from_rune(ch),context.temp_allocator);append(&folded,lower);for _ in 0..<len(lower) {append(&positions,index)}}
    text:=string(folded[:]);query:=strings.to_lower(string(view.find_text[:]),context.temp_allocator)
    source_start:=clamp(max(view.selection_anchor,view.selection_end),0,len(original));start:=len(text)
    for position,i in positions {if position>=source_start {start=i;break}}
    found:=-1
    if restart {start=0}
    if backwards {
        source_start=clamp(min(view.selection_anchor,view.selection_end),0,len(original));start=len(text)
        for position,i in positions {if position>=source_start {start=i;break}}
        found=strings.last_index(text[:start],query);if found<0 {found=strings.last_index(text,query)}
    } else {offset:=strings.index(text[start:],query);if offset>=0 {found=start+offset} else {found=strings.index(text[:start],query)}}
    if found<0 {return}
    view.selection_anchor=positions[found];view.selection_end=len(original)
    if found+len(query)<len(positions) {view.selection_end=positions[found+len(query)]}
    for fragment in view.native.fragments {if fragment.start<=view.selection_anchor&&fragment.end>view.selection_anchor {view.scroll=clamp(fragment.y-24,0,max(0,view.native.height-view.viewport_height));break}}
}
document_find_insert :: proc(a:^App,view:^Document_View,text:string) {
    first,last:=text_edit_selection(view.find_text[:],view.find_cursor,view.find_anchor,view.find_selecting,view.find_all)
    if last>first {used:=text_edit_remove(view.find_text[:],first,last);resize(&view.find_text,used);view.find_cursor=first}
    view.find_all=false;view.find_selecting=false
    for ch in text {
        if ch<32||ch==127 {continue}
        bytes,n:=utf8.encode_rune(ch);used:=len(view.find_text)
        if used+n>65536 {break}
        resize(&view.find_text,used+n)
        for i:=used-1;i>=view.find_cursor;i-=1 {view.find_text[i+n]=view.find_text[i]}
        copy(view.find_text[view.find_cursor:view.find_cursor+n],bytes[:n]);view.find_cursor+=n
    }
    document_find(view,restart=true);a.dirty=true
}
document_insert :: proc(view:^Document_View,text:string) {
    if !atomic.atomic_load(&view.done)||view.focused_node<0||view.focused_node>=len(view.native.nodes) {return}
    node:=&view.native.nodes[view.focused_node]
    if native_has_attr(&view.native,view.focused_node,"readonly")||native_has_attr(&view.native,view.focused_node,"disabled") {return}
    if node.tag!="input"&&node.tag!="textarea" {return}
    context.allocator=vmem.arena_allocator(&view.native.arena)
    caret:=clamp(view.caret,0,len(node.value));view.caret=caret;value:=make([dynamic]u8,0,len(node.value)+len(text))
    append(&value,node.value[:caret]);for ch in text {if ch>=32||node.tag=="textarea"&&ch=='\n' {append(&value,string_from_rune(ch));view.caret+=len(string_from_rune(ch))}}
    append(&value,node.value[caret:]);node.value=string(value[:]);view.native.revision+=1
    native_dispatch_event(view,view.focused_node,"input")
}
document_copy :: proc(a:^App,view:^Document_View) {
    text:=view.native.text;first,last:=clamp(min(view.selection_anchor,view.selection_end),0,len(text)),clamp(max(view.selection_anchor,view.selection_end),0,len(text))
    if view.focused_node>=0 {text=view.native.nodes[view.focused_node].value;first=0;last=len(text)}
    if last>first {glfw.SetClipboardString(a.renderer.window,strings.clone_to_cstring(text[first:last],context.temp_allocator))}
}
document_input_key :: proc(a:^App,view:^Document_View,key,mods:c.int)->bool {
    ctrl:=mods&glfw.MOD_CONTROL!=0;shift:=mods&glfw.MOD_SHIFT!=0
    if atomic.atomic_load(&view.done)&&native_select_key(a,view,key) {return true}
    if ctrl&&key==glfw.KEY_F {view.find_open=true;view.find_focused=true;view.find_all=true;view.find_cursor=len(view.find_text);a.dirty=true;return true}
    if view.find_open&&key==glfw.KEY_ESCAPE {view.find_open=false;view.find_focused=false;a.dirty=true;return true}
    if view.find_open&&view.find_focused {
        if key==glfw.KEY_ENTER||key==glfw.KEY_KP_ENTER {document_find(view,shift);a.dirty=true;return true}
        if ctrl&&key==glfw.KEY_V {document_find_insert(a,view,glfw.GetClipboardString(a.renderer.window));return true}
        handled,first,last:=text_edit_key(a,view.find_text[:],&view.find_cursor,&view.find_anchor,&view.find_selecting,&view.find_all,key,mods)
        if handled&&last>first {used:=text_edit_remove(view.find_text[:],first,last);resize(&view.find_text,used);document_find(view,restart=true)}
        a.dirty=true;return true
    }
    if key==glfw.KEY_ESCAPE||ctrl&&key==glfw.KEY_W {return false}
    if !atomic.atomic_load(&view.done) {return true}
    if document_send_key(view,key,int(mods),glfw.PRESS) {return true}
    if key==glfw.KEY_F5||ctrl&&key==glfw.KEY_R {delete(view.pending_path);view.pending_path=strings.clone(view.path);a.dirty=true;return true}
    if ctrl&&(key==glfw.KEY_C||key==glfw.KEY_X) {document_copy(a,view);if key==glfw.KEY_X&&view.focused_node>=0 {native_dom_set(view,view.focused_node,"value",native_dom_text(""));view.caret=0};a.dirty=true;return true}
    if ctrl&&key==glfw.KEY_V {document_insert(view,glfw.GetClipboardString(a.renderer.window));a.dirty=true;return true}
    if ctrl&&key==glfw.KEY_A {view.selection_anchor=0;view.selection_end=len(view.native.text);a.dirty=true;return true}
    if key==glfw.KEY_TAB {
        count:=len(view.native.nodes);node:=view.focused_node
        for _ in 0..<count {if shift {node=(node-1+count)%count} else {node=(node+1)%count};tag:=view.native.nodes[node].tag;if (tag=="input"||tag=="textarea"||tag=="button"||tag=="select")&&!native_has_attr(&view.native,node,"disabled") {native_focus(view,node);view.scroll=clamp(view.native.nodes[node].y-24,0,max(0,view.native.height-view.viewport_height));break}}
        a.dirty=true;return true
    }
    if view.focused_node>=0 {
        node:=&view.native.nodes[view.focused_node]
        context.allocator=vmem.arena_allocator(&view.native.arena)
        value:=node.value;caret:=clamp(view.caret,0,len(value))
        if key==glfw.KEY_BACKSPACE&&caret>0 {start:=caret-1;for start>0&&(u8(value[start])&0xc0)==0x80 {start-=1};node.value=strings.concatenate([]string{value[:start],value[caret:]});view.caret=start;view.native.revision+=1;native_dispatch_event(view,view.focused_node,"input")}
        else if key==glfw.KEY_DELETE&&caret<len(value) {_,size:=utf8.decode_rune_in_string(value[caret:]);node.value=strings.concatenate([]string{value[:caret],value[caret+max(1,size):]});view.native.revision+=1;native_dispatch_event(view,view.focused_node,"input")}
        else if key==glfw.KEY_LEFT&&caret>0 {view.caret=caret-1;for view.caret>0&&(u8(value[view.caret])&0xc0)==0x80 {view.caret-=1}}
        else if key==glfw.KEY_RIGHT&&caret<len(value) {_,size:=utf8.decode_rune_in_string(value[caret:]);view.caret=caret+max(1,size)}
        else if key==glfw.KEY_HOME {view.caret=0}
        else if key==glfw.KEY_END {view.caret=len(value)}
        else if key==glfw.KEY_ENTER||key==glfw.KEY_KP_ENTER {if node.tag=="textarea" {document_insert(view,"\n")} else {native_dispatch_event(view,view.focused_node,"click");native_dispatch_event(view,view.focused_node,"change");native_submit_form(view,view.focused_node)}}
        a.dirty=true;return true
    }
    switch key {
    case glfw.KEY_UP:view.scroll-=40
    case glfw.KEY_DOWN:view.scroll+=40
    case glfw.KEY_PAGE_UP:view.scroll-=view.viewport_height*0.9
    case glfw.KEY_PAGE_DOWN,glfw.KEY_SPACE:view.scroll+=view.viewport_height*0.9
    case glfw.KEY_HOME:view.scroll=0
    case glfw.KEY_END:view.scroll=max(0,view.native.height-view.viewport_height)
    }
    view.scroll=clamp(view.scroll,0,max(0,view.native.height-view.viewport_height));a.dirty=true;return true
}
document_input_char :: proc(a:^App,view:^Document_View,ch:rune) {
    if view.find_open&&view.find_focused {document_find_insert(a,view,string_from_rune(ch));return}
    document_insert(view,string_from_rune(ch));a.dirty=true
}
document_zoom :: proc(a:^App,view:^Document_View,steps:f64=0,reset:bool=false) {if reset {view.zoom=1} else {view.zoom=clamp(view.zoom*math.pow(1.1,steps),0.25,5)};a.dirty=true}
document_zoom_key :: proc(a:^App,key,mods:c.int)->bool {
    view:=document_active_view(a);if view==nil||mods&glfw.MOD_CONTROL==0||mods&glfw.MOD_ALT!=0 {return false}
    switch key {case glfw.KEY_EQUAL,glfw.KEY_KP_ADD,glfw.KEY_KP_EQUAL:document_zoom(a,view,1);case glfw.KEY_MINUS,glfw.KEY_KP_SUBTRACT:document_zoom(a,view,-1);case glfw.KEY_0,glfw.KEY_KP_0:document_zoom(a,view,reset=true);case:return false};return true
}
document_find_rect :: proc(box:Preview_Layout)->Explorer_Rect {
    width:=min(360,box.w-32)
    return {box.x+box.w-width-16,box.y+78,width,42}
}
document_find_render :: proc(a:^App,view:^Document_View,box:Preview_Layout) {
    if !view.find_open {return}
    rect:=document_find_rect(box)
    ui_glass(a,rect.x,rect.y,rect.w,rect.h,RADIUS_POPUP-2)
    if view.find_focused {ui_round_border(a,rect.x-2,rect.y-2,rect.w+4,rect.h+4,RADIUS_POPUP,FOCUS_RING)}
    explorer_icon(a,.Search,rect.x+12,rect.y+rect.h/2-7,MUTED)
    x:=rect.x+36;width:=rect.w-120
    start:=explorer_input_start(a,view.find_text[:],view.find_cursor,13,width-4)
    if view.find_focused {text_edit_selection_render(a,view.find_text[:],start,view.find_cursor,view.find_anchor,view.find_selecting,view.find_all,x,rect.y+rect.h/2-11,13,width,22)}
    ui_text_mid(a,string(view.find_text[start:]),x,rect.y+rect.h/2,13,width,TEXT)
    if len(view.find_text)==0 {ui_text_mid(a,"Find in page",x,rect.y+rect.h/2,13,width,MUTED)}
    if view.find_focused {caret:=renderer_text_width(&a.renderer,string(view.find_text[start:view.find_cursor]),13*a.scale)/a.scale;ui_caret(a,x+caret,rect.y+rect.h/2-9,18)}
    mx,my:=glfw.GetCursorPos(a.renderer.window)
    right:=rect.x+rect.w;cy:=rect.y+rect.h/2
    over:=f32(my)>=rect.y&&f32(my)<rect.y+rect.h
    ui_rect(a,right-84,cy-9,1,18,Color{1,1,1,0.08})
    for i in 0..<3 {
        bx:=right-80+f32(i)*24
        hover:=over&&f32(mx)>=bx&&f32(mx)<bx+24
        if hover {ui_round(a,bx+1,cy-11,22,22,6,Color{1,1,1,0.08})}
        color:=TEXT if hover else SOFT
        switch i {
        case 0:ui_icon_chevron(a,bx+12,cy,9,color,3)
        case 1:ui_icon_chevron(a,bx+12,cy,9,color,2)
        case 2:ui_icon_close(a,bx+12,cy,7,color)
        }
    }
}

native_document_hit :: proc(a:^App,view:^Document_View,mouse_x,mouse_y:f32)->(node,offset:int) {
    box:=explorer_preview_layout(a);x:=mouse_x-box.x;y:=mouse_y-box.y-68+view.scroll
    nearest:=0;distance:f32=1e30
    for fragment in view.native.fragments {
        fy:=fragment.y+native_node_scroll_adjust(view,fragment.node)
        dy:=abs(y-fy-fragment.h/2)
        if dy<distance {nearest=fragment.start;distance=dy}
        if y>=fy&&y<fy+fragment.h&&x>=fragment.x&&x<=fragment.x+fragment.w {
            offset=fragment.start;cursor:=fragment.x
            for ch,i in fragment.text {width:=native_text_width(a,string_from_rune(ch),fragment.style,f32(view.zoom));if x<cursor+width/2 {return fragment.node,fragment.start+i};cursor+=width;offset=fragment.start+i+len(string_from_rune(ch))}
            return fragment.node,min(offset,fragment.end)
        }
    }
    return -1,nearest
}
native_document_navigate :: proc(a:^App,view:^Document_View,reference:string) {
    if reference=="" {return}
    if reference[0]=='#' {id,ok:=document_url_decode(reference[1:]);if ok {defer delete(id);for _,i in view.native.nodes {if native_attr(&view.native,i,"id")==id {view.scroll=view.native.nodes[i].y;break}}};a.dirty=true;return}
    base:=view.base_path;if base=="" {base=view.resource_path}
    path:=native_url_resolve(base,reference)
    if media_kind(path)!=.None {media_view_open(a,active_tab(a),path);delete(path);return}
    native_queue_navigation(view,path,"GET","","");delete(path);a.dirty=true
}
document_input_mouse :: proc(a:^App,view:^Document_View,button,action:c.int,x,y:f32) {
    if !atomic.atomic_load(&view.done) {return}
    if native_select_mouse(a,view,button,action,x,y) {return}
    if view.find_open&&explorer_contains(document_find_rect(explorer_preview_layout(a)),x,y) {
        if button==glfw.MOUSE_BUTTON_LEFT&&action==glfw.PRESS {rect:=document_find_rect(explorer_preview_layout(a));right:=rect.x+rect.w;if x>=right-32 {view.find_open=false;view.find_focused=false} else if x>=right-56 {document_find(view)} else if x>=right-80 {document_find(view,true)} else {view.find_focused=true;view.find_all=true;view.find_cursor=len(view.find_text)};a.dirty=true};return
    }
    if button!=glfw.MOUSE_BUTTON_LEFT {return}
    node,offset:=native_document_hit(a,view,x,y)
    if action==glfw.PRESS {
        view.find_focused=false;native_focus(view,-1);view.buttons|=1;view.selecting=true;view.native.revision+=1
        now:=time.tick_now();if abs(x-view.last_x)<5&&abs(y-view.last_y)<5&&time.tick_diff(view.last_click,now)<400*time.Millisecond {view.clicks=view.clicks%3+1} else {view.clicks=1};view.last_click=now;view.last_x=x;view.last_y=y
        view.selection_anchor=offset;view.selection_end=offset
        if node>=0 {tag:=view.native.nodes[node].tag;if (tag=="input"||tag=="textarea"||tag=="select")&&!native_has_attr(&view.native,node,"disabled") {native_focus(view,node);view.selecting=false}}
        if view.clicks>=2 {text:=view.native.text;first,last:=clamp(offset,0,len(text)),clamp(offset,0,len(text));for first>0&&text[first-1]!=' '&&text[first-1]!='\n' {first-=1};for last<len(text)&&text[last]!=' '&&text[last]!='\n' {last+=1};view.selection_anchor=first;view.selection_end=last;view.selecting=false}
    } else {
        view.buttons&=~int(1);view.selecting=false
        if node>=0&&view.selection_anchor==view.selection_end&&abs(x-view.last_x)<5&&abs(y-view.last_y)<5 {
            if native_dispatch_event(view,node,"click") {a.dirty=true;return}
            target:=node
            for target>=0 {
                tag:=view.native.nodes[target].tag
                if tag=="select" {view.select_node=target;view.select_scroll=0;break}
                if tag=="video"||tag=="audio" {
                    reference:=native_attr(&view.native,target,"src")
                    child:=view.native.nodes[target].first
                    for reference==""&&child>=0 {if view.native.nodes[child].tag=="source" {reference=native_attr(&view.native,child,"src")};child=view.native.nodes[child].next}
                    if reference!="" {base:=view.base_path;if base=="" {base=view.resource_path};path:=native_url_resolve(base,reference);media_view_open(a,active_tab(a),path);delete(path)} else {document_set_script_error(view,"This media element has no source.")}
                    break
                }
                if tag=="a" {native_document_navigate(a,view,native_attr(&view.native,target,"href"));break}
                if tag=="summary" {parent:=view.native.nodes[target].parent;if parent>=0 {view.native.nodes[parent].expanded=!view.native.nodes[parent].expanded;view.native.revision+=1};break}
                if tag=="input" {kind:=native_attr(&view.native,target,"type");if kind=="checkbox"||kind=="radio" {view.native.nodes[target].checked=!view.native.nodes[target].checked;view.native.revision+=1;native_dispatch_event(view,target,"change")}}
                if tag=="button"||tag=="input"&&native_attr(&view.native,target,"type")=="submit" {if native_attr(&view.native,target,"type")!="button" {native_submit_form(view,target)};break}
                target=view.native.nodes[target].parent
            }
        }
    }
    a.dirty=true
}
document_input_cursor :: proc(a:^App,view:^Document_View,x,y:f32)->bool {
    box:=explorer_preview_layout(a);inside:=x>=box.x&&x<box.x+box.w&&y>=box.y+68&&y<box.y+box.h-30
    if atomic.atomic_load(&view.done) {
        hovered:=-1;if inside {hovered,_=native_document_hit(a,view,x,y)}
        if hovered!=view.hovered_node {view.hovered_node=hovered;view.native.revision+=1;a.dirty=true}
    }
    if !inside&&!view.selecting {return false}
    if atomic.atomic_load(&view.done)&&view.selecting {_,view.selection_end=native_document_hit(a,view,x,y);if y<box.y+68 {view.scroll=max(0,view.scroll-12)} else if y>=box.y+box.h-30 {view.scroll=min(max(0,view.native.height-view.viewport_height),view.scroll+12)};a.dirty=true}
    return true
}
document_input_scroll :: proc(a:^App,dx,dy:f64,ctrl:bool)->bool {
    view:=document_active_view(a);if view==nil {return false}
    _,y:=glfw.GetCursorPos(a.renderer.window);box:=explorer_preview_layout(a);if y<f64(box.y+68)||y>=f64(box.y+box.h-30) {return false}
    if ctrl {document_zoom(a,view,dy)} else {view.scroll=clamp(view.scroll-f32(dy)*60,0,max(0,view.native.height-view.viewport_height));a.dirty=true};return true
}

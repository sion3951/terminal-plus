package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import glfw "vendor:glfw"

document_active_view :: proc(a:^App)->^Document_View {
    tab:=active_tab(a)
    if tab==nil||!a.explorer_visible||!tab.explorer.preview_open {return nil}
    view:=tab.explorer.document
    if view==nil||view.source_mode {return nil}
    return view
}
document_evaluate :: proc(view:^Document_View,expression:string,clipboard:bool=false) {
    params:=struct {expression:string,returnByValue:bool}{expression,true}
    document_control_queue(&view.control,"Runtime.evaluate",params,clipboard)
}
document_modifiers :: proc(a:^App)->int {
    w:=a.renderer.window;mods:=0
    if glfw.GetKey(w,glfw.KEY_LEFT_ALT)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_ALT)==glfw.PRESS {mods|=1}
    if glfw.GetKey(w,glfw.KEY_LEFT_CONTROL)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_CONTROL)==glfw.PRESS {mods|=2}
    if glfw.GetKey(w,glfw.KEY_LEFT_SUPER)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_SUPER)==glfw.PRESS {mods|=4}
    if glfw.GetKey(w,glfw.KEY_LEFT_SHIFT)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_SHIFT)==glfw.PRESS {mods|=8}
    return mods
}
document_key :: proc(key:c.int,shift:bool)->(name,code:string,vk:int) {
    if key>=glfw.KEY_A&&key<=glfw.KEY_Z {
        vk=int(key);letter:=u8(key);if !shift {letter+=32}
        return fmt.tprintf("%c",letter),fmt.tprintf("Key%c",u8(key)),vk
    }
    if key>=glfw.KEY_0&&key<=glfw.KEY_9 {return fmt.tprintf("%c",u8(key)),fmt.tprintf("Digit%c",u8(key)),int(key)}
    if key>=glfw.KEY_F1&&key<=glfw.KEY_F24 {number:=int(key-glfw.KEY_F1)+1;return fmt.tprintf("F%d",number),fmt.tprintf("F%d",number),111+number}
    switch key {
    case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:return "Enter","Enter",13
    case glfw.KEY_TAB:return "Tab","Tab",9
    case glfw.KEY_BACKSPACE:return "Backspace","Backspace",8
    case glfw.KEY_DELETE:return "Delete","Delete",46
    case glfw.KEY_INSERT:return "Insert","Insert",45
    case glfw.KEY_ESCAPE:return "Escape","Escape",27
    case glfw.KEY_LEFT:return "ArrowLeft","ArrowLeft",37
    case glfw.KEY_UP:return "ArrowUp","ArrowUp",38
    case glfw.KEY_RIGHT:return "ArrowRight","ArrowRight",39
    case glfw.KEY_DOWN:return "ArrowDown","ArrowDown",40
    case glfw.KEY_HOME:return "Home","Home",36
    case glfw.KEY_END:return "End","End",35
    case glfw.KEY_PAGE_UP:return "PageUp","PageUp",33
    case glfw.KEY_PAGE_DOWN:return "PageDown","PageDown",34
    case glfw.KEY_SPACE:return " ","Space",32
    case glfw.KEY_LEFT_CONTROL:return "Control","ControlLeft",17
    case glfw.KEY_RIGHT_CONTROL:return "Control","ControlRight",17
    case glfw.KEY_LEFT_SHIFT:return "Shift","ShiftLeft",16
    case glfw.KEY_RIGHT_SHIFT:return "Shift","ShiftRight",16
    case glfw.KEY_LEFT_ALT:return "Alt","AltLeft",18
    case glfw.KEY_RIGHT_ALT:return "Alt","AltRight",18
    case glfw.KEY_LEFT_SUPER:return "Meta","MetaLeft",91
    case glfw.KEY_RIGHT_SUPER:return "Meta","MetaRight",92
    }
    return "","",0
}
document_send_key :: proc(view:^Document_View,key:c.int,mods:int,action:c.int) {
    name,code,vk:=document_key(key,mods&8!=0)
    if name=="" {return}
    kind:="rawKeyDown";text:=""
    if action==glfw.RELEASE {kind="keyUp"}
    else if vk==13 {kind="keyDown";text="\r"}
    else if vk==9 {kind="keyDown";text="\t"}
    params:=struct {kind:string `json:"type"`,key,code:string,windowsVirtualKeyCode,modifiers:int,autoRepeat:bool,text:string}{
        kind,name,code,vk,mods,action==glfw.REPEAT,text}
    document_control_queue(&view.control,"Input.dispatchKeyEvent",params)
}
document_insert :: proc(view:^Document_View,text:string) {
    document_control_queue(&view.control,"Input.insertText",struct {text:string}{text})
}
document_find :: proc(view:^Document_View,backwards:bool=false,restart:bool=false) {
    query,_:=json.marshal(string(view.find_text[:]),allocator=context.temp_allocator)
    expression:=fmt.tprintf("%swindow.find(%s,false,%t,true,false,false,false)",
        "",string(query),backwards)
    if restart {expression=strings.concatenate([]string{"if(window.getSelection().rangeCount)window.getSelection().collapseToStart();",expression},context.temp_allocator)}
    document_evaluate(view,expression)
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
document_input_key :: proc(a:^App,view:^Document_View,key,mods:c.int)->bool {
    ctrl:=mods&glfw.MOD_CONTROL!=0;shift:=mods&glfw.MOD_SHIFT!=0
    if ctrl&&key==glfw.KEY_F {view.find_open=true;view.find_focused=true;view.find_all=true;view.find_cursor=len(view.find_text);a.dirty=true;return true}
    if view.find_open&&key==glfw.KEY_ESCAPE {view.find_open=false;view.find_focused=false;a.dirty=true;return true}
    if ctrl&&key==glfw.KEY_W {return false}
    if view.find_open&&view.find_focused {
        if key==glfw.KEY_ENTER||key==glfw.KEY_KP_ENTER {document_find(view,shift);return true}
        if ctrl&&key==glfw.KEY_V {document_find_insert(a,view,glfw.GetClipboardString(a.renderer.window));return true}
        handled,first,last:=text_edit_key(a,view.find_text[:],&view.find_cursor,&view.find_anchor,&view.find_selecting,&view.find_all,key,mods)
        if handled&&last>first {used:=text_edit_remove(view.find_text[:],first,last);resize(&view.find_text,used);document_find(view,restart=true)}
        a.dirty=true;return true
    }
    if key==glfw.KEY_ESCAPE||(ctrl&&key==glfw.KEY_W) {return false}
    if key==glfw.KEY_F5||(ctrl&&key==glfw.KEY_R) {
        document_control_queue(&view.control,"Page.reload",struct {ignoreCache:bool}{shift});return true
    }
    if ctrl&&(key==glfw.KEY_C||key==glfw.KEY_X) {
        document_evaluate(view,`(()=>{const s=String(window.getSelection());if(s)return s;const e=document.activeElement;return e&&typeof e.value==='string'&&e.selectionStart!=null?e.value.slice(e.selectionStart,e.selectionEnd):''})()`,true)
        if key==glfw.KEY_X {document_send_key(view,glfw.KEY_BACKSPACE,0,glfw.PRESS)}
        return true
    }
    if ctrl&&key==glfw.KEY_V {document_insert(view,glfw.GetClipboardString(a.renderer.window));return true}
    document_send_key(view,key,document_modifiers(a),glfw.PRESS)
    return true
}
document_input_char :: proc(a:^App,view:^Document_View,ch:rune) {
    if view.find_open&&view.find_focused {document_find_insert(a,view,string_from_rune(ch));return}
    document_insert(view,string_from_rune(ch))
}
document_zoom :: proc(a:^App,view:^Document_View,steps:f64=0,reset:bool=false) {
    if reset {view.zoom=1} else {view.zoom=clamp(view.zoom*math.pow(1.1,steps),0.25,5)}
    a.dirty=true
}
document_zoom_key :: proc(a:^App,key,mods:c.int)->bool {
    view:=document_active_view(a)
    if view==nil||mods&glfw.MOD_CONTROL==0||mods&glfw.MOD_ALT!=0 {return false}
    switch key {
    case glfw.KEY_EQUAL,glfw.KEY_KP_ADD,glfw.KEY_KP_EQUAL:document_zoom(a,view,1)
    case glfw.KEY_MINUS,glfw.KEY_KP_SUBTRACT:document_zoom(a,view,-1)
    case glfw.KEY_0,glfw.KEY_KP_0:document_zoom(a,view,reset=true)
    case:return false
    }
    return true
}
document_find_rect :: proc(box:Preview_Layout)->Explorer_Rect {
    width:=min(360,box.w-32)
    return {box.x+box.w-width-16,box.y+78,width,42}
}
document_find_render :: proc(a:^App,view:^Document_View,box:Preview_Layout) {
    if !view.find_open {return}
    rect:=document_find_rect(box);explorer_field(a,rect,view.find_focused,false)
    x:=rect.x+12;width:=rect.w-94
    start:=explorer_input_start(a,view.find_text[:],view.find_cursor,13,width-4)
    if view.find_focused {text_edit_selection_render(a,view.find_text[:],start,view.find_cursor,view.find_anchor,view.find_selecting,view.find_all,x,rect.y+9,13,width,22)}
    ui_fit_text(a,string(view.find_text[start:]),x,rect.y+15,13,width,TEXT)
    if len(view.find_text)==0 {ui_text(a,"Find in page",x,rect.y+15,13,MUTED)}
    if view.find_focused {caret:=renderer_text_width(&a.renderer,string(view.find_text[start:view.find_cursor]),13*a.scale)/a.scale;ui_rect(a,x+caret,rect.y+11,1,20,ACCENT)}
    ui_text(a,"‹",rect.x+rect.w-74,rect.y+12,18,SOFT)
    ui_text(a,"›",rect.x+rect.w-50,rect.y+12,18,SOFT)
    ui_text(a,"×",rect.x+rect.w-26,rect.y+13,16,MUTED)
}
document_mouse :: proc(a:^App,view:^Document_View,kind,button:string,x,y:f32,clicks:int=0,dx:f64=0,dy:f64=0) {
    box:=explorer_preview_layout(a)
    // The headless widget uses physical viewport pixels; Chromium applies the
    // emulated monitor/zoom transform when it dispatches into the page's CSS.
    params:=struct {kind:string `json:"type"`,x,y:f64,button:string,buttons,clickCount,modifiers:int,deltaX,deltaY:f64}{
        kind,f64((x-box.x)*a.scale),f64((y-box.y-68)*a.scale),button,view.buttons,clicks,document_modifiers(a),dx/view.zoom,dy/view.zoom}
    document_control_queue(&view.control,"Input.dispatchMouseEvent",params)
}
document_input_mouse :: proc(a:^App,view:^Document_View,button,action:c.int,x,y:f32) {
    if view.find_open&&explorer_contains(document_find_rect(explorer_preview_layout(a)),x,y) {
        if button==glfw.MOUSE_BUTTON_LEFT&&action==glfw.PRESS {
            rect:=document_find_rect(explorer_preview_layout(a));right:=rect.x+rect.w
            if x>=right-32 {view.find_open=false;view.find_focused=false}
            else if x>=right-56 {document_find(view)}
            else if x>=right-80 {document_find(view,true)}
            else {view.find_focused=true;view.find_all=true;view.find_cursor=len(view.find_text)}
            a.dirty=true
        }
        return
    }
    name:="left";mask:=1
    if button==glfw.MOUSE_BUTTON_RIGHT {name="right";mask=2}
    else if button==glfw.MOUSE_BUTTON_MIDDLE {name="middle";mask=4}
    else if button!=glfw.MOUSE_BUTTON_LEFT {return}
    if action==glfw.PRESS {
        view.find_focused=false;a.dirty=true
        now:=time.tick_now()
        if int(button)==view.last_button&&abs(x-view.last_x)<5&&abs(y-view.last_y)<5&&time.tick_diff(view.last_click,now)<400*time.Millisecond {view.clicks=view.clicks%3+1}
        else {view.clicks=1}
        view.last_click=now;view.last_button=int(button);view.last_x=x;view.last_y=y;view.buttons|=mask
        document_mouse(a,view,"mousePressed",name,x,y,view.clicks)
    } else {view.buttons&= ~mask;document_mouse(a,view,"mouseReleased",name,x,y,view.clicks)}
}
document_input_cursor :: proc(a:^App,view:^Document_View,x,y:f32)->bool {
    box:=explorer_preview_layout(a)
    inside:=x>=box.x&&x<box.x+box.w&&y>=box.y+68&&y<box.y+box.h-30
    if !inside&&view.buttons==0 {return false}
    if view.find_open&&explorer_contains(document_find_rect(box),x,y)&&view.buttons==0 {return true}
    button:="none"
    if view.buttons&1!=0 {button="left"} else if view.buttons&2!=0 {button="right"} else if view.buttons&4!=0 {button="middle"}
    document_mouse(a,view,"mouseMoved",button,x,y)
    return true
}
document_input_scroll :: proc(a:^App,dx,dy:f64,ctrl:bool)->bool {
    view:=document_active_view(a);if view==nil {return false}
    x,y:=glfw.GetCursorPos(a.renderer.window);box:=explorer_preview_layout(a)
    if y<f64(box.y+68)||y>=f64(box.y+box.h-30) {return false}
    if ctrl {document_zoom(a,view,dy)}
    else {document_mouse(a,view,"mouseWheel","none",f32(x),f32(y),dx= -dx*60,dy= -dy*60)}
    return true
}

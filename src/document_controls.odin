package main

import "core:strings"
import "core:c"
import vmem "core:mem/virtual"
import glfw "vendor:glfw"

native_select_options :: proc(view:^Document_View,node:int)->[dynamic]int {
    options:=make([dynamic]int,context.temp_allocator)
    for n,index in view.native.nodes {if n.tag=="option"&&native_dom_contains(&view.native,node,index)&&!native_control_disabled(&view.native,index) {append(&options,index)}}
    return options
}
native_option_value :: proc(doc:^Native_Document,node:int)->string {
    if native_has_attr(doc,node,"value") {return native_attr(doc,node,"value")};return native_node_text(doc,node)
}
native_select_value :: proc(view:^Document_View,node:int)->string {
    options:=native_select_options(view,node);doc:=&view.native
    for option in options {if doc.nodes[node].value_dirty {if doc.nodes[option].checked {return native_option_value(doc,option)}} else if doc.nodes[option].checked||native_has_attr(doc,option,"selected") {return native_option_value(doc,option)}}
    if !doc.nodes[node].value_dirty&&len(options)>0 {return native_option_value(doc,options[0])}
    return ""
}
native_select_choose :: proc(view:^Document_View,node,option:int) {
    doc:=&view.native
    for candidate in native_select_options(view,node) {doc.nodes[candidate].checked=candidate==option}
    doc.nodes[node].value=strings.clone(native_option_value(doc,option),vmem.arena_allocator(&doc.arena));doc.nodes[node].value_dirty=true;doc.revision+=1
    native_dispatch_event(view,node,"input");native_dispatch_event(view,node,"change")
}
native_select_rect :: proc(a:^App,view:^Document_View,rows:int)->Explorer_Rect {
    box:=explorer_preview_layout(a);node:=view.native.nodes[view.select_node]
    width:=min(box.w-16,max(180,node.w));height:=f32(min(8,rows))*28
    x:=clamp(box.x+node.x,box.x+4,max(box.x+4,box.x+box.w-width-4))
    y:=box.y+68+node.y-view.scroll+native_node_scroll_adjust(view,view.select_node)+node.h
    if y+height>box.y+box.h-30 {y=max(box.y+68,y-node.h-height)}
    return {x,y,width,height}
}
native_select_render :: proc(a:^App,view:^Document_View) {
    if view.select_node<0||view.select_node>=len(view.native.nodes) {return}
    options:=native_select_options(view,view.select_node);if len(options)==0 {return}
    rect:=native_select_rect(a,view,len(options));first:=clamp(view.select_scroll,0,max(0,len(options)-8))
    ui_glass(a,rect.x,rect.y,rect.w,rect.h,RADIUS_CONTROL)
    value:=native_select_value(view,view.select_node)
    mx,my:=glfw.GetCursorPos(a.renderer.window)
    for option,row in options[first:min(len(options),first+8)] {
        y:=rect.y+f32(row)*28
        hover:=f32(mx)>=rect.x&&f32(mx)<rect.x+rect.w&&f32(my)>=y&&f32(my)<y+28
        selected:=native_option_value(&view.native,option)==value
        ui_row(a,rect.x+3,y+2,rect.w-6,24,false,hover)
        if selected {ui_icon(a,.Check,rect.x+8,y+6,TEXT)}
        ui_text_mid(a,native_node_text(&view.native,option),rect.x+30,y+14,13,rect.w-40,TEXT)
    }
}
native_select_mouse :: proc(a:^App,view:^Document_View,button,action:c.int,x,y:f32)->bool {
    if view.select_node<0||action!=glfw.PRESS||button!=glfw.MOUSE_BUTTON_LEFT {return false}
    options:=native_select_options(view,view.select_node);rect:=native_select_rect(a,view,len(options));node:=view.select_node
    view.select_node=-1;a.dirty=true
    if !explorer_contains(rect,x,y) {return false}
    index:=clamp(view.select_scroll,0,max(0,len(options)-8))+int((y-rect.y)/28)
    if index>=0&&index<len(options) {native_select_choose(view,node,options[index])}
    return true
}
native_select_key :: proc(a:^App,view:^Document_View,key:c.int)->bool {
    node:=view.focused_node
    if key==glfw.KEY_ESCAPE&&view.select_node>=0 {view.select_node=-1;a.dirty=true;return true}
    if node<0||view.native.nodes[node].tag!="select" {return false}
    if key==glfw.KEY_ENTER||key==glfw.KEY_KP_ENTER||key==glfw.KEY_SPACE {if view.select_node>=0 {view.select_node=-1} else {view.select_node=node};a.dirty=true;return true}
    if key!=glfw.KEY_UP&&key!=glfw.KEY_DOWN&&key!=glfw.KEY_HOME&&key!=glfw.KEY_END {return false}
    options:=native_select_options(view,node);if len(options)==0 {return true}
    current:=0;value:=native_select_value(view,node)
    for option,index in options {if native_option_value(&view.native,option)==value {current=index;break}}
    if key==glfw.KEY_UP {current=max(0,current-1)} else if key==glfw.KEY_DOWN {current=min(len(options)-1,current+1)} else if key==glfw.KEY_HOME {current=0} else {current=len(options)-1}
    native_select_choose(view,node,options[current]);view.select_scroll=max(0,current-7);a.dirty=true;return true
}

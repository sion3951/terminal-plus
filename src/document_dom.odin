package main

import "core:fmt"
import "core:strings"
import vmem "core:mem/virtual"

native_dom_contains :: proc(doc:^Native_Document,parent,node:int,include_self:bool=true)->bool {
    current:=node;if !include_self&&current>=0&&current<len(doc.nodes) {current=doc.nodes[current].parent}
    for _ in 0..=len(doc.nodes) {if current==parent {return true};if current<0||current>=len(doc.nodes) {return false};current=doc.nodes[current].parent}
    return false
}
native_dom_detach :: proc(doc:^Native_Document,node:int) {
    if node<0||node>=len(doc.nodes) {return}
    parent:=doc.nodes[node].parent
    if parent>=0&&parent<len(doc.nodes) {
        previous:=-1;current:=doc.nodes[parent].first
        for current>=0&&current!=node {previous=current;current=doc.nodes[current].next}
        if current==node {
            if previous>=0 {doc.nodes[previous].next=doc.nodes[node].next} else {doc.nodes[parent].first=doc.nodes[node].next}
            if doc.nodes[parent].last==node {doc.nodes[parent].last=previous}
        }
    }
    doc.nodes[node].parent=-1;doc.nodes[node].next=-1;doc.revision+=1
}
native_dom_insert :: proc(doc:^Native_Document,parent,child:int,before:int=-1)->bool {
    if parent<0||child<0||parent>=len(doc.nodes)||child>=len(doc.nodes)||native_dom_contains(doc,child,parent) {return false}
    if child==before {return true}
    if before>=len(doc.nodes)||before>=0&&doc.nodes[before].parent!=parent {return false}
    native_dom_detach(doc,child)
    doc.nodes[child].parent=parent;doc.nodes[child].hidden=native_has_attr(doc,child,"hidden")
    if before<0 {
        previous:=doc.nodes[parent].last
        if previous>=0 {doc.nodes[previous].next=child} else {doc.nodes[parent].first=child}
        doc.nodes[parent].last=child
    } else {
        previous:=-1;current:=doc.nodes[parent].first
        for current>=0&&current!=before {previous=current;current=doc.nodes[current].next}
        doc.nodes[child].next=before
        if previous>=0 {doc.nodes[previous].next=child} else {doc.nodes[parent].first=child}
    }
    doc.revision+=1;return true
}
native_dom_remove_attribute :: proc(doc:^Native_Document,node:int,name:string) {
    for attribute,i in doc.nodes[node].attributes {if attribute.name==name {ordered_remove(&doc.nodes[node].attributes,i);doc.revision+=1;return}}
}
native_dom_html_write :: proc(doc:^Native_Document,node:int,output:^[dynamic]u8,depth:int=0) {
    if node<0||node>=len(doc.nodes)||depth>256 {return}
    n:=doc.nodes[node]
    if n.tag=="#text" {
        raw:=n.parent>=0&&(doc.nodes[n.parent].tag=="script"||doc.nodes[n.parent].tag=="style")
        if raw {append(output,n.text)} else {escaped:=document_html_attribute(n.text);append(output,escaped);delete(escaped)}
        return
    }
    if n.tag!="#document" {
        append(output,'<');append(output,n.tag)
        for attribute in n.attributes {escaped:=document_html_attribute(attribute.value);append(output,fmt.tprintf(" %s=\"%s\"",attribute.name,escaped));delete(escaped)}
        append(output,'>')
    }
    child:=n.first
    for child>=0 {native_dom_html_write(doc,child,output,depth+1);child=doc.nodes[child].next}
    if n.tag!="#document"&&!html_void(n.tag) {append(output,"</");append(output,n.tag);append(output,'>')}
}
native_dom_html :: proc(doc:^Native_Document,node:int,outer:bool=false)->string {
    output:=make([dynamic]u8,context.allocator)
    if outer {native_dom_html_write(doc,node,&output)}
    else {child:=doc.nodes[node].first;for child>=0 {native_dom_html_write(doc,child,&output);child=doc.nodes[child].next}}
    return string(output[:])
}
native_dom_elements :: proc(view:^Document_View,parent:int,selector:string,first_only:bool=false)->Native_JS_Value {
    doc:=&view.native;js:=&doc.script;result:Native_JS_Value
    if !first_only {result=native_js_array(js,nil)}
    if parent<0||parent>=len(doc.nodes) {if first_only {return {kind=.Null}};return result}
    // Walk the live tree in document order. Allocation order becomes stale
    // after insertBefore/reparenting and scanning every node also visits detached trees.
    skip_inert:=!html_node_inert(doc,parent)
    node:=doc.nodes[parent].first
    for node>=0 {
        inert:=skip_inert&&doc.nodes[node].tag=="template"
        if !inert&&native_css_matches(doc,node,selector) {
            if first_only {return native_dom_object(node)}
            append(&result.reference.items,native_dom_object(node))
        }
        if !inert&&doc.nodes[node].first>=0 {node=doc.nodes[node].first;continue}
        for node!=parent&&doc.nodes[node].next<0 {node=doc.nodes[node].parent}
        if node==parent {break}
        node=doc.nodes[node].next
    }
    if first_only {return {kind=.Null}}
    return result
}
native_location :: proc(view:^Document_View)->string {
    if native_http_url(view.resource_path) {return view.resource_path}
    return view.path
}
native_location_get :: proc(view:^Document_View,name:string)->Native_JS_Value {
    location:=native_location(view)
    switch name {
    case "href":return native_dom_text(location)
    case "origin":return native_dom_text(native_url_origin(location))
    case "hash":if fragment:=native_url_fragment(location);fragment!="" {return native_dom_text(fmt.tprintf("#%s",fragment))};return native_dom_text("")
    case "search":return native_dom_text(native_url_query(location))
    case "pathname":
        path:=native_url_without_fragment(location);if query:=strings.index_byte(path,'?');query>=0 {path=path[:query]}
        if native_http_url(path) {origin:=native_url_origin(path);if len(path)<=len(origin) {return native_dom_text("/")};path=path[len(origin):]}
        return native_dom_text(path)
    case "protocol":if index:=strings.index_byte(location,':');index>=0 {return native_dom_text(location[:index+1])};return native_dom_text("file:")
    case "host","hostname","port":
        origin:=native_url_origin(location);if origin=="null" {return native_dom_text("")}
        host:=origin[strings.index(origin,"://")+3:]
        colon:=strings.last_index_byte(host,':')
        if name=="host" {return native_dom_text(host)}
        if name=="port" {if colon>=0&&!strings.has_suffix(host,"]") {return native_dom_text(host[colon+1:])};return native_dom_text("")}
        if colon>=0&&!strings.has_suffix(host,"]") {host=host[:colon]};return native_dom_text(host)
    }
    return {}
}

native_listener_add :: proc(view:^Document_View,object:int,event:string,callback:Native_JS_Value,options:[]Native_JS_Value=nil) {
    listener:=Native_Listener{event=strings.clone(event,vmem.arena_allocator(&view.native.arena)),callback=callback}
    if len(options)>0 {
        if options[0].kind==.Bool {listener.capture=options[0].boolean}
        else if options[0].reference!=nil {listener.capture=native_js_truth(options[0].reference.properties["capture"]);listener.once=native_js_truth(options[0].reference.properties["once"])}
    }
    if object== -2 {append(&view.window_listeners,listener)} else {node:=object;if node<0 {node=0};append(&view.native.nodes[node].listeners,listener)}
}

native_dom_order :: proc(doc:^Native_Document)->[dynamic]int {
    order:=make([dynamic]int,context.allocator);stack:=make([dynamic]int,context.temp_allocator)
    append(&stack,0)
    for len(stack)>0 {
        node:=pop(&stack)
        if html_node_inert(doc,node) {continue}
        append(&order,node)
        children:=make([dynamic]int,context.temp_allocator);child:=doc.nodes[node].first
        for child>=0 {append(&children,child);child=doc.nodes[child].next}
        for i:=len(children)-1;i>=0;i-=1 {append(&stack,children[i])}
    }
    return order
}
native_focus :: proc(view:^Document_View,node:int) {
    if node==view.focused_node {return}
    previous:=view.focused_node;view.focused_node=node;view.native.revision+=1
    if previous>=0 {native_dispatch_event(view,previous,"blur",false);native_dispatch_event(view,previous,"focusout")}
    if node>=0 {view.caret=len(view.native.nodes[node].value);native_dispatch_event(view,node,"focus",false);native_dispatch_event(view,node,"focusin")}
}

native_computed_get :: proc(view:^Document_View,node:int,name:string)->Native_JS_Value {
    if node<0||node>=len(view.native.nodes) {return {}}
    if view.owner!=nil&&view.layout_revision!=view.native.revision {native_document_layout(view.owner,view,view.native.width)}
    style:=view.native.nodes[node].style
    switch native_css_property(name) {
    case "color":return native_dom_text(fmt.tprintf("rgb(%d, %d, %d)",int(style.color[0]*255+0.5),int(style.color[1]*255+0.5),int(style.color[2]*255+0.5)))
    case "background-color":return native_dom_text(fmt.tprintf("rgba(%d, %d, %d, %g)",int(style.background[0]*255+0.5),int(style.background[1]*255+0.5),int(style.background[2]*255+0.5),style.background[3]))
    case "width":return native_dom_text(fmt.tprintf("%gpx",view.native.nodes[node].w/f32(view.zoom)))
    case "height":return native_dom_text(fmt.tprintf("%gpx",view.native.nodes[node].h/f32(view.zoom)))
    case "font-size":return native_dom_text(fmt.tprintf("%gpx",style.size))
    case "display": #partial switch style.display {case .None:return native_dom_text("none");case .Inline:return native_dom_text("inline");case .Flex:return native_dom_text("flex");case .Grid:return native_dom_text("grid");case:return native_dom_text("block")}
    }
    if strings.has_prefix(name,"--") {if value,exists:=style.custom_properties[name];exists {return native_dom_text(value)}}
    return native_dom_text("")
}

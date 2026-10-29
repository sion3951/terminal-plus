package main

import "core:fmt"
import "core:os"
import vmem "core:mem/virtual"
import "core:strings"
import "core:strconv"
import atomic "core:sync"
import "core:time"

native_dom_object :: proc(object:int)->Native_JS_Value {return Native_JS_Value{kind=.Object,object=(-1 if object==0 else object)}}
native_dom_text :: proc(text:string)->Native_JS_Value {return Native_JS_Value{kind=.String,text=text}}
native_js_value_text :: proc(value:Native_JS_Value)->string {
     #partial switch value.kind {case .String:return value.text;case .Number:return fmt.tprintf("%g",value.number);case .Bool:if value.boolean {return "true"};return "false";case .Null:return "null";case .Undefined:return "undefined";case:return "[object Object]"}
}
native_query :: proc(doc:^Native_Document,selector:string,start:int=0)->int {
    for i:=max(1,start);i<len(doc.nodes);i+=1 {if native_node_attached(doc,i)&&!html_node_inert(doc,i)&&native_css_matches(doc,i,selector) {return i}}
    return -1
}
native_dom_get :: proc(data:rawptr,object:int,name:string)->Native_JS_Value {
    view:=cast(^Document_View)data;doc:=&view.native
    if object>=9000000 {return native_computed_get(view,object-9000000,name)}
    if object>=8000000 {return native_url_value_get(view,object-8000000,name)}
    if object>=7000000 {index:=object-7000000;if index<len(view.params)&&name=="size" {return native_js_number(f64(len(view.params[index].entries)))};return {}}
    if object>=6000000 {return native_canvas_get(view,object-6000000,name)}
    if object>=5000000 {return {}}
    if object>=4000000 {return native_response_get(view,object-4000000,name)}
    if object== -3 {return native_location_get(view,name)}
    if object== -2 {
        if name=="CSS" {return native_dom_object(-9)}
        if name=="location" {return native_dom_object(-3)}
        if name=="fetch"||name=="queueMicrotask"||name=="getComputedStyle"||name=="stopImmediatePropagation" {return Native_JS_Value{kind=.Builtin,text=name}}
        switch name {case "document":return native_dom_object(-1);case "window","self","globalThis":return native_dom_object(-2);case "innerWidth":return native_js_number(f64(doc.width));case "innerHeight":return native_js_number(f64(view.viewport_height));case "scrollY":return native_js_number(f64(view.scroll));case "setTimeout","setInterval","clearTimeout","clearInterval","requestAnimationFrame","cancelAnimationFrame","alert","preventDefault","stopPropagation":return Native_JS_Value{kind=.Builtin,text=name};case:return {}}
    }
    if object== -1 {
        switch name {
        case "body":node:=native_query(doc,"body");if node<0 {node=0};return native_dom_object(node)
        case "documentElement":node:=native_query(doc,"html");if node<0 {node=0};return native_dom_object(node)
        case "activeElement":return native_dom_object(view.focused_node)
        case "currentScript":if view.current_script_node>=0 {return native_dom_object(view.current_script_node)};return {kind=.Null}
        case "title":node:=native_query(doc,"title");if node>=0 {return native_dom_text(native_node_text(doc,node))}
        case "readyState":return native_dom_text(view.ready_state)
        case "URL","documentURI":return native_dom_text(native_location(view))
        case "baseURI":return native_dom_text(view.base_path)
        case "location":return native_dom_object(-3)
        case "head":node:=native_query(doc,"head");if node>=0 {return native_dom_object(node)};return {kind=.Null}
        }
        return {}
    }
    if object>=3000000 {node:=object-3000000;if node<len(doc.nodes) {return native_dom_text(native_attr(doc,node,fmt.tprintf("data-%s",native_css_property(name))))};return {}}
    if object>=2000000 {return {}}
    if object>=1000000 {
        node:=object-1000000;if node>=len(doc.nodes) {return {}}
        declarations:=native_attr(doc,node,"style")
        for item in strings.split_iterator(&declarations,";") {colon:=strings.index_byte(item,':');if colon>=0&&native_css_property(strings.trim_space(item[:colon]))==native_css_property(name) {return native_dom_text(strings.trim_space(item[colon+1:]))}}
        return native_dom_text("")
    }
    if object<0||object>=len(doc.nodes) {return {}}
    if view.owner!=nil&&(doc.revision!=view.layout_revision) {native_document_layout(view.owner,view,doc.width)}
    node:=&doc.nodes[object]
    switch name {
    case "width","height":
        if node.tag=="canvas" {size:=f64(300);if name=="height" {size=150};if value,okay:=strconv.parse_f64(native_attr(doc,object,name));okay {size=value};return native_js_number(size)}
    case "textContent","innerText":return native_dom_text(native_node_text(doc,object))
    case "innerHTML":return native_dom_text(native_dom_html(doc,object))
    case "outerHTML":return native_dom_text(native_dom_html(doc,object,true))
    case "nodeType":if node.tag=="#text" {return native_js_number(3)};if node.tag=="#document" {return native_js_number(9)};return native_js_number(1)
    case "isConnected":return native_js_bool(native_node_attached(doc,object))
    case "ownerDocument":return native_dom_object(-1)
    case "value":if node.tag=="select" {return native_dom_text(native_select_value(view,object))};return native_dom_text(node.value)
    case "checked":return native_js_bool(node.checked)
    case "hidden":return native_js_bool(node.hidden)
    case "disabled":return native_js_bool(native_has_attr(doc,object,"disabled"))
    case "id":return native_dom_text(native_attr(doc,object,"id"))
    case "className":return native_dom_text(native_attr(doc,object,"class"))
    case "tagName","nodeName":return native_dom_text(strings.to_upper(node.tag,context.temp_allocator))
    case "style":return native_dom_object(object+1000000)
    case "classList":return native_dom_object(object+2000000)
    case "dataset":return native_dom_object(object+3000000)
    case "form":form:=native_form_owner(doc,object);if form>=0 {return native_dom_object(form)};return {kind=.Null}
    case "selected":return native_js_bool(node.checked||native_has_attr(doc,object,"selected"))
    case "options":return native_dom_elements(view,object,"option")
    case "parentNode","parentElement":if node.parent>=0 {return native_dom_object(node.parent)};return {kind=.Null}
    case "firstChild","firstElementChild":child:=node.first;for child>=0&&name=="firstElementChild"&&doc.nodes[child].tag=="#text" {child=doc.nodes[child].next};if child>=0 {return native_dom_object(child)};return {kind=.Null}
    case "nextSibling","nextElementSibling":child:=node.next;for child>=0&&name=="nextElementSibling"&&doc.nodes[child].tag=="#text" {child=doc.nodes[child].next};if child>=0 {return native_dom_object(child)};return {kind=.Null}
    case "children","childNodes":
        values:=make([dynamic]Native_JS_Value,context.temp_allocator);child:=node.first
        for child>=0 {if name=="childNodes"||doc.nodes[child].tag!="#text" {append(&values,native_dom_object(child))};child=doc.nodes[child].next}
        return native_js_array(&doc.script,values[:])
    case "clientWidth","offsetWidth":return native_js_number(f64(node.w))
    case "clientHeight","offsetHeight":return native_js_number(f64(node.h))
    case "offsetTop":return native_js_number(f64(node.y))
    }
    if strings.has_prefix(name,"on") {for listener in node.listeners {if listener.event==name[2:] {return listener.callback}}}
    if native_has_attr(doc,object,name) {return native_dom_text(native_attr(doc,object,name))}
    return {}
}
native_css_property :: proc(name:string)->string {
    out:=make([dynamic]u8,context.temp_allocator)
    for b in transmute([]u8)name {if b>='A'&&b<='Z' {append(&out,'-',b+32)} else {append(&out,b)}}
    return string(out[:])
}
native_hide_children :: proc(doc:^Native_Document,node:int) {
    child:=doc.nodes[node].first
    for child>=0 {next:=doc.nodes[child].next;native_dom_detach(doc,child);child=next}
    doc.nodes[node].first=-1;doc.nodes[node].last=-1
}
native_dom_set :: proc(data:rawptr,object:int,name:string,value:Native_JS_Value)->bool {
    view:=cast(^Document_View)data;doc:=&view.native
    context.allocator=vmem.arena_allocator(&doc.arena)
    if object>=9000000 {return false}
    if object>=8000000 {index:=object-8000000;if index>=len(view.urls) {return false};url:=view.urls[index];text:=native_js_value_text(value);if name=="href" {url.href=native_url_resolve(url.href,text)} else if name=="hash" {url.href=fmt.aprintf("%s#%s",native_url_without_fragment(url.href),strings.trim_prefix(text,"#"))} else if name=="search" {bare:=native_url_without_fragment(url.href);if query:=strings.index_byte(bare,'?');query>=0 {bare=bare[:query]};url.href=fmt.aprintf("%s?%s",bare,strings.trim_prefix(text,"?"))} else {return false};return true}
    if object>=7000000 {return false}
    if object>=6000000 {return native_canvas_set(view,object-6000000,name,value)}
    if object>=3000000&&object<4000000 {node:=object-3000000;if node>=len(doc.nodes) {return false};native_set_attr(doc,node,fmt.tprintf("data-%s",native_css_property(name)),native_js_value_text(value));return true}
    if object== -2&&strings.has_prefix(name,"on") {append(&view.window_listeners,Native_Listener{event=strings.clone(name[2:]),callback=value});return true}
    if object== -2&&name=="location"||object== -3&&(name=="href"||name=="hash"||name=="search") {
        target:=native_js_value_text(value);if object== -3&&name=="hash"&&!strings.has_prefix(target,"#") {target=fmt.tprintf("#%s",target)}
        resolved:=native_url_resolve(native_location(view),target);native_queue_navigation(view,resolved,"GET","","");return true
    }
    if object== -1&&name=="title" {title:=native_query(doc,"title");if title<0 {head:=native_query(doc,"head");if head<0 {head=0};title=native_add_node(doc,head,"title","")};native_hide_children(doc,title);native_add_node(doc,title,"#text",native_js_value_text(value));doc.revision+=1;return true}
    if object>=1000000&&object<2000000 {
        node:=object-1000000;if node>=len(doc.nodes) {return false}
        declarations:=fmt.aprintf("%s;%s:%s",native_attr(doc,node,"style"),native_css_property(name),native_js_value_text(value));native_set_attr(doc,node,"style",declarations);return true
    }
    if object<0||object>=len(doc.nodes) {return false}
    node:=&doc.nodes[object];text:=strings.clone(native_js_value_text(value))
    if node.tag=="canvas"&&(name=="width"||name=="height") {native_set_attr(doc,object,name,text);native_canvas_reset(view,object);doc.revision+=1;return true}
    switch name {
    case "textContent","innerText":native_hide_children(doc,object);native_add_node(doc,object,"#text",text)
    case "innerHTML":native_hide_children(doc,object);native_parse_html(doc,text,object)
    case "value":node.value=text;node.value_dirty=true
    case "checked","selected":node.checked=native_js_truth(value)
    case "hidden":node.hidden=native_js_truth(value);if node.hidden {native_set_attr(doc,object,"hidden","")} else {native_dom_remove_attribute(doc,object,"hidden")}
    case "disabled","required","readOnly","multiple":attribute:=name;if name=="readOnly" {attribute="readonly"};if native_js_truth(value) {native_set_attr(doc,object,attribute,"")} else {native_dom_remove_attribute(doc,object,attribute)}
    case "className":native_set_attr(doc,object,"class",text)
    case "id":native_set_attr(doc,object,"id",text)
    case "onclick","oninput","onchange","onsubmit","onkeydown":append(&node.listeners,Native_Listener{event=name[2:],callback=value})
    case:native_set_attr(doc,object,name,text)
    }
    doc.revision+=1;return true
}
native_dom_call :: proc(data:rawptr,object:int,name:string,args:[]Native_JS_Value)->Native_JS_Value {
    view:=cast(^Document_View)data;doc:=&view.native
    context.allocator=vmem.arena_allocator(&doc.arena)
    first:="";if len(args)>0 {first=native_js_value_text(args[0])}
    if object>=9000000 {if name=="getPropertyValue" {return native_computed_get(view,object-9000000,first)};return {}}
    if object>=8000000 {index:=object-8000000;if index<len(view.urls)&&(name=="toString"||name=="toJSON") {return native_dom_text(view.urls[index].href)};return {}}
    if object>=7000000 {return native_params_call(view,object-7000000,name,args)}
    if object>=6000000 {return native_canvas_call(view,object-6000000,name,args)}
    if object>=5000000 {
        index:=object-5000000;if index>=len(view.responses) {return {}}
        value:=native_http_header(view.responses[index].headers,first)
        if name=="has" {return native_js_bool(value!="")};if name=="get" {if value=="" {return {kind=.Null}};return native_dom_text(value)};return {}
    }
    if object>=4000000 {return native_response_call(view,object-4000000,name,args)}
    if object== -3 {
        if name=="assign"||name=="replace" {target:=native_url_resolve(native_location(view),first);native_queue_navigation(view,target,"GET","","");return {}}
        if name=="reload" {native_queue_navigation(view,view.path,view.request_method,view.request_body,view.request_content_type);return {}}
    }
    if object== -9&&name=="supports" {query:=first;if len(args)>1 {query=fmt.tprintf("%s:%s",first,native_js_value_text(args[1]))};return native_js_bool(native_css_supports(query))}
    if object== -2 {
        switch name {
        case "fetch":return native_fetch_start(view,args)
        case "getComputedStyle":if len(args)>0 {return native_dom_object(9000000+args[0].object)};return {kind=.Null}
        case "URLSearchParams":return native_dom_object(7000000+native_params_create(view,first))
        case "URL":return native_url_create(view,args)
        case "__import_module":
            path:=native_module_resolve(view,view.current_script_url,first)
            if path=="" {native_js_fail(&doc.script,"Unmapped module specifier.");return {}}
            result,error:=native_module_evaluate(view,path);if error!="" {native_js_fail(&doc.script,error)};return result
        case "scrollTo","scroll":if len(args)>1 {view.scroll=max(0,f32(args[1].number))}
        case "scrollBy":if len(args)>1 {view.scroll=max(0,view.scroll+f32(args[1].number))}
        case "alert":document_set_script_error(view,first)
        case "preventDefault":view.event_cancelled=true;if view.current_event.reference!=nil {view.current_event.reference.properties["defaultPrevented"]=native_js_bool(true)}
        case "stopPropagation":view.event_stopped=true
        case "stopImmediatePropagation":view.event_stopped=true;view.event_immediate=true
        case "setTimeout","setInterval","requestAnimationFrame":
            if len(args)>0 {
                delay:=f64(0);if len(args)>1 {delay=max(0,native_js_numeric(args[1]))};if name=="requestAnimationFrame" {delay=16}
                view.timer_sequence+=1;timer:=Native_Document_Timer{id=view.timer_sequence,callback=args[0],began=time.tick_now(),delay=time.Duration(delay*f64(time.Millisecond))}
                if name=="setInterval" {timer.repeat=true;timer.delay=max(time.Millisecond,timer.delay)}
                if len(args)>2 {timer.args=make([]Native_JS_Value,len(args)-2,vmem.arena_allocator(&doc.arena));copy(timer.args,args[2:])}
                append(&view.timers,timer);return native_js_number(f64(timer.id))
            }
        case "clearTimeout","clearInterval","cancelAnimationFrame":if len(args)>0 {id:=int(native_js_numeric(args[0]));for i:=len(view.timers)-1;i>=0;i-=1 {if view.timers[i].id==id {ordered_remove(&view.timers,i)}}}
        case "addEventListener":if len(args)>1 {native_listener_add(view,-2,first,args[1],args[2:])}
        }
        return {}
    }
    if object>=2000000 {
        node:=object-2000000;if node>=len(doc.nodes) {return {}}
        current:=native_attr(doc,node,"class");found:=false;out:=make([dynamic]u8)
        for item in strings.fields(current,context.temp_allocator) {if item==first {found=true;if name=="remove"||name=="toggle" {continue}};if len(out)>0 {append(&out,' ')};append(&out,item)}
        if name=="contains" {return native_js_bool(found)}
        if (name=="add"||name=="toggle")&&!found {if len(out)>0 {append(&out,' ')};append(&out,first)}
        native_set_attr(doc,node,"class",string(out[:]));return native_js_bool(!found)
    }
    if object== -1||object>=0&&object<len(doc.nodes) {
        switch name {
        case "getElementById":for _,i in doc.nodes {if native_attr(doc,i,"id")==first&&native_node_attached(doc,i)&&!html_node_inert(doc,i) {return native_dom_object(i)}};return {kind=.Null}
        case "querySelector":parent:=object;if parent<0 {parent=0};return native_dom_elements(view,parent,first,true)
        case "querySelectorAll","getElementsByClassName","getElementsByTagName":
            selector:=first;if name=="getElementsByClassName" {selector=fmt.tprintf(".%s",first)}
            parent:=object;if parent<0 {parent=0};return native_dom_elements(view,parent,selector)
        case "createElement":node:=native_add_node(doc,-1,strings.to_lower(first),"");return native_dom_object(node)
        case "createTextNode":node:=native_add_node(doc,-1,"#text",first);return native_dom_object(node)
        case "addEventListener":
            if len(args)>1 {native_listener_add(view,object,first,args[1],args[2:])}
            return {}
        }
    }
    if object<0||object>=len(doc.nodes) {return {}}
    switch name {
    case "getContext":if doc.nodes[object].tag=="canvas"&&first=="2d" {return native_dom_object(6000000+object)};return {kind=.Null}
    case "getBoundingClientRect":
        if view.owner!=nil&&doc.revision!=view.layout_revision {native_document_layout(view.owner,view,doc.width)}
        node:=doc.nodes[object];result:=native_js_object(&doc.script)
        result.reference.properties["x"]=native_js_number(f64(node.x));result.reference.properties["y"]=native_js_number(f64(node.y-view.scroll))
        result.reference.properties["width"]=native_js_number(f64(node.w));result.reference.properties["height"]=native_js_number(f64(node.h))
        result.reference.properties["left"]=native_js_number(f64(node.x));result.reference.properties["top"]=native_js_number(f64(node.y-view.scroll))
        result.reference.properties["right"]=native_js_number(f64(node.x+node.w));result.reference.properties["bottom"]=native_js_number(f64(node.y+node.h-view.scroll));return result
    case "matches":return native_js_bool(native_css_matches(doc,object,first))
    case "closest":node:=object;for node>=0 {if native_css_matches(doc,node,first) {return native_dom_object(node)};node=doc.nodes[node].parent};return {kind=.Null}
    case "contains":if len(args)>0 {return native_js_bool(native_dom_contains(doc,object,args[0].object))};return native_js_bool(false)
    case "hasAttribute":return native_js_bool(native_has_attr(doc,object,first))
    case "removeAttribute":native_dom_remove_attribute(doc,object,first)
    case "insertBefore":if len(args)>=2 {before:=args[1].object;if args[1].kind==.Null {before=-1};if native_dom_insert(doc,object,args[0].object,before) {return args[0]}};return {kind=.Null}
    case "removeChild":if len(args)>0&&args[0].object>=0&&doc.nodes[args[0].object].parent==object {native_dom_detach(doc,args[0].object);return args[0]};return {kind=.Null}
    case "submit":native_submit_form(view,object,false)
    case "requestSubmit":native_submit_form(view,object)
    case "checkValidity","reportValidity":form:=native_form_owner(doc,object);if form>=0 {return native_js_bool(native_form_validate(view,form))};return native_js_bool(true)
    case "getAttribute":return native_dom_text(native_attr(doc,object,first))
    case "setAttribute":if len(args)>1 {native_set_attr(doc,object,first,native_js_value_text(args[1]))}
    case "appendChild","append":
        if len(args)>0&&args[0].kind==.Object {
            child:=args[0].object
            if child>=0&&child<len(doc.nodes)&&child!=object {
                ancestor:=object;steps:=0
                for ancestor>=0&&steps<=len(doc.nodes) {if ancestor==child {document_set_script_error(view,"A DOM node cannot contain itself or an ancestor.");return {}};ancestor=doc.nodes[ancestor].parent;steps+=1}
                previous_parent:=doc.nodes[child].parent
                if previous_parent>=0 {
                    previous:=-1;candidate:=doc.nodes[previous_parent].first
                    for candidate>=0&&candidate!=child {previous=candidate;candidate=doc.nodes[candidate].next}
                    if candidate==child {if previous>=0 {doc.nodes[previous].next=doc.nodes[child].next} else {doc.nodes[previous_parent].first=doc.nodes[child].next};if doc.nodes[previous_parent].last==child {doc.nodes[previous_parent].last=previous}}
                }
                last:=doc.nodes[object].last;doc.nodes[child].parent=object;doc.nodes[child].next=-1;doc.nodes[child].hidden=false
                if last>=0 {doc.nodes[last].next=child} else {doc.nodes[object].first=child};doc.nodes[object].last=child;doc.revision+=1;return args[0]
            }
        }
    case "remove":native_dom_detach(doc,object)
    case "focus":native_focus(view,object)
    case "blur":native_focus(view,-1)
    case "scrollIntoView":view.scroll=doc.nodes[object].y
    case "click":native_dispatch_event(view,object,"click")
    }
    return {}
}
native_dispatch_event :: proc(view:^Document_View,node:int,event:string,bubbles:bool=true)->bool {
    doc:=&view.native
    if node!= -2&&(node<0||node>=len(doc.nodes)) {return false}
    context.allocator=vmem.arena_allocator(&doc.arena)
    previous:=view.current_event;previous_cancelled:=view.event_cancelled;previous_stopped:=view.event_stopped;previous_immediate:=view.event_immediate
    view.event_cancelled=false;view.event_stopped=false;view.event_immediate=false
    value:=native_js_object(&doc.script);view.current_event=value
    value.reference.properties["target"]=native_dom_object(node);value.reference.properties["type"]=native_dom_text(event)
    value.reference.properties["bubbles"]=native_js_bool(bubbles);value.reference.properties["cancelable"]=native_js_bool(true);value.reference.properties["defaultPrevented"]=native_js_bool(false)
    value.reference.properties["key"]=native_js_string(&doc.script,view.event_key);value.reference.properties["code"]=native_js_string(&doc.script,view.event_code)
    value.reference.properties["ctrlKey"]=native_js_bool(view.event_ctrl);value.reference.properties["shiftKey"]=native_js_bool(view.event_shift);value.reference.properties["altKey"]=native_js_bool(view.event_alt);value.reference.properties["metaKey"]=native_js_bool(view.event_meta)
    value.reference.properties["preventDefault"]={kind=.Builtin,text="preventDefault"};value.reference.properties["stopPropagation"]={kind=.Builtin,text="stopPropagation"};value.reference.properties["stopImmediatePropagation"]={kind=.Builtin,text="stopImmediatePropagation"}
    doc.script.globals.values["event"]=value
    path:=make([dynamic]int,context.temp_allocator)
    if node== -2 {append(&path,-2)} else {current:=node;for current>=0 {append(&path,current);current=doc.nodes[current].parent};append(&path,-2)}
    arguments:=[1]Native_JS_Value{value}
    for phase in 0..<2 {
        for i in 0..<len(path) {
            index:=i;if phase==0 {index=len(path)-1-i}
            target:=path[index];capture:=phase==0
            if !capture&&target!=node&&!bubbles {continue}
            value.reference.properties["currentTarget"]=native_dom_object(target)
            listeners:=view.window_listeners
            if target>=0 {listeners=doc.nodes[target].listeners}
            count:=len(listeners)
            for j in 0..<count {
                listener:=listeners[j]
                if listener.event!=event||listener.capture!=capture {continue}
                _,error:=native_js_invoke(&doc.script,listener.callback,arguments[:],target)
                if error!="" {document_set_script_error(view,error)}
                if listener.once {
                    if target<0 {view.window_listeners[j].event=""} else {doc.nodes[target].listeners[j].event=""}
                }
                if view.event_immediate {break}
            }
            if !capture&&!view.event_immediate&&target>=0 {
                if script:=native_attr(doc,target,fmt.tprintf("on%s",event));script!="" {
                    result,error:=native_js_event(&doc.script,script,target)
                    if result.kind==.Bool&&!result.boolean {view.event_cancelled=true;value.reference.properties["defaultPrevented"]=native_js_bool(true)}
                    if error!="" {document_set_script_error(view,error)}
                }
            }
            if view.event_stopped {break}
        }
        if view.event_stopped {break}
    }
    cancelled:=view.event_cancelled
    view.current_event=previous
    if previous.reference!=nil {view.event_cancelled=previous_cancelled;view.event_stopped=previous_stopped;view.event_immediate=previous_immediate;doc.script.globals.values["event"]=previous}
    return cancelled
}
document_set_script_error :: proc(view:^Document_View,message:string) {
    // Published on the UI thread after loading; keep actual script errors visible.
    if !atomic.atomic_load(&view.done) {delete(view.loading_error);view.loading_error=strings.clone(message,os.heap_allocator());return}
    delete(view.control_error_seen);view.control_error_seen=strings.clone(message,os.heap_allocator())
}

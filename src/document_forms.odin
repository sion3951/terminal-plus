package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:os"

Native_Form_Entry :: struct {name,value:string}
native_node_attached :: proc(doc:^Native_Document,node:int)->bool {
    current:=node
    for _ in 0..=len(doc.nodes) {if current==0 {return true};if current<0||current>=len(doc.nodes) {return false};current=doc.nodes[current].parent}
    return false
}
native_form_owner :: proc(doc:^Native_Document,node:int)->int {
    if reference:=native_attr(doc,node,"form");reference!="" {for n,i in doc.nodes {if n.tag=="form"&&native_attr(doc,i,"id")==reference {return i}};return -1}
    current:=node
    for current>=0&&current<len(doc.nodes) {if doc.nodes[current].tag=="form" {return current};current=doc.nodes[current].parent}
    return -1
}
native_control_disabled :: proc(doc:^Native_Document,node:int)->bool {
    if native_has_attr(doc,node,"disabled") {return true}
    current:=doc.nodes[node].parent
    for current>=0 {
        if doc.nodes[current].tag=="fieldset"&&native_has_attr(doc,current,"disabled") {
            legend:=doc.nodes[current].first
            for legend>=0&&doc.nodes[legend].tag!="legend" {legend=doc.nodes[legend].next}
            inside:=node
            for inside>=0&&inside!=legend&&inside!=current {inside=doc.nodes[inside].parent}
            if legend<0||inside!=legend {return true}
        }
        current=doc.nodes[current].parent
    }
    return false
}
native_form_entries :: proc(doc:^Native_Document,form,submitter:int)->[dynamic]Native_Form_Entry {
    entries:=make([dynamic]Native_Form_Entry,context.allocator)
    for n,node in doc.nodes {
        if !native_node_attached(doc,node)||native_form_owner(doc,node)!=form||native_control_disabled(doc,node) {continue}
        name:=native_attr(doc,node,"name");if name=="" {continue}
        kind:=strings.to_lower(native_attr(doc,node,"type"),context.temp_allocator)
        if n.tag=="button"||n.tag=="input"&&(kind=="submit"||kind=="image"||kind=="reset"||kind=="button") {if node!=submitter||kind=="reset"||kind=="button" {continue}}
        if n.tag!="input"&&n.tag!="textarea"&&n.tag!="select"&&n.tag!="button" {continue}
        if n.tag=="input"&&(kind=="checkbox"||kind=="radio")&&!n.checked {continue}
        if kind=="file" {continue}
        value:=n.value
        if (kind=="checkbox"||kind=="radio")&&!native_has_attr(doc,node,"value") {value="on"}
        if n.tag=="select" {
            options:=make([dynamic]int,context.temp_allocator)
            for option,index in doc.nodes {
                if option.tag!="option"||native_control_disabled(doc,index) {continue}
                parent:=option.parent;for parent>=0&&parent!=node&&doc.nodes[parent].tag!="select" {parent=doc.nodes[parent].parent}
                if parent==node {append(&options,index)}
            }
            multiple:=native_has_attr(doc,node,"multiple");selected:=false
            for option in options {if doc.nodes[option].checked||native_has_attr(doc,option,"selected") {selected=true;break}}
            for option,index in options {
                chosen:=doc.nodes[option].checked||native_has_attr(doc,option,"selected")
                option_value:=native_attr(doc,option,"value");if !native_has_attr(doc,option,"value") {option_value=native_node_text(doc,option)}
                if n.value!="" {chosen=option_value==n.value}
                if !selected&&!multiple&&n.value==""&&index==0 {chosen=true}
                if chosen {append(&entries,Native_Form_Entry{name,option_value});if !multiple {break}}
            }
            continue
        }
        append(&entries,Native_Form_Entry{name,native_form_newlines(value)})
    }
    return entries
}
native_form_urlencoded :: proc(entries:[]Native_Form_Entry)->string {
    out:=make([dynamic]u8,context.allocator)
    for entry,i in entries {
        name:=native_form_escape(entry.name);value:=native_form_escape(entry.value)
        if i>0 {append(&out,'&')};append(&out,name);append(&out,'=');append(&out,value)
        delete(name);delete(value)
    }
    return string(out[:])
}
native_queue_navigation :: proc(view:^Document_View,target,method,body,content_type:string) {
    delete(view.pending_path,os.heap_allocator());view.pending_path=strings.clone(target,os.heap_allocator())
    delete(view.pending_method,os.heap_allocator());view.pending_method=strings.clone(method,os.heap_allocator())
    delete(view.pending_body,os.heap_allocator());view.pending_body=strings.clone(body,os.heap_allocator())
    delete(view.pending_content_type,os.heap_allocator());view.pending_content_type=strings.clone(content_type,os.heap_allocator())
    delete(view.pending_fragment,os.heap_allocator());view.pending_fragment=strings.clone(native_url_fragment(target),os.heap_allocator())
}
native_form_validate :: proc(view:^Document_View,form:int)->bool {
    doc:=&view.native
    for n,node in doc.nodes {
        if native_form_owner(doc,node)!=form||native_control_disabled(doc,node)||n.tag!="input"&&n.tag!="textarea"&&n.tag!="select" {continue}
        kind:=native_attr(doc,node,"type")
        if kind=="hidden"||kind=="submit"||kind=="reset"||kind=="button"||native_has_attr(doc,node,"readonly") {continue}
        if native_has_attr(doc,node,"required") {
            valid:=n.value!=""
            if kind=="checkbox" {valid=n.checked}
            if kind=="radio" {valid=false;name:=native_attr(doc,node,"name");for other,i in doc.nodes {if other.tag=="input"&&native_attr(doc,i,"type")=="radio"&&native_attr(doc,i,"name")==name&&native_form_owner(doc,i)==form&&other.checked {valid=true;break}}}
            if !valid {view.focused_node=node;document_set_script_error(view,"Complete the required form field.");native_dispatch_event(view,node,"invalid",false);return false}
        }
        if n.value!=""&&kind=="email"&&(!strings.contains(n.value,"@")||strings.contains_any(n.value," \r\n")) {document_set_script_error(view,"Enter a valid email address.");return false}
        if n.value!=""&&(kind=="number"||kind=="range") {
            number,valid:=strconv.parse_f64(n.value)
            if !valid {document_set_script_error(view,"Enter a valid number.");return false}
            for attribute in n.attributes {
                if attribute.name!="min"&&attribute.name!="max" {continue}
                bound,ok:=strconv.parse_f64(attribute.value);if !ok {continue}
                if attribute.name=="min"&&number<bound||attribute.name=="max"&&number>bound {document_set_script_error(view,"The form value is outside its allowed range.");return false}
            }
        }
    }
    return true
}
native_submit_form :: proc(view:^Document_View,initial_node:int,dispatch:bool=true) {
    doc:=&view.native;form:=native_form_owner(doc,initial_node)
    if form<0 {return}
    submitter:=-1
    if doc.nodes[initial_node].tag=="button"||doc.nodes[initial_node].tag=="input" {submitter=initial_node}
    if dispatch {
        if !native_has_attr(doc,form,"novalidate")&&(submitter<0||!native_has_attr(doc,submitter,"formnovalidate"))&&!native_form_validate(view,form) {return}
        if native_dispatch_event(view,form,"submit") {return}
    }
    action:=native_attr(doc,form,"action");method:=strings.to_upper(native_attr(doc,form,"method"),context.temp_allocator)
    enctype:=native_attr(doc,form,"enctype")
    if submitter>=0 {
        if value:=native_attr(doc,submitter,"formaction");value!="" {action=value}
        if value:=native_attr(doc,submitter,"formmethod");value!="" {method=strings.to_upper(value,context.temp_allocator)}
        if value:=native_attr(doc,submitter,"formenctype");value!="" {enctype=value}
    }
    if method=="DIALOG" {native_set_attr(doc,form,"hidden","");doc.nodes[form].hidden=true;doc.revision+=1;return}
    if method!="POST" {method="GET"}
    base:=view.base_path;if base=="" {base=view.resource_path};if base=="" {base=view.path}
    target:=native_url_resolve(base,action);defer delete(target)
    entries:=native_form_entries(doc,form,submitter);defer delete(entries)
    encoded:=native_form_urlencoded(entries[:]);defer delete(encoded)
    body:=encoded
    content_type:="application/x-www-form-urlencoded"
    if method=="GET" {
        bare:=native_url_without_fragment(target);if query:=strings.index_byte(bare,'?');query>=0 {bare=bare[:query]}
        destination:=fmt.tprintf("%s?%s",bare,body);fragment:=native_url_fragment(target);if fragment!="" {destination=fmt.tprintf("%s#%s",destination,fragment)}
        native_queue_navigation(view,destination,"GET","","");return
    }
    if !native_http_url(target) {document_set_script_error(view,"POST form submissions require an HTTP or HTTPS action.");return}
    if enctype=="text/plain" {
        out:=make([dynamic]u8,context.temp_allocator);for entry in entries {append(&out,entry.name);append(&out,'=');append(&out,entry.value);append(&out,"\r\n")}
        body=string(out[:]);content_type="text/plain"
    } else if enctype=="multipart/form-data" {
        boundary:=fmt.tprintf("minor-%s",session_new_id());out:=make([dynamic]u8,context.temp_allocator)
        for entry in entries {
            name,_:=strings.replace_all(entry.name,"\"","%22",context.temp_allocator)
            append(&out,fmt.tprintf("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n",boundary,name,entry.value))
        }
        append(&out,fmt.tprintf("--%s--\r\n",boundary));body=string(out[:]);content_type=fmt.tprintf("multipart/form-data; boundary=%s",boundary)
    }
    native_queue_navigation(view,target,"POST",body,content_type)
}

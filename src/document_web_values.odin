package main

import "core:fmt"
import "core:strconv"
import "core:strings"

Native_Search_Params :: struct {entries:[dynamic]Native_Form_Entry,owner:^Native_URL_Value}
Native_URL_Value :: struct {href:string,params:int}
native_query_decode :: proc(text:string)->string {
    out:=make([dynamic]u8,context.allocator)
    for i:=0;i<len(text);i+=1 {
        if text[i]=='+' {append(&out,' ')}
        else if text[i]=='%'&&i+2<len(text) {value,okay:=strconv.parse_uint(text[i+1:i+3],16);if okay {append(&out,u8(value));i+=2} else {append(&out,text[i])}}
        else {append(&out,text[i])}
    }
    return string(out[:])
}
native_params_create :: proc(view:^Document_View,text:string)->int {
    params:=new(Native_Search_Params);params.entries=make([dynamic]Native_Form_Entry)
    remaining:=text;if strings.has_prefix(remaining,"?") {remaining=remaining[1:]}
    for item in strings.split_iterator(&remaining,"&") {
        if item=="" {continue};equal:=strings.index_byte(item,'=');key,value:=item,""
        if equal>=0 {key=item[:equal];value=item[equal+1:]}
        append(&params.entries,Native_Form_Entry{native_query_decode(key),native_query_decode(value)})
    }
    index:=len(view.params);append(&view.params,params);return index
}
native_params_sync :: proc(view:^Document_View,index:int) {
    params:=view.params[index];if params.owner==nil {return}
    original:=params.owner.href;fragment:=native_url_fragment(original);bare:=native_url_without_fragment(original)
    if query:=strings.index_byte(bare,'?');query>=0 {bare=bare[:query]}
    encoded:=native_form_urlencoded(params.entries[:]);separator:="";if encoded!="" {separator="?"}
    tail:="";if fragment!="" {tail=fmt.tprintf("#%s",fragment)}
    params.owner.href=fmt.aprintf("%s%s%s%s",bare,separator,encoded,tail)
}
native_params_call :: proc(view:^Document_View,index:int,name:string,args:[]Native_JS_Value)->Native_JS_Value {
    if index<0||index>=len(view.params) {return {}}
    params:=view.params[index];js:=&view.native.script;key,value:="",""
    if len(args)>0 {key=native_js_value_text(args[0])};if len(args)>1 {value=native_js_value_text(args[1])}
    switch name {
    case "get","getAll","has":
        result:=native_js_array(js,nil)
        for entry in params.entries {if entry.name==key {if name=="get" {return native_dom_text(entry.value)};if name=="has" {return native_js_bool(true)};append(&result.reference.items,native_dom_text(entry.value))}}
        if name=="get" {return {kind=.Null}};if name=="has" {return native_js_bool(false)};return result
    case "set","delete":for i:=len(params.entries)-1;i>=0;i-=1 {if params.entries[i].name==key {ordered_remove(&params.entries,i)}};if name=="set" {append(&params.entries,Native_Form_Entry{strings.clone(key),strings.clone(value)})};native_params_sync(view,index)
    case "append":append(&params.entries,Native_Form_Entry{strings.clone(key),strings.clone(value)});native_params_sync(view,index)
    case "toString":return native_dom_text(native_form_urlencoded(params.entries[:]))
    case "keys","values","entries":
        result:=native_js_array(js,nil)
        for entry in params.entries {
            item:=native_dom_text(entry.name);if name=="values" {item=native_dom_text(entry.value)}
            if name=="entries" {pair:=[2]Native_JS_Value{native_dom_text(entry.name),native_dom_text(entry.value)};item=native_js_array(js,pair[:])}
            append(&result.reference.items,item)
        }
        return result
    }
    return {}
}
native_url_create :: proc(view:^Document_View,args:[]Native_JS_Value)->Native_JS_Value {
    if len(args)==0 {native_js_fail(&view.native.script,"URL requires a value.");return {}}
    base:=view.resource_path;if len(args)>1 {base=native_js_value_text(args[1])}
    url:=new(Native_URL_Value);url.href=native_url_resolve(base,native_js_value_text(args[0]))
    url.params=native_params_create(view,native_url_query(url.href));view.params[url.params].owner=url
    index:=len(view.urls);append(&view.urls,url);return native_dom_object(8000000+index)
}
native_url_value_get :: proc(view:^Document_View,index:int,name:string)->Native_JS_Value {
    if index<0||index>=len(view.urls) {return {}}
    if name=="searchParams" {return native_dom_object(7000000+view.urls[index].params)}
    temporary:=Document_View{path=view.urls[index].href,resource_path=view.urls[index].href}
    return native_location_get(&temporary,name)
}

package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "core:text/regex"
import regex_vm "core:text/regex/virtual_machine"

Native_JS_Regex :: struct {pattern,flags:string,compiled:regex.Regular_Expression,last_index:int,global,sticky:bool}
native_js_regex_allowed :: proc(tokens:[]Native_JS_Token)->bool {
    if len(tokens)==0 {return true}
    previous:=tokens[len(tokens)-1]
    if previous.kind==.Identifier {
        switch previous.text {case "return","throw","case","delete","typeof","void","yield","await","in","of","else":return true}
        return false
    }
    if previous.kind==.Number||previous.kind==.String||previous.kind==.Regex||previous.kind==.Template {return false}
    return previous.text!=")"&&previous.text!="]"&&previous.text!="}"&&previous.text!="++"&&previous.text!="--"
}
native_js_regex_literal :: proc(source:string,start:int)->(end:int,pattern,flags:string,valid:bool) {
    in_class:=false
    for i:=start+1;i<len(source);i+=1 {
        b:=source[i]
        if b=='\n'||b=='\r' {return}
        if b=='\\' {i+=1;continue}
        if b=='[' {in_class=true};if b==']' {in_class=false}
        if b=='/'&&!in_class {
            pattern=source[start+1:i];end=i+1;flag_start:=end
            for end<len(source)&&native_js_identifier_part(source[end]) {end+=1}
            flags=source[flag_start:end];valid=true;return
        }
    }
    return
}
native_js_regex :: proc(js:^Native_JS,pattern,raw_flags:string)->Native_JS_Value {
    if len(pattern)>4096 {native_js_fail(js,"Regular expression exceeds 4096 bytes.");return {}}
    seen:=make(map[rune]bool,native_js_allocator(js));flags:=regex.Flags{.Unicode}
    for flag in raw_flags {
        if seen[flag] {native_js_fail(js,"Duplicate JavaScript regular-expression flag.");return {}}
        seen[flag]=true
        switch flag {
        case 'g','y','d','u':
        case 'i':flags+={.Case_Insensitive}
        case 'm':flags+={.Multiline}
        case 's':
        case:native_js_fail(js,fmt.tprintf("Unsupported JavaScript regular-expression flag: %c",flag));return {}
        }
    }
    transformed:=make([dynamic]u8,native_js_allocator(js));in_class:=false
    for i:=0;i<len(pattern);i+=1 {
        b:=pattern[i]
        if b=='\\'&&i+1<len(pattern) {if pattern[i+1]=='/' {append(&transformed,'/');i+=1;continue};append(&transformed,b,pattern[i+1]);i+=1;continue}
        if b=='[' {in_class=true};if b==']' {in_class=false}
        if b=='.'&&!in_class&&seen['s'] {append(&transformed,"[\\s\\S]")} else {append(&transformed,b)}
    }
    compiled,error:=regex.create(string(transformed[:]),flags,permanent_allocator=native_js_allocator(js))
    if error!=nil {native_js_fail(js,fmt.tprintf("Unsupported or invalid JavaScript regular expression: %v",error));return {}}
    result:=native_js_object(js);expression:=new(Native_JS_Regex,native_js_allocator(js))
    result.reference.prototype=js.regex_prototype
    expression.pattern=native_js_clone(js,pattern);expression.compiled=compiled;expression.global=seen['g'];expression.sticky=seen['y']
    ordered:=make([dynamic]u8,native_js_allocator(js));for flag in "dgimsuy" {if seen[flag] {append(&ordered,u8(flag))}}
    expression.flags=string(ordered[:]);result.reference.regex=expression
    return result
}
native_js_regex_property :: proc(js:^Native_JS,value:Native_JS_Value,name:string)->(Native_JS_Value,bool) {
    expression:=value.reference.regex
    switch name {
    case "source":pattern:=expression.pattern;if pattern=="" {pattern="(?:)"};return native_js_string(js,pattern),true
    case "flags":return native_js_string(js,expression.flags),true
    case "lastIndex":return native_js_number(f64(expression.last_index)),true
    case "global":return native_js_bool(expression.global),true
    case "sticky":return native_js_bool(expression.sticky),true
    case "ignoreCase":return native_js_bool(strings.contains(expression.flags,"i")),true
    case "multiline":return native_js_bool(strings.contains(expression.flags,"m")),true
    case "dotAll":return native_js_bool(strings.contains(expression.flags,"s")),true
    case "unicode":return native_js_bool(strings.contains(expression.flags,"u")),true
    case "hasIndices":return native_js_bool(strings.contains(expression.flags,"d")),true
    }
    return {},false
}
native_js_regex_exec :: proc(js:^Native_JS,value:Native_JS_Value,text:string,start:int=-1)->Native_JS_Value {
    expression:=value.reference.regex
    if len(text)>2*1024*1024 {native_js_fail(js,"Regular-expression input exceeds 2 MiB.");return {kind=.Null}}
    position:=start
    if position<0 {position=0;if expression.global||expression.sticky {position=expression.last_index}}
    if position>len(text) {expression.last_index=0;return {kind=.Null}}
    context.allocator=context.temp_allocator
    vm:=regex_vm.create(expression.compiled.program,text);vm.class_data=expression.compiled.class_data;vm.string_pointer=position
    saved,okay:=regex_vm.run(&vm,true)
    if !okay||saved==nil||saved[0]<0||expression.sticky&&saved[0]!=position {if expression.global||expression.sticky {expression.last_index=0};return {kind=.Null}}
    count:=1
    for i:=2;i<len(saved);i+=2 {if saved[i]>=0||saved[i+1]>=0 {count=i/2+1}}
    result:=native_js_array(js,nil)
    indices:=native_js_array(js,nil)
    for i in 0..<count {
        first,last:=saved[i*2],saved[i*2+1]
        if first>=0&&last>=first&&last<=len(text) {append(&result.reference.items,native_js_string(js,text[first:last]));append(&indices.reference.items,native_js_array(js,[]Native_JS_Value{native_js_number(f64(first)),native_js_number(f64(last))}))}
        else {append(&result.reference.items,Native_JS_Value{});append(&indices.reference.items,Native_JS_Value{})}
    }
    result.reference.properties["index"]=native_js_number(f64(saved[0]));result.reference.properties["input"]=native_js_string(js,text)
    if strings.contains(expression.flags,"d") {result.reference.properties["indices"]=indices}
    if expression.global||expression.sticky {expression.last_index=saved[1]}
    return result
}
native_js_regex_method :: proc(js:^Native_JS,receiver:Native_JS_Value,name:string,args:[]Native_JS_Value)->(Native_JS_Value,bool) {
    switch name {
    case "exec":return native_js_regex_exec(js,receiver,native_js_text(js,native_js_argument(args,0))),true
    case "test":return native_js_bool(native_js_regex_exec(js,receiver,native_js_text(js,native_js_argument(args,0))).kind!=.Null),true
    case "toString":return native_js_string(js,fmt.tprintf("/%s/%s",receiver.reference.regex.pattern,receiver.reference.regex.flags)),true
    }
    return {},false
}
native_js_regex_replacement :: proc(js:^Native_JS,replacement:Native_JS_Value,match:Native_JS_Value,text:string,start,end:int)->string {
    groups:=match.reference.items
    if replacement.kind==.Function||replacement.kind==.Builtin {
        args:=make([dynamic]Native_JS_Value,native_js_allocator(js));append(&args,..groups[:]);append(&args,native_js_number(f64(start)),native_js_string(js,text))
        return native_js_text(js,native_js_call_function(js,replacement,args[:],{}))
    }
    template:=native_js_text(js,replacement);out:=make([dynamic]u8,native_js_allocator(js))
    for i:=0;i<len(template);i+=1 {
        if template[i]!='$'||i+1>=len(template) {append(&out,template[i]);continue}
        next:=template[i+1]
        switch next {
        case '$':append(&out,'$');i+=1
        case '&':append(&out,text[start:end]);i+=1
        case '`':append(&out,text[:start]);i+=1
        case '\'':append(&out,text[end:]);i+=1
        case:
            if next>='1'&&next<='9' {
                index:=int(next-'0');used:=1
                if i+2<len(template)&&template[i+2]>='0'&&template[i+2]<='9' {candidate:=index*10+int(template[i+2]-'0');if candidate<len(groups) {index=candidate;used=2}}
                if index<len(groups) {if groups[index].kind!=.Undefined {append(&out,native_js_text(js,groups[index]))};i+=used;continue}
            }
            append(&out,'$')
        }
    }
    return string(out[:])
}
native_js_regex_string_method :: proc(js:^Native_JS,receiver:Native_JS_Value,name:string,args:[]Native_JS_Value)->(Native_JS_Value,bool) {
    first:=native_js_argument(args,0);second:=native_js_argument(args,1)
    if name!="match"&&name!="matchAll"&&name!="search"&&name!="replace"&&name!="replaceAll"&&name!="split" {return {},false}
    if first.reference==nil||first.reference.regex==nil {
        if name!="match"&&name!="matchAll"&&name!="search" {return {},false}
        pattern:="";if first.kind!=.Undefined {pattern=native_js_text(js,first)}
        first=native_js_regex(js,pattern,"");if first.reference==nil {return {},true}
    }
    expression:=first.reference.regex;text:=receiver.text
    if (name=="replaceAll"||name=="matchAll")&&!expression.global {native_js_fail(js,"This string method requires a global regular expression.");return {},true}
    if name=="search" {saved:=expression.last_index;match:=native_js_regex_exec(js,first,text,0);expression.last_index=saved;if match.kind==.Null {return native_js_number(-1),true};return native_js_property(js,match,"index"),true}
    if name=="match"&&!expression.global {return native_js_regex_exec(js,first,text),true}
    result:=native_js_array(js,nil);out:=make([dynamic]u8,native_js_allocator(js));last:=0;position:=0
    expression.last_index=0
    for native_js_step(js)&&position<=len(text) {
        match:=native_js_regex_exec(js,first,text,position)
        if match.kind==.Null {break}
        start:=int(native_js_property(js,match,"index").number);matched:=native_js_text(js,match.reference.items[0]);end:=start+len(matched)
        if name=="match" {append(&result.reference.items,match.reference.items[0])}
        else if name=="matchAll" {append(&result.reference.items,match)}
        else if name=="split" {append(&result.reference.items,native_js_string(js,text[last:start]));for group in match.reference.items[1:] {append(&result.reference.items,group)}}
        else {append(&out,text[last:start]);append(&out,native_js_regex_replacement(js,second,match,text,start,end))}
        last=end;position=end
        if end==start {if position==len(text) {break};_,size:=utf8.decode_rune_in_string(text[position:]);position+=max(1,size)}
        if name=="replace"&&!expression.global {break}
    }
    if name=="replace"||name=="replaceAll" {append(&out,text[last:]);expression.last_index=0;return native_js_string(js,string(out[:])),true}
    if name=="split" {append(&result.reference.items,native_js_string(js,text[last:]))}
    expression.last_index=0
    if name=="match"&&len(result.reference.items)==0 {return {kind=.Null},true}
    return result,true
}

native_js_regex_clone :: proc(js:^Native_JS,value:Native_JS_Value)->Native_JS_Value {
    result:=native_js_object(js);result.reference.regex=new(Native_JS_Regex,native_js_allocator(js));result.reference.regex^=value.reference.regex^;result.reference.regex.last_index=0;result.reference.prototype=js.regex_prototype;return result
}

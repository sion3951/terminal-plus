package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"

native_http_url :: proc(url:string)->bool {return strings.has_prefix(url,"http://")||strings.has_prefix(url,"https://")}
native_url_without_fragment :: proc(url:string)->string {if at:=strings.index_byte(url,'#');at>=0 {return url[:at]};return url}
native_url_fragment :: proc(url:string)->string {if at:=strings.index_byte(url,'#');at>=0 {return url[at+1:]};return ""}
native_url_query :: proc(url:string)->string {
    value:=native_url_without_fragment(url)
    if at:=strings.index_byte(value,'?');at>=0 {return value[at:]};return ""
}
native_url_origin :: proc(url:string)->string {
    scheme:=strings.index(url,"://");if scheme<0 {return "null"}
    end:=len(url)
    for i:=scheme+3;i<len(url);i+=1 {if url[i]=='/'||url[i]=='?'||url[i]=='#' {end=i;break}}
    return strings.to_lower(url[:end],context.allocator)
}
// Resolve URL references before decoding filename escapes. Reserved ?, # and /
// must retain their URL roles; encoded bytes in local filenames stay filenames.
native_url_resolve :: proc(base,raw_reference:string)->string {
    reference:=strings.trim_space(raw_reference)
    if reference=="" {return strings.clone(native_url_without_fragment(base))}
    if native_http_url(reference) {
        origin:=native_url_origin(reference);defer delete(origin)
        path:=reference[len(origin):];if path=="" {path="/"};if path[0]=='?'||path[0]=='#' {path=fmt.tprintf("/%s",path)}
        return native_url_resolve(fmt.tprintf("%s/",origin),path)
    }
    if strings.has_prefix(reference,"//")&&native_http_url(base) {scheme:=strings.index_byte(base,':');return native_url_resolve(base,fmt.tprintf("%s:%s",base[:scheme],reference))}
    if strings.index(reference,":")>=0 {
        colon:=strings.index_byte(reference,':');slash:=strings.index_byte(reference,'/')
        if slash<0||colon<slash {return strings.clone(reference)}
    }
    bare:=native_url_without_fragment(base)
    if reference[0]=='#' {return fmt.aprintf("%s%s",bare,reference)}
    if question:=strings.index_byte(bare,'?');question>=0 {bare=bare[:question]}
    if reference[0]=='?' {return fmt.aprintf("%s%s",bare,reference)}
    origin:="";path:=bare
    defer {if origin!="" {delete(origin)}}
    if native_http_url(base) {
        origin=native_url_origin(base)
        if len(bare)>len(origin) {path=bare[len(origin):]} else {path="/"}
    }
    suffix:="";end:=len(reference)
    if i:=strings.index_byte(reference,'?');i>=0 {end=min(end,i)}
    if i:=strings.index_byte(reference,'#');i>=0 {end=min(end,i)}
    suffix=reference[end:];relative:=reference[:end]
    joined:=relative
    if !strings.has_prefix(relative,"/") {joined=fmt.tprintf("%s/%s",filepath.dir(path),relative)}
    parts:=make([dynamic]string,context.temp_allocator)
    remaining:=joined
    index:=0
    for segment in strings.split_iterator(&remaining,"/") {
        folded:=strings.to_lower(segment,context.temp_allocator)
        folded,_=strings.replace_all(folded,"%2e",".",context.temp_allocator)
        if segment=="" {if index>0&&remaining!="" {append(&parts,segment)};index+=1;continue};index+=1
        if folded=="." {continue}
        if folded==".." {if len(parts)>0 {pop(&parts)};continue}
        append(&parts,segment)
    }
    normalized:=strings.join(parts[:],"/",context.temp_allocator)
    trailing:=len(relative)>0&&(relative=="."||relative==".."||strings.has_suffix(relative,"/")||strings.has_suffix(relative,"/.")||strings.has_suffix(relative,"/.."))
    slash:="";if trailing&&normalized!="" {slash="/"}
    return fmt.aprintf("%s/%s%s%s",origin,normalized,slash,suffix)
}
native_form_escape :: proc(text:string)->string {
    result:=make([dynamic]u8,context.allocator);digits:="0123456789ABCDEF"
    for byte in transmute([]u8)text {
        if byte==' ' {append(&result,'+')}
        else if byte>='a'&&byte<='z'||byte>='A'&&byte<='Z'||byte>='0'&&byte<='9'||byte=='*'||byte=='-'||byte=='.'||byte=='_' {append(&result,byte)}
        else {append(&result,'%',digits[byte>>4],digits[byte&15])}
    }
    return string(result[:])
}
native_form_newlines :: proc(value:string)->string {
    result:=make([dynamic]u8,context.temp_allocator)
    for i:=0;i<len(value);i+=1 {
        if value[i]==13 {append(&result,13,10);if i+1<len(value)&&value[i+1]==10 {i+=1}}
        else if value[i]==10 {append(&result,13,10)} else {append(&result,value[i])}
    }
    return string(result[:])
}

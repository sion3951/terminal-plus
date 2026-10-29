package main

import "core:c"
import "core:strings"

// Character conversion uses libc already linked by the application. Parsing,
// styling, scripts and rendering remain native; this adds no library dependency.
foreign import document_encoding_lib "system:c"
foreign document_encoding_lib {
    @(link_name="iconv_open") html_iconv_open :: proc(to,from:cstring)->rawptr ---
    @(link_name="iconv") html_iconv :: proc(converter:rawptr,input:^[^]u8,input_left:^c.size_t,output:^[^]u8,output_left:^c.size_t)->c.size_t ---
    @(link_name="iconv_close") html_iconv_close :: proc(converter:rawptr)->c.int ---
}
native_decode_html :: proc(bytes:[]u8,content_type:string="")->string {
    encoding:="";input:=bytes
    if len(bytes)>=3&&bytes[0]==0xef&&bytes[1]==0xbb&&bytes[2]==0xbf {return string(bytes[3:])}
    if len(bytes)>=2&&bytes[0]==0xff&&bytes[1]==0xfe {encoding="UTF-16LE";input=bytes[2:]}
    else if len(bytes)>=2&&bytes[0]==0xfe&&bytes[1]==0xff {encoding="UTF-16BE";input=bytes[2:]}
    sniff:=strings.to_lower(content_type,context.temp_allocator)
    if encoding=="" {
        if strings.index(sniff,"charset")<0 {sniff=strings.to_lower(string(bytes[:min(len(bytes),1024)]),context.temp_allocator)}
        if index:=strings.index(sniff,"charset");index>=0 {
            tail:=strings.trim_space(sniff[index+7:]);if strings.has_prefix(tail,"=") {tail=strings.trim_left(tail[1:]," \t\r\n\"'");end:=0;for end<len(tail)&&tail[end]!='\''&&tail[end]!='"'&&tail[end]!=' '&&tail[end]!='\t'&&tail[end]!=';'&&tail[end]!='>' {end+=1};encoding=tail[:end]}
        }
    }
    if encoding==""||encoding=="utf-8"||encoding=="utf8" {return string(input)}
    if encoding=="iso-8859-1"||encoding=="latin1"||encoding=="us-ascii" {encoding="windows-1252"}
    converter:=html_iconv_open("UTF-8",strings.clone_to_cstring(encoding,context.temp_allocator))
    if converter==rawptr(uintptr(max(uintptr))) {return string(input)}
    defer html_iconv_close(converter)
    output:=make([]u8,len(input)*4+16)
    source,destination:=raw_data(input),raw_data(output);input_left,output_left:=c.size_t(len(input)),c.size_t(len(output))
    result:=html_iconv(converter,&source,&input_left,&destination,&output_left)
    if result==max(c.size_t) {delete(output);return string(input)}
    return string(output[:len(output)-int(output_left)])
}

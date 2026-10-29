package main

import "core:strings"

native_stylesheet :: proc(view:^Document_View,css,base:string,depth:int=0) {
    if depth>16 {document_set_script_error(view,"Stylesheet imports are nested too deeply.");return}
    rest:=css;clean:=make([dynamic]u8,context.allocator)
    for {
        at:=strings.index(rest,"@import")
        if at<0 {append(&clean,rest);break}
        append(&clean,rest[:at]);tail:=rest[at+7:];end:=strings.index_byte(tail,';')
        if end<0 {break}
        declaration:=strings.trim_space(tail[:end]);rest=tail[end+1:]
        reference:="";qualifier:=""
        if strings.has_prefix(declaration,"url(") {
            close:=strings.index_byte(declaration,')');if close>4 {reference=strings.trim(strings.trim_space(declaration[4:close]),"\"'");qualifier=strings.trim_space(declaration[close+1:])}
        } else if len(declaration)>1&&(declaration[0]=='\''||declaration[0]=='"') {
            close:=strings.index_byte(declaration[1:],declaration[0]);if close>=0 {reference=declaration[1:close+1];qualifier=strings.trim_space(declaration[close+2:])}
        }
        if reference==""||qualifier=="print" {continue}
        path:=native_resource_path(view,base,reference);bytes,error:=native_read_resource(view,path)
        if error!="" {document_set_script_error(view,error);continue}
        native_stylesheet(view,string(bytes),path,depth+1)
    }
    native_css_parse(&view.native,string(clean[:]))
}

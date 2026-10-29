package main

import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

Native_Attribute :: struct {name,value:string}
Native_Listener :: struct {event:string,callback:Native_JS_Value,script:string,capture,once:bool}
Native_DOM_Node :: struct {
    tag,text:string,
    parent,first,last,next:int,
    attributes:[dynamic]Native_Attribute,
    listeners:[dynamic]Native_Listener,
    style:Native_Style,
    x,y,w,h:f32,
    image:int,
    value:string,
    checked,hidden,expanded,value_dirty:bool,
}
Native_CSS_Rule :: struct {selector,declarations:string,specificity:int,dark_only,light_only:bool,min_width,max_width:f32}
Native_Image :: struct {path:string,pixels:[]u8,width,height,x,y:int}
Native_Fragment :: struct {node,start,end:int,text:string,x,y,w,h:f32,style:Native_Style,image:int}
Native_Document :: struct {
    arena:vmem.Arena,
    nodes:[dynamic]Native_DOM_Node,
    rules:[dynamic]Native_CSS_Rule,
    images:[dynamic]Native_Image,
    canvases:map[int]^Native_Canvas,
    fragments:[dynamic]Native_Fragment,
    variables:map[string]string,
    scripts:[dynamic]string,
    script_nodes:[dynamic]int,
    script_urls:[dynamic]string,
    modules:map[string]^Native_Module,
    imports:map[string]string,
    text:string,
    width,height:f32,
    atlas_width,atlas_height:int,
    revision:u64,
    script:Native_JS,
    initialized:bool,
    media_dark,media_light:bool,
    media_min_width,media_max_width:f32,
}

native_document_init :: proc(doc:^Native_Document) {
    if vmem.arena_init_growing(&doc.arena)!=nil {return}
    context.allocator=vmem.arena_allocator(&doc.arena)
    doc.nodes=make([dynamic]Native_DOM_Node)
    doc.rules=make([dynamic]Native_CSS_Rule)
    doc.images=make([dynamic]Native_Image)
    doc.canvases=make(map[int]^Native_Canvas)
    doc.variables=make(map[string]string)
    doc.scripts=make([dynamic]string)
    doc.script_nodes=make([dynamic]int);doc.script_urls=make([dynamic]string)
    doc.modules=make(map[string]^Native_Module);doc.imports=make(map[string]string)
    append(&doc.nodes,Native_DOM_Node{tag="#document",parent=-1,first=-1,last=-1,next=-1,image=-1,expanded=true})
    doc.initialized=true
}
native_document_destroy :: proc(doc:^Native_Document) {
    if !doc.initialized {return}
    native_js_destroy(&doc.script)
    native_canvas_destroy(doc)
    delete(doc.fragments);delete(doc.text)
    vmem.arena_destroy(&doc.arena)
    doc^={}
}
native_attr :: proc(doc:^Native_Document,node:int,name:string)->string {
    if node<0||node>=len(doc.nodes) {return ""}
    for attribute in doc.nodes[node].attributes {if attribute.name==name {return attribute.value}}
    return ""
}
native_has_attr :: proc(doc:^Native_Document,node:int,name:string)->bool {
    if node<0||node>=len(doc.nodes) {return false}
    for attribute in doc.nodes[node].attributes {if attribute.name==name {return true}}
    return false
}
native_set_attr :: proc(doc:^Native_Document,node:int,name,value:string) {
    if node<0||node>=len(doc.nodes) {return}
    context.allocator=vmem.arena_allocator(&doc.arena)
    for &attribute in doc.nodes[node].attributes {if attribute.name==name {attribute.value=strings.clone(value);doc.revision+=1;return}}
    append(&doc.nodes[node].attributes,Native_Attribute{strings.clone(name),strings.clone(value)});doc.revision+=1
}
native_add_node :: proc(doc:^Native_Document,parent:int,tag,text:string)->int {
    node:=len(doc.nodes)
    append(&doc.nodes,Native_DOM_Node{tag=strings.clone(tag),text=strings.clone(text),parent=parent,first=-1,last=-1,next=-1,image=-1,expanded=true})
    if parent>=0 {
        last:=doc.nodes[parent].last
        if last>=0 {doc.nodes[last].next=node} else {doc.nodes[parent].first=node}
        doc.nodes[parent].last=node
    }
    return node
}
native_resource_path :: proc(view:^Document_View,base,raw_reference:string)->string {
    reference:=strings.trim_space(raw_reference)
    if native_http_url(base)||strings.has_prefix(reference,"//") {return native_url_resolve(base,reference)}
    if reference==""||strings.has_prefix(reference,"#")||strings.contains(reference,"://")||strings.has_prefix(reference,"data:") {return strings.clone(reference)}
    end:=len(reference);if q:=strings.index_byte(reference,'?');q>=0 {end=min(end,q)};if q:=strings.index_byte(reference,'#');q>=0 {end=min(end,q)}
    if end==0 {return strings.clone(base)}
    decoded,ok:=document_url_decode(reference[:end]);if !ok {return ""};defer delete(decoded)
    path:=decoded
    if !strings.has_prefix(path,"/") {path=fmt.tprintf("%s/%s",filepath.dir(base),path)}
    clean,_:=filepath.clean(path)
    return clean
}
native_read_resource :: proc(view:^Document_View,path:string)->(bytes:[]u8,error:string) {
    if strings.has_prefix(path,"data:") {
        comma:=strings.index_byte(path,',');if comma<0 {return nil,"Malformed data URL."}
        if strings.has_suffix(path[:comma],";base64") {data,err:=base64.decode(path[comma+1:]);if err!=nil {return nil,"Malformed base64 asset."};return data,""}
        decoded,ok:=document_url_decode(path[comma+1:]);if !ok {return nil,"Malformed data asset."};return transmute([]u8)decoded,""
    }
    if strings.has_prefix(path,"https://")||strings.has_prefix(path,"http://") {return native_network_read(&view.source,path)}
    if strings.contains(path,"://") {return nil,"This asset URL scheme is not supported."}
    if !view.remote {
        canonical:=file_realpath(strings.clone_to_cstring(path,context.temp_allocator),nil)
        if canonical==nil {return nil,"Could not resolve resource."};defer file_cfree(rawptr(canonical))
        if !document_inside_root(view.source.root,string(canonical)) {return nil,DOCUMENT_OUTSIDE_ROOT}
        result,err:=os.read_entire_file(string(canonical),context.allocator);if err!=nil {return nil,"Could not read resource."};return result,""
    }
    s:=File_SFTP{browser=&view.source.browser,generation=1,io=-1,stderr=-1};defer file_sftp_destroy(&s)
    if !file_sftp_spawn(&s,view.profile) {return nil,strings.clone(s.error)}
    handle,size,directory:=document_remote_open(&s,path,view.source.root);defer delete(handle)
    if directory||handle==""||s.error!="" {return nil,strings.clone(s.error)}
    output:=make([dynamic]u8,0,int(size))
    if !document_remote_bytes(&s,handle,0,size,nil,&output) {delete(output);return nil,strings.clone(s.error)}
    return output[:],""
}
native_document_assets :: proc(view:^Document_View) {
    doc:=&view.native
    context.allocator=vmem.arena_allocator(&doc.arena)
    clear(&doc.scripts);clear(&doc.script_nodes);clear(&doc.script_urls);clear(&doc.rules)
    order:=native_dom_order(doc)
    for node in order {if doc.nodes[node].tag=="script"&&strings.equal_fold(native_attr(doc,node,"type"),"importmap") {native_import_map(view,native_node_text(doc,node))}}
    for i in order {
        node:=doc.nodes[i];reference:="";base:=view.base_path;if base=="" {base=view.resource_path}
        if node.tag=="style" {native_stylesheet(view,native_node_text(doc,i),base);continue}
        if node.tag=="script" {
            if !html_script_type(doc,i)||native_has_attr(doc,i,"nomodule") {continue}
            reference=native_attr(doc,i,"src");source:=native_node_text(doc,i);path:=base
            if reference!="" {
                path=native_resource_path(view,base,reference);bytes,error:=native_read_resource(view,path)
                if error!="" {document_set_script_error(view,fmt.tprintf("Script %s: %s",reference,error));continue};source=string(bytes)
            }
            if strings.equal_fold(native_attr(doc,i,"type"),"module") {
                if reference=="" {path=fmt.aprintf("%s#inline-module-%d",base,i)}
                native_module_prefetch(view,path,source)
            }
            append(&doc.scripts,strings.clone(source));append(&doc.script_nodes,i);append(&doc.script_urls,strings.clone(path));continue
        }
        if node.tag=="link"&&strings.contains(native_attr(doc,i,"rel"),"stylesheet") {reference=native_attr(doc,i,"href")}
        if node.tag=="img" {reference=native_attr(doc,i,"src")}
        bytes:[]u8;path:string;error:string
        if node.tag=="svg" {
            if !native_has_attr(doc,i,"xmlns") {native_set_attr(doc,i,"xmlns","http://www.w3.org/2000/svg")}
            bytes=transmute([]u8)native_dom_html(doc,i,true);path=fmt.aprintf("%s#svg-%d",base,i)
        } else {
            if reference=="" {continue}
            path=native_resource_path(view,base,reference);bytes,error=native_read_resource(view,path)
        }
        if error!="" {if view.loading_error=="" {document_set_script_error(view,fmt.tprintf("Asset %s: %s",reference,error))};continue}
        if node.tag=="link" {native_stylesheet(view,string(bytes),path);continue}
        width,height,channels:c.int
        pixels:=stbi.load_from_memory(raw_data(bytes),c.int(len(bytes)),&width,&height,&channels,4)
        if pixels==nil {
            fallback,fw,fh,decode_error:=media_decode_still(&view.source,bytes)
            if decode_error!="" {if view.loading_error=="" {document_set_script_error(view,fmt.tprintf("Image %s: %s",reference,decode_error))};continue}
            doc.nodes[i].image=len(doc.images);append(&doc.images,Native_Image{path=path,pixels=fallback,width=fw,height=fh});continue
        }
        if width<=0||height<=0||width>16384||height>16384||i64(width)*i64(height)>64*1024*1024 {stbi.image_free(pixels);continue}
        image_copy:=make([]u8,int(width)*int(height)*4);mem.copy(raw_data(image_copy),pixels,len(image_copy));stbi.image_free(pixels)
        doc.nodes[i].image=len(doc.images);append(&doc.images,Native_Image{path=path,pixels=image_copy,width=int(width),height=int(height)})
    }
    if len(doc.images)==0 {return}
    // One document atlas lets text and all image assets share the Vulkan batch.
    atlas_width:=1
    for image in doc.images {atlas_width=max(atlas_width,image.width)}
    atlas_width=min(16384,max(1024,atlas_width))
    x,y,row:=0,0,0
    for &image in doc.images {
        if x+image.width>atlas_width {x=0;y+=row;row=0}
        image.x=x;image.y=y;x+=image.width;row=max(row,image.height)
    }
    atlas_height:=y+row
    if atlas_height>16384 {return}
    pixels:=make([]u8,atlas_width*atlas_height*4)
    for image in doc.images {for line in 0..<image.height {copy(pixels[((image.y+line)*atlas_width+image.x)*4:][:image.width*4],image.pixels[line*image.width*4:][:image.width*4])}}
    renderer_pixels_publish(&view.frame,pixels,atlas_width,atlas_height)
    doc.atlas_width=atlas_width;doc.atlas_height=atlas_height
}

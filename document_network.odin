package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

Native_Network_State :: struct {mutex:sync.Mutex,cookies:map[string]string}
Native_HTTP_Response :: struct {
    bytes:[]u8,
    url,mime,headers,error:string,
    status:int,
    consumed:bool,
    allocator:runtime.Allocator,
}
native_network_init :: proc(source:^Document_Source) {
    if source.network!=nil {return}
    source.network=new(Native_Network_State,os.heap_allocator())
    source.network.cookies=make(map[string]string,os.heap_allocator())
}
native_network_clone :: proc(destination,source:^Document_Source) {
    native_network_init(destination)
    if source==nil||source.network==nil {return}
    sync.mutex_lock(&source.network.mutex);defer sync.mutex_unlock(&source.network.mutex)
    for key,value in source.network.cookies {destination.network.cookies[strings.clone(key,os.heap_allocator())]=strings.clone(value,os.heap_allocator())}
}
native_network_destroy :: proc(source:^Document_Source) {
    state:=source.network;if state==nil {return}
    for key,value in state.cookies {delete(key,os.heap_allocator());delete(value,os.heap_allocator())}
    delete(state.cookies);free(state,os.heap_allocator());source.network=nil
}
native_http_destroy :: proc(response:^Native_HTTP_Response) {
    if response.allocator.procedure!=nil {
        delete(response.bytes,response.allocator);delete(response.url,response.allocator)
        delete(response.mime,response.allocator);delete(response.headers,response.allocator)
    }
    response^={}
}
native_http_header :: proc(headers,name:string)->string {
    result:="";remaining:=headers
    for line in strings.split_lines_iterator(&remaining) {
        if strings.has_prefix(line,"HTTP/") {result="";continue}
        colon:=strings.index_byte(line,':')
        if colon>0&&strings.equal_fold(line[:colon],name) {result=strings.trim_space(line[colon+1:])}
    }
    return result
}
native_cookie_snapshot :: proc(source:^Document_Source)->string {
    native_network_init(source);state:=source.network
    sync.mutex_lock(&state.mutex);defer sync.mutex_unlock(&state.mutex)
    out:=make([dynamic]u8,context.allocator);append(&out,"# Netscape HTTP Cookie File\n")
    for _,line in state.cookies {append(&out,line);append(&out,'\n')}
    return string(out[:])
}
native_cookie_merge :: proc(source:^Document_Source,jar:string) {
    state:=source.network;if state==nil {return}
    sync.mutex_lock(&state.mutex);defer sync.mutex_unlock(&state.mutex)
    remaining:=jar
    for line in strings.split_lines_iterator(&remaining) {
        if line==""||line[0]=='#'&&!strings.has_prefix(line,"#HttpOnly_") {continue}
        fields:=strings.split(line,"\t",context.temp_allocator);if len(fields)<7 {continue}
        key:=fmt.tprintf("%s\t%s\t%s",fields[0],fields[2],fields[5])
        if old,exists:=state.cookies[key];exists {delete(old,os.heap_allocator());state.cookies[key]=strings.clone(line,os.heap_allocator())}
        else {state.cookies[strings.clone(key,os.heap_allocator())]=strings.clone(line,os.heap_allocator())}
    }
}
// The existing curl transport handles HTTP/TLS, redirects and cookies. Loading
// and cancellation stay on workers; no browser or new linked library is used.
native_network_request :: proc(source:^Document_Source,url:string,method:string="GET",body:string="",content_type:string="",headers:string="")->Native_HTTP_Response {
    result:=Native_HTTP_Response{allocator=context.allocator,url=strings.clone(url)}
    if !native_http_url(url) {result.error="Unsupported resource URL.";return result}
    if sync.atomic_load(&source.stopping) {result.error="Cancelled.";return result}
    directory,temp_error:=os.mkdir_temp("","minor-document-http-*",context.allocator)
    if temp_error!=nil {result.error="Could not create the document resource directory.";return result}
    defer os.remove_all(directory)
    path:=fmt.tprintf("%s/body",directory);header_path:=fmt.tprintf("%s/headers",directory);meta_path:=fmt.tprintf("%s/meta",directory)
    cookie_path:=fmt.tprintf("%s/cookies",directory);request_path:=fmt.tprintf("%s/request",directory)
    snapshot:=native_cookie_snapshot(source);defer delete(snapshot)
    if os.write_entire_file(cookie_path,snapshot,{.Read_User,.Write_User})!=nil {result.error="Could not prepare document cookies.";return result}
    meta,meta_error:=os.open(meta_path,{.Write,.Create,.Trunc},{.Read_User,.Write_User})
    if meta_error!=nil {result.error="Could not prepare HTTP response metadata.";return result}
    defer os.close(meta)
    curl:=os.get_env("TERMINAL_PLUS_CURL",context.temp_allocator);if curl=="" {curl="curl"}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,curl,"--disable","--silent","--show-error","--location","--max-redirs","8",
        "--proto","=http,https","--proto-redir","=http,https","--connect-timeout","10","--max-time","30",
        "--max-filesize","33554432","--cookie",cookie_path,"--cookie-jar",cookie_path,
        "--dump-header",header_path,"--write-out","%{http_code}\n%{content_type}\n%{url_effective}\n","--output",path)
    if method=="HEAD" {append(&command,"--head")}
    else if method!="GET" {
        if strings.contains_any(method,"\r\n \x00") {result.error="Invalid HTTP method.";return result}
        if os.write_entire_file(request_path,body,{.Read_User,.Write_User})!=nil {result.error="Could not prepare HTTP request data.";return result}
        // --data-binary uses normal POST redirect rules; custom methods are explicit.
        if method!="POST" {append(&command,"--request",method)}
        append(&command,"--data-binary",fmt.tprintf("@%s",request_path))
        if content_type!="" {append(&command,"--header",fmt.tprintf("Content-Type: %s",content_type))}
    }
    remaining:=headers
    for line in strings.split_lines_iterator(&remaining) {if strings.trim_space(line)!="" {append(&command,"--header",line)}}
    append(&command,"--",native_url_without_fragment(url))
    child,start_error:=os.process_start({command=command[:],stdout=meta})
    if start_error!=nil {result.error="Could not start the existing HTTP resource transport.";return result}
    for {
        if sync.atomic_load(&source.stopping) {_=os.process_kill(child);_,_=os.process_wait(child,2*time.Second);result.error="Cancelled.";return result}
        if info,stat_error:=os.stat(path,context.temp_allocator);stat_error==nil&&info.size>32*1024*1024 {
            _=os.process_kill(child);_,_=os.process_wait(child,2*time.Second);result.error="Document resource exceeds 32 MiB.";return result
        }
        state,wait_error:=os.process_wait(child,50*time.Millisecond)
        if wait_error==.Timeout {continue}
        if wait_error!=nil||!state.exited||state.exit_code!=0 {result.error="Could not download the document resource.";return result}
        break
    }
    result.bytes,_=os.read_entire_file(path,context.allocator)
    header_bytes,_:=os.read_entire_file(header_path,context.allocator);result.headers=string(header_bytes)
    metadata,_:=os.read_entire_file(meta_path,context.temp_allocator)
    fields:=strings.split(string(metadata),"\n",context.temp_allocator)
    if len(fields)>=3 {
        result.status,_=strconv.parse_int(fields[0]);result.mime=strings.clone(fields[1])
        delete(result.url);result.url=strings.clone(fields[2])
    }
    jar,jar_error:=os.read_entire_file(cookie_path,context.temp_allocator)
    if jar_error==nil {native_cookie_merge(source,string(jar))}
    if result.status==0 {result.error="The HTTP server returned no response."}
    return result
}
native_network_read :: proc(source:^Document_Source,url:string)->([]u8,string) {
    response:=native_network_request(source,url)
    if response.error!="" {error:=response.error;native_http_destroy(&response);return nil,error}
    if response.status>=400 {native_http_destroy(&response);return nil,"The document resource server returned an HTTP error."}
    bytes:=response.bytes;response.bytes=nil;native_http_destroy(&response);return bytes,""
}

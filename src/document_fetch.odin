package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

Native_Fetch_Job :: struct {
    view:^Document_View,
    worker:^thread.Thread,
    url,method,body,content_type,headers:string,
    promise:Native_JS_Value,
    response:Native_HTTP_Response,
    done:bool,
}
// Scripts must not override transport framing, credentials, or browser-owned
// origin metadata. These headers are supplied by the transport itself.
native_fetch_forbidden_header :: proc(name:string)->bool {
    lower:=strings.to_lower(name,context.temp_allocator)
    if strings.has_prefix(lower,"proxy-")||strings.has_prefix(lower,"sec-") {return true}
    switch lower {
    case "accept-charset","accept-encoding","access-control-request-headers","access-control-request-method",
         "connection","content-length","cookie","cookie2","date","dnt","expect","host","keep-alive",
         "origin","referer","set-cookie","te","trailer","transfer-encoding","upgrade","via":return true
    }
    return false
}
native_fetch_worker :: proc(worker:^thread.Thread) {
    job:=cast(^Native_Fetch_Job)worker.data
    defer {sync.atomic_store(&job.done,true);terminal_wake()}
    if native_http_url(job.url) {
        job.response=native_network_request(&job.view.source,job.url,job.method,job.body,job.content_type,job.headers)
        origin:=native_url_origin(job.view.resource_path);defer delete(origin)
        // Redirects can change the response origin even for a same-origin request.
        destination:=native_url_origin(job.response.url);defer delete(destination)
        if origin!=destination {
            allowed:=native_http_header(job.response.headers,"Access-Control-Allow-Origin")
            if allowed!="*"&&allowed!=origin {job.response.error="The response does not allow this document origin (CORS)."}
        }
    } else if job.method=="GET" {
        bytes,error:=native_read_resource(job.view,job.url)
        job.response=Native_HTTP_Response{bytes=bytes,error=error,url=strings.clone(job.url),status=200,allocator=context.allocator,mime=strings.clone(document_mime(job.url))}
    } else {job.response=Native_HTTP_Response{error="Local document resources support GET requests."}}
}
native_fetch_start :: proc(view:^Document_View,args:[]Native_JS_Value)->Native_JS_Value {
    js:=&view.native.script;promise:=native_js_promise(js)
    if len(args)==0 {native_js_promise_reject(js,promise,native_js_string(js,"fetch requires a URL."));return promise}
    if len(view.fetches)>=32 {native_js_promise_reject(js,promise,native_js_string(js,"Too many pending document requests."));return promise}
    base:=view.base_path;if base=="" {base=view.resource_path}
    reference:=native_js_value_text(args[0]);url:=native_resource_path(view,base,reference);defer delete(url)
    job:=new(Native_Fetch_Job,os.heap_allocator());job.view=view;job.promise=promise
    job.url=strings.clone(url,os.heap_allocator());job.method=strings.clone("GET",os.heap_allocator())
    if len(args)>1&&args[1].reference!=nil {
        options:=args[1].reference.properties
        if method,exists:=options["method"];exists {delete(job.method,os.heap_allocator());job.method=strings.to_upper(native_js_value_text(method),os.heap_allocator())}
        if body,exists:=options["body"];exists {job.body=strings.clone(native_js_value_text(body),os.heap_allocator())}
        if headers,exists:=options["headers"];exists&&headers.reference!=nil {
            out:=make([dynamic]u8,context.temp_allocator)
            for key,value in headers.reference.properties {
                text:=native_js_value_text(value)
                if !native_http_token(key)||native_fetch_forbidden_header(key)||strings.contains_any(text,"\r\n\x00") {continue}
                append(&out,fmt.tprintf("%s: %s\r\n",key,text))
                if strings.equal_fold(key,"content-type") {delete(job.content_type,os.heap_allocator());job.content_type=strings.clone(text,os.heap_allocator())}
            }
            job.headers=strings.clone(string(out[:]),os.heap_allocator())
        }
    }
    if native_http_url(job.url) {
        origin:=native_url_origin(view.resource_path)
        headers:=fmt.aprintf("%sOrigin: %s\r\n",job.headers,origin)
        delete(origin);delete(job.headers,os.heap_allocator());job.headers=strings.clone(headers,os.heap_allocator());delete(headers)
    }
    if !native_http_token(job.method)||job.method=="CONNECT"||job.method=="TRACE"||job.method=="TRACK" {
        native_js_promise_reject(js,promise,native_js_string(js,"Invalid or forbidden HTTP method."));native_fetch_free(job);return promise
    }
    // Initialize on the script thread before concurrent fetch workers can use it.
    native_network_init(&view.source)
    job.worker=thread.create(native_fetch_worker)
    if job.worker==nil {native_js_promise_reject(js,promise,native_js_string(js,"Could not start the document request."));native_fetch_free(job);return promise}
    append(&view.fetches,job);job.worker.data=job;thread.start(job.worker)
    return promise
}
native_fetch_free :: proc(job:^Native_Fetch_Job) {
    if job.worker!=nil {thread.join(job.worker);thread.destroy(job.worker)}
    native_http_destroy(&job.response)
    delete(job.url,os.heap_allocator());delete(job.method,os.heap_allocator());delete(job.body,os.heap_allocator());delete(job.content_type,os.heap_allocator());delete(job.headers,os.heap_allocator())
    free(job,os.heap_allocator())
}
native_fetch_poll :: proc(view:^Document_View) {
    for i:=len(view.fetches)-1;i>=0;i-=1 {
        job:=view.fetches[i];if !sync.atomic_load(&job.done) {continue}
        if job.response.error!="" {native_js_promise_reject(&view.native.script,job.promise,native_js_string(&view.native.script,job.response.error))}
        else {
            index:=len(view.responses);append(&view.responses,job.response);job.response={}
            native_js_promise_resolve(&view.native.script,job.promise,native_dom_object(4000000+index))
        }
        ordered_remove(&view.fetches,i);native_fetch_free(job)
    }
}
native_fetch_destroy :: proc(view:^Document_View) {
    for job in view.fetches {native_fetch_free(job)}
    for &response in view.responses {native_http_destroy(&response)}
    delete(view.fetches);delete(view.responses)
}
native_response_get :: proc(view:^Document_View,index:int,name:string)->Native_JS_Value {
    if index<0||index>=len(view.responses) {return {}}
    response:=&view.responses[index]
    switch name {
    case "status":return native_js_number(f64(response.status))
    case "ok":return native_js_bool(response.status>=200&&response.status<300)
    case "url":return native_dom_text(response.url)
    case "statusText":return native_dom_text("")
    case "headers":return native_dom_object(5000000+index)
    case "bodyUsed":return native_js_bool(response.consumed)
    case "type":return native_dom_text("basic")
    }
    return {}
}
native_response_call :: proc(view:^Document_View,index:int,name:string,args:[]Native_JS_Value)->Native_JS_Value {
    js:=&view.native.script
    if index<0||index>=len(view.responses) {return {}}
    response:=&view.responses[index]
    promise:=native_js_promise(js)
    if response.consumed {native_js_promise_reject(js,promise,native_js_string(js,"The response body has already been consumed."));return promise}
    response.consumed=true
    if name=="text" {native_js_promise_resolve(js,promise,native_js_string(js,string(response.bytes)));return promise}
    if name=="json" {
        value:json.Value
        if error:=json.unmarshal(response.bytes,&value,allocator=native_js_allocator(js));error!=nil {native_js_promise_reject(js,promise,native_js_string(js,"The response is not valid JSON."))}
        else {native_js_promise_resolve(js,promise,native_js_json_read(js,value))}
        return promise
    }
    native_js_promise_reject(js,promise,native_js_string(js,"Unsupported response body reader."));return promise
}

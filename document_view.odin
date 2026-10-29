#+build linux
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import atomic "core:sync"
import "core:thread"
import "core:time"
import vmem "core:mem/virtual"
import glfw "vendor:glfw"

// Layout, DOM, scripts and interaction are native Odin; glyphs and images are
// submitted to the application's Vulkan renderer at physical monitor scale.
Native_Document_Timer :: struct {id:int,callback:Native_JS_Value,args:[]Native_JS_Value,began:time.Tick,delay:time.Duration,repeat:bool}
Document_View :: struct {
    worker:^thread.Thread,
    source:Document_Source,
    frame:Renderer_Pixels,
    native:Native_Document,
    owner:^App,
    script_index:int,
    scripts_ready:bool,
    current_script_url:string,
    current_script_node:int,
    hovered_node:int,
    select_node,select_scroll:int,
    path,resource_path,error,control_error_seen,loading_error,pending_path:string,
    request_method,request_body,request_content_type,pending_method,pending_body,pending_content_type,pending_fragment:string,
    source_bytes:[]u8,
    base_path:string,
    source_published:bool,
    fetches:[dynamic]^Native_Fetch_Job,
    responses:[dynamic]Native_HTTP_Response,
    params:[dynamic]^Native_Search_Params,
    urls:[dynamic]^Native_URL_Value,
    profile:Device_Profile,
    kind:Document_Kind,
    remote,done,finished,cancelled,source_mode,ready_seen,dark_mode:bool,
    frame_seen,layout_revision:u64,
    zoom,layout_zoom:f64,
    scroll,viewport_height:f32,
    buttons:int,
    find_open,find_focused:bool,
    last_click:time.Tick,
    last_button,clicks:int,
    last_x,last_y:f32,
    find_text:[dynamic]u8,
    find_cursor,find_anchor:int,
    find_selecting,find_all:bool,
    selection_anchor,selection_end,focused_node,caret:int,
    selecting:bool,
    window_listeners:[dynamic]Native_Listener,
    current_event:Native_JS_Value,
    event_key,event_code:string,
    event_shift,event_ctrl,event_alt,event_meta,event_immediate:bool,
    ready_state:string,
    event_cancelled,event_stopped:bool,
    timer_sequence:int,
    timers:[dynamic]Native_Document_Timer,
}
document_set_error :: proc(view:^Document_View,message:string) {
    delete(view.error);view.error=strings.clone(message,os.heap_allocator())
}
native_source_prepare :: proc(view:^Document_View)->string {
    source:=&view.source
    source.remote=view.remote;source.profile=profile_clone(view.profile);source.browser.generation=1
    actual:=view.path
    if native_http_url(actual) {
        view.remote=false;source.remote=false;view.resource_path=strings.clone(actual)
        source.root=native_url_origin(actual);return ""
    }
    if view.remote {
        if !explorer_remote_ready(view.profile) {return "Finish SSH login in the terminal before opening this document."}
        s:=File_SFTP{browser=&source.browser,generation=1,io=-1,stderr=-1};defer file_sftp_destroy(&s)
        if !file_sftp_spawn(&s,view.profile)||!document_sftp_init(&s) {return strings.clone(s.error)}
        resolved:=document_remote_resolve(&s,actual)
        if resolved==""||s.error!="" {delete(resolved);return strings.clone(s.error)}
        view.resource_path=resolved;actual=resolved
    } else {
        filename:=actual
        if _,stat_error:=os.stat(filename,context.temp_allocator);stat_error!=nil {
            filename=native_url_without_fragment(filename);if query:=strings.index_byte(filename,'?');query>=0 {filename=filename[:query]}
        }
        canonical:=file_realpath(strings.clone_to_cstring(filename,context.temp_allocator),nil)
        if canonical==nil {return "Could not resolve the document path."}
        resolved:=strings.clone(string(canonical));file_cfree(rawptr(canonical));view.resource_path=resolved;actual=resolved
    }
    root:=filepath.dir(actual)
    if !view.remote {
        candidate:=root
        for {
            if _,error:=os.stat(fmt.tprintf("%s/.git",candidate),context.temp_allocator);error==nil {root=candidate;break}
            parent:=filepath.dir(candidate);if parent==candidate {break};candidate=parent
        }
    }
    source.root=strings.clone(root)
    return ""
}
document_view_worker :: proc(worker:^thread.Thread) {
    view:=cast(^Document_View)worker.data
    defer {atomic.atomic_store(&view.done,true);atomic.atomic_store(&view.finished,true);glfw.PostEmptyEvent()}
    if error:=native_source_prepare(view);error!="" {document_set_error(view,error);return}
    bytes:[]u8;error:string;content_type:string
    if native_http_url(view.resource_path) {
        response:=native_network_request(&view.source,view.resource_path,view.request_method,view.request_body,view.request_content_type)
        bytes=response.bytes;response.bytes=nil;error=response.error
        content_type=strings.clone(response.mime,context.temp_allocator)
        if error=="" {delete(view.resource_path);view.resource_path=strings.clone(response.url)}
        native_http_destroy(&response)
    } else {bytes,error=native_read_resource(view,view.resource_path)}
    if error!="" {document_set_error(view,error);return};defer delete(bytes)
    view.source_bytes=make([]u8,len(bytes),os.heap_allocator());copy(view.source_bytes,bytes)
    if atomic.atomic_load(&view.cancelled) {return}
    view.base_path=strings.clone(view.resource_path,os.heap_allocator())
    native_document_init(&view.native)
    if !view.native.initialized {document_set_error(view,"Could not allocate native document storage.");return}
    context.allocator=vmem.arena_allocator(&view.native.arena)
    html:=native_decode_html(bytes,content_type)
    if view.kind==.Markdown {
        rendered,err:=document_markdown(bytes,filepath.base(view.path),"")
        if err!="" {view.error=strings.clone(err,os.heap_allocator());return}
        html=string(rendered)
    }
    native_parse_html(&view.native,html)
    if base:=native_query(&view.native,"base[href]");base>=0 {
        resolved:=native_url_resolve(view.resource_path,native_attr(&view.native,base,"href"))
        delete(view.base_path);view.base_path=strings.clone(resolved,os.heap_allocator());delete(resolved)
    }
    native_js_init(&view.native.script,Native_JS_Host{data=view,get=native_dom_get,set=native_dom_set,call=native_dom_call})
    native_document_assets(view)
    native_document_anchors(&view.native)
    view.native.revision+=1
}
native_document_anchors :: proc(doc:^Native_Document) {
    used:=make(map[string]bool,context.temp_allocator)
    for n,i in doc.nodes {
        if len(n.tag)!=2||n.tag[0]!='h'||n.tag[1]<'1'||n.tag[1]>'6' {continue}
        existing:=native_attr(doc,i,"id");if existing!="" {used[existing]=true;continue}
        text:=strings.to_lower(strings.trim_space(native_node_text(doc,i)),context.temp_allocator)
        slug:=make([dynamic]u8,context.temp_allocator)
        for ch in text {
            if ch==' '||ch=='\t'||ch=='\n' {if len(slug)>0&&slug[len(slug)-1]!='-' {append(&slug,'-')}}
            else if ch>127||ch>='a'&&ch<='z'||ch>='0'&&ch<='9'||ch=='_'||ch=='-' {append(&slug,string_from_rune(ch))}
        }
        base:=strings.trim(string(slug[:]),"-");id:=base;number:=0
        for used[id] {number+=1;id=fmt.tprintf("%s-%d",base,number)}
        native_set_attr(doc,i,"id",id);used[id]=true
    }
}
document_view_open :: proc(path:string,remote:bool,profile:Device_Profile,method:string="GET",body:string="",content_type:string="",previous:^Document_Source=nil)->^Document_View {
    view:=new(Document_View)
    view.path=strings.clone(path);view.remote=remote&&!native_http_url(path);view.kind=document_kind(path);view.profile=profile_clone(profile)
    if view.kind==.None {view.kind=.HTML}
    view.request_method=strings.clone(method);view.request_body=strings.clone(body);view.request_content_type=strings.clone(content_type)
    native_network_clone(&view.source,previous)
    view.zoom=1;view.focused_node=-1;view.hovered_node=-1;view.select_node=-1;view.timers=make([dynamic]Native_Document_Timer,os.heap_allocator())
    view.window_listeners=make([dynamic]Native_Listener,os.heap_allocator());view.ready_state="loading"
    view.fetches=make([dynamic]^Native_Fetch_Job,os.heap_allocator());view.responses=make([dynamic]Native_HTTP_Response,os.heap_allocator())
    renderer_pixels_init(&view.frame)
    view.worker=thread.create(document_view_worker)
    if view.worker==nil {document_set_error(view,"Could not start the native document worker.");view.done=true;view.finished=true;return view}
    view.worker.data=view;thread.start(view.worker)
    return view
}
document_view_destroy :: proc(view:^Document_View) {
    if view==nil {return}
    atomic.atomic_store(&view.cancelled,true);document_source_cancel(&view.source)
    if view.worker!=nil {thread.join(view.worker);thread.destroy(view.worker)}
    native_fetch_destroy(view)
    native_document_destroy(&view.native)
    renderer_pixels_destroy(&view.frame)
    document_source_close(&view.source)
    delete(view.path);delete(view.resource_path);delete(view.base_path);delete(view.error);delete(view.control_error_seen);delete(view.loading_error);delete(view.pending_path);delete(view.find_text);delete(view.timers)
    delete(view.source_bytes);delete(view.request_method);delete(view.request_body);delete(view.request_content_type)
    delete(view.pending_method);delete(view.pending_body);delete(view.pending_content_type);delete(view.pending_fragment);delete(view.window_listeners)
    delete(view.profile.name);delete(view.profile.target);free(view)
}
document_view_toggle_dark :: proc(a:^App,view:^Document_View) {
    if view==nil||view.kind!=.HTML {return}
    view.dark_mode=!view.dark_mode;if atomic.atomic_load(&view.done) {view.native.revision+=1};a.dirty=true
}
document_view_update :: proc(a:^App) {
    for tab in a.tabs {
        e:=&tab.explorer;view:=e.document
        if view==nil {continue}
        if !e.preview_open {document_view_destroy(view);e.document=nil;a.dirty=true;continue}
        if !atomic.atomic_load(&view.done) {continue}
        if !view.ready_seen {view.ready_seen=true;view.control_error_seen=view.loading_error;view.loading_error="";a.dirty=true}
        if !view.source_published {
            view.source_published=true
            explorer_result_destroy(&e.preview)
            e.preview.path=strings.clone(view.path);e.preview.preview=make([]u8,len(view.source_bytes));copy(e.preview.preview,view.source_bytes)
            clear(&e.lines);append(&e.lines,0)
            for byte,index in e.preview.preview {if byte==10&&index+1<len(e.preview.preview) {append(&e.lines,index+1)}}
            e.waiting=false;e.binary=false
            fragment:=native_url_fragment(view.path)
            if fragment!="" {delete(view.pending_fragment);view.pending_fragment=strings.clone(fragment)}
        }
        view.owner=a
        if !view.scripts_ready&&view.error=="" {
            box:=explorer_preview_layout(a);view.viewport_height=max(1,box.h-98)
            if view.native.width==0 {native_document_layout(a,view,box.w)}
            began:=time.tick_now();count:=0
            for view.script_index<len(view.native.scripts)&&count<16 {
                index:=view.script_index;script:=view.native.scripts[index];view.script_index+=1;count+=1
                view.current_script_url=view.native.script_urls[index];view.current_script_node=view.native.script_nodes[index]
                err:string
                if strings.equal_fold(native_attr(&view.native,view.current_script_node,"type"),"module") {_,err=native_module_evaluate(view,view.current_script_url)}
                else {_,err=native_js_evaluate(&view.native.script,script)}
                if err!="" {document_set_script_error(view,err)}
                if jobs_error:=native_js_run_jobs(&view.native.script);jobs_error!="" {document_set_script_error(view,jobs_error)}
                if time.tick_diff(began,time.tick_now())>=8*time.Millisecond {break}
            }
            if view.script_index==len(view.native.scripts) {
                view.scripts_ready=true;view.ready_state="interactive"
                native_dispatch_event(view,0,"DOMContentLoaded");view.ready_state="complete";native_dispatch_event(view,-2,"load")
            }
            a.dirty=true
        }
        native_fetch_poll(view)
        if err:=native_js_run_jobs(&view.native.script);err!="" {document_set_script_error(view,err)}
        if view.native.revision!=view.layout_revision {a.dirty=true}
        if view.scripts_ready&&view.pending_fragment!="" {
            box:=explorer_preview_layout(a);native_document_layout(a,view,box.w)
            id,valid:=document_url_decode(view.pending_fragment)
            if valid {for _,node in view.native.nodes {if native_attr(&view.native,node,"id")==id {view.scroll=clamp(view.native.nodes[node].y,0,max(0,view.native.height-view.viewport_height));break}};delete(id)}
            delete(view.pending_fragment);view.pending_fragment="";a.dirty=true
        }
        now:=time.tick_now()
        fired:=0
        for i:=len(view.timers)-1;i>=0&&fired<64;i-=1 {
            if i>=len(view.timers) {continue}
            timer:=view.timers[i]
            if time.tick_diff(timer.began,now)<timer.delay {continue}
            if timer.repeat {view.timers[i].began=now} else {ordered_remove(&view.timers,i)}
            if timer.callback.kind==.String {_,error:=native_js_evaluate(&view.native.script,timer.callback.text);if error!="" {document_set_script_error(view,error)}}
            else {_,error:=native_js_invoke(&view.native.script,timer.callback,timer.args,-2);if error!="" {document_set_script_error(view,error)}}
            fired+=1;a.dirty=true
        }
        if view.pending_path!="" {
            path:=strings.clone(view.pending_path);dark:=view.dark_mode;zoom:=view.zoom
            method:=view.pending_method;if method=="" {method="GET"}
            fresh:=document_view_open(path,view.remote,view.profile,method,view.pending_body,view.pending_content_type,&view.source)
            fresh.dark_mode=dark;fresh.zoom=zoom
            fresh.pending_fragment=strings.clone(view.pending_fragment)
            e.document=fresh
            if tab.document_path!="" {delete(tab.document_path);tab.document_path=strings.clone(path);session_touch(a)}
            if !native_http_url(path) {explorer_request(&e.browser,path,.Preview)}
            document_view_destroy(view);delete(path);a.dirty=true
        }
    }
    for index:=len(a.tabs)-1;index>=0;index-=1 {tab:=a.tabs[index];if tab.document_path!=""&&tab.explorer.loaded&&!tab.explorer.preview_open {app_close_tab(a,index)}}
}
document_view_render_status :: proc(a:^App,view:^Document_View,box:Preview_Layout) {
    if !atomic.atomic_load(&view.done) {ui_text(a,"Preparing native document…",box.x+20,box.y+88,14,MUTED);return}
    if view.error!="" {ui_fit_text(a,view.error,box.x+20,box.y+88,14,box.w-40,Color{0.96,0.36,0.36,1});return}
    native_document_render(a,view,box)
    native_select_render(a,view)
    document_find_render(a,view,box)
}

document_view_wait_delay :: proc(a:^App)->f64 {
    wait:=f64(60);now:=time.tick_now()
    for tab in a.tabs {view:=tab.explorer.document;if view==nil||!atomic.atomic_load(&view.done) {continue};if !view.scripts_ready {wait=min(wait,0.001)};for timer in view.timers {wait=min(wait,max(0.001,time.duration_seconds(timer.delay-time.tick_diff(timer.began,now))))}}
    return wait
}

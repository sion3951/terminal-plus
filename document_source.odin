#+build linux
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"

foreign import document_md4c "system:md4c-html"
foreign document_md4c {
    @(link_name="md_html") document_md_html :: proc(input:[^]u8,size:c.uint,output:proc "c" ([^]u8,c.uint,rawptr),user:rawptr,parser_flags,renderer_flags:c.uint)->c.int ---
}

Document_Kind :: enum {None,Markdown,HTML}
Document_Source :: struct {
    stopping:bool,
    // The existing SFTP cancellation protocol also cancels stalled asset reads.
    browser:File_Browser,
    profile:Device_Profile,
    remote:bool,
    listener:net.TCP_Socket,
    listening:bool,
    workers:[4]^thread.Thread,
    token,host,root:string,
    network:^Native_Network_State,
}
Document_HTTP :: struct {source:^Document_Source,fd:posix.FD,progress:time.Tick}

document_kind :: proc(path:string)->Document_Kind {
    resource:=native_url_without_fragment(path);if query:=strings.index_byte(resource,'?');query>=0 {resource=resource[:query]}
    ext:=strings.to_lower(filepath.ext(resource),context.temp_allocator)
    switch ext {
    case ".md",".markdown",".mdown",".mkd",".mkdn",".mdwn":return .Markdown
    case ".html",".htm",".xhtml":return .HTML
    }
    return .None
}
document_source_cancel :: proc(source:^Document_Source) {
    sync.atomic_store(&source.stopping,true)
    sync.mutex_lock(&source.browser.mutex)
    source.browser.stopping=true
    sync.mutex_unlock(&source.browser.mutex)
}
document_source_close :: proc(source:^Document_Source) {
    document_source_cancel(source)
    for worker in source.workers {if worker!=nil {thread.join(worker);thread.destroy(worker)}}
    if source.listening {net.close(source.listener)}
    native_network_destroy(source)
    delete(source.profile.name);delete(source.profile.target);delete(source.token);delete(source.host);delete(source.root)
    source^={}
}

// URL paths are byte escaped, so spaces, Unicode, '#', '?' and '%' in actual
// filenames remain filenames rather than changing URL structure.
document_url_path :: proc(path:string)->string {
    output:=make([dynamic]u8,0,len(path)+32)
    digits:="0123456789ABCDEF"
    for byte in transmute([]u8)path {
        if byte>='a'&&byte<='z'||byte>='A'&&byte<='Z'||byte>='0'&&byte<='9'||byte=='-'||byte=='_'||byte=='.'||byte=='~'||byte=='/' {
            append(&output,byte)
        } else {append(&output,'%',digits[byte>>4],digits[byte&15])}
    }
    return string(output[:])
}
document_html_attribute :: proc(text:string)->string {
    output:=make([dynamic]u8,0,len(text)+32)
    for byte in transmute([]u8)text {
        switch byte {
        case '&':append(&output,"&amp;")
        case '"':append(&output,"&quot;")
        case '<':append(&output,"&lt;")
        case '>':append(&output,"&gt;")
        case:append(&output,byte)
        }
    }
    return string(output[:])
}
document_markdown_output :: proc "c" (bytes:[^]u8,size:c.uint,user:rawptr) {
    context=runtime.default_context()
    output:=cast(^[dynamic]u8)user
    append(output,..bytes[:int(size)])
}
document_append :: proc(output:^[dynamic]u8,parts:..string) {for part in parts {append(output,part)}}
DOCUMENT_MARKDOWN_STYLE :: `
@font-face{font-family:Inter;src:url('/.minor-document/font/Inter-Regular.ttf') format('truetype');font-style:normal;font-weight:400;font-display:swap}
:root{color-scheme:dark;--bg:#0a0a0a;--fg:#d9d9d9;--muted:#a3a3a3;--line:#262626;--accent:#e5e5e5}
*{box-sizing:border-box}html{background:var(--bg);color:var(--fg);font:16px/1.65 Inter,system-ui,sans-serif;scroll-behavior:auto}
body{margin:0}main{max-width:920px;margin:0 auto;padding:28px 36px 72px;overflow-wrap:anywhere}
h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.6em 0 .65em;font-weight:650;scroll-margin-top:24px}h1{font-size:2.1em}h2{font-size:1.65em}h3{font-size:1.3em}h1,h2{padding-bottom:.28em;border-bottom:1px solid var(--line)}
h1:first-child,h2:first-child{margin-top:0}p,ul,ol,pre,blockquote,table,dl{margin:.85em 0}li+li{margin-top:.2em}li>p{margin:.45em 0}.task-list-item{list-style:none}li input[type=checkbox]{accent-color:var(--accent);margin-right:.5em}.task-list-item>input[type=checkbox]{margin-left:-1.3em}
a{color:var(--accent);text-decoration:underline;text-underline-offset:3px}a:hover{color:#fff}a img{border:0}
img,video,svg{max-width:100%;height:auto}iframe{max-width:100%}blockquote{border-left:3px solid var(--accent);color:var(--muted);padding:.1em 1.15em;margin-left:0;margin-right:0}
code,kbd,samp,pre{font:14px/1.6 ui-monospace,'Liberation Mono',monospace}code,kbd{padding:.15em .35em;background:#1c1c1c;border-radius:5px}pre{padding:16px 18px;background:#111;border:1px solid var(--line);border-radius:10px;overflow:auto;overflow-wrap:normal}pre code{padding:0;background:none;border-radius:0}
table{display:block;max-width:100%;overflow:auto;border-collapse:collapse}th,td{padding:8px 14px;border:1px solid var(--line)}th{font-weight:650;background:#212121}tr:nth-child(even){background:#0a0a0a}
hr{border:0;border-top:1px solid var(--line);margin:1.7em 0}details{padding:10px 14px;border:1px solid var(--line);border-radius:6px}summary{cursor:pointer;font-weight:600}mark{background:#665017;color:#fff}del{color:var(--muted)}
.markdown-alert{border-left:3px solid var(--accent);padding:.1em 1.15em;margin:1em 0}.markdown-alert-title{font-weight:650;color:var(--accent)}.footnotes{border-top:1px solid var(--line);margin-top:2em;font-size:.9em}
@media(max-width:600px){main{padding:20px 18px 48px}html{font-size:15px}}@media print{:root{color-scheme:light;--bg:white;--fg:black;--muted:#444;--line:#aaa;--accent:#333}main{max-width:none}}
`
document_markdown :: proc(bytes:[]u8,title,base:string)->(html:[]u8,error:string) {
    if u64(len(bytes))>0xffffffff {return nil,strings.clone("Markdown exceeds the parser's 4 GiB input range.")}
    escaped_title:=document_html_attribute(title);defer delete(escaped_title)
    escaped_base:=document_html_attribute(base);defer delete(escaped_base)
    output:=make([dynamic]u8,0,len(bytes)+4096)
    document_append(&output,"<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>",escaped_title,"</title>")
    if base!="" {document_append(&output,"<base href=\"",escaped_base,"\">")}
    document_append(&output,"<style>",DOCUMENT_MARKDOWN_STYLE,"</style></head><body><main>")
    // CommonMark plus GitHub tables, strike-through, autolinks, tasks,
    // admonitions and footnotes. Raw HTML is preserved for the native document renderer.
    FLAGS:c.uint=0x4|0x8|0x100|0x200|0x400|0x800|0x80000|0x100000
    if document_md_html(raw_data(bytes),c.uint(len(bytes)),document_markdown_output,&output,FLAGS,0x4)!=0 {
        delete(output);return nil,strings.clone("Markdown parser could not render this document.")
    }
    append(&output,"</main></body></html>")
    return output[:],""
}

document_prepare :: proc(source:^Document_Source,path:string,remote:bool,profile:Device_Profile,workdir:string)->(url:string,error:string) {
    if sync.atomic_load(&source.stopping) {return "",strings.clone("Cancelled.")}
    source.remote=remote
    source.profile.name=strings.clone(profile.name);source.profile.target=strings.clone(profile.target);source.profile.port=profile.port
    source.browser.generation=1
    actual:=path
    resolved:string;defer delete(resolved)
    if remote {
        if !explorer_remote_ready(profile) {return "",strings.clone("Finish SSH login in the terminal before opening this document.")}
        if !strings.has_prefix(path,"/") {return "",strings.clone("Remote document path must be absolute.")}
        s:=File_SFTP{browser=&source.browser,generation=1,io= -1,stderr= -1};defer file_sftp_destroy(&s)
        if !file_sftp_spawn(&s,profile)||!document_sftp_init(&s) {return "",strings.clone(s.error)}
        resolved=document_remote_resolve(&s,path)
        if s.error!=""||resolved=="" {return "",strings.clone(s.error)}
        actual=resolved
    } else {
        canonical:=file_realpath(strings.clone_to_cstring(path,context.temp_allocator),nil)
        if canonical==nil {return "",strings.clone("Could not resolve the document path.")}
        resolved=strings.clone(string(canonical));file_cfree(rawptr(canonical));actual=resolved
        info,stat_error:=os.stat(actual,context.temp_allocator)
        if stat_error!=nil||info.type!=.Regular {return "",strings.clone("Could not read the selected document.")}
    }
    root,_:=filepath.clean(filepath.dir(actual),context.temp_allocator)
    if !remote {
        candidate:=root
        for {
            _,git_error:=os.stat(fmt.tprintf("%s/.git",candidate),context.temp_allocator)
            if git_error==nil {root=candidate;break}
            parent,_:=filepath.clean(filepath.dir(candidate),context.temp_allocator)
            if parent==candidate {break};candidate=parent
        }
    }
    source.root=strings.clone(root)
    listener,listen_error:=net.listen_tcp({address=net.IP4_Loopback,port=0},32)
    if listen_error!=nil {return "",strings.clone("Could not start the private document resource channel.")}
    source.listener=listener;source.listening=true
    endpoint,endpoint_error:=net.bound_endpoint(listener)
    if endpoint_error!=nil {return "",strings.clone("Could not discover the document resource port.")}
    net.set_blocking(listener,false)
    source.token=session_new_id()
    source.host=fmt.aprintf("127.0.0.1:%d",endpoint.port)
    for &worker in source.workers {
        worker=thread.create(document_source_server)
        if worker==nil {document_source_cancel(source);return "",strings.clone("Could not start document resource workers.")}
        worker.data=source;thread.start(worker)
    }
    relative:=actual[len(root):]
    if !strings.has_prefix(relative,"/") {relative=fmt.tprintf("/%s",relative)}
    escaped:=document_url_path(relative);defer delete(escaped)
    return fmt.aprintf("http://%s/.minor-document/%s%s",source.host,source.token,escaped),""
}

document_source_server :: proc(worker:^thread.Thread) {
    source:=cast(^Document_Source)worker.data
    for !sync.atomic_load(&source.stopping) {
        fds:=[1]posix.pollfd{{fd=posix.FD(source.listener),events={.IN}}}
        if posix.poll(raw_data(fds[:]),1,100)<=0 {continue}
        client,_,error:=net.accept_tcp(source.listener)
        if error!=nil {continue}
        net.set_blocking(client,false)
        http:=Document_HTTP{source=source,fd=posix.FD(client),progress=time.tick_now()}
        document_http_request(&http)
        net.close(client)
        free_all(context.temp_allocator)
    }
}
document_http_poll :: proc(http:^Document_HTTP,writing:bool)->bool {
    if sync.atomic_load(&http.source.stopping)||time.duration_seconds(time.tick_diff(http.progress,time.tick_now()))>20 {return false}
    fds:=[1]posix.pollfd{{fd=http.fd,events={.IN}}};if writing {fds[0].events={.OUT}}
    ret:=posix.poll(raw_data(fds[:]),1,100)
    return ret>=0||posix.errno()==.EINTR
}
document_http_write :: proc(http:^Document_HTTP,bytes:[]u8)->bool {
    offset:=0
    for offset<len(bytes) {
        if sync.atomic_load(&http.source.stopping) {return false}
        count:=file_socket_send(http.fd,&bytes[offset],c.size_t(int(len(bytes))-offset),0x4000)
        if count>0 {offset+=int(count);http.progress=time.tick_now()}
        else if count<0&&posix.errno()==.EAGAIN {if !document_http_poll(http,true) {return false}}
        else if count<0&&posix.errno()==.EINTR {continue}
        else {return false}
    }
    return true
}
document_http_text :: proc(http:^Document_HTTP,text:string)->bool {return document_http_write(http,transmute([]u8)text)}
document_http_error :: proc(http:^Document_HTTP,status:int,message:string) {
    escaped:=document_html_attribute(message);defer delete(escaped)
    body:=fmt.tprintf("<!doctype html><meta charset=utf-8><title>Document unavailable</title><style>%s</style><main><h2>Document unavailable</h2><p>%s</p></main>",DOCUMENT_MARKDOWN_STYLE,escaped)
    document_http_text(http,fmt.tprintf("HTTP/1.1 %d Document unavailable\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n%s",status,len(body),body))
}
document_http_header :: proc(headers,name:string)->string {
    remaining:=headers
    for line in strings.split_lines_iterator(&remaining) {
        colon:=strings.index_byte(line,':')
        if colon>0&&strings.equal_fold(line[:colon],name) {return strings.trim_space(line[colon+1:])}
    }
    return ""
}
document_http_cookie :: proc(headers,token:string)->bool {
    cookies:=document_http_header(headers,"Cookie")
    for item in strings.split_iterator(&cookies,";") {
        if strings.trim_space(item)==fmt.tprintf("minor_document=%s",token) {return true}
    }
    return false
}
document_url_decode :: proc(path:string)->(decoded:string,valid:bool) {
    output:=make([dynamic]u8,0,len(path))
    for i:=0;i<len(path);i+=1 {
        byte:=path[i]
        if byte=='%' {
            if i+2>=len(path) {delete(output);return "",false}
            hi,ok_hi:=strconv.parse_uint(path[i+1:i+2],16);lo,ok_lo:=strconv.parse_uint(path[i+2:i+3],16)
            if !ok_hi||!ok_lo {delete(output);return "",false}
            byte=u8((hi<<4)|lo);i+=2
        }
        if byte==0||byte<32||byte==127 {delete(output);return "",false}
        append(&output,byte)
    }
    return string(output[:]),true
}
document_http_request :: proc(http:^Document_HTTP) {
    request:[32*1024]u8
    used:=0
    for used<len(request) {
        count:=posix.read(http.fd,&request[used],c.size_t(len(request)-used))
        if count>0 {used+=int(count);http.progress=time.tick_now();if strings.contains(string(request[:used]),"\r\n\r\n") {break}}
        else if count<0&&posix.errno()==.EAGAIN {if !document_http_poll(http,false) {return}}
        else if count<0&&posix.errno()==.EINTR {continue}
        else {return}
    }
    text:=string(request[:used]);first:=strings.index(text,"\r\n")
    if first<0||!strings.contains(text,"\r\n\r\n") {document_http_error(http,400,"Invalid HTTP request.");return}
    parts:=strings.split(text[:first]," ",context.temp_allocator)
    if len(parts)!=3||(parts[0]!="GET"&&parts[0]!="HEAD") {document_http_error(http,405,"The document viewer serves static files with GET and HEAD.");return}
    headers:=text[first+2:]
    if document_http_header(headers,"Host")!=http.source.host {document_http_error(http,403,"Invalid document origin.");return}
    fetch_site:=document_http_header(headers,"Sec-Fetch-Site")
    if fetch_site=="cross-site" {document_http_error(http,403,"Cross-site document access is unavailable.");return}
    target:=parts[1]
    question:=strings.index_byte(target,'?');if question>=0 {target=target[:question]}
    initial:=fmt.tprintf("/.minor-document/%s/",http.source.token)
    if strings.has_prefix(target,initial) {
        location:=target[len(initial)-1:]
        document_http_text(http,fmt.tprintf("HTTP/1.1 303 See Other\r\nLocation: %s\r\nSet-Cookie: minor_document=%s; Path=/; HttpOnly; SameSite=Strict\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",location,http.source.token));return
    }
    if !document_http_cookie(headers,http.source.token) {document_http_error(http,403,"This document resource channel is private.");return}
    if target=="/.minor-document/font/Inter-Regular.ttf" {
        document_http_text(http,fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: font/ttf\r\nContent-Length: %d\r\nCache-Control: private, max-age=86400\r\nConnection: close\r\n\r\n",len(INTER_FONT_DATA)))
        if parts[0]!="HEAD" {document_http_write(http,transmute([]u8)INTER_FONT_DATA)}
        return
    }
    decoded,valid:=document_url_decode(target)
    if !valid {document_http_error(http,400,"Invalid filename URL.");return};defer delete(decoded)
    if !strings.has_prefix(decoded,"/") {document_http_error(http,400,"An absolute resource path is required.");return}
    path,_:=filepath.clean(fmt.tprintf("%s/%s",http.source.root,decoded),context.temp_allocator)
    if !document_inside_root(http.source.root,path) {document_http_error(http,403,DOCUMENT_OUTSIDE_ROOT);return}
    if http.source.remote {document_remote_serve(http,path,decoded,headers,parts[0]=="HEAD")}
    else {document_local_serve(http,path,decoded,headers,parts[0]=="HEAD")}
}

document_mime :: proc(path:string)->string {
    switch strings.to_lower(filepath.ext(path),context.temp_allocator) {
    case ".html",".htm":return "text/html"
    case ".xhtml":return "application/xhtml+xml"
    case ".css":return "text/css"
    case ".js",".mjs",".cjs":return "text/javascript"
    case ".json",".map":return "application/json"
    case ".svg":return "image/svg+xml"
    case ".png":return "image/png"
    case ".jpg",".jpeg":return "image/jpeg"
    case ".gif":return "image/gif"
    case ".webp":return "image/webp"
    case ".avif":return "image/avif"
    case ".ico":return "image/x-icon"
    case ".bmp":return "image/bmp"
    case ".woff":return "font/woff"
    case ".woff2":return "font/woff2"
    case ".ttf":return "font/ttf"
    case ".otf":return "font/otf"
    case ".mp4",".m4v":return "video/mp4"
    case ".webm":return "video/webm"
    case ".mp3":return "audio/mpeg"
    case ".ogg",".oga":return "audio/ogg"
    case ".wav":return "audio/wav"
    case ".pdf":return "application/pdf"
    case ".xml":return "application/xml"
    case ".wasm":return "application/wasm"
    case ".txt",".log",".csv":return "text/plain; charset=utf-8"
    }
    return "application/octet-stream"
}
DOCUMENT_OUTSIDE_ROOT :: "This resource is outside the document's permitted directory."
document_inside_root :: proc(root,path:string)->bool {
    return root=="/"||path==root||(strings.has_prefix(path,root)&&len(path)>len(root)&&path[len(root)]=='/')
}
document_sftp_init :: proc(s:^File_SFTP)->bool {
    initial:=[9]u8{0,0,0,5,1,0,0,0,3}
    if !file_sftp_write(s,initial[:]) {return false}
    version:=file_sftp_packet(s)
    valid_version:=len(version)>=5&&version[0]==2&&version[1]==0&&version[2]==0&&version[3]==0&&version[4]==3
    delete(version)
    if !valid_version {if s.error=="" {s.error="The server does not support SFTP version 3."};return false}
    return true
}
document_remote_resolve :: proc(s:^File_SFTP,path:string)->string {
    payload:=make([dynamic]u8,context.temp_allocator);file_put_string(&payload,path)
    if !file_sftp_send(s,16,payload[:]) {return ""}
    packet:=file_sftp_packet(s);if packet==nil {return ""};defer delete(packet)
    kind,d:=file_sftp_response(s,packet)
    if kind==101 {file_sftp_status(s,&d);return ""}
    if kind!=104||file_u32(&d)<1 {s.error="Invalid SFTP resource path.";return ""}
    resolved:=file_string(&d)
    if !d.valid||!strings.has_prefix(resolved,"/") {s.error="Invalid SFTP resource path.";return ""}
    return strings.clone(resolved)
}
document_remote_open :: proc(s:^File_SFTP,path,root:string)->(handle:string,size:i64,directory:bool) {
    if !document_sftp_init(s) {return}
    resolved:=document_remote_resolve(s,path);defer delete(resolved)
    if s.error!=""||resolved=="" {return}
    if !document_inside_root(root,resolved) {s.error=DOCUMENT_OUTSIDE_ROOT;return}
    payload:=make([dynamic]u8,context.temp_allocator)
    file_put_string(&payload,resolved)
    if !file_sftp_send(s,17,payload[:]) {return}
    packet:=file_sftp_packet(s);if packet==nil {return}
    kind,d:=file_sftp_response(s,packet)
    if kind==101 {file_sftp_status(s,&d);delete(packet);return}
    if kind!=105 {s.error="Invalid SFTP document attributes.";delete(packet);return}
    mode:u32;size,mode=file_attrs(&d);delete(packet)
    if !d.valid {s.error="Invalid SFTP document attributes.";return}
    if mode&0o170000==0o040000 {directory=true;return}
    clear(&payload);file_put_string(&payload,resolved);file_put_u32(&payload,1);file_put_u32(&payload,0)
    if !file_sftp_send(s,3,payload[:]) {return}
    packet=file_sftp_packet(s);if packet==nil {return}
    kind,d=file_sftp_response(s,packet)
    if kind==101 {file_sftp_status(s,&d);delete(packet);return}
    if kind!=102 {s.error="Invalid SFTP document handle.";delete(packet);return}
    handle=strings.clone(file_string(&d));delete(packet)
    if !d.valid {delete(handle);handle="";s.error="Invalid SFTP document handle."}
    return
}

// Read windows in parallel and send them in file order. HTML/assets stream
// through a 256 KiB window, regardless of the full file's size.
document_remote_bytes :: proc(s:^File_SFTP,handle:string,start,length:i64,http:^Document_HTTP,collect:^[dynamic]u8=nil)->bool {
    CHUNK :: 32768
    WINDOW :: 8
    bytes:[WINDOW][CHUNK]u8
    slots:[WINDOW]File_SFTP_Read
    payload:=make([dynamic]u8,0,len(handle)+24);defer delete(payload)
    position:=start;end:=start+length
    for position<end {
        count:=WINDOW
        if end-position<i64(WINDOW*CHUNK) {count=int((end-position+CHUNK-1)/CHUNK)}
        for &slot,i in slots[:count] {
            offset:=position+i64(i*CHUNK)
            slot=File_SFTP_Read{offset=int(offset),length=int(min(i64(CHUNK),end-offset))}
            file_put_string(&payload,handle);file_put_u64(&payload,u64(offset));file_put_u32(&payload,u32(slot.length))
            if !file_sftp_send(s,5,payload[:]) {return false};slot.id=s.sequence;clear(&payload)
        }
        pending:=count
        for pending>0 {
            packet:=file_sftp_packet(s);if packet==nil {return false}
            kind,id,d:=file_sftp_response_any(s,packet)
            index:= -1
            for slot,i in slots[:count] {if !slot.done&&slot.id==id {index=i;break}}
            if !d.valid||index<0 {delete(packet);s.error="SFTP document read ID mismatch.";return false}
            slot:=&slots[index]
            if kind==101 {
                code:=file_sftp_status(s,&d);delete(packet)
                if code==1 {s.error="The remote file changed while it was being read."}
                return false
            }
            if kind!=103 {delete(packet);s.error="Invalid SFTP document data.";return false}
            data:=file_string(&d)
            if !d.valid||len(data)==0||len(data)>slot.length {delete(packet);s.error="Invalid SFTP document data.";return false}
            within:=slot.offset-int(position)-index*CHUNK
            copy(bytes[index][within:within+len(data)],transmute([]u8)data)
            slot.offset+=len(data);slot.length-=len(data);delete(packet)
            if slot.length==0 {slot.done=true;pending-=1}
            else {
                file_put_string(&payload,handle);file_put_u64(&payload,u64(slot.offset));file_put_u32(&payload,u32(slot.length))
                if !file_sftp_send(s,5,payload[:]) {return false};slot.id=s.sequence;clear(&payload)
            }
        }
        for i in 0..<count {
            length:=int(min(i64(CHUNK),end-position))
            if collect!=nil {append(collect,..bytes[i][:length])}
            else if !document_http_write(http,bytes[i][:length]) {return false}
            position+=i64(length)
        }
    }
    return true
}
document_http_range :: proc(value:string,size:i64)->(start,length:i64,partial,valid:bool) {
    start=0;length=size;valid=true
    if value=="" {return}
    partial=true
    if !strings.has_prefix(value,"bytes=")||strings.contains(value,",")||size==0 {valid=false;return}
    range:=value[6:];dash:=strings.index_byte(range,'-')
    if dash<0 {valid=false;return}
    if dash==0 {
        suffix,ok:=strconv.parse_i64(range[1:],10)
        if !ok||suffix<=0 {valid=false;return}
        length=min(size,suffix);start=size-length;return
    }
    first,first_ok:=strconv.parse_i64(range[:dash],10)
    if !first_ok||first<0||first>=size {valid=false;return}
    last:=size-1
    if dash+1<len(range) {
        parsed,last_ok:=strconv.parse_i64(range[dash+1:],10)
        if !last_ok||parsed<first {valid=false;return};last=min(last,parsed)
    }
    start=first;length=last-first+1
    return
}
document_http_directory :: proc(http:^Document_HTTP,path:string) {
    escaped:=document_url_path(path);defer delete(escaped)
    document_http_text(http,fmt.tprintf("HTTP/1.1 303 See Other\r\nLocation: %s/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",escaped))
}
document_local_serve :: proc(http:^Document_HTTP,path,virtual,headers:string,head:bool) {
    canonical:=file_realpath(strings.clone_to_cstring(path,context.temp_allocator),nil)
    if canonical==nil {document_http_error(http,404,"The document resource could not be resolved.");return}
    resolved:=strings.clone(string(canonical),context.temp_allocator);file_cfree(rawptr(canonical))
    if !document_inside_root(http.source.root,resolved) {document_http_error(http,403,DOCUMENT_OUTSIDE_ROOT);return}
    info,stat_error:=os.stat(resolved,context.temp_allocator)
    if stat_error!=nil {document_http_error(http,404,"The document resource could not be read.");return}
    actual:=resolved
    if info.type==.Directory {
        if !strings.has_suffix(virtual,"/") {document_http_directory(http,virtual);return}
        actual=fmt.tprintf("%s/index.html",resolved)
        index_canonical:=file_realpath(strings.clone_to_cstring(actual,context.temp_allocator),nil)
        if index_canonical==nil {document_http_error(http,404,"This directory has no index.html document.");return}
        actual=strings.clone(string(index_canonical),context.temp_allocator);file_cfree(rawptr(index_canonical))
        if !document_inside_root(http.source.root,actual) {document_http_error(http,403,DOCUMENT_OUTSIDE_ROOT);return}
        info,stat_error=os.stat(actual,context.temp_allocator)
        if stat_error!=nil {document_http_error(http,404,"This directory has no index.html document.");return}
    }
    if info.type!=.Regular {document_http_error(http,403,"Only regular document files can be opened.");return}
    if document_kind(actual)==.Markdown {
        if info.size>0xffffffff {document_http_error(http,413,"Markdown exceeds the parser's 4 GiB input range.");return}
        bytes,read_error:=os.read_entire_file(actual,context.allocator)
        if read_error!=nil {document_http_error(http,404,"The Markdown document could not be read.");return};defer delete(bytes)
        if sync.atomic_load(&http.source.stopping) {return}
        html,error:=document_markdown(bytes,filepath.base(actual),"")
        if error!="" {defer delete(error);document_http_error(http,500,error);return};defer delete(html)
        document_http_text(http,fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",len(html)))
        if !head {document_http_write(http,html)}
        return
    }
    file,open_error:=os.open(actual)
    if open_error!=nil {document_http_error(http,404,"The document resource could not be opened.");return};defer os.close(file)
    start,length,partial,valid:=document_http_range(document_http_header(headers,"Range"),info.size)
    if !valid {document_http_text(http,fmt.tprintf("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%d\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",info.size));return}
    status:="200 OK";range:=""
    if partial {status="206 Partial Content";range=fmt.tprintf("Content-Range: bytes %d-%d/%d\r\n",start,start+length-1,info.size)}
    if !document_http_text(http,fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\n%sCache-Control: no-store\r\nConnection: close\r\n\r\n",status,document_mime(actual),length,range)) {return}
    if head {return}
    _,seek_error:=os.seek(file,start,.Start)
    if seek_error!=nil {return}
    buffer:[256*1024]u8
    remaining:=length
    for remaining>0&&!sync.atomic_load(&http.source.stopping) {
        count,error:=os.read(file,buffer[:int(min(remaining,i64(len(buffer))))])
        if count<=0||error!=nil {return}
        if !document_http_write(http,buffer[:count]) {return}
        remaining-=i64(count)
    }
}
document_remote_serve :: proc(http:^Document_HTTP,path,virtual,headers:string,head:bool) {
    s:=File_SFTP{browser=&http.source.browser,generation=1,io= -1,stderr= -1}
    defer file_sftp_destroy(&s)
    if !file_sftp_spawn(&s,http.source.profile) {document_http_error(http,502,s.error);return}
    actual:=path
    if strings.has_suffix(virtual,"/") {actual=fmt.tprintf("%s/index.html",actual)}
    handle,size,directory:=document_remote_open(&s,actual,http.source.root);defer delete(handle)
    if directory {document_http_directory(http,virtual);return}
    if s.error!=""||handle=="" {status:=404;if s.error==DOCUMENT_OUTSIDE_ROOT {status=403};document_http_error(http,status,s.error);return}
    if document_kind(actual)==.Markdown {
        if size>0xffffffff {document_http_error(http,413,"Markdown exceeds the parser's 4 GiB input range.");return}
        bytes:=make([dynamic]u8,0,int(size));defer delete(bytes)
        if !document_remote_bytes(&s,handle,0,size,http,&bytes) {if s.error!="" {document_http_error(http,502,s.error)};return}
        html,error:=document_markdown(bytes[:],filepath.base(actual),"")
        if error!="" {defer delete(error);document_http_error(http,500,error);return};defer delete(html)
        document_http_text(http,fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",len(html)))
        if !head {document_http_write(http,html)}
    } else {
        start,length,partial,valid:=document_http_range(document_http_header(headers,"Range"),size)
        if !valid {document_http_text(http,fmt.tprintf("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%d\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",size));return}
        status:="200 OK";range:=""
        if partial {status="206 Partial Content";range=fmt.tprintf("Content-Range: bytes %d-%d/%d\r\n",start,start+length-1,size)}
        if !document_http_text(http,fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\n%sCache-Control: no-store\r\nConnection: close\r\n\r\n",status,document_mime(actual),length,range)) {return}
        if !head {document_remote_bytes(&s,handle,start,length,http)}
    }
    if s.error=="" {file_sftp_close_handle(&s,handle)}
}

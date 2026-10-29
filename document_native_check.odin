package main

import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:sync"
import "core:time"

// A small diagnostic exercises the native pipeline without requiring a window.
// It uses the real FreeType atlas and the same layout/DOM/script code as the UI.
native_document_selfcheck :: proc()->bool {
    a:=new(App);defer free(a)
    a.scale=1;a.renderer.atlas.scale=1
    if !renderer_font_rasterize(&a.renderer.atlas) {return false}
    defer renderer_font_dispose(&a.renderer.atlas)
    a.renderer.fonts=a.renderer.atlas.fonts;a.renderer.atlas_height=4096
    view:=new(Document_View)
    view.done=true;view.finished=true;view.zoom=1;view.focused_node=-1;view.viewport_height=300
    renderer_pixels_init(&view.frame)
    defer document_view_destroy(view)
    native_document_init(&view.native)
    if !view.native.initialized {return false}
    native_parse_html(&view.native,`<!doctype html><html><head><style>
        :root{--ink:#2468ac} #counter{font-size:22px;color:var(--ink)}
        .row{display:flex} td{padding:4px;border:1px solid #888}
        </style></head><body><h1>Native document</h1><p id="counter">Waiting</p>
        <button id="run">Run</button><div id="left"><span id="moving">Move me</span></div><div id="right"></div>
        <table><tr><th>One</th><th>Two</th></tr><tr><td>A</td><td>B</td></tr></table>
        <input id="field" value="edit me"><p>Unicode café λ, long words and wrapping.</p></body></html>`)
    native_js_init(&view.native.script,Native_JS_Host{data=view,get=native_dom_get,set=native_dom_set,call=native_dom_call})
    _,error:=native_js_evaluate(&view.native.script,`document.getElementById('counter').textContent='Ready';document.getElementById('run').addEventListener('click',function(event){document.getElementById('counter').textContent='Clicked';});document.getElementById('right').appendChild(document.getElementById('moving'));`)
    if error!="" {fmt.eprintln(error);return false}
    native_document_layout(a,view,600)
    counter:=native_query(&view.native,"#counter");button:=native_query(&view.native,"#run");moving:=native_query(&view.native,"#moving");right:=native_query(&view.native,"#right")
    if counter<0||button<0||moving<0||right<0||view.native.nodes[moving].parent!=right||view.native.nodes[counter].style.size!=22||len(view.native.fragments)<10||!strings.contains(view.native.text,"Ready") {return false}
    if abs(view.native.nodes[counter].style.color[0]-f32(0x24)/255)>0.001 {return false}
    native_dispatch_event(view,button,"click")
    native_document_layout(a,view,600)
    if !strings.contains(view.native.text,"Clicked")||strings.contains(view.native.text,"Ready") {return false}
    append(&view.find_text,"Clicked");document_find(view,restart=true)
    if view.selection_end-view.selection_anchor!=7||view.native.text[view.selection_anchor:view.selection_end]!="Clicked" {return false}
    height:=view.native.height;view.zoom=1.5;native_document_layout(a,view,600)
    if view.native.height<=height {return false}
    _,error=native_js_evaluate(&view.native.script,`document.getElementById('moving').appendChild(document.getElementById('right'));`)
    if view.native.nodes[right].parent==moving {return false}
    if !native_document_extended_check(a,view) {return false}
    return true
}

native_document_extended_check :: proc(a:^App,view:^Document_View)->bool {
    doc:=&view.native;body:=native_query(doc,"body")
    latin:=[4]u8{'c','a','f',0xe9};wide:=[4]u8{0xff,0xfe,'A',0}
    if native_decode_html(latin[:],"text/html; charset=windows-1252")!="café"||native_decode_html(wide[:])!="A" {fmt.eprintln("Native HTML character encoding failed");return false}
    resolved:=native_url_resolve("https://example.test/a/b/page.html?old=1","../c?q=a+b#z");defer delete(resolved)
    if resolved!="https://example.test/a/c?q=a+b#z" {fmt.eprintf("Native URL resolution failed: %s\n",resolved);return false}
    native_parse_html(doc,`<div id="fx" style="display:flex;width:300px;gap:10px;margin:0;padding:0"><div id="f1" style="flex:1">A</div><div id="f2" style="flex:2">B</div></div>
        <div id="gd" style="display:grid;width:330px;grid-template-columns:100px 1fr;gap:10px"><div id="g1">A</div><div id="g2">B</div><div id="gs" style="grid-column:span 2">Span</div></div>
        <div id="pos" style="position:relative;width:100px;height:100px"><div id="abs" style="position:absolute;right:0;bottom:0;width:20px;height:20px"></div></div>
        <table id="repair"><tr><td>A<td>B</table><template><div id="inert">Not a document match</div></template>
        <form id="f" action="results.html"><input name="q" value="a &amp; café"><input type="checkbox" name="on" checked><input name="disabled" disabled value="no"></form>
        <canvas id="cv" width="200" height="100"></canvas>`,body)
    doc.revision+=1;view.zoom=1;native_document_layout(a,view,600)
    node :: proc(doc:^Native_Document,id:string)->Native_DOM_Node {return doc.nodes[native_query(doc,id)]}
    if abs(node(doc,"#f1").w-96.6667)>1||abs(node(doc,"#f2").w-193.3333)>1 {fmt.eprintln("Native flex dimensions failed");return false}
    if abs(node(doc,"#g1").w-100)>1||abs(node(doc,"#g2").w-220)>1||abs(node(doc,"#gs").w-330)>1 {fmt.eprintln("Native grid dimensions failed");return false}
    parent:=node(doc,"#pos");child:=node(doc,"#abs")
    if abs(child.x-parent.x-80)>1||abs(child.y-parent.y-80)>1 {fmt.eprintln("Native positioned dimensions failed");return false}
    if native_query(doc,"#inert")>=0||native_query(doc,"#repair tbody")<0||native_entity("&NotEqualTilde; &euro; &#x80;")!="≂̸ € €" {fmt.eprintln("Native HTML recovery/entities failed");return false}
    form:=native_query(doc,"#f");entries:=native_form_entries(doc,form,-1);encoded:=native_form_urlencoded(entries[:]);defer delete(entries);defer delete(encoded)
    if encoded!="q=a+%26+caf%C3%A9&on=on" {fmt.eprintf("Native form encoding failed: %s\n",encoded);return false}
    canvas:=native_query(doc,"#cv")
    native_canvas_set(view,canvas,"fillStyle",native_dom_text("#f00"))
    rectangle:=[4]Native_JS_Value{native_js_number(0),native_js_number(0),native_js_number(100),native_js_number(100)}
    native_canvas_call(view,canvas,"fillRect",rectangle[:]);rectangle={native_js_number(25),native_js_number(25),native_js_number(50),native_js_number(50)}
    native_canvas_call(view,canvas,"clearRect",rectangle[:]);clear(&a.vertices)
    native_canvas_render(a,view,canvas,0,0,200,100,{0,0,200,100})
    area:f32
    for i:=0;i+2<len(a.vertices);i+=3 {p,q,r:=a.vertices[i].pos,a.vertices[i+1].pos,a.vertices[i+2].pos;area+=abs((q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0]))/2}
    if abs(area-7500)>1 {fmt.eprintf("Native canvas clipping failed: %g\n",area);return false}
    delete(a.vertices);a.vertices=nil
    return true
}

native_document_fixture_check :: proc(path:string)->bool {
    a:=new(App);defer free(a)
    a.scale=1;a.renderer.width=900;a.renderer.height=760;a.renderer.atlas.scale=1
    if !renderer_font_rasterize(&a.renderer.atlas) {return false}
    defer renderer_font_dispose(&a.renderer.atlas)
    a.renderer.fonts=a.renderer.atlas.fonts;a.renderer.atlas_height=4096
    absolute:=path
    if !native_http_url(path) {resolved,absolute_error:=filepath.abs(path,context.temp_allocator);if absolute_error!=nil {return false};absolute=resolved}
    view:=document_view_open(absolute,false,{})
    tab:=new(Tab);defer free(tab)
    tab.files=true;tab.explorer.loaded=true;tab.explorer.preview_open=true;tab.explorer.document=view
    append(&a.tabs,tab);defer delete(a.tabs)
    defer {explorer_result_destroy(&tab.explorer.preview);delete(tab.explorer.lines);document_view_destroy(view)}
    a.explorer_visible=true
    started:=time.tick_now()
    for time.tick_diff(started,time.tick_now())<15*time.Second {
        if sync.atomic_load(&view.done) {document_view_update(a);if view.error!=""||view.scripts_ready&&len(view.fetches)==0 {break}}
        time.sleep(5*time.Millisecond)
    }
    if !sync.atomic_load(&view.done)||!view.scripts_ready||view.error!=""||view.control_error_seen!="" {
        fmt.eprintf("Native HTML fixture failed (%s): %s %s\n",path,view.error,view.control_error_seen);return false
    }
    native_document_layout(a,view,900)
    if len(view.native.fragments)<2 {fmt.eprintf("HTML fixture has no native layout: %s\n",path);return false}
    if filepath.base(path)=="scripts.html" {
        text:=view.native.text
        if !strings.contains(text,"Module import and class construction: working")||!strings.contains(text,"Asynchronous local fetch") {fmt.eprintf("Native module/fetch output failed: %s\n",text);return false}
        button:=native_query(&view.native,"#increment");native_dispatch_event(view,button,"click");native_document_layout(a,view,900)
        if !strings.contains(view.native.text,"Count: 1") {fmt.eprintln("Native module event callback failed");return false}
    }
    if filepath.base(path)=="forms.html" {
        form:=native_query(&view.native,"#local-form");native_submit_form(view,form)
        native_document_layout(a,view,900)
        if view.pending_path!=""||!strings.contains(view.native.text,"Hello native HTML") {fmt.eprintf("Native preventDefault form event failed: pending=%s text=%s error=%s\n",view.pending_path,view.native.text,view.control_error_seen);return false}
    }
    if filepath.base(path)=="canvas.html"&&len(view.native.canvases)==0 {fmt.eprintln("Native canvas script did not run");return false}
    fmt.printf("Native HTML fixture: OK (%s)\n",path)
    return true
}

native_network_selfcheck :: proc(base:string)->bool {
    source:Document_Source
    native_network_init(&source);defer document_source_close(&source)
    response:=native_network_request(&source,fmt.tprintf("%s/redirect",base))
    if response.error!=""||response.status!=200||!strings.has_suffix(response.url,"/landing") {fmt.eprintf("Native HTTP redirect failed: %s (%d)\n",response.error,response.status);native_http_destroy(&response);return false}
    native_http_destroy(&response)
    posted:=native_network_request(&source,fmt.tprintf("%s/post",base),"POST","q=a+%26+caf%C3%A9","application/x-www-form-urlencoded")
    defer native_http_destroy(&posted)
    if posted.error!=""||posted.status!=200||!strings.contains(string(posted.bytes),"q=a+%26+caf%C3%A9")||!strings.contains(string(posted.bytes),"terminal_native=kept") {fmt.eprintf("Native form POST/cookie failed: %s (%d)\n",posted.error,posted.status);return false}
    return native_document_fixture_check(fmt.tprintf("%s/scripts.html",base))
}

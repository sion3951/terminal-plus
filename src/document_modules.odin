package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import vmem "core:mem/virtual"

Native_Module :: struct {url,source:string,namespace:Native_JS_Value,status:int}
native_module_resolve :: proc(view:^Document_View,base,specifier:string)->string {
    mapped:=specifier
    if value,exists:=view.native.imports[specifier];exists {mapped=value}
    else {
        longest:=0
        for key,replacement in view.native.imports {if strings.has_suffix(key,"/")&&strings.has_prefix(specifier,key)&&len(key)>longest {mapped=fmt.tprintf("%s%s",replacement,specifier[len(key):]);longest=len(key)}}
    }
    if !strings.has_prefix(mapped,".")&&!strings.has_prefix(mapped,"/")&&!strings.contains(mapped,":")&&mapped==specifier {return ""}
    return native_resource_path(view,base,mapped)
}
native_import_map :: proc(view:^Document_View,text:string) {
    value:struct {imports:map[string]string}
    if json.unmarshal(transmute([]u8)text,&value,allocator=vmem.arena_allocator(&view.native.arena))!=nil {document_set_script_error(view,"Invalid HTML import map.");return}
    for key,path in value.imports {view.native.imports[key]=native_resource_path(view,view.base_path,path)}
}
native_module_prefetch :: proc(view:^Document_View,url,source:string,depth:int=0) {
    doc:=&view.native
    if _,exists:=doc.modules[url];exists {return}
    if depth>64||len(doc.modules)>=512 {document_set_script_error(view,"The document module graph is too large.");return}
    context.allocator=vmem.arena_allocator(&doc.arena)
    module:=new(Native_Module);module.url=strings.clone(url);module.source=strings.clone(source);module.namespace=native_js_object(&doc.script)
    doc.modules[module.url]=module
    dependencies,error:=native_js_module_sources(&doc.script,source)
    if error!="" {document_set_script_error(view,error);return}
    for specifier in dependencies {
        path:=native_module_resolve(view,url,specifier)
        if path=="" {document_set_script_error(view,fmt.tprintf("Unmapped JavaScript module: %s",specifier));continue}
        if _,exists:=doc.modules[path];exists {continue}
        bytes,read_error:=native_read_resource(view,path)
        if read_error!="" {document_set_script_error(view,read_error);continue}
        native_module_prefetch(view,path,string(bytes),depth+1)
    }
}
native_module_evaluate :: proc(view:^Document_View,url:string)->(Native_JS_Value,string) {
    module,exists:=view.native.modules[url]
    if !exists {return {},"JavaScript module was not loaded."}
    if module.status>0 {return module.namespace,""}
    previous:=view.current_script_url;view.current_script_url=module.url
    defer {view.current_script_url=previous}
    module.status=1
    result,error:=native_js_evaluate_module(&view.native.script,module.source,module.namespace)
    if error!="" {module.status=0;return {},error}
    module.namespace=result;module.status=2;return result,""
}

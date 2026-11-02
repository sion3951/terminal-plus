package main

native_js_bind_pattern :: proc(js:^Native_JS,scope:^Native_JS_Environment,pattern:^Native_JS_Expression,value:Native_JS_Value,declare:bool,depth:int=0) {
    if pattern==nil||!native_js_step(js) {return}
    if depth>128 {native_js_fail(js,"JavaScript destructuring nesting limit reached.");return}
    #partial switch pattern.kind {
    case .Identifier:native_js_bind(js,scope,pattern.text,value,declare)
    case .Assign:
        item:=value;if item.kind==.Undefined {item=native_js_eval(js,scope,pattern.right)}
        native_js_bind_pattern(js,scope,pattern.left,item,declare,depth+1)
    case .Array:
        if value.kind!=.Array&&value.kind!=.String {native_js_fail(js,"Array destructuring needs an iterable value.");return}
        items:=make([dynamic]Native_JS_Value,native_js_allocator(js));native_js_spread_items(js,&items,value)
        for child,i in pattern.arguments {
            if child.kind==.Spread {native_js_bind_pattern(js,scope,child.left,native_js_array(js,items[min(i,len(items)):]),declare,depth+1);break}
            if child.kind==.Literal&&child.value.kind==.Undefined {continue}
            native_js_bind_pattern(js,scope,child,native_js_argument(items[:],i),declare,depth+1)
        }
    case .Object:
        if value.kind==.Undefined||value.kind==.Null {native_js_fail(js,"Cannot destructure null or undefined.");return}
        used:=make(map[string]bool,native_js_allocator(js))
        for child,i in pattern.arguments {
            if child.kind==.Spread {
                rest:=native_js_object(js)
                if value.reference!=nil {for key,item in value.reference.properties {if !used[key] {rest.reference.properties[key]=item}}}
                native_js_bind_pattern(js,scope,child.left,rest,declare,depth+1);continue
            }
            name:=pattern.keys[i];used[name]=true
            native_js_bind_pattern(js,scope,child,native_js_property(js,value,name),declare,depth+1)
        }
    case:native_js_fail(js,"Invalid JavaScript binding pattern.")
    }
}

native_js_pattern_names :: proc(pattern:^Native_JS_Expression,names:^[dynamic]string) {
    if pattern==nil {return}
    #partial switch pattern.kind {
    case .Identifier:append(names,pattern.text)
    case .Assign,.Spread:native_js_pattern_names(pattern.left,names)
    case .Object,.Array:for child in pattern.arguments {native_js_pattern_names(child,names)}
    }
}

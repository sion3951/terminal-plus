package main

import "core:strings"


Native_JS_Bound :: struct {callable,receiver:Native_JS_Value,arguments:[]Native_JS_Value}
Native_JS_Class_Member :: struct {name:string,expression:^Native_JS_Expression,static,getter,setter,field:bool}

native_js_parse_class :: proc(p:^Native_JS_Parser)->^Native_JS_Expression {
    expression:=native_js_expression_new(p,.Class)
    expression.members=make([dynamic]Native_JS_Class_Member,native_js_allocator(p.js))
    if native_js_peek(p).kind==.Identifier&&native_js_peek(p).text!="extends" {expression.text=native_js_next(p).text}
    if native_js_accept(p,"extends") {expression.left=native_js_parse_expression(p,14)}
    native_js_expect(p,"{")
    for p.js.error==""&&!native_js_accept(p,"}") {
        if native_js_accept(p,";") {continue}
        member:=Native_JS_Class_Member{}
        token:=native_js_next(p)
        if token.text=="static"&&native_js_peek(p).text!="(" {member.static=true;token=native_js_next(p)}
        if (token.text=="get"||token.text=="set")&&native_js_peek(p).text!="(" {member.getter=token.text=="get";member.setter=token.text=="set";token=native_js_next(p)}
        async:=false
        if token.text=="async"&&native_js_peek(p).text!="(" {async=true;token=native_js_next(p)}
        if token.kind!=.Identifier&&token.kind!=.String&&token.kind!=.Number {native_js_fail(p.js,"Expected a JavaScript class member name.");break}
        member.name=token.text
        if native_js_accept(p,"(") {
            method:=native_js_expression_new(p,.Function);method.async=async
            native_js_parameters(p,method)
            if native_js_peek(p).text!="{" {native_js_fail(p.js,"Expected class method body.");break}
            method.body=native_js_parse_statement(p);member.expression=method
        } else {
            member.field=true
            if native_js_accept(p,"=") {member.expression=native_js_parse_expression(p,1)}
            native_js_accept(p,";")
        }
        append(&expression.members,member)
    }
    return expression
}
native_js_set_prototype :: proc(js:^Native_JS,value,prototype:Native_JS_Value) {
    if value.reference==nil||prototype.kind!=.Null&&prototype.reference==nil {native_js_fail(js,"Invalid JavaScript prototype.");return}
    cursor:=prototype
    for depth:=0;cursor.reference!=nil;depth+=1 {
        if depth>=128||cursor.reference==value.reference {native_js_fail(js,"Cyclic JavaScript prototype chain.");return}
        cursor=cursor.reference.prototype
    }
    value.reference.prototype=prototype
}
native_js_instanceof :: proc(js:^Native_JS,value,constructor:Native_JS_Value)->bool {
    if constructor.kind==.Builtin {
        if prototype,okay:=js.error_prototypes[constructor.text];okay {if value.reference!=nil {for cursor:=value.reference.prototype;cursor.reference!=nil;cursor=cursor.reference.prototype {if cursor.reference==prototype.reference {return true}}};return false}
        switch constructor.text {case "Object":return value.reference!=nil;case "Array":return value.kind==.Array;case "RegExp":return value.reference!=nil&&value.reference.regex!=nil;case "Promise":return value.reference!=nil&&value.reference.promise!=nil}
    }
    if constructor.kind!=.Function {native_js_fail(js,"Right side of instanceof is not callable.");return false}
    prototype:=native_js_property(js,constructor,"prototype")
    if prototype.reference==nil {native_js_fail(js,"Constructor has no object prototype.");return false}
    if value.reference!=nil {for cursor:=value.reference.prototype;cursor.reference!=nil;cursor=cursor.reference.prototype {if cursor.reference==prototype.reference {return true}}}
    return false
}
native_js_class_value :: proc(js:^Native_JS,scope:^Native_JS_Environment,expression:^Native_JS_Expression)->Native_JS_Value {
    parent:=native_js_eval(js,scope,expression.left)
    if expression.left!=nil&&parent.kind!=.Function&&parent.kind!=.Null {native_js_fail(js,"Class extends requires a constructor or null.");return {}}
    function:=new(Native_JS_Function,native_js_allocator(js));function.scope=native_js_environment(js,scope);function.class_constructor=true;function.parent=parent
    storage:=native_js_object(js);storage.reference.prototype=js.function_prototype
    value:=Native_JS_Value{kind=.Function,function=function,reference=storage.reference}
    prototype:=native_js_object(js)
    if parent.reference!=nil {prototype.reference.prototype=native_js_property(js,parent,"prototype");value.reference.prototype=parent}
    prototype.reference.properties["constructor"]=value;value.reference.properties["prototype"]=prototype
    function.scope.values["this"]=value
    if expression.text!="" {function.scope.values[expression.text]=value;scope.values[expression.text]=value}
    fields:=make([dynamic]Native_JS_Class_Member,native_js_allocator(js))
    for member in expression.members {
        if member.field {
            if member.static {value.reference.properties[member.name]=native_js_eval(js,function.scope,member.expression)} else {append(&fields,member)}
            continue
        }
        method:=native_js_eval(js,function.scope,member.expression)
        method.function.parent=parent;method.function.static=member.static
        if member.name=="constructor"&&!member.static {function.parameters=method.function.parameters;function.defaults=method.function.defaults;function.patterns=method.function.patterns;function.rest=method.function.rest;function.body=method.function.body;continue}
        target:=prototype;if member.static {target=value}
        if member.getter {if target.reference.getters==nil {target.reference.getters=make(map[string]Native_JS_Value,native_js_allocator(js))};target.reference.getters[member.name]=method}
        else if member.setter {if target.reference.setters==nil {target.reference.setters=make(map[string]Native_JS_Value,native_js_allocator(js))};target.reference.setters[member.name]=method}
        else {target.reference.properties[member.name]=method}
    }
    function.fields=fields[:]
    return value
}
native_js_initialize_fields :: proc(js:^Native_JS,constructor,object:Native_JS_Value) {
    if constructor.function==nil {return}
    environment:=native_js_environment(js,constructor.function.scope);environment.values["this"]=object
    for field in constructor.function.fields {native_js_set_property(js,object,field.name,native_js_eval(js,environment,field.expression))}
}
native_js_construct :: proc(js:^Native_JS,constructor:Native_JS_Value,args:[]Native_JS_Value)->Native_JS_Value {
    if constructor.function==nil||constructor.function.arrow||constructor.function.async {native_js_fail(js,"This JavaScript function is not a constructor.");return {}}
    object:=native_js_object(js);prototype:=native_js_property(js,constructor,"prototype")
    if prototype.reference!=nil {object.reference.prototype=prototype}
    value:Native_JS_Value
    if constructor.function.body==nil&&constructor.function.class_constructor&&constructor.function.parent.kind==.Function {value=native_js_call_function(js,constructor.function.parent,args,object);native_js_initialize_fields(js,constructor,object)}
    else {value=native_js_call_function(js,constructor,args,object)}
    if value.kind==.Object||value.kind==.Array||value.kind==.Function {return value};return object
}
native_js_extended_builtin :: proc(js:^Native_JS,name:string,args:[]Native_JS_Value)->(Native_JS_Value,bool) {
    first,second:=native_js_argument(args,0),native_js_argument(args,1)
    switch name {
    case "__import":
        promise:=native_js_promise(js);namespace:=native_js_load_module(js,first)
        if js.error!="" {message:=js.error;js.error="";native_js_promise_reject(js,promise,native_js_builtin(js,"Error",[]Native_JS_Value{native_js_string(js,message)}))} else {native_js_promise_resolve(js,promise,namespace)}
        return promise,true
    case "RegExp":
        if first.reference!=nil&&first.reference.regex!=nil {flags:=first.reference.regex.flags;if second.kind!=.Undefined {flags=native_js_text(js,second)};return native_js_regex(js,first.reference.regex.pattern,flags),true}
        pattern:="";if first.kind!=.Undefined {pattern=native_js_text(js,first)};flags:="";if second.kind!=.Undefined {flags=native_js_text(js,second)};return native_js_regex(js,pattern,flags),true
    case "Promise":
        promise:=native_js_promise(js)
        if first.kind!=.Function {native_js_fail(js,"Promise constructor requires an executor function.");return promise,true}
        parameters:=[2]Native_JS_Value{{kind=.Builtin,text="__promise_resolve",reference=promise.reference},{kind=.Builtin,text="__promise_reject",reference=promise.reference}}
        native_js_call_function(js,first,parameters[:],{})
        if js.throwing {exception:=js.exception;js.throwing=false;native_js_promise_reject(js,promise,exception)}
        if js.error!="" {message:=js.error;js.error="";native_js_promise_reject(js,promise,native_js_builtin(js,"Error",[]Native_JS_Value{native_js_string(js,message)}))}
        return promise,true
    case "Promise.resolve":
        if first.reference!=nil&&first.reference.promise!=nil {return first,true};promise:=native_js_promise(js);native_js_promise_resolve(js,promise,first);return promise,true
    case "Promise.reject":promise:=native_js_promise(js);native_js_promise_reject(js,promise,first);return promise,true
    case "Promise.all","Promise.allSettled","Promise.race","Promise.any":return native_js_promise_collection(js,name,first),true
    case "queueMicrotask":
        if first.kind!=.Function&&first.kind!=.Builtin {native_js_fail(js,"queueMicrotask requires a callback.");return {},true}
        append(&js.jobs,Native_JS_Job{callback=first});return {},true
    case "Object.create":
        result:=native_js_object(js);native_js_set_prototype(js,result,first);return result,true
    case "Object.getPrototypeOf":if first.reference!=nil {return first.reference.prototype,true};return {kind=.Null},true
    case "Object.setPrototypeOf":native_js_set_prototype(js,first,second);return first,true
    case "Object.assign":
        if first.reference==nil {native_js_fail(js,"Object.assign target must be an object.");return {},true}
        for source in args[min(1,len(args)):] {if source.reference!=nil {for key,item in source.reference.properties {native_js_set_property(js,first,key,item)}}};return first,true
    case "Object.entries":
        result:=native_js_array(js,nil);if first.reference!=nil {for key,item in first.reference.properties {append(&result.reference.items,native_js_array(js,[]Native_JS_Value{native_js_string(js,key),item}))}};return result,true
    case "Object.fromEntries":
        result:=native_js_object(js);if first.reference!=nil {for pair in first.reference.items {if pair.reference!=nil&&len(pair.reference.items)>=2 {result.reference.properties[native_js_text(js,pair.reference.items[0])]=pair.reference.items[1]}}};return result,true
    case "Object.hasOwn":if first.reference!=nil {_,exists:=first.reference.properties[native_js_text(js,second)];return native_js_bool(exists),true};return native_js_bool(false),true
    case "Object.defineProperty":
        property:=native_js_text(js,second);descriptor:=native_js_argument(args,2)
        if first.reference==nil||descriptor.reference==nil {native_js_fail(js,"Invalid property descriptor.");return {},true}
        if value,okay:=descriptor.reference.properties["value"];okay {native_js_set_property(js,first,property,value)}
        if getter,okay:=descriptor.reference.properties["get"];okay {if first.reference.getters==nil {first.reference.getters=make(map[string]Native_JS_Value,native_js_allocator(js))};first.reference.getters[property]=getter}
        if setter,okay:=descriptor.reference.properties["set"];okay {if first.reference.setters==nil {first.reference.setters=make(map[string]Native_JS_Value,native_js_allocator(js))};first.reference.setters[property]=setter}
        return first,true
    }
    return {},false
}
native_js_extended_method :: proc(js:^Native_JS,receiver:Native_JS_Value,name:string,args:[]Native_JS_Value)->(Native_JS_Value,bool) {
    if receiver.reference!=nil&&receiver.reference.promise!=nil {return native_js_promise_method(js,receiver,name,args)}
    if receiver.reference!=nil&&receiver.reference.regex!=nil {return native_js_regex_method(js,receiver,name,args)}
    if receiver.kind==.String {if result,handled:=native_js_regex_string_method(js,receiver,name,args);handled {return result,true}}
    if (receiver.kind==.Function||receiver.kind==.Builtin)&&name=="bind" {
        result:=native_js_object(js);bound:=new(Native_JS_Bound,native_js_allocator(js));bound.callable=receiver;bound.receiver=native_js_argument(args,0)
        bound.arguments=make([]Native_JS_Value,max(0,len(args)-1),native_js_allocator(js));copy(bound.arguments,args[min(1,len(args)):]);result.reference.bound=bound
        return Native_JS_Value{kind=.Builtin,text="__bound",reference=result.reference},true
    }
    switch name {
    case "hasOwnProperty":if receiver.reference!=nil {_,okay:=receiver.reference.properties[native_js_text(js,native_js_argument(args,0))];return native_js_bool(okay),true}
    case "isPrototypeOf":
        first:=native_js_argument(args,0);if first.reference!=nil {for prototype:=first.reference.prototype;prototype.reference!=nil;prototype=prototype.reference.prototype {if prototype.reference==receiver.reference {return native_js_bool(true),true}}};return native_js_bool(false),true
    }
    return {},false
}

native_js_spread_items :: proc(js:^Native_JS,items:^[dynamic]Native_JS_Value,value:Native_JS_Value) {
    if value.kind==.Array&&value.reference!=nil {append(items,..value.reference.items[:]);return}
    if value.kind==.String {for ch in value.text {append(items,native_js_string(js,native_js_rune(ch)))};return}
    native_js_fail(js,"Spread value is not iterable.")
}
native_js_arguments :: proc(js:^Native_JS,scope:^Native_JS_Environment,expressions:[]^Native_JS_Expression)->[]Native_JS_Value {
    values:=make([dynamic]Native_JS_Value,native_js_allocator(js))
    for expression in expressions {if expression.kind==.Spread {native_js_spread_items(js,&values,native_js_eval(js,scope,expression.left))} else {append(&values,native_js_eval(js,scope,expression))}}
    return values[:]
}

native_js_setup_prototypes :: proc(js:^Native_JS) {
    for name in ([]string{"hasOwnProperty","isPrototypeOf","toString"}) {js.object_prototype.reference.properties[name]={kind=.Builtin,text=native_js_clone(js,strings.concatenate([]string{"__method:",name},native_js_allocator(js)))}}
    for name in ([]string{"call","apply","bind"}) {js.function_prototype.reference.properties[name]={kind=.Builtin,text=native_js_clone(js,strings.concatenate([]string{"__method:",name},native_js_allocator(js)))}}
    for name in ([]string{"push","pop","shift","unshift","includes","indexOf","join","slice","forEach","map","filter","find","some","every"}) {js.array_prototype.reference.properties[name]={kind=.Builtin,text=native_js_clone(js,strings.concatenate([]string{"__method:",name},native_js_allocator(js)))}}
    for name in ([]string{"trim","toLowerCase","toUpperCase","includes","startsWith","endsWith","indexOf","slice","substring","charAt","split","replace","replaceAll","concat","match","matchAll","search"}) {js.string_prototype.reference.properties[name]={kind=.Builtin,text=native_js_clone(js,strings.concatenate([]string{"__method:",name},native_js_allocator(js)))}}
    for name in ([]string{"then","catch","finally"}) {js.promise_prototype.reference.properties[name]={kind=.Builtin,text=native_js_clone(js,strings.concatenate([]string{"__method:",name},native_js_allocator(js)))}}
    for name in ([]string{"exec","test","toString"}) {js.regex_prototype.reference.properties[name]={kind=.Builtin,text=native_js_clone(js,strings.concatenate([]string{"__method:",name},native_js_allocator(js)))}}
}

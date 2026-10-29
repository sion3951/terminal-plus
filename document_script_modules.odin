package main

Native_JS_Module_Binding :: struct {name,local:string}
Native_JS_Module_Import :: struct {namespace:Native_JS_Value,name:string}

native_js_parse_module_bindings :: proc(p:^Native_JS_Parser)->[dynamic]Native_JS_Module_Binding {
    bindings:=make([dynamic]Native_JS_Module_Binding,native_js_allocator(p.js))
    native_js_expect(p,"{")
    for p.js.error==""&&!native_js_accept(p,"}") {
        token:=native_js_next(p)
        if token.kind!=.Identifier&&token.kind!=.String {native_js_fail(p.js,"Expected a module binding name.");break}
        binding:=Native_JS_Module_Binding{name=token.text,local=token.text}
        if native_js_accept(p,"as") {binding.local=native_js_next(p).text}
        append(&bindings,binding)
        if native_js_accept(p,"}") {break};native_js_expect(p,",")
    }
    return bindings
}
native_js_module_source :: proc(p:^Native_JS_Parser)->^Native_JS_Expression {
    token:=native_js_next(p);if token.kind!=.String {native_js_fail(p.js,"Expected a quoted module source.")}
    expression:=native_js_expression_new(p,.Literal);expression.value={kind=.String,text=token.text};return expression
}
native_js_parse_import :: proc(p:^Native_JS_Parser)->^Native_JS_Statement {
    native_js_expect(p,"import");statement:=native_js_statement_new(p,.Import)
    statement.bindings=make([dynamic]Native_JS_Module_Binding,native_js_allocator(p.js))
    if native_js_peek(p).kind==.String {statement.expression=native_js_module_source(p);native_js_accept(p,";");return statement}
    if native_js_peek(p).kind==.Identifier {
        append(&statement.bindings,Native_JS_Module_Binding{name="default",local=native_js_next(p).text})
        if native_js_peek(p).text!="from" {native_js_expect(p,",")}
    }
    if native_js_accept(p,"*") {native_js_expect(p,"as");append(&statement.bindings,Native_JS_Module_Binding{name="*",local=native_js_next(p).text})}
    else if native_js_peek(p).text=="{" {bindings:=native_js_parse_module_bindings(p);append(&statement.bindings,..bindings[:])}
    native_js_expect(p,"from");statement.expression=native_js_module_source(p);native_js_accept(p,";");return statement
}
native_js_parse_export :: proc(p:^Native_JS_Parser)->^Native_JS_Statement {
    native_js_expect(p,"export");statement:=native_js_statement_new(p,.Export)
    statement.bindings=make([dynamic]Native_JS_Module_Binding,native_js_allocator(p.js))
    if native_js_accept(p,"default") {
        statement.name="default";statement.expression=native_js_parse_expression(p,1);native_js_accept(p,";");return statement
    }
    if native_js_accept(p,"*") {
        local:="*";if native_js_accept(p,"as") {local=native_js_next(p).text}
        append(&statement.bindings,Native_JS_Module_Binding{name="*",local=local})
        native_js_expect(p,"from");statement.expression=native_js_module_source(p);native_js_accept(p,";");return statement
    }
    if native_js_peek(p).text=="{" {
        statement.bindings=native_js_parse_module_bindings(p)
        if native_js_accept(p,"from") {statement.expression=native_js_module_source(p)}
        native_js_accept(p,";");return statement
    }
    statement.first=native_js_parse_statement(p)
    if statement.first!=nil {
        if statement.first.kind==.Variable {append(&statement.bindings,Native_JS_Module_Binding{name=statement.first.name,local=statement.first.name})}
        else if statement.first.kind==.Block {for child in statement.first.statements {if child.kind==.Variable {if child.pattern!=nil {names:=make([dynamic]string,native_js_allocator(p.js));native_js_pattern_names(child.pattern,&names);for name in names {append(&statement.bindings,Native_JS_Module_Binding{name=name,local=name})}} else {append(&statement.bindings,Native_JS_Module_Binding{name=child.name,local=child.name})}}}}
        else {native_js_fail(p.js,"Expected exported variable, function or class declaration.")}
    }
    return statement
}
native_js_load_module :: proc(js:^Native_JS,source:Native_JS_Value)->Native_JS_Value {
    if js.host.call==nil {native_js_fail(js,"No native JavaScript module loader is configured.");return {}}
    value:=js.host.call(js.host.data,-2,"__import_module",[]Native_JS_Value{source})
    if value.kind!=.Object||value.reference==nil {native_js_fail(js,"The native module loader did not return an export namespace.");return {}}
    return value
}
native_js_execute_import :: proc(js:^Native_JS,scope:^Native_JS_Environment,statement:^Native_JS_Statement) {
    exports:=native_js_lookup(js,scope,"__exports")
    if exports.reference==nil {native_js_fail(js,"Static import is only valid in a module script.");return}
    namespace:=native_js_load_module(js,native_js_eval(js,scope,statement.expression))
    if js.error!="" {return}
    for binding in statement.bindings {scope.imports[binding.local]={namespace=namespace,name=binding.name}}
}
native_js_export_binding :: proc(js:^Native_JS,exports:Native_JS_Value,name,local:string,scope:^Native_JS_Environment) {
    exports.reference.module_exports[native_js_clone(js,name)]=native_js_clone(js,local)
    exports.reference.properties[native_js_clone(js,name)]=native_js_lookup(js,scope,local)
}
native_js_execute_export :: proc(js:^Native_JS,scope:^Native_JS_Environment,statement:^Native_JS_Statement)->Native_JS_Completion {
    exports:=native_js_lookup(js,scope,"__exports")
    if exports.reference==nil {native_js_fail(js,"Export is only valid in a module script.");return {}}
    if statement.name=="default" {exports.reference.properties["default"]=native_js_eval(js,scope,statement.expression);return {}}
    if statement.first!=nil {result:=native_js_execute(js,scope,statement.first);if result.flow!=.Normal||js.error!="" {return result}}
    if statement.expression!=nil {
        namespace:=native_js_load_module(js,native_js_eval(js,scope,statement.expression));if js.error!="" {return {}}
        for binding in statement.bindings {
            if binding.name=="*" {
                if binding.local!="*" {exports.reference.properties[binding.local]=namespace}
                else {for name in namespace.reference.properties {if name!="default" {local:=native_js_clone(js,name);scope.imports[local]={namespace=namespace,name=name};native_js_export_binding(js,exports,name,local,scope)}}}
            } else {scope.imports[binding.name]={namespace=namespace,name=binding.name};native_js_export_binding(js,exports,binding.local,binding.name,scope)}
        }
    } else {for binding in statement.bindings {native_js_export_binding(js,exports,binding.local,binding.name,scope)}}
    return {}
}
// Exports is optional so the document loader can cache a namespace before
// evaluating it, allowing cycles to refer to the same live binding storage.
native_js_evaluate_module :: proc(js:^Native_JS,source:string,initial_exports:Native_JS_Value={})->(Native_JS_Value,string) {
    exports:=initial_exports
    if !js.initialized {return {},"JavaScript runtime is not initialized."}
    previous_async,previous_await,previous_throw,previous_exception:=js.current_async,js.awaiting,js.throwing,js.exception
    js.current_async=nil;js.awaiting={};js.throwing=false;js.exception={}
    defer {js.current_async=previous_async;js.awaiting=previous_await;js.throwing=previous_throw;js.exception=previous_exception}
    if exports.reference==nil {exports=native_js_object(js)}
    scope:=native_js_environment(js,js.globals)
    exports.reference.module_scope=scope;exports.reference.module_exports=make(map[string]string,native_js_allocator(js))
    scope.values["__exports"]=exports
    scope.values["this"]={}
    js.error="";if js.fuel<=0 {js.fuel=1000000};js.throwing=false;js.exception={}
    tree:=native_js_parse(js,source);if js.error!="" {return exports,js.error}
    // Hoisted exported functions are available while cyclic dependencies link.
    for statement in tree.statements {
        declaration:=statement;if statement.kind==.Export {declaration=statement.first}
        if declaration!=nil&&declaration.function_declaration {native_js_execute(js,scope,declaration);if statement.kind==.Export {for binding in statement.bindings {native_js_export_binding(js,exports,binding.local,binding.name,scope)}}}
    }
    // Imports are instantiated before ordinary module statements execute.
    for statement in tree.statements {if statement.kind==.Import {native_js_execute_import(js,scope,statement);if js.error!="" {return exports,js.error}}}
    for statement in tree.statements {
        if statement.kind==.Import||statement.function_declaration {continue}
        if statement.kind==.Export&&statement.first!=nil&&statement.first.function_declaration {continue}
        result:=native_js_execute(js,scope,statement);native_js_unhandled(js,result);if js.error!="" {break}
    }
    return exports,js.error
}

native_js_module_sources_expression :: proc(expression:^Native_JS_Expression,sources:^[dynamic]string,depth:int=0) {
    if expression==nil||depth>128 {return}
    if expression.kind==.Call&&expression.left!=nil&&expression.left.kind==.Identifier&&expression.left.text=="__import"&&len(expression.arguments)>0 {
        argument:=expression.arguments[0];if argument.kind==.Literal&&argument.value.kind==.String {append(sources,argument.value.text)}
    }
    native_js_module_sources_expression(expression.left,sources,depth+1);native_js_module_sources_expression(expression.right,sources,depth+1);native_js_module_sources_expression(expression.third,sources,depth+1)
    for argument in expression.arguments {native_js_module_sources_expression(argument,sources,depth+1)}
    native_js_module_sources_statement(expression.body,sources,depth+1)
    for member in expression.members {native_js_module_sources_expression(member.expression,sources,depth+1)}
}
native_js_module_sources_statement :: proc(statement:^Native_JS_Statement,sources:^[dynamic]string,depth:int=0) {
    if statement==nil||depth>128 {return}
    if (statement.kind==.Import||statement.kind==.Export)&&statement.expression!=nil&&statement.name!="default"&&statement.expression.kind==.Literal&&statement.expression.value.kind==.String {append(sources,statement.expression.value.text)}
    native_js_module_sources_expression(statement.expression,sources,depth+1);native_js_module_sources_expression(statement.condition,sources,depth+1);native_js_module_sources_expression(statement.update,sources,depth+1)
    native_js_module_sources_statement(statement.first,sources,depth+1);native_js_module_sources_statement(statement.second,sources,depth+1);native_js_module_sources_statement(statement.third,sources,depth+1)
    for child in statement.statements {native_js_module_sources_statement(child,sources,depth+1)}
    for branch in statement.cases {native_js_module_sources_expression(branch.test,sources,depth+1);native_js_module_sources_statement(branch.body,sources,depth+1)}
}
native_js_module_sources :: proc(js:^Native_JS,source:string)->([]string,string) {
    if !js.initialized {return nil,"JavaScript runtime is not initialized."}
    js.error="";js.fuel=1000000
    tree:=native_js_parse(js,source);if js.error!="" {return nil,js.error}
    sources:=make([dynamic]string,native_js_allocator(js));native_js_module_sources_statement(tree,&sources)
    return sources[:],""
}

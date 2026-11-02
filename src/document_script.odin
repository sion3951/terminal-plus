package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Document scripts run in-process, without a browser, JIT, or external runtime.
// This is a deliberately bounded interpreter, not a complete ECMAScript engine.
// Unsupported grammar is reported rather than silently treated as working.
Native_JS_Kind :: enum {Undefined,Null,Bool,Number,String,Object,Array,Function,Builtin}
Native_JS_Value :: struct {
    kind:Native_JS_Kind,
    boolean:bool,
    number:f64,
    text:string,
    object:int,
    reference:^Native_JS_Object,
    function:^Native_JS_Function,
}
Native_JS_Object :: struct {
    properties:map[string]Native_JS_Value,
    items:[dynamic]Native_JS_Value,
    prototype:Native_JS_Value,
    getters,setters:map[string]Native_JS_Value,
    promise:^Native_JS_Promise,
    regex:^Native_JS_Regex,
    bound:^Native_JS_Bound,
    module_scope:^Native_JS_Environment,
    module_exports:map[string]string,
    error_object:bool,
}
Native_JS_Host :: struct {
    data:rawptr,
    get:proc(data:rawptr,object:int,name:string)->Native_JS_Value,
    set:proc(data:rawptr,object:int,name:string,value:Native_JS_Value)->bool,
    call:proc(data:rawptr,object:int,name:string,args:[]Native_JS_Value)->Native_JS_Value,
}
Native_JS_Environment :: struct {parent:^Native_JS_Environment,values:map[string]Native_JS_Value,imports:map[string]Native_JS_Module_Import}
Native_JS_Function :: struct {
    parameters:[]string,
    defaults:[]^Native_JS_Expression,
    patterns:[]^Native_JS_Expression,
    body:^Native_JS_Statement,
    expression:^Native_JS_Expression,
    scope:^Native_JS_Environment,
    parent:Native_JS_Value,
    fields:[]Native_JS_Class_Member,
    async,arrow,class_constructor,rest,static:bool,
}
Native_JS :: struct {
    arena:virtual.Arena,
    host:Native_JS_Host,
    globals:^Native_JS_Environment,
    scripts:map[string]^Native_JS_Statement,
    error:string,
    fuel,depth,eval_depth,text_depth:int,
    text_stack:[64]^Native_JS_Object,
    throwing:bool,
    exception:Native_JS_Value,
    initialized:bool,
    object_prototype,array_prototype,function_prototype,string_prototype,promise_prototype,regex_prototype:Native_JS_Value,
    jobs:[dynamic]Native_JS_Job,
    rejected_promises:[dynamic]Native_JS_Value,
    error_prototypes:map[string]Native_JS_Value,
    job_offset:int,
    running_jobs:bool,
    current_async:^Native_JS_Async,
    awaiting:Native_JS_Value,
}
Native_JS_Token :: struct {text:string,offset:int,kind:enum {End,Identifier,Number,String,Template,Regex,Punctuation}}
Native_JS_Expression_Kind :: enum {Literal,Identifier,Unary,Binary,Conditional,Assign,Member,Call,Construct,Array,Object,Function,Class,Await,Spread,Update}
Native_JS_Expression :: struct {
    kind:Native_JS_Expression_Kind,
    value:Native_JS_Value,
    text:string,
    left,right,third:^Native_JS_Expression,
    arguments:[dynamic]^Native_JS_Expression,
    keys:[dynamic]string,
    parameters:[dynamic]string,
    defaults:[dynamic]^Native_JS_Expression,
    patterns:[dynamic]^Native_JS_Expression,
    members:[dynamic]Native_JS_Class_Member,
    async,arrow,rest:bool,
    body:^Native_JS_Statement,
    postfix:bool,
}
Native_JS_Statement_Kind :: enum {Empty,Expression,Block,Variable,If,While,Do,For,For_Each,Switch,Try,Import,Export,Return,Break,Continue,Throw}
Native_JS_Statement :: struct {
    kind:Native_JS_Statement_Kind,
    expression,condition,update,pattern:^Native_JS_Expression,
    first,second,third:^Native_JS_Statement,
    cases:[dynamic]Native_JS_Case,
    statements:[dynamic]^Native_JS_Statement,
    name:string,
    keys:bool,
    function_declaration:bool,
    bindings:[dynamic]Native_JS_Module_Binding,
}
Native_JS_Case :: struct {test:^Native_JS_Expression,body:^Native_JS_Statement}
Native_JS_Parser :: struct {js:^Native_JS,tokens:[dynamic]Native_JS_Token,index,depth:int}
Native_JS_Completion :: struct {value:Native_JS_Value,flow:enum {Normal,Return,Break,Continue,Throw}}

native_js_allocator :: proc(js:^Native_JS)->runtime.Allocator {return virtual.arena_allocator(&js.arena)}
native_js_clone :: proc(js:^Native_JS,text:string)->string {return strings.clone(text,native_js_allocator(js))}
native_js_string :: proc(js:^Native_JS,text:string)->Native_JS_Value {return {kind=.String,text=native_js_clone(js,text)}}
native_js_number :: proc(number:f64)->Native_JS_Value {return {kind=.Number,number=number}}
native_js_bool :: proc(value:bool)->Native_JS_Value {return {kind=.Bool,boolean=value}}
native_js_object :: proc(js:^Native_JS)->Native_JS_Value {
    object:=new(Native_JS_Object,native_js_allocator(js));object.properties=make(map[string]Native_JS_Value,native_js_allocator(js));object.prototype=js.object_prototype
    return {kind=.Object,reference=object}
}
native_js_array :: proc(js:^Native_JS,items:[]Native_JS_Value)->Native_JS_Value {
    value:=native_js_object(js);value.kind=.Array;value.reference.prototype=js.array_prototype
    value.reference.items=make([dynamic]Native_JS_Value,len(items),native_js_allocator(js));copy(value.reference.items[:],items)
    return value
}
native_js_environment :: proc(js:^Native_JS,parent:^Native_JS_Environment)->^Native_JS_Environment {
    scope:=new(Native_JS_Environment,native_js_allocator(js));scope.parent=parent;scope.values=make(map[string]Native_JS_Value,native_js_allocator(js));scope.imports=make(map[string]Native_JS_Module_Import,native_js_allocator(js));return scope
}
native_js_init :: proc(js:^Native_JS,host:Native_JS_Host) {
    js^={host=host};if error:=virtual.arena_init_growing(&js.arena);error!=nil {return}
    js.initialized=true;js.object_prototype=native_js_object(js);js.array_prototype=native_js_object(js);js.function_prototype=native_js_object(js);js.string_prototype=native_js_object(js);js.promise_prototype=native_js_object(js);js.regex_prototype=native_js_object(js)
    js.jobs=make([dynamic]Native_JS_Job,native_js_allocator(js));js.rejected_promises=make([dynamic]Native_JS_Value,native_js_allocator(js))
    js.globals=native_js_environment(js,nil)
    js.scripts=make(map[string]^Native_JS_Statement,native_js_allocator(js))
    js.globals.values["document"]={kind=.Object,object=-1}
    js.globals.values["window"]={kind=.Object,object=-2}
    js.globals.values["globalThis"]={kind=.Object,object=-2}
    js.globals.values["this"]={kind=.Object,object=-2}
    js.globals.values["NaN"]=native_js_number(math.QNAN_F64)
    js.globals.values["Infinity"]=native_js_number(math.INF_F64)
    for name in ([]string{"String","Number","Boolean","parseInt","parseFloat","isNaN","isFinite","Math","Array","Object","JSON","console","Error","TypeError","RangeError","SyntaxError","RegExp","Promise","fetch","queueMicrotask","URL","URLSearchParams","__import"}) {js.globals.values[name]={kind=.Builtin,text=name}}
    js.error_prototypes=make(map[string]Native_JS_Value,native_js_allocator(js))
    for name in ([]string{"Error","TypeError","RangeError","SyntaxError"}) {prototype:=native_js_object(js);if name!="Error" {prototype.reference.prototype=js.error_prototypes["Error"]};js.error_prototypes[name]=prototype}
    native_js_setup_prototypes(js)
}
native_js_destroy :: proc(js:^Native_JS) {if js.initialized {virtual.arena_destroy(&js.arena)};js^={}}
native_js_fail :: proc(js:^Native_JS,message:string) {if js.error=="" {js.error=native_js_clone(js,message)}}
native_js_step :: proc(js:^Native_JS)->bool {
    if js.error!=""||js.throwing||js.awaiting.reference!=nil {return false}
    if js.arena.total_used>256*1024*1024 {native_js_fail(js,"JavaScript document memory limit reached; reload this document to release its script state.");return false}
    js.fuel-=1
    if js.fuel<0 {native_js_fail(js,"JavaScript execution limit reached.");return false};return true
}
native_js_truth :: proc(value:Native_JS_Value)->bool {
    #partial switch value.kind {
    case .Undefined,.Null:return false
    case .Bool:return value.boolean
    case .Number:return value.number!=0&&!math.is_nan(value.number)
    case .String:return len(value.text)>0
    case:return true
    }
}
native_js_text :: proc(js:^Native_JS,value:Native_JS_Value)->string {
    // Array stringification treats references already being converted as empty.
    // Track the active path, so shared (but non-cyclic) arrays still stringify twice.
    if value.reference!=nil&&(value.kind==.Array||value.kind==.Object) {
        for reference in js.text_stack[:js.text_depth] {if reference==value.reference {return ""}}
        if js.text_depth>=len(js.text_stack) {native_js_fail(js,"JavaScript string conversion nesting limit reached.");return ""}
        js.text_stack[js.text_depth]=value.reference;js.text_depth+=1
        defer {js.text_depth-=1;js.text_stack[js.text_depth]=nil}
        return native_js_text_inner(js,value)
    }
    return native_js_text_inner(js,value)
}
native_js_text_inner :: proc(js:^Native_JS,value:Native_JS_Value)->string {
    #partial switch value.kind {
    case .Undefined:return "undefined"
    case .Null:return "null"
    case .Bool:if value.boolean {return "true"};return "false"
    case .Number:return native_js_clone(js,fmt.tprintf("%g",value.number))
    case .String:return value.text
    case .Function,.Builtin:return "[function]"
    case .Array:
        result:=make([dynamic]u8,native_js_allocator(js))
        if value.reference!=nil {for item,i in value.reference.items {if !native_js_step(js) {break};if i>0 {append(&result,',')};if item.kind!=.Null&&item.kind!=.Undefined {append(&result,native_js_text(js,item))}}}
        return string(result[:])
    case .Object:if value.reference!=nil&&value.reference.error_object {name:=native_js_property(js,value,"name");message:=native_js_property(js,value,"message");return native_js_clone(js,fmt.tprintf("%s: %s",native_js_text(js,name),native_js_text(js,message)))};return "[object Object]"
    }
    return ""
}
native_js_numeric :: proc(value:Native_JS_Value)->f64 {
    #partial switch value.kind {
    case .Number:return value.number
    case .Null:return 0
    case .Bool:if value.boolean {return 1};return 0
    case .String:
        text:=strings.trim_space(value.text);if text=="" {return 0}
        number,ok:=strconv.parse_f64(text);if ok {return number};return math.QNAN_F64
    case:return math.QNAN_F64
    }
}
native_js_equal :: proc(a,b:Native_JS_Value,strict:bool)->bool {
    if a.kind!=b.kind {
        if strict {return false}
        if (a.kind==.Null&&b.kind==.Undefined)||(a.kind==.Undefined&&b.kind==.Null) {return true}
        return native_js_numeric(a)==native_js_numeric(b)
    }
    switch a.kind {
    case .Undefined,.Null:return true
    case .Bool:return a.boolean==b.boolean
    case .Number:return a.number==b.number
    case .String:return a.text==b.text
    case .Function:return a.function==b.function
    case .Builtin:return a.text==b.text
    case .Object,.Array:return a.reference==b.reference&&a.object==b.object
    }
    return false
}
native_js_lookup :: proc(js:^Native_JS,scope:^Native_JS_Environment,name:string)->Native_JS_Value {
    for cursor:=scope;cursor!=nil;cursor=cursor.parent {if binding,okay:=cursor.imports[name];okay {if binding.name=="*" {return binding.namespace};return native_js_property(js,binding.namespace,binding.name)};if value,ok:=cursor.values[name];ok {return value}}
    if js.host.get!=nil {value:=js.host.get(js.host.data,-2,name);if value.kind==.String {value.text=native_js_clone(js,value.text)};return value}
    return {}
}
native_js_bind :: proc(js:^Native_JS,scope:^Native_JS_Environment,name:string,value:Native_JS_Value,declare:bool=false) {
    if js.awaiting.reference!=nil {return}
    target:=scope
    if !declare {for cursor:=scope;cursor!=nil;cursor=cursor.parent {if _,okay:=cursor.imports[name];okay {native_js_fail(js,"Cannot assign an imported module binding.");return};if _,ok:=cursor.values[name];ok {target=cursor;break}}}
    target.values[native_js_clone(js,name)]=value
}
native_js_property :: proc(js:^Native_JS,value:Native_JS_Value,name:string)->Native_JS_Value {
    #partial switch value.kind {
    case .String:
        if name=="length" {count:=0;for _ in value.text {count+=1};return native_js_number(f64(count))}
        index,ok:=strconv.parse_int(name);if ok&&index>=0 {for ch,i in value.text {if i==index {return native_js_string(js,native_js_rune(ch))}}}
        if member,okay:=js.string_prototype.reference.properties[name];okay {return member}
    case .Array,.Object,.Function:
        if value.reference==nil {
            if js.host.get!=nil {return js.host.get(js.host.data,value.object,name)}
        } else {
            if value.reference.module_scope!=nil {if local,okay:=value.reference.module_exports[name];okay {return native_js_lookup(js,value.reference.module_scope,local)}}
            if getter,ok:=value.reference.getters[name];ok {return native_js_call_function(js,getter,nil,value)}
            if found,ok:=value.reference.properties[name];ok {return found}
            if value.reference.regex!=nil {if found,handled:=native_js_regex_property(js,value,name);handled {return found}}
            if value.kind==.Array {
                if name=="length" {return native_js_number(f64(len(value.reference.items)))}
                index,ok:=strconv.parse_int(name);if ok&&index>=0&&index<len(value.reference.items) {return value.reference.items[index]}
            }
            if name=="__proto__" {return value.reference.prototype}
            for prototype:=value.reference.prototype;prototype.reference!=nil;prototype=prototype.reference.prototype {
                if getter,ok:=prototype.reference.getters[name];ok {return native_js_call_function(js,getter,nil,value)}
                if found,ok:=prototype.reference.properties[name];ok {return found}
            }
        }
    case .Builtin:
        if name=="call"||name=="apply"||name=="bind" {return {kind=.Builtin,text=native_js_clone(js,fmt.tprintf("__method:%s",name))}}
        if name=="prototype" {if prototype,okay:=js.error_prototypes[value.text];okay {return prototype};switch value.text {case "Object":return js.object_prototype;case "Array":return js.array_prototype;case "Function":return js.function_prototype;case "String":return js.string_prototype;case "Promise":return js.promise_prototype;case "RegExp":return js.regex_prototype}}
        if value.text=="Math" {switch name {case "PI":return native_js_number(math.PI);case "E":return native_js_number(math.E)}}
        return {kind=.Builtin,text=native_js_clone(js,fmt.tprintf("%s.%s",value.text,name))}
    case:
    }
    return {}
}
native_js_set_property :: proc(js:^Native_JS,value:Native_JS_Value,name:string,item:Native_JS_Value) {
    if js.throwing||js.error!=""||js.awaiting.reference!=nil {return}
    if value.kind!=.Object&&value.kind!=.Array&&value.kind!=.Function {native_js_fail(js,"Cannot assign a property to this JavaScript value.");return}
    if value.reference==nil {
        if js.host.set==nil||!js.host.set(js.host.data,value.object,name,item) {native_js_fail(js,fmt.tprintf("Unsupported DOM property assignment: %s",name))}
        return
    }
    if value.reference.module_scope!=nil {native_js_fail(js,"Module namespaces are read-only.");return}
    if setter,okay:=value.reference.setters[name];okay {native_js_call_function(js,setter,[]Native_JS_Value{item},value);return}
    for prototype:=value.reference.prototype;prototype.reference!=nil;prototype=prototype.reference.prototype {if setter,okay:=prototype.reference.setters[name];okay {native_js_call_function(js,setter,[]Native_JS_Value{item},value);return}}
    if value.reference.regex!=nil&&name=="lastIndex" {value.reference.regex.last_index=max(0,int(native_js_numeric(item)));return}
    if name=="__proto__" {native_js_set_prototype(js,value,item);return}
    if value.kind==.Array {
        if name=="length" {length:=int(native_js_numeric(item));if length>=0&&length<=100000 {resize(&value.reference.items,length)} else {native_js_fail(js,"Invalid array length.")};return}
        index,ok:=strconv.parse_int(name)
        if ok&&index>=0&&index<=100000 {if index>=len(value.reference.items) {resize(&value.reference.items,index+1)};value.reference.items[index]=item;return}
    }
    value.reference.properties[native_js_clone(js,name)]=item
}

native_js_identifier_start :: proc(b:u8)->bool {return b=='_'||b=='$'||b>='a'&&b<='z'||b>='A'&&b<='Z'||b>=128}
native_js_identifier_part :: proc(b:u8)->bool {return native_js_identifier_start(b)||b>='0'&&b<='9'}
native_js_lex :: proc(parser:^Native_JS_Parser,script:string) {
    js:=parser.js;allocator:=native_js_allocator(js)
    parser.tokens=make([dynamic]Native_JS_Token,0,128,allocator)
    for i:=0;i<len(script)&&js.error==""; {
        if len(parser.tokens)>100000 {native_js_fail(js,"JavaScript token limit reached.");break}
        b:=script[i]
        if b==' '||b=='\t'||b=='\r'||b=='\n' {i+=1;continue}
        if i+1<len(script)&&script[i:i+2]=="//" {for i<len(script)&&script[i]!='\n' {i+=1};continue}
        if i+1<len(script)&&script[i:i+2]=="/*" {
            end:=strings.index(script[i+2:],"*/")
            if end<0 {native_js_fail(js,"Unterminated JavaScript comment.");break};i+=end+4;continue
        }
        start:=i
        token:=Native_JS_Token{offset=i}
        if native_js_identifier_start(b) {
            i+=1;for i<len(script)&&native_js_identifier_part(script[i]) {i+=1}
            token.kind=.Identifier;token.text=script[start:i]
        } else if b>='0'&&b<='9'||b=='.'&&i+1<len(script)&&script[i+1]>='0'&&script[i+1]<='9' {
            i+=1
            for i<len(script) {
                c:=script[i]
                if c>='0'&&c<='9'||c=='.'||c=='x'||c=='X'||c=='e'||c=='E'||c>='a'&&c<='f'||c>='A'&&c<='F' {i+=1}
                else if (c=='+'||c=='-')&&(script[i-1]=='e'||script[i-1]=='E') {i+=1}
                else {break}
            }
            token.kind=.Number;token.text=script[start:i]
        } else if b=='`' {
            end,closed:=native_js_template_end(script,i,0)
            if !closed {native_js_fail(js,"Unterminated JavaScript template literal.");break}
            token.kind=.Template;token.text=script[i+1:end-1];i=end
        } else if b=='/'&&native_js_regex_allowed(parser.tokens[:]) {
            end,pattern,flags,valid:=native_js_regex_literal(script,i)
            if !valid {native_js_fail(js,"Unterminated JavaScript regular expression.");break}
            token.kind=.Regex;token.text=native_js_clone(js,fmt.tprintf("%s\x00%s",pattern,flags));i=end
        } else if b=='\''||b=='"' {
            quote:=b;i+=1;bytes:=make([dynamic]u8,allocator);closed:=false
            for i<len(script) {
                c:=script[i];i+=1
                if c==quote {closed=true;break}
                if c=='\\' {
                    if i>=len(script) {break};c=script[i];i+=1
                    switch c {
                    case 'n':c='\n'
                    case 'r':c='\r'
                    case 't':c='\t'
                    case 'b':c=8
                    case 'f':c=12
                    case '0':c=0
                    case '\n':continue
                    case 'u','x':
                        digits:=4;if c=='x' {digits=2}
                        if i+digits>len(script) {native_js_fail(js,"Invalid JavaScript character escape.");break}
                        number,ok:=strconv.parse_uint(script[i:i+digits],16);i+=digits
                        if !ok {native_js_fail(js,"Invalid JavaScript character escape.");break}
                        encoded,n:=utf8.encode_rune(rune(number));append(&bytes,..encoded[:n]);continue
                    case:
                    }
                }
                append(&bytes,c)
            }
            if !closed {native_js_fail(js,"Unterminated JavaScript string.")}
            token.kind=.String;token.text=string(bytes[:])
        } else {
            token.kind=.Punctuation;count:=1
            for operator in ([]string{"...","===","!==",">>>","**=","=>","==","!=","<=",">=","&&","||","??","++","--","+=","-=","*=","/=","%=","**","<<",">>","?."}) {
                if strings.has_prefix(script[i:],operator) {count=len(operator);break}
            }
            token.text=script[i:i+count];i+=count
        }
        append(&parser.tokens,token)
    }
    append(&parser.tokens,Native_JS_Token{kind=.End,offset=len(script)})
}
native_js_peek :: proc(p:^Native_JS_Parser)->Native_JS_Token {return p.tokens[min(p.index,len(p.tokens)-1)]}
native_js_next :: proc(p:^Native_JS_Parser)->Native_JS_Token {token:=native_js_peek(p);if token.kind!=.End {p.index+=1};return token}
native_js_accept :: proc(p:^Native_JS_Parser,text:string)->bool {if native_js_peek(p).text==text {p.index+=1;return true};return false}
native_js_expect :: proc(p:^Native_JS_Parser,text:string)->bool {
    if native_js_accept(p,text) {return true}
    token:=native_js_peek(p);native_js_fail(p.js,fmt.tprintf("JavaScript syntax at byte %d: expected '%s', found '%s'.",token.offset,text,token.text));return false
}
native_js_expression_new :: proc(p:^Native_JS_Parser,kind:Native_JS_Expression_Kind)->^Native_JS_Expression {value:=new(Native_JS_Expression,native_js_allocator(p.js));value.kind=kind;return value}
native_js_statement_new :: proc(p:^Native_JS_Parser,kind:Native_JS_Statement_Kind)->^Native_JS_Statement {value:=new(Native_JS_Statement,native_js_allocator(p.js));value.kind=kind;return value}
native_js_parameters :: proc(p:^Native_JS_Parser,expression:^Native_JS_Expression) {
    expression.parameters=make([dynamic]string,native_js_allocator(p.js));expression.defaults=make([dynamic]^Native_JS_Expression,native_js_allocator(p.js));expression.patterns=make([dynamic]^Native_JS_Expression,native_js_allocator(p.js))
    if native_js_accept(p,")") {return}
    for p.js.error=="" {
        rest:=native_js_accept(p,"...")
        token:=native_js_peek(p);name:="";pattern:^Native_JS_Expression
        if token.text=="{"||token.text=="[" {pattern=native_js_parse_primary(p)}
        else {native_js_next(p);if token.kind!=.Identifier {native_js_fail(p.js,"Expected a JavaScript function parameter.");return};name=token.text}
        append(&expression.parameters,name);append(&expression.patterns,pattern)
        default:^Native_JS_Expression
        if native_js_accept(p,"=") {default=native_js_parse_expression(p,1)}
        append(&expression.defaults,default)
        if rest {expression.rest=true;if !native_js_expect(p,")") {return};break}
        if native_js_accept(p,")") {break};if !native_js_expect(p,",") {break}
    }
}
native_js_function_body :: proc(p:^Native_JS_Parser,expression:^Native_JS_Expression) {
    if native_js_peek(p).text=="{" {expression.body=native_js_parse_statement(p)}
    else {expression.left=native_js_parse_expression(p,1)}
}
native_js_parse_primary :: proc(p:^Native_JS_Parser)->^Native_JS_Expression {
    token:=native_js_next(p);result:^Native_JS_Expression
    if token.kind==.Number {
        result=native_js_expression_new(p,.Literal);number,ok:=strconv.parse_f64(token.text)
        if strings.has_prefix(token.text,"0x")||strings.has_prefix(token.text,"0X") {integer,valid:=strconv.parse_uint(token.text[2:],16);number=f64(integer);ok=valid}
        if !ok {native_js_fail(p.js,"Invalid JavaScript number.")};result.value=native_js_number(number)
    } else if token.kind==.Regex {
        result=native_js_expression_new(p,.Literal);separator:=strings.index_byte(token.text,0)
        result.value=native_js_regex(p.js,token.text[:separator],token.text[separator+1:])
    } else if token.kind==.String {result=native_js_expression_new(p,.Literal);result.value={kind=.String,text=token.text}}
    else if token.kind==.Template {result=native_js_template_expression(p,token.text)}
    else if token.text=="true"||token.text=="false"||token.text=="null"||token.text=="undefined" {
        result=native_js_expression_new(p,.Literal)
        if token.text=="null" {result.value.kind=.Null}
        else if token.text!="undefined" {result.value=native_js_bool(token.text=="true")}
    } else if token.text=="..." {result=native_js_expression_new(p,.Spread);result.left=native_js_parse_expression(p,1)}
    else if token.text=="class" {result=native_js_parse_class(p)}
    else if token.text=="await" {result=native_js_expression_new(p,.Await);result.left=native_js_parse_expression(p,14)}
    else if token.text=="import" {result=native_js_expression_new(p,.Identifier);result.text="__import";if native_js_peek(p).text!="(" {native_js_fail(p.js,"Expected dynamic import argument list.")}}
    else if token.text=="async" {
        result=native_js_parse_primary(p)
        if result.kind!=.Function {native_js_fail(p.js,"Expected an async function or arrow.")} else {result.async=true}
    }
    else if token.text=="!"||token.text=="~"||token.text=="+"||token.text=="-"||token.text=="typeof"||token.text=="void"||token.text=="delete"||token.text=="++"||token.text=="--" {
        kind:Native_JS_Expression_Kind=.Unary;if token.text=="++"||token.text=="--" {kind=.Update}
        result=native_js_expression_new(p,kind);result.text=token.text;result.left=native_js_parse_expression(p,14)
    } else if token.text=="new" {
        name:=native_js_next(p)
        if name.kind!=.Identifier {native_js_fail(p.js,"Expected a JavaScript constructor name.")}
        callee:=native_js_expression_new(p,.Identifier);callee.text=name.text
        for native_js_accept(p,".") {
            property:=native_js_next(p);if property.kind!=.Identifier {native_js_fail(p.js,"Expected a constructor property name.");break}
            member:=native_js_expression_new(p,.Member);member.left=callee;member.text=property.text;callee=member
        }
        result=native_js_expression_new(p,.Construct);result.left=callee;result.arguments=make([dynamic]^Native_JS_Expression,native_js_allocator(p.js))
        if native_js_accept(p,"(") {for p.js.error==""&&!native_js_accept(p,")") {append(&result.arguments,native_js_parse_expression(p,1));if native_js_accept(p,")") {break};if !native_js_expect(p,",") {break}}}
    } else if token.text=="function" {
        result=native_js_expression_new(p,.Function)
        if native_js_peek(p).kind==.Identifier {result.text=native_js_next(p).text}
        native_js_expect(p,"(");native_js_parameters(p,result);native_js_expect(p,"{")
        p.index-=1;result.body=native_js_parse_statement(p)
    } else if token.text=="(" {
        saved:=p.index;closing:=p.index;nesting:=1
        for closing<len(p.tokens)&&nesting>0 {if p.tokens[closing].text=="(" {nesting+=1};if p.tokens[closing].text==")" {nesting-=1};closing+=1}
        if nesting==0&&closing<len(p.tokens)&&p.tokens[closing].text=="=>" {
            result=native_js_expression_new(p,.Function);result.arrow=true;native_js_parameters(p,result);native_js_expect(p,"=>");native_js_function_body(p,result)
        } else {p.index=saved;result=native_js_parse_expression(p,1);native_js_expect(p,")")}
    } else if token.text=="[" {
        result=native_js_expression_new(p,.Array);result.arguments=make([dynamic]^Native_JS_Expression,native_js_allocator(p.js))
        for p.js.error==""&&!native_js_accept(p,"]") {
            if native_js_accept(p,",") {append(&result.arguments,native_js_expression_new(p,.Literal));continue}
            append(&result.arguments,native_js_parse_expression(p,1));if native_js_accept(p,"]") {break};if !native_js_expect(p,",") {break}
        }
    } else if token.text=="{" {
        result=native_js_expression_new(p,.Object);result.arguments=make([dynamic]^Native_JS_Expression,native_js_allocator(p.js));result.keys=make([dynamic]string,native_js_allocator(p.js))
        for p.js.error==""&&!native_js_accept(p,"}") {
            key:=native_js_next(p)
            if key.text=="..." {append(&result.keys,"...");spread:=native_js_expression_new(p,.Spread);spread.left=native_js_parse_expression(p,1);append(&result.arguments,spread);if native_js_accept(p,"}") {break};native_js_expect(p,",");continue}
            if key.kind!=.Identifier&&key.kind!=.String&&key.kind!=.Number {native_js_fail(p.js,"Unsupported JavaScript object key.");break}
            append(&result.keys,key.text)
            if native_js_accept(p,":") {append(&result.arguments,native_js_parse_expression(p,1))}
            else if native_js_accept(p,"(") {method:=native_js_expression_new(p,.Function);native_js_parameters(p,method);method.body=native_js_parse_statement(p);append(&result.arguments,method)}
            else {item:=native_js_expression_new(p,.Identifier);item.text=key.text;if native_js_accept(p,"=") {assignment:=native_js_expression_new(p,.Assign);assignment.text="=";assignment.postfix=true;assignment.left=item;assignment.right=native_js_parse_expression(p,1);item=assignment};append(&result.arguments,item)}
            if native_js_accept(p,"}") {break};if !native_js_expect(p,",") {break}
        }
    } else if token.kind==.Identifier {
        if token.text=="yield"||token.text=="import"||token.text=="export" {native_js_fail(p.js,fmt.tprintf("JavaScript '%s' syntax is not yet supported by the native engine.",token.text))}
        if native_js_accept(p,"=>") {result=native_js_expression_new(p,.Function);result.parameters=make([dynamic]string,native_js_allocator(p.js));append(&result.parameters,token.text);result.arrow=true;native_js_function_body(p,result)}
        else {result=native_js_expression_new(p,.Identifier);result.text=token.text}
    } else {native_js_fail(p.js,fmt.tprintf("Unsupported JavaScript expression '%s' at byte %d.",token.text,token.offset));return native_js_expression_new(p,.Literal)}
    for p.js.error=="" {
        if native_js_accept(p,".")||native_js_accept(p,"?.") {
            member:=native_js_expression_new(p,.Member);member.left=result;key:=native_js_next(p)
            if key.kind!=.Identifier {native_js_fail(p.js,"Expected a JavaScript property name.");break};member.text=key.text;result=member
        } else if native_js_accept(p,"[") {member:=native_js_expression_new(p,.Member);member.left=result;member.right=native_js_parse_expression(p,1);native_js_expect(p,"]");result=member}
        else if native_js_accept(p,"(") {
            call:=native_js_expression_new(p,.Call);call.left=result;call.arguments=make([dynamic]^Native_JS_Expression,native_js_allocator(p.js))
            for p.js.error==""&&!native_js_accept(p,")") {append(&call.arguments,native_js_parse_expression(p,1));if native_js_accept(p,")") {break};if !native_js_expect(p,",") {break}}
            result=call
        } else if native_js_peek(p).text=="++"||native_js_peek(p).text=="--" {update:=native_js_expression_new(p,.Update);update.text=native_js_next(p).text;update.left=result;update.postfix=true;result=update}
        else if native_js_peek(p).kind==.Template {native_js_fail(p.js,"Tagged JavaScript templates are not yet supported.");break}
        else {break}
    }
    return result
}
native_js_precedence :: proc(operator:string)->int {
    switch operator {
    case "=","+=","-=","*=","/=","%=":return 1
    case "?":return 2
    case "??","||":return 3
    case "&&":return 4
    case "|":return 5
    case "^":return 6
    case "&":return 7
    case "==","!=","===","!==":return 8
    case "<",">","<=",">=","in","instanceof":return 9
    case "<<",">>",">>>":return 10
    case "+","-":return 11
    case "*","/","%":return 12
    case "**":return 13
    }
    return 0
}
native_js_parse_expression :: proc(p:^Native_JS_Parser,minimum:int)->^Native_JS_Expression {
    p.depth+=1;defer {p.depth-=1}
    if p.depth>128 {native_js_fail(p.js,"JavaScript nesting limit reached.");return nil}
    left:=native_js_parse_primary(p)
    for p.js.error=="" {
        operator:=native_js_peek(p).text;precedence:=native_js_precedence(operator)
        if precedence==0||precedence<minimum {break};native_js_next(p)
        if operator=="?" {
            expression:=native_js_expression_new(p,.Conditional);expression.left=left;expression.right=native_js_parse_expression(p,1);native_js_expect(p,":");expression.third=native_js_parse_expression(p,2);left=expression;continue
        }
        right_minimum:=precedence+1
        kind:Native_JS_Expression_Kind=.Binary
        if precedence==1 {kind=.Assign;right_minimum=precedence}
        if operator=="**" {right_minimum=precedence}
        expression:=native_js_expression_new(p,kind);expression.text=operator;expression.left=left;expression.right=native_js_parse_expression(p,right_minimum);left=expression
    }
    return left
}
native_js_parse_variable :: proc(p:^Native_JS_Parser)->^Native_JS_Statement {
    declaration:=native_js_statement_new(p,.Block);declaration.statements=make([dynamic]^Native_JS_Statement,native_js_allocator(p.js))
    for p.js.error=="" {
        token:=native_js_peek(p);statement:=native_js_statement_new(p,.Variable)
        if token.text=="{"||token.text=="[" {statement.pattern=native_js_parse_primary(p)}
        else {native_js_next(p);if token.kind!=.Identifier {native_js_fail(p.js,"Expected a JavaScript variable name.");break};statement.name=token.text}
        if native_js_accept(p,"=") {statement.expression=native_js_parse_expression(p,1)}
        append(&declaration.statements,statement)
        if !native_js_accept(p,",") {break}
    }
    return declaration
}
native_js_parse_statement :: proc(p:^Native_JS_Parser)->^Native_JS_Statement {
    if p.js.error!="" {return nil}
    p.depth+=1;defer {p.depth-=1}
    if p.depth>128 {native_js_fail(p.js,"JavaScript statement nesting limit reached.");return nil}
    token:=native_js_peek(p)
    if token.text=="import"&&p.index+1<len(p.tokens)&&p.tokens[p.index+1].text!="(" {return native_js_parse_import(p)}
    if token.text=="export" {return native_js_parse_export(p)}
    if native_js_accept(p,";") {return native_js_statement_new(p,.Empty)}
    if native_js_accept(p,"{") {
        result:=native_js_statement_new(p,.Block);result.statements=make([dynamic]^Native_JS_Statement,native_js_allocator(p.js))
        for p.js.error==""&&!native_js_accept(p,"}") {
            if native_js_peek(p).kind==.End {native_js_fail(p.js,"Unterminated JavaScript block.");break}
            append(&result.statements,native_js_parse_statement(p))
        }
        return result
    }
    if token.text=="let"||token.text=="const"||token.text=="var" {native_js_next(p);result:=native_js_parse_variable(p);native_js_accept(p,";");return result}
    if native_js_accept(p,"if") {
        result:=native_js_statement_new(p,.If);native_js_expect(p,"(");result.condition=native_js_parse_expression(p,1);native_js_expect(p,")");result.first=native_js_parse_statement(p)
        if native_js_accept(p,"else") {result.second=native_js_parse_statement(p)};return result
    }
    if native_js_accept(p,"while") {
        result:=native_js_statement_new(p,.While);native_js_expect(p,"(");result.condition=native_js_parse_expression(p,1);native_js_expect(p,")");result.first=native_js_parse_statement(p);return result
    }
    if native_js_accept(p,"for") {
        result:=native_js_statement_new(p,.For);native_js_expect(p,"(")
        token=native_js_peek(p)
        if token.text=="let"||token.text=="const"||token.text=="var" {
            if p.index+2<len(p.tokens)&&(p.tokens[p.index+2].text=="of"||p.tokens[p.index+2].text=="in") {
                native_js_next(p);result.kind=.For_Each;result.name=native_js_next(p).text;result.keys=native_js_next(p).text=="in";result.expression=native_js_parse_expression(p,1);native_js_expect(p,")");result.first=native_js_parse_statement(p);return result
            }
            native_js_next(p);result.first=native_js_parse_variable(p)
            if native_js_peek(p).text=="of"||native_js_peek(p).text=="in" {
                if len(result.first.statements)!=1 {native_js_fail(p.js,"A for-of binding needs one declaration.");return result}
                binding:=result.first.statements[0];result.kind=.For_Each;result.name=binding.name;result.pattern=binding.pattern;result.keys=native_js_next(p).text=="in"
                result.expression=native_js_parse_expression(p,1);native_js_expect(p,")");result.first=native_js_parse_statement(p);return result
            }
        } else if token.text!=";" {result.expression=native_js_parse_expression(p,1)}
        native_js_expect(p,";")
        if native_js_peek(p).text!=";" {result.condition=native_js_parse_expression(p,1)};native_js_expect(p,";")
        if native_js_peek(p).text!=")" {result.update=native_js_parse_expression(p,1)};native_js_expect(p,")");result.second=native_js_parse_statement(p);return result
    }
    if native_js_accept(p,"return") {
        result:=native_js_statement_new(p,.Return)
        if native_js_peek(p).text!=";"&&native_js_peek(p).text!="}"&&native_js_peek(p).kind!=.End {result.expression=native_js_parse_expression(p,1)};native_js_accept(p,";");return result
    }
    if native_js_accept(p,"break") {native_js_accept(p,";");return native_js_statement_new(p,.Break)}
    if native_js_accept(p,"continue") {native_js_accept(p,";");return native_js_statement_new(p,.Continue)}
    if native_js_accept(p,"throw") {result:=native_js_statement_new(p,.Throw);result.expression=native_js_parse_expression(p,1);native_js_accept(p,";");return result}
    if token.text=="function"||token.text=="async"||token.text=="class" {
        expression:=native_js_parse_expression(p,1)
        if expression==nil||(expression.kind!=.Function&&expression.kind!=.Class)||expression.text=="" {native_js_fail(p.js,"A JavaScript function declaration needs a name.")}
        result:=native_js_statement_new(p,.Variable);result.function_declaration=expression!=nil&&expression.kind==.Function;if expression!=nil {result.name=expression.text};result.expression=expression;return result
    }
    if native_js_accept(p,"do") {
        result:=native_js_statement_new(p,.Do);result.first=native_js_parse_statement(p)
        native_js_expect(p,"while");native_js_expect(p,"(");result.condition=native_js_parse_expression(p,1);native_js_expect(p,")");native_js_accept(p,";");return result
    }
    if native_js_accept(p,"switch") {
        result:=native_js_statement_new(p,.Switch);result.cases=make([dynamic]Native_JS_Case,native_js_allocator(p.js))
        native_js_expect(p,"(");result.expression=native_js_parse_expression(p,1);native_js_expect(p,")");native_js_expect(p,"{")
        has_default:=false
        for p.js.error==""&&!native_js_accept(p,"}") {
            branch:=Native_JS_Case{}
            if native_js_accept(p,"case") {branch.test=native_js_parse_expression(p,1)}
            else if native_js_accept(p,"default") {if has_default {native_js_fail(p.js,"Duplicate default in JavaScript switch.")};has_default=true}
            else {native_js_fail(p.js,"Expected case or default in JavaScript switch.");break}
            native_js_expect(p,":");branch.body=native_js_statement_new(p,.Block);branch.body.statements=make([dynamic]^Native_JS_Statement,native_js_allocator(p.js))
            for p.js.error=="" {
                next:=native_js_peek(p)
                if next.text=="case"||next.text=="default"||next.text=="}" {break}
                if next.kind==.End {native_js_fail(p.js,"Unterminated JavaScript switch.");break}
                append(&branch.body.statements,native_js_parse_statement(p))
            }
            append(&result.cases,branch)
        }
        return result
    }
    if native_js_accept(p,"try") {
        result:=native_js_statement_new(p,.Try)
        if native_js_peek(p).text!="{" {native_js_fail(p.js,"JavaScript try needs a block.");return result}
        result.first=native_js_parse_statement(p)
        if native_js_accept(p,"catch") {
            if native_js_accept(p,"(") {
                binding:=native_js_next(p);if binding.kind!=.Identifier {native_js_fail(p.js,"Expected a JavaScript catch binding.")};result.name=binding.text;native_js_expect(p,")")
            }
            if native_js_peek(p).text!="{" {native_js_fail(p.js,"JavaScript catch needs a block.");return result}
            result.second=native_js_parse_statement(p)
        }
        if native_js_accept(p,"finally") {
            if native_js_peek(p).text!="{" {native_js_fail(p.js,"JavaScript finally needs a block.");return result}
            result.third=native_js_parse_statement(p)
        }
        if result.second==nil&&result.third==nil {native_js_fail(p.js,"JavaScript try needs catch or finally.")}
        return result
    }
    if token.text=="with" {native_js_fail(p.js,"JavaScript with statements are not supported by the native engine.");return nil}
    result:=native_js_statement_new(p,.Expression);result.expression=native_js_parse_expression(p,1);native_js_accept(p,";");return result
}

native_js_binary :: proc(js:^Native_JS,operator:string,left,right:Native_JS_Value)->Native_JS_Value {
    a,b:=native_js_numeric(left),native_js_numeric(right)
    switch operator {
    case "+":if left.kind==.String||right.kind==.String {return native_js_string(js,strings.concatenate([]string{native_js_text(js,left),native_js_text(js,right)},native_js_allocator(js)))};return native_js_number(a+b)
    case "-":return native_js_number(a-b)
    case "*":return native_js_number(a*b)
    case "/":return native_js_number(a/b)
    case "%":return native_js_number(math.mod(a,b))
    case "**":return native_js_number(math.pow(a,b))
    case "==","===":return native_js_bool(native_js_equal(left,right,operator=="==="))
    case "!=","!==":return native_js_bool(!native_js_equal(left,right,operator=="!=="))
    case "<":if left.kind==.String&&right.kind==.String {return native_js_bool(left.text<right.text)};return native_js_bool(a<b)
    case ">":if left.kind==.String&&right.kind==.String {return native_js_bool(left.text>right.text)};return native_js_bool(a>b)
    case "<=":if left.kind==.String&&right.kind==.String {return native_js_bool(left.text<=right.text)};return native_js_bool(a<=b)
    case ">=":if left.kind==.String&&right.kind==.String {return native_js_bool(left.text>=right.text)};return native_js_bool(a>=b)
    case "&":return native_js_number(f64(i32(a)&i32(b)))
    case "|":return native_js_number(f64(i32(a)|i32(b)))
    case "^":return native_js_number(f64(i32(a)~i32(b)))
    case "<<":return native_js_number(f64(i32(a)<<u32(i32(b)&31)))
    case ">>":return native_js_number(f64(i32(a)>>u32(i32(b)&31)))
    case ">>>":return native_js_number(f64(u32(i32(a))>>u32(i32(b)&31)))
    case "instanceof":return native_js_bool(native_js_instanceof(js,left,right))
    case "in":
        if right.reference!=nil {name:=native_js_text(js,left);for current:=right;current.reference!=nil;current=current.reference.prototype {if _,exists:=current.reference.properties[name];exists {return native_js_bool(true)};if _,exists:=current.reference.getters[name];exists {return native_js_bool(true)}};return native_js_bool(false)}
        return native_js_bool(native_js_property(js,right,native_js_text(js,left)).kind!=.Undefined)
    }
    native_js_fail(js,fmt.tprintf("Unsupported JavaScript operator: %s",operator));return {}
}
native_js_member_key :: proc(js:^Native_JS,scope:^Native_JS_Environment,expression:^Native_JS_Expression)->string {
    if expression.right!=nil {return native_js_text(js,native_js_eval(js,scope,expression.right))};return expression.text
}
native_js_assign :: proc(js:^Native_JS,scope:^Native_JS_Environment,target:^Native_JS_Expression,value:Native_JS_Value) {
    if js.throwing||js.error!=""||js.awaiting.reference!=nil {return}
    if target==nil {native_js_fail(js,"Invalid JavaScript assignment.");return}
    #partial switch target.kind {
    case .Identifier:native_js_bind(js,scope,target.text,value)
    case .Member:native_js_set_property(js,native_js_eval(js,scope,target.left),native_js_member_key(js,scope,target),value)
    case:native_js_fail(js,"Invalid JavaScript assignment target.")
    }
}
native_js_call_function :: proc(js:^Native_JS,value:Native_JS_Value,args:[]Native_JS_Value,this_value:Native_JS_Value)->Native_JS_Value {
    if !native_js_step(js) {return {}}
    js.depth+=1;defer {js.depth-=1}
    if js.depth>64 {native_js_fail(js,"JavaScript call depth exceeded.");return {}}
    if value.kind==.Builtin {
        if strings.has_prefix(value.text,"__method:") {return native_js_method(js,this_value,value.text[9:],args)}
        if value.reference!=nil&&value.reference.bound!=nil {bound:=value.reference.bound;combined:=make([dynamic]Native_JS_Value,native_js_allocator(js));append(&combined,..bound.arguments);append(&combined,..args);return native_js_call_function(js,bound.callable,combined[:],bound.receiver)}
        if value.reference!=nil&&value.reference.promise!=nil {if value.text=="__promise_resolve" {native_js_promise_resolve(js,{kind=.Object,reference=value.reference},native_js_argument(args,0));return {}};if value.text=="__promise_reject" {native_js_promise_reject(js,{kind=.Object,reference=value.reference},native_js_argument(args,0));return {}}}
        return native_js_builtin(js,value.text,args)
    }
    if value.kind!=.Function||value.function==nil {native_js_fail(js,"The JavaScript value is not callable.");return {}}
    function:=value.function
    if function.async {return native_js_async_start(js,value,args,this_value)}
    previous_async:=js.current_async;js.current_async=nil;defer {js.current_async=previous_async}
    if function.class_constructor&&function.parent.kind!=.Function {native_js_initialize_fields(js,value,this_value)}
    scope:=native_js_environment(js,function.scope)
    scope.values["__constructor"]=value
    receiver:=this_value;if function.arrow {receiver=native_js_lookup(js,function.scope,"this")}
    scope.values["this"]=receiver;scope.values["__super"]=function.parent;scope.values["__super_static"]=native_js_bool(function.static);scope.values["arguments"]=native_js_array(js,args)
    for name,i in function.parameters {
        argument:=native_js_argument(args,i)
        if function.rest&&i==len(function.parameters)-1 {argument=native_js_array(js,args[min(i,len(args)):])}
        if argument.kind==.Undefined&&i<len(function.defaults)&&function.defaults[i]!=nil {argument=native_js_eval(js,scope,function.defaults[i])}
        if i<len(function.patterns)&&function.patterns[i]!=nil {native_js_bind_pattern(js,scope,function.patterns[i],argument,true)} else {scope.values[name]=argument}
    }
    if function.expression!=nil {return native_js_eval(js,scope,function.expression)}
    result:=native_js_execute(js,scope,function.body)
    if result.flow==.Return {return result.value}
    if result.flow==.Throw {js.throwing=true;js.exception=result.value}
    return {}
}
native_js_eval :: proc(js:^Native_JS,scope:^Native_JS_Environment,expression:^Native_JS_Expression)->Native_JS_Value {
    js.eval_depth+=1;defer {js.eval_depth-=1}
    if js.eval_depth>256 {native_js_fail(js,"JavaScript expression nesting limit reached.");return {}}
    if js.current_async!=nil&&expression!=nil {if js.current_async.rejected_expression==expression {js.throwing=true;js.exception=js.current_async.await_exception;return {}};if value,okay:=js.current_async.cache[expression];okay {return value}}
    value:=native_js_eval_inner(js,scope,expression)
    if js.current_async!=nil&&expression!=nil&&js.awaiting.reference==nil&&js.error==""&&!js.throwing {js.current_async.cache[expression]=value}
    return value
}
native_js_eval_inner :: proc(js:^Native_JS,scope:^Native_JS_Environment,expression:^Native_JS_Expression)->Native_JS_Value {
    if expression==nil||!native_js_step(js) {return {}}
    switch expression.kind {
    case .Literal:if expression.value.reference!=nil&&expression.value.reference.regex!=nil {return native_js_regex_clone(js,expression.value)};return expression.value
    case .Identifier:if expression.text=="super" {parent:=native_js_lookup(js,scope,"__super");if native_js_truth(native_js_lookup(js,scope,"__super_static")) {return parent};return native_js_property(js,parent,"prototype")};return native_js_lookup(js,scope,expression.text)
    case .Array:
        result:=native_js_array(js,nil)
        for argument in expression.arguments {if argument.kind==.Spread {native_js_spread_items(js,&result.reference.items,native_js_eval(js,scope,argument.left))} else {append(&result.reference.items,native_js_eval(js,scope,argument))}};return result
    case .Object:
        result:=native_js_object(js)
        for argument,i in expression.arguments {if argument.kind==.Assign&&argument.postfix {native_js_fail(js,"Invalid object literal shorthand initializer.");return {}};if argument.kind==.Spread {value:=native_js_eval(js,scope,argument.left);if value.reference!=nil {for key,item in value.reference.properties {result.reference.properties[key]=item}}} else {result.reference.properties[expression.keys[i]]=native_js_eval(js,scope,argument)}};return result
    case .Spread:native_js_fail(js,"Spread syntax is only valid inside an array, object or argument list.");return {}
    case .Class:return native_js_class_value(js,scope,expression)
    case .Await:
        if js.current_async==nil {native_js_fail(js,"await requires an async function.");return {}}
        value:=native_js_eval(js,scope,expression.left)
        if js.awaiting.reference!=nil||js.throwing||js.error!="" {return {}}
        if !native_js_is_promise(value) {promise:=native_js_promise(js);native_js_promise_resolve(js,promise,value);value=promise}
        js.current_async.await_expression=expression;js.awaiting=value;return {}
    case .Function:
        function:=new(Native_JS_Function,native_js_allocator(js));function.parameters=expression.parameters[:];function.defaults=expression.defaults[:];function.patterns=expression.patterns[:];function.async=expression.async;function.arrow=expression.arrow;function.rest=expression.rest;function.body=expression.body;function.expression=expression.left;function.scope=scope
        object:=native_js_object(js);object.reference.prototype=js.function_prototype
        result:=Native_JS_Value{kind=.Function,function=function,reference=object.reference}
        if !function.arrow {prototype:=native_js_object(js);prototype.reference.properties["constructor"]=result;result.reference.properties["prototype"]=prototype}
        if expression.text!="" {scope.values[expression.text]=result};return result
    case .Member:
        result:=native_js_property(js,native_js_eval(js,scope,expression.left),native_js_member_key(js,scope,expression))
        if result.kind==.String {result.text=native_js_clone(js,result.text)};return result
    case .Assign:
        right:=native_js_eval(js,scope,expression.right)
        if expression.text!="=" {right=native_js_binary(js,expression.text[:1],native_js_eval(js,scope,expression.left),right)}
        native_js_assign(js,scope,expression.left,right);return right
    case .Update:
        before:=native_js_eval(js,scope,expression.left);change:f64=1;if expression.text=="--" {change=-1}
        after:=native_js_number(native_js_numeric(before)+change);native_js_assign(js,scope,expression.left,after)
        if expression.postfix {return before};return after
    case .Unary:
        value:=native_js_eval(js,scope,expression.left)
        if js.throwing||js.error!="" {return {}}
        switch expression.text {
        case "!":return native_js_bool(!native_js_truth(value))
        case "~":return native_js_number(f64(~i32(native_js_numeric(value))))
        case "+":return native_js_number(native_js_numeric(value))
        case "-":return native_js_number(-native_js_numeric(value))
        case "void":return {}
        case "typeof":
            kind:="undefined"
            #partial switch value.kind {case .Null,.Array,.Object:kind="object";case .Bool:kind="boolean";case .Number:kind="number";case .String:kind="string";case .Function,.Builtin:kind="function";case .Undefined:}
            return native_js_string(js,kind)
        case "delete":
            if expression.left.kind==.Member {
                object:=native_js_eval(js,scope,expression.left.left)
                if object.reference!=nil {delete_key(&object.reference.properties,native_js_member_key(js,scope,expression.left));return native_js_bool(true)}
            }
            native_js_fail(js,"Deleting native DOM properties is not supported.");return native_js_bool(false)
        }
    case .Binary:
        left:=native_js_eval(js,scope,expression.left)
        if expression.text=="&&" {if !native_js_truth(left) {return left};return native_js_eval(js,scope,expression.right)}
        if expression.text=="||" {if native_js_truth(left) {return left};return native_js_eval(js,scope,expression.right)}
        if expression.text=="??" {if left.kind!=.Undefined&&left.kind!=.Null {return left};return native_js_eval(js,scope,expression.right)}
        return native_js_binary(js,expression.text,left,native_js_eval(js,scope,expression.right))
    case .Conditional:
        if native_js_truth(native_js_eval(js,scope,expression.left)) {return native_js_eval(js,scope,expression.right)};return native_js_eval(js,scope,expression.third)
    case .Construct:
        args:=native_js_arguments(js,scope,expression.arguments[:])
        callee:=native_js_eval(js,scope,expression.left)
        if js.throwing||js.error!="" {return {}}
        if callee.kind==.Builtin {return native_js_builtin(js,callee.text,args)}
        if callee.kind!=.Function {native_js_fail(js,"This JavaScript value is not a constructor.");return {}}
        return native_js_construct(js,callee,args)
    case .Call:
        args:=native_js_arguments(js,scope,expression.arguments[:])
        if js.throwing||js.error!="" {return {}}
        if expression.left.kind==.Identifier&&expression.left.text=="super" {
            constructor:=native_js_lookup(js,scope,"__constructor");receiver:=native_js_lookup(js,scope,"this")
            result:=native_js_call_function(js,native_js_lookup(js,scope,"__super"),args,receiver)
            native_js_initialize_fields(js,constructor,receiver);return result
        }
        if expression.left.kind==.Member {
            receiver:=native_js_eval(js,scope,expression.left.left);name:=native_js_member_key(js,scope,expression.left)
            if js.throwing||js.error!="" {return {}}
            member:=native_js_property(js,receiver,name)
            if member.kind==.Function||member.kind==.Builtin {this_value:=receiver;if expression.left.left.kind==.Identifier&&expression.left.left.text=="super" {this_value=native_js_lookup(js,scope,"this")};return native_js_call_function(js,member,args,this_value)}
            if receiver.kind==.Object&&receiver.reference==nil {
                if js.host.call!=nil {value:=js.host.call(js.host.data,receiver.object,name,args);if value.kind==.String {value.text=native_js_clone(js,value.text)};return value}
                native_js_fail(js,fmt.tprintf("Native DOM method '%s' is unavailable.",name));return {}
            }
            return native_js_method(js,receiver,name,args)
        }
        return native_js_call_function(js,native_js_eval(js,scope,expression.left),args,{kind=.Object,object=-2})
    }
    return {}
}
native_js_execute :: proc(js:^Native_JS,scope:^Native_JS_Environment,statement:^Native_JS_Statement)->Native_JS_Completion {
    result:=native_js_execute_inner(js,scope,statement)
    if js.throwing {result={flow=.Throw,value=js.exception};js.throwing=false}
    return result
}
native_js_execute_inner :: proc(js:^Native_JS,scope:^Native_JS_Environment,statement:^Native_JS_Statement)->Native_JS_Completion {
    if statement==nil||!native_js_step(js) {return {}}
    switch statement.kind {
    case .Import:native_js_execute_import(js,scope,statement);return {}
    case .Export:return native_js_execute_export(js,scope,statement)
    case .Empty:return {}
    case .Expression:return {value=native_js_eval(js,scope,statement.expression)}
    case .Variable:
        value:=native_js_eval(js,scope,statement.expression);if js.throwing||js.error!="" {return {}}
        if statement.pattern!=nil {native_js_bind_pattern(js,scope,statement.pattern,value,true)} else {native_js_bind(js,scope,statement.name,value,true)};return {}
    case .Block:
        result:Native_JS_Completion
        // Function declarations are visible throughout their containing block.
        for child in statement.statements {if child!=nil&&child.function_declaration {native_js_execute(js,scope,child)}}
        for child in statement.statements {if child!=nil&&child.function_declaration {continue};result=native_js_execute(js,scope,child);if result.flow!=.Normal||js.error!="" {break}}
        return result
    case .If:
        if native_js_truth(native_js_eval(js,scope,statement.condition)) {return native_js_execute(js,scope,statement.first)};return native_js_execute(js,scope,statement.second)
    case .While:
        for native_js_step(js)&&native_js_truth(native_js_eval(js,scope,statement.condition)) {
            result:=native_js_execute(js,scope,statement.first)
            if result.flow==.Return||result.flow==.Throw {return result};if result.flow==.Break {break}
        }
    case .Do:
        for native_js_step(js) {
            result:=native_js_execute(js,scope,statement.first)
            if result.flow==.Return||result.flow==.Throw {return result};if result.flow==.Break {break}
            if !native_js_truth(native_js_eval(js,scope,statement.condition)) {break}
        }
    case .For:
        initial:=native_js_execute(js,scope,statement.first);if initial.flow!=.Normal {return initial}
        native_js_eval(js,scope,statement.expression)
        for native_js_step(js)&&(statement.condition==nil||native_js_truth(native_js_eval(js,scope,statement.condition))) {
            result:=native_js_execute(js,scope,statement.second)
            if result.flow==.Return||result.flow==.Throw {return result};if result.flow==.Break {break}
            native_js_eval(js,scope,statement.update)
        }
    case .For_Each:
        collection:=native_js_eval(js,scope,statement.expression)
        if js.throwing||js.error!="" {return {}}
        values:=make([dynamic]Native_JS_Value,native_js_allocator(js))
        if collection.kind==.Array&&collection.reference!=nil {
            for item,i in collection.reference.items {if statement.keys {append(&values,native_js_string(js,fmt.tprintf("%d",i)))} else {append(&values,item)}}
        } else if collection.reference!=nil {
            for key,value in collection.reference.properties {if statement.keys {append(&values,native_js_string(js,key))} else {append(&values,value)}}
        } else if collection.kind==.String {for ch in collection.text {append(&values,native_js_string(js,native_js_rune(ch)))}}
        else {native_js_fail(js,"JavaScript for-of expects an iterable collection.")}
        for value in values {
            if !native_js_step(js) {break};if statement.pattern!=nil {native_js_bind_pattern(js,scope,statement.pattern,value,true)} else {native_js_bind(js,scope,statement.name,value,true)}
            result:=native_js_execute(js,scope,statement.first);if result.flow==.Return||result.flow==.Throw {return result};if result.flow==.Break {break}
        }
    case .Switch:
        target:=native_js_eval(js,scope,statement.expression);selected,fallback:= -1,-1
        for branch,i in statement.cases {
            if branch.test==nil {fallback=i;continue}
            if native_js_equal(target,native_js_eval(js,scope,branch.test),true) {selected=i;break}
        }
        if selected<0 {selected=fallback}
        if selected>=0 {for branch in statement.cases[selected:] {result:=native_js_execute(js,scope,branch.body);if result.flow==.Break {break};if result.flow!=.Normal {return result}}}
    case .Try:
        result:=native_js_execute(js,scope,statement.first)
        if result.flow==.Throw&&statement.second!=nil {
            catch_scope:=native_js_environment(js,scope)
            if statement.name!="" {catch_scope.values[statement.name]=result.value}
            result=native_js_execute(js,catch_scope,statement.second)
        }
        if statement.third!=nil {final:=native_js_execute(js,scope,statement.third);if final.flow!=.Normal {return final}}
        return result
    case .Return:return {value=native_js_eval(js,scope,statement.expression),flow=.Return}
    case .Break:return {flow=.Break}
    case .Continue:return {flow=.Continue}
    case .Throw:return {flow=.Throw,value=native_js_eval(js,scope,statement.expression)}
    }
    return {}
}
native_js_argument :: proc(args:[]Native_JS_Value,index:int)->Native_JS_Value {if index>=0&&index<len(args) {return args[index]};return {}}
native_js_builtin :: proc(js:^Native_JS,name:string,args:[]Native_JS_Value)->Native_JS_Value {
    first:=native_js_argument(args,0);second:=native_js_argument(args,1)
    if value,handled:=native_js_extended_builtin(js,name,args);handled {return value}
    switch name {
    case "Error","TypeError","RangeError","SyntaxError":
        result:=native_js_object(js);result.reference.error_object=true;result.reference.prototype=js.error_prototypes[name];result.reference.properties["name"]=native_js_string(js,name)
        message:="";if len(args)>0 {message=native_js_text(js,first)};result.reference.properties["message"]=native_js_string(js,message);return result
    case "Object":if first.kind==.Object||first.kind==.Array {return first};return native_js_object(js)
    case "Array":
        if len(args)==1&&first.kind==.Number {length:=int(first.number);if length<0||length>1000000||f64(length)!=first.number {native_js_fail(js,"Invalid array length.");return {}};result:=native_js_array(js,nil);resize(&result.reference.items,length);return result}
        return native_js_array(js,args)
    case "String":if len(args)==0 {return native_js_string(js,"")};return native_js_string(js,native_js_text(js,first))
    case "Number":if len(args)==0 {return native_js_number(0)};return native_js_number(native_js_numeric(first))
    case "Boolean":return native_js_bool(native_js_truth(first))
    case "isNaN":return native_js_bool(math.is_nan(native_js_numeric(first)))
    case "isFinite":number:=native_js_numeric(first);return native_js_bool(!math.is_nan(number)&&!math.is_inf(number))
    case "parseFloat":
        text:=strings.trim_space(native_js_text(js,first));end:=0
        for end<len(text) {c:=text[end];if c>='0'&&c<='9'||c=='.'||c=='-'||c=='+'||c=='e'||c=='E' {end+=1} else {break}}
        value,ok:=strconv.parse_f64(text[:end]);if !ok {value=math.QNAN_F64};return native_js_number(value)
    case "parseInt":
        text:=strings.trim_space(native_js_text(js,first));base:=10
        if second.kind!=.Undefined {base=int(native_js_numeric(second));if base==0 {base=10}}
        negative:=false;if len(text)>0&&(text[0]=='-'||text[0]=='+') {negative=text[0]=='-';text=text[1:]}
        if strings.has_prefix(text,"0x")||strings.has_prefix(text,"0X") {if second.kind==.Undefined {base=16};text=text[2:]}
        if base<2||base>36 {return native_js_number(math.QNAN_F64)}
        number:f64;count:=0
        for c in transmute([]u8)text {digit:=int(c)-'0';if c>='a'&&c<='z' {digit=int(c)-'a'+10};if c>='A'&&c<='Z' {digit=int(c)-'A'+10};if digit<0||digit>=base {break};number=number*f64(base)+f64(digit);count+=1}
        if count==0 {return native_js_number(math.QNAN_F64)};if negative {number=-number};return native_js_number(number)
    case "Math.abs":return native_js_number(abs(native_js_numeric(first)))
    case "Math.floor":return native_js_number(math.floor(native_js_numeric(first)))
    case "Math.ceil":return native_js_number(math.ceil(native_js_numeric(first)))
    case "Math.round":return native_js_number(math.floor(native_js_numeric(first)+0.5))
    case "Math.trunc":return native_js_number(math.trunc(native_js_numeric(first)))
    case "Math.sqrt":return native_js_number(math.sqrt(native_js_numeric(first)))
    case "Math.pow":return native_js_number(math.pow(native_js_numeric(first),native_js_numeric(second)))
    case "Math.sin":return native_js_number(math.sin(native_js_numeric(first)))
    case "Math.cos":return native_js_number(math.cos(native_js_numeric(first)))
    case "Math.min","Math.max":
        value:=math.INF_F64;if name=="Math.max" {value=-value}
        for item in args {number:=native_js_numeric(item);if math.is_nan(number) {return native_js_number(number)};if name=="Math.max" {value=max(value,number)} else {value=min(value,number)}};return native_js_number(value)
    case "Array.isArray":return native_js_bool(first.kind==.Array)
    case "Array.from":
        if first.kind==.Array&&first.reference!=nil {return native_js_array(js,first.reference.items[:])}
        if first.kind==.String {result:=native_js_array(js,nil);for ch in first.text {append(&result.reference.items,native_js_string(js,native_js_rune(ch)))};return result}
        return native_js_array(js,nil)
    case "Object.keys","Object.values":
        result:=native_js_array(js,nil)
        if first.reference!=nil {for key,value in first.reference.properties {if name=="Object.keys" {append(&result.reference.items,native_js_string(js,key))} else {append(&result.reference.items,value)}}}
        return result
    case "JSON.stringify":
        output:=make([dynamic]u8,native_js_allocator(js));native_js_json_write(js,&output,first,0);return native_js_string(js,string(output[:]))
    case "JSON.parse":
        value,error:=json.parse(native_js_text(js,first),spec=.JSON,allocator=native_js_allocator(js))
        if error!=nil {native_js_fail(js,"Invalid JSON document.");return {}};return native_js_json_read(js,value)
    case "console.log","console.info","console.warn","console.error":
        // Console messages have no effect on document layout or the shell PTY.
        return {}
    }
    if js.host.call!=nil {return js.host.call(js.host.data,-2,name,args)}
    native_js_fail(js,fmt.tprintf("Unsupported JavaScript built-in: %s",name));return {}
}
native_js_method :: proc(js:^Native_JS,receiver:Native_JS_Value,name:string,args:[]Native_JS_Value)->Native_JS_Value {
    first:=native_js_argument(args,0);second:=native_js_argument(args,1)
    if value,handled:=native_js_extended_method(js,receiver,name,args);handled {return value}
    if name=="toString" {return native_js_string(js,native_js_text(js,receiver))}
    if receiver.kind==.String {
        text:=receiver.text;needle:=native_js_text(js,first)
        switch name {
        case "trim":return native_js_string(js,strings.trim_space(text))
        case "toLowerCase":return native_js_string(js,strings.to_lower(text,native_js_allocator(js)))
        case "toUpperCase":return native_js_string(js,strings.to_upper(text,native_js_allocator(js)))
        case "includes":return native_js_bool(strings.contains(text,needle))
        case "startsWith":return native_js_bool(strings.has_prefix(text,needle))
        case "endsWith":return native_js_bool(strings.has_suffix(text,needle))
        case "indexOf":return native_js_number(f64(strings.index(text,needle)))
        case "slice","substring":
            start:=int(native_js_numeric(first));end:=len(text)
            if second.kind!=.Undefined {end=int(native_js_numeric(second))}
            if name=="slice" {if start<0 {start+=len(text)};if end<0 {end+=len(text)}}
            start=clamp(start,0,len(text));end=clamp(end,0,len(text));if name=="substring"&&start>end {start,end=end,start}
            return native_js_string(js,text[start:max(start,end)])
        case "charAt":index:=int(native_js_numeric(first));if index<0||index>=len(text) {return native_js_string(js,"")};return native_js_string(js,text[index:index+1])
        case "split":
            result:=native_js_array(js,nil)
            if first.kind==.Undefined {append(&result.reference.items,receiver);return result}
            if needle=="" {for ch in text {append(&result.reference.items,native_js_string(js,native_js_rune(ch)))}}
            else {remaining:=text;for part in strings.split_iterator(&remaining,needle) {append(&result.reference.items,native_js_string(js,part))}}
            return result
        case "replace":
            index:=strings.index(text,needle);if index<0 {return receiver}
            return native_js_string(js,strings.concatenate([]string{text[:index],native_js_text(js,second),text[index+len(needle):]},native_js_allocator(js)))
        case "replaceAll":replaced,_:=strings.replace_all(text,needle,native_js_text(js,second),native_js_allocator(js));return native_js_string(js,replaced)
        case "concat":result:=text;for value in args {result=strings.concatenate([]string{result,native_js_text(js,value)},native_js_allocator(js))};return native_js_string(js,result)
        }
    }
    if receiver.kind==.Array&&receiver.reference!=nil {
        array:=receiver.reference
        switch name {
        case "push":for value in args {append(&array.items,value)};return native_js_number(f64(len(array.items)))
        case "pop":if len(array.items)==0 {return {}};value:=array.items[len(array.items)-1];resize(&array.items,len(array.items)-1);return value
        case "shift":if len(array.items)==0 {return {}};value:=array.items[0];ordered_remove(&array.items,0);return value
        case "unshift":
            old:=len(array.items);resize(&array.items,old+len(args));for i:=old-1;i>=0;i-=1 {array.items[i+len(args)]=array.items[i]};copy(array.items[:len(args)],args);return native_js_number(f64(len(array.items)))
        case "includes","indexOf":for value,i in array.items {if native_js_equal(value,first,true) {if name=="includes" {return native_js_bool(true)};return native_js_number(f64(i))}};if name=="includes" {return native_js_bool(false)};return native_js_number(-1)
        case "join":
            separator:=",";if first.kind!=.Undefined {separator=native_js_text(js,first)}
            output:=make([dynamic]u8,native_js_allocator(js));for value,i in array.items {if i>0 {append(&output,separator)};if value.kind!=.Null&&value.kind!=.Undefined {append(&output,native_js_text(js,value))}};return native_js_string(js,string(output[:]))
        case "slice":
            start:=int(native_js_numeric(first));end:=len(array.items);if second.kind!=.Undefined {end=int(native_js_numeric(second))};if start<0 {start+=len(array.items)};if end<0 {end+=len(array.items)};start=clamp(start,0,len(array.items));end=clamp(end,start,len(array.items));return native_js_array(js,array.items[start:end])
        case "forEach","map","filter","find","some","every":
            result:=native_js_array(js,nil);count:=len(array.items)
            for i in 0..<count {
                if i>=len(array.items)||!native_js_step(js) {break}
                value:=array.items[i];parameters:=[3]Native_JS_Value{value,native_js_number(f64(i)),receiver}
                mapped:=native_js_call_function(js,first,parameters[:],second)
                if name=="map" {append(&result.reference.items,mapped)}
                else if name=="filter"&&native_js_truth(mapped) {append(&result.reference.items,value)}
                else if name=="find"&&native_js_truth(mapped) {return value}
                else if name=="some"&&native_js_truth(mapped) {return native_js_bool(true)}
                else if name=="every"&&!native_js_truth(mapped) {return native_js_bool(false)}
            }
            if name=="forEach"||name=="find" {return {}};if name=="some" {return native_js_bool(false)};if name=="every" {return native_js_bool(true)};return result
        }
    }
    if (receiver.kind==.Function||receiver.kind==.Builtin)&&(name=="call"||name=="apply") {
        if name=="apply" {if second.reference!=nil {return native_js_call_function(js,receiver,second.reference.items[:],first)};return native_js_call_function(js,receiver,nil,first)}
        return native_js_call_function(js,receiver,args[min(1,len(args)):],first)
    }
    native_js_fail(js,fmt.tprintf("Unsupported JavaScript method: %s",name));return {}
}
native_js_json_write :: proc(js:^Native_JS,output:^[dynamic]u8,value:Native_JS_Value,depth:int) {
    if !native_js_step(js) {return}
    if depth>64 {native_js_fail(js,"JSON object nesting limit reached.");return}
    #partial switch value.kind {
    case .Undefined,.Null:append(output,"null")
    case .Bool,.Number:append(output,native_js_text(js,value))
    case .String:bytes,error:=json.marshal(value.text,allocator=native_js_allocator(js));if error==nil {append(output,..bytes)}
    case .Array:
        append(output,'[');if value.reference!=nil {for item,i in value.reference.items {if js.error!="" {break};if i>0 {append(output,',')};native_js_json_write(js,output,item,depth+1)}};append(output,']')
    case .Object:
        append(output,'{');count:=0
        if value.reference!=nil {for key,item in value.reference.properties {if js.error!="" {break};if count>0 {append(output,',')};native_js_json_write(js,output,native_js_string(js,key),depth+1);append(output,':');native_js_json_write(js,output,item,depth+1);count+=1}}
        append(output,'}')
    case:append(output,"null")
    }
}
native_js_json_read :: proc(js:^Native_JS,value:json.Value)->Native_JS_Value {
    switch item in value {
    case json.Null:return {kind=.Null}
    case json.Boolean:return native_js_bool(item)
    case json.Integer:return native_js_number(f64(item))
    case json.Float:return native_js_number(item)
    case json.String:return native_js_string(js,item)
    case json.Array:result:=native_js_array(js,nil);for element in item {append(&result.reference.items,native_js_json_read(js,element))};return result
    case json.Object:result:=native_js_object(js);for key,element in item {result.reference.properties[key]=native_js_json_read(js,element)};return result
    }
    return {}
}
native_js_rune :: proc(ch:rune)->string {return fmt.tprintf("%c",ch)}
native_js_parse :: proc(js:^Native_JS,script:string)->^Native_JS_Statement {
    if len(script)>2*1024*1024 {native_js_fail(js,"JavaScript source exceeds 2 MiB.");return nil}
    if tree,exists:=js.scripts[script];exists {return tree}
    if !native_js_step(js) {return nil}
    source:=native_js_clone(js,script)
    parser:=Native_JS_Parser{js=js};native_js_lex(&parser,source)
    result:=native_js_statement_new(&parser,.Block);result.statements=make([dynamic]^Native_JS_Statement,native_js_allocator(js))
    for js.error==""&&native_js_peek(&parser).kind!=.End {before:=parser.index;append(&result.statements,native_js_parse_statement(&parser));if parser.index<=before {native_js_fail(js,"The JavaScript parser could not advance.");break}}
    if js.error=="" {js.scripts[source]=result}
    return result
}
native_js_evaluate :: proc(js:^Native_JS,script:string)->(Native_JS_Value,string) {
    if !js.initialized {return {},"JavaScript runtime is not initialized."}
    js.error="";js.fuel=1000000;js.depth=0;js.throwing=false;js.exception={}
    tree:=native_js_parse(js,script)
    if js.error!="" {return {},js.error}
    result:=native_js_execute(js,js.globals,tree)
    native_js_unhandled(js,result)
    return result.value,js.error
}
native_js_event :: proc(js:^Native_JS,script:string,this_object:int=-2)->(Native_JS_Value,string) {
    if !js.initialized {return {},"JavaScript runtime is not initialized."}
    js.error="";js.fuel=1000000;js.depth=0;js.throwing=false;js.exception={}
    tree:=native_js_parse(js,script);if js.error!="" {return {},js.error}
    scope:=native_js_environment(js,js.globals);scope.values["this"]={kind=.Object,object=this_object}
    result:=native_js_execute(js,scope,tree);native_js_unhandled(js,result);return result.value,js.error
}
native_js_invoke :: proc(js:^Native_JS,callback:Native_JS_Value,args:[]Native_JS_Value=nil,this_object:int=-2)->(Native_JS_Value,string) {
    if !js.initialized {return {},"JavaScript runtime is not initialized."}
    js.error="";js.fuel=1000000;js.depth=0;js.throwing=false;js.exception={}
    value:=native_js_call_function(js,callback,args,{kind=.Object,object=this_object})
    if js.throwing {native_js_unhandled(js,{flow=.Throw,value=js.exception});js.throwing=false}
    return value,js.error
}

// Find the end of a template/interpolation without mistaking braces in strings,
// comments, or nested templates for the interpolation's closing brace.
native_js_template_end :: proc(source:string,start,depth:int)->(end:int,valid:bool) {
    if depth>128||start>=len(source)||source[start]!='`' {return 0,false}
    for i:=start+1;i<len(source); {
        if source[i]=='\\' {i+=2;continue}
        if source[i]=='`' {return i+1,true}
        if source[i]=='$'&&i+1<len(source)&&source[i+1]=='{' {
            close,ok:=native_js_interpolation_end(source,i+2,depth+1)
            if !ok {return 0,false};i=close+1;continue
        }
        i+=1
    }
    return 0,false
}
native_js_interpolation_end :: proc(source:string,start,depth:int)->(end:int,valid:bool) {
    if depth>128 {return 0,false}
    braces:=1
    for i:=start;i<len(source); {
        c:=source[i]
        if c=='`' {close,ok:=native_js_template_end(source,i,depth+1);if !ok {return 0,false};i=close;continue}
        if c=='\''||c=='"' {
            quote:=c;i+=1;closed:=false
            for i<len(source) {if source[i]=='\\' {i+=2;continue};if source[i]==quote {i+=1;closed=true;break};i+=1}
            if !closed {return 0,false};continue
        }
        if c=='/'&&i+1<len(source) {
            if source[i+1]=='/' {for i<len(source)&&source[i]!='\n' {i+=1};continue}
            if source[i+1]=='*' {close:=strings.index(source[i+2:],"*/");if close<0 {return 0,false};i+=close+4;continue}
        }
        if c=='{' {braces+=1}
        if c=='}' {braces-=1;if braces==0 {return i,true}}
        i+=1
    }
    return 0,false
}
native_js_template_chunk :: proc(js:^Native_JS,text:string)->string {
    bytes:=make([dynamic]u8,native_js_allocator(js))
    for i:=0;i<len(text);i+=1 {
        c:=text[i]
        if c=='\\'&&i+1<len(text) {
            i+=1;c=text[i]
            switch c {
            case 'n':c='\n'
            case 'r':c='\r'
            case 't':c='\t'
            case 'b':c=8
            case 'f':c=12
            case '0':c=0
            case '\n':continue
            case '\r':if i+1<len(text)&&text[i+1]=='\n' {i+=1};continue
            case 'u','x':
                digits:=4;if c=='x' {digits=2}
                if i+digits>=len(text) {native_js_fail(js,"Invalid JavaScript template character escape.");return ""}
                number,ok:=strconv.parse_uint(text[i+1:i+1+digits],16);i+=digits
                if !ok {native_js_fail(js,"Invalid JavaScript template character escape.");return ""}
                encoded,n:=utf8.encode_rune(rune(number));append(&bytes,..encoded[:n]);continue
            case:
            }
        }
        append(&bytes,c)
    }
    return string(bytes[:])
}
native_js_template_expression :: proc(parser:^Native_JS_Parser,text:string)->^Native_JS_Expression {
    result:=native_js_expression_new(parser,.Literal);result.value={kind=.String,text=""}
    start:=0;i:=0
    for i<len(text)&&parser.js.error=="" {
        if text[i]=='\\' {i+=2;continue}
        if text[i]!='$'||i+1>=len(text)||text[i+1]!='{' {i+=1;continue}
        prefix:=native_js_expression_new(parser,.Literal);prefix.value={kind=.String,text=native_js_template_chunk(parser.js,text[start:i])}
        joined:=native_js_expression_new(parser,.Binary);joined.text="+";joined.left=result;joined.right=prefix;result=joined
        end,valid:=native_js_interpolation_end(text,i+2,0)
        if !valid {native_js_fail(parser.js,"Unterminated JavaScript template interpolation.");break}
        nested:=Native_JS_Parser{js=parser.js,depth=parser.depth};native_js_lex(&nested,text[i+2:end])
        expression:=native_js_parse_expression(&nested,1)
        if native_js_peek(&nested).kind!=.End {native_js_fail(parser.js,"Invalid JavaScript template interpolation expression.")}
        joined=native_js_expression_new(parser,.Binary);joined.text="+";joined.left=result;joined.right=expression;result=joined
        i=end+1;start=i
    }
    suffix:=native_js_expression_new(parser,.Literal);suffix.value={kind=.String,text=native_js_template_chunk(parser.js,text[start:])}
    joined:=native_js_expression_new(parser,.Binary);joined.text="+";joined.left=result;joined.right=suffix
    return joined
}
native_js_unhandled :: proc(js:^Native_JS,completion:Native_JS_Completion) {
    if completion.flow!=.Throw {return}
    message:=native_js_text(js,completion.value)
    if completion.value.reference!=nil {
        name:=native_js_property(js,completion.value,"name");detail:=native_js_property(js,completion.value,"message")
        if detail.kind!=.Undefined {message=native_js_text(js,detail);if name.kind!=.Undefined {message=fmt.tprintf("%s: %s",native_js_text(js,name),message)}}
    }
    native_js_fail(js,fmt.tprintf("Uncaught JavaScript exception: %s",message))
}

// Exercise hostile object graphs through the same entry point used by documents.
native_js_safety_selfcheck :: proc()->bool {
    js:Native_JS;native_js_init(&js,{});defer native_js_destroy(&js)
    _,error:=native_js_evaluate(&js,`var cycle=[];cycle.push(cycle);var converted=String(cycle);var shared=[1];var repeated=String([shared,shared]);`)
    if error!=""||native_js_lookup(&js,js.globals,"converted").text!=""||native_js_lookup(&js,js.globals,"repeated").text!="1,1" {fmt.eprintln("JavaScript cyclic string conversion failed");return false}
    _,error=native_js_evaluate(&js,`var graph=[];graph.push(graph,graph);JSON.stringify(graph);`)
    if !strings.contains(error,"nesting limit") {fmt.eprintln("JavaScript JSON traversal bound failed");return false}
    _,error=native_js_evaluate(&js,`var bound=function(){return 1;};for(var i=0;i<80;i++){bound=bound.bind(null);}bound();`)
    if !strings.contains(error,"call depth") {fmt.eprintln("JavaScript bound call limit failed");return false}
    source:=make([dynamic]u8);defer delete(source)
    for _ in 0..<300 {append(&source,"1+")};append(&source,"1;")
    _,error=native_js_evaluate(&js,string(source[:]))
    if !strings.contains(error,"expression nesting") {fmt.eprintln("JavaScript expression depth bound failed");return false}
    _,error=native_js_evaluate(&js,`var recovered=1+2;`)
    return error==""&&native_js_lookup(&js,js.globals,"recovered").number==3
}

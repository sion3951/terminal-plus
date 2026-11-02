package main

Native_JS_Async_Frame :: struct {
    statement:^Native_JS_Statement,
    scope:^Native_JS_Environment,
    stage,index:int,
    values:[]Native_JS_Value,
    completion:Native_JS_Completion,
}
Native_JS_Async :: struct {
    promise:Native_JS_Value,
    scope:^Native_JS_Environment,
    stack:[dynamic]Native_JS_Async_Frame,
    cache:map[^Native_JS_Expression]Native_JS_Value,
    resume_value:Native_JS_Value,
    resume_rejected:bool,
    await_expression,rejected_expression:^Native_JS_Expression,
    await_exception:Native_JS_Value,
}
native_js_async_clear_cache :: proc(task:^Native_JS_Async) {clear(&task.cache);task.rejected_expression=nil;task.await_exception={}}
native_js_async_start :: proc(js:^Native_JS,value:Native_JS_Value,args:[]Native_JS_Value,this_value:Native_JS_Value)->Native_JS_Value {
    function:=value.function;task:=new(Native_JS_Async,native_js_allocator(js))
    task.promise=native_js_promise(js);task.scope=native_js_environment(js,function.scope)
    task.cache=make(map[^Native_JS_Expression]Native_JS_Value,native_js_allocator(js));task.stack=make([dynamic]Native_JS_Async_Frame,native_js_allocator(js))
    receiver:=this_value;if function.arrow {receiver=native_js_lookup(js,function.scope,"this")}
    task.scope.values["this"]=receiver;task.scope.values["arguments"]=native_js_array(js,args);task.scope.values["__super"]=function.parent
    for name,i in function.parameters {
        argument:=native_js_argument(args,i)
        if function.rest&&i==len(function.parameters)-1 {argument=native_js_array(js,args[min(i,len(args)):])}
        if argument.kind==.Undefined&&i<len(function.defaults)&&function.defaults[i]!=nil {argument=native_js_eval(js,task.scope,function.defaults[i])}
        if i<len(function.patterns)&&function.patterns[i]!=nil {native_js_bind_pattern(js,task.scope,function.patterns[i],argument,true)} else {task.scope.values[name]=argument}
    }
    body:=function.body
    if function.expression!=nil {body=new(Native_JS_Statement,native_js_allocator(js));body.kind=.Return;body.expression=function.expression}
    append(&task.stack,Native_JS_Async_Frame{statement=body,scope=task.scope})
    native_js_async_resume(js,task)
    return task.promise
}
native_js_async_push :: proc(task:^Native_JS_Async,statement:^Native_JS_Statement,scope:^Native_JS_Environment) {
    append(&task.stack,Native_JS_Async_Frame{statement=statement,scope=scope})
}
native_js_async_finish :: proc(js:^Native_JS,task:^Native_JS_Async,completion:Native_JS_Completion) {
    if completion.flow==.Normal {return}
    for len(task.stack)>0 {
        frame:=&task.stack[len(task.stack)-1];statement:=frame.statement
        if statement!=nil&&statement.kind==.Try {
            if completion.flow==.Throw&&frame.stage==1&&statement.second!=nil {
                frame.stage=2;scope:=native_js_environment(js,frame.scope)
                if statement.name!="" {scope.values[statement.name]=completion.value}
                native_js_async_push(task,statement.second,scope);return
            }
            if frame.stage!=3&&statement.third!=nil {frame.completion=completion;frame.stage=3;native_js_async_push(task,statement.third,frame.scope);return}
        }
        if statement!=nil&&(statement.kind==.While||statement.kind==.For||statement.kind==.For_Each||statement.kind==.Do||statement.kind==.Switch) {
            if completion.flow==.Break {pop(&task.stack);return}
            if completion.flow==.Continue&&statement.kind!=.Switch {
                #partial switch statement.kind {case .While:frame.stage=0;case .For:frame.stage=2;case .For_Each:frame.stage=1;case .Do:frame.stage=1;case:}
                return
            }
        }
        pop(&task.stack)
    }
    if completion.flow==.Throw {native_js_promise_reject(js,task.promise,completion.value)}
    else {native_js_promise_resolve(js,task.promise,completion.value)}
}
native_js_async_resume :: proc(js:^Native_JS,task:^Native_JS_Async) {
    if !native_js_is_promise(task.promise)||task.promise.reference.promise.state!=.Pending {return}
    previous_async,previous_await,previous_throw,previous_exception:=js.current_async,js.awaiting,js.throwing,js.exception
    js.current_async=task;js.awaiting={};js.throwing=false;js.exception={}
    if task.await_expression!=nil {
        if task.resume_rejected {task.rejected_expression=task.await_expression;task.await_exception=task.resume_value}
        else {task.cache[task.await_expression]=task.resume_value}
        task.await_expression=nil
    }
    defer {js.current_async=previous_async;js.awaiting=previous_await;js.throwing=previous_throw;js.exception=previous_exception}
    for len(task.stack)>0&&native_js_step(js) {
        frame:=&task.stack[len(task.stack)-1];statement:=frame.statement;scope:=frame.scope
        if statement==nil {pop(&task.stack);continue}
        #partial switch statement.kind {
        case .Block:
            if frame.stage==0 {
                for child in statement.statements {if child!=nil&&child.function_declaration {native_js_execute(js,scope,child)}}
                frame.stage=1
            }
            if frame.index>=len(statement.statements) {pop(&task.stack);continue}
            child:=statement.statements[frame.index];frame.index+=1;if child!=nil&&child.function_declaration {continue};native_js_async_push(task,child,scope)
        case .If:
            if frame.stage==1 {pop(&task.stack);continue}
            condition:=native_js_truth(native_js_eval(js,scope,statement.condition))
            if js.awaiting.reference!=nil||js.throwing {break}
            native_js_async_clear_cache(task);frame.stage=1
            if condition {native_js_async_push(task,statement.first,scope)} else {native_js_async_push(task,statement.second,scope)}
        case .While:
            if frame.stage==1 {frame.stage=0;continue}
            condition:=native_js_truth(native_js_eval(js,scope,statement.condition))
            if js.awaiting.reference!=nil||js.throwing {break}
            native_js_async_clear_cache(task)
            if !condition {pop(&task.stack);continue}
            frame.stage=1;native_js_async_push(task,statement.first,scope)
        case .Do:
            if frame.stage==0 {frame.stage=1;native_js_async_push(task,statement.first,scope);continue}
            condition:=native_js_truth(native_js_eval(js,scope,statement.condition))
            if js.awaiting.reference!=nil||js.throwing {break}
            native_js_async_clear_cache(task)
            if condition {frame.stage=0} else {pop(&task.stack)}
        case .For:
            if frame.stage==0 {frame.stage=1;if statement.first!=nil {native_js_async_push(task,statement.first,scope);continue};native_js_eval(js,scope,statement.expression);if js.awaiting.reference!=nil||js.throwing {frame.stage=0;break};native_js_async_clear_cache(task)}
            if frame.stage==2 {
                native_js_eval(js,scope,statement.update);if js.awaiting.reference!=nil||js.throwing {break};native_js_async_clear_cache(task);frame.stage=1
            }
            condition:=statement.condition==nil||native_js_truth(native_js_eval(js,scope,statement.condition))
            if js.awaiting.reference!=nil||js.throwing {break}
            native_js_async_clear_cache(task)
            if !condition {pop(&task.stack);continue}
            frame.stage=2;native_js_async_push(task,statement.second,scope)
        case .For_Each:
            if frame.stage==0 {
                value:=native_js_eval(js,scope,statement.expression);if js.awaiting.reference!=nil||js.throwing {break}
                values:=make([dynamic]Native_JS_Value,native_js_allocator(js))
                if value.kind==.Array&&value.reference!=nil {for item,i in value.reference.items {if statement.keys {append(&values,native_js_string(js,native_js_text(js,native_js_number(f64(i)))))} else {append(&values,item)}}}
                else if value.reference!=nil {for key,item in value.reference.properties {if statement.keys {append(&values,native_js_string(js,key))} else {append(&values,item)}}}
                else if value.kind==.String {for ch in value.text {append(&values,native_js_string(js,native_js_rune(ch)))}}
                else {native_js_fail(js,"Expected async loop iterable.");break}
                frame.values=values[:];frame.stage=1;native_js_async_clear_cache(task)
            }
            if frame.index>=len(frame.values) {pop(&task.stack);continue}
            if statement.pattern!=nil {native_js_bind_pattern(js,scope,statement.pattern,frame.values[frame.index],true)} else {scope.values[statement.name]=frame.values[frame.index]};frame.index+=1;native_js_async_push(task,statement.first,scope)
        case .Switch:
            if frame.stage==0 {
                value:=native_js_eval(js,scope,statement.expression);if js.awaiting.reference!=nil||js.throwing {break}
                selected,fallback:= -1,-1
                for branch,i in statement.cases {if branch.test==nil {fallback=i;continue};if native_js_equal(value,native_js_eval(js,scope,branch.test),true) {selected=i;break}}
                if js.awaiting.reference!=nil||js.throwing {break}
                if selected<0 {selected=fallback};if selected<0 {pop(&task.stack);continue};frame.index=selected;frame.stage=1;native_js_async_clear_cache(task)
            }
            if frame.index>=len(statement.cases) {pop(&task.stack);continue};branch:=statement.cases[frame.index];frame.index+=1;native_js_async_push(task,branch.body,scope)
        case .Try:
            if frame.stage==0 {frame.stage=1;native_js_async_push(task,statement.first,scope);continue}
            if frame.stage!=3&&statement.third!=nil {frame.stage=3;native_js_async_push(task,statement.third,scope);continue}
            completion:=frame.completion;pop(&task.stack);native_js_async_finish(js,task,completion)
        case:
            completion:=native_js_execute(js,scope,statement)
            if js.awaiting.reference!=nil {break}
            native_js_async_clear_cache(task);pop(&task.stack);native_js_async_finish(js,task,completion)
        }
        if js.throwing {
            exception:=js.exception;js.throwing=false;native_js_async_clear_cache(task)
            if len(task.stack)>0 {pop(&task.stack)}
            native_js_async_finish(js,task,{flow=.Throw,value=exception})
        }
        if js.awaiting.reference!=nil||js.error!="" {break}
    }
    if js.error!="" {
        message:=js.error;js.error="";clear(&task.stack)
        native_js_promise_reject(js,task.promise,native_js_builtin(js,"Error",[]Native_JS_Value{native_js_string(js,message)}));return
    }
    if js.awaiting.reference!=nil {native_js_promise_react(js,js.awaiting,{resume=task});return}
    if len(task.stack)==0&&task.promise.reference.promise.state==.Pending {native_js_promise_resolve(js,task.promise,{})}
}

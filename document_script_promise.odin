package main


Native_JS_Promise_State :: enum {Pending,Fulfilled,Rejected}
Native_JS_Reaction :: struct {fulfilled,rejected,next:Native_JS_Value,finally:bool,adoption:bool,resume:^Native_JS_Async,collection:^Native_JS_Promise_Collection,index:int,passthrough:bool,retained:Native_JS_Value,retained_rejected:bool}
Native_JS_Promise :: struct {state:Native_JS_Promise_State,value:Native_JS_Value,reactions:[dynamic]Native_JS_Reaction,resolving,handled,reported:bool}
Native_JS_Job :: struct {callback,this_value,value,next:Native_JS_Value,args:[]Native_JS_Value,rejected,finally,adoption:bool,resume:^Native_JS_Async,collection:^Native_JS_Promise_Collection,index:int,passthrough:bool,retained:Native_JS_Value,retained_rejected:bool}
Native_JS_Promise_Collection :: struct {result,values,errors:Native_JS_Value,remaining,fulfilled:int,mode:string}

native_js_promise :: proc(js:^Native_JS)->Native_JS_Value {
    result:=native_js_object(js);result.reference.prototype=js.promise_prototype;promise:=new(Native_JS_Promise,native_js_allocator(js))
    promise.reactions=make([dynamic]Native_JS_Reaction,native_js_allocator(js));result.reference.promise=promise
    return result
}
native_js_is_promise :: proc(value:Native_JS_Value)->bool {return value.reference!=nil&&value.reference.promise!=nil}
native_js_promise_schedule :: proc(js:^Native_JS,promise:Native_JS_Value,reaction:Native_JS_Reaction) {
    state:=promise.reference.promise
    callback:=reaction.fulfilled;if state.state==.Rejected {callback=reaction.rejected}
    append(&js.jobs,Native_JS_Job{callback=callback,value=state.value,next=reaction.next,rejected=state.state==.Rejected,finally=reaction.finally,adoption=reaction.adoption,resume=reaction.resume,collection=reaction.collection,index=reaction.index,passthrough=reaction.passthrough,retained=reaction.retained,retained_rejected=reaction.retained_rejected})
}
native_js_promise_react :: proc(js:^Native_JS,promise:Native_JS_Value,reaction:Native_JS_Reaction) {
    if !native_js_is_promise(promise) {native_js_fail(js,"Expected a Promise.");return}
    promise.reference.promise.handled=true
    if promise.reference.promise.state==.Pending {append(&promise.reference.promise.reactions,reaction)} else {native_js_promise_schedule(js,promise,reaction)}
}
native_js_promise_finish :: proc(js:^Native_JS,promise,value:Native_JS_Value,rejected:bool) {
    if !native_js_is_promise(promise)||promise.reference.promise.state!=.Pending {return}
    state:=promise.reference.promise;state.value=value;state.state=.Fulfilled;if rejected {state.state=.Rejected}
    if rejected {append(&js.rejected_promises,promise)}
    for reaction in state.reactions {native_js_promise_schedule(js,promise,reaction)};clear(&state.reactions)
}
native_js_promise_resolve :: proc(js:^Native_JS,promise,value:Native_JS_Value) {
    if !native_js_is_promise(promise)||promise.reference.promise.state!=.Pending||promise.reference.promise.resolving {return}
    if value.reference!=nil&&value.reference==promise.reference {
        error:=native_js_builtin(js,"TypeError",[]Native_JS_Value{native_js_string(js,"A Promise cannot resolve to itself.")});native_js_promise_finish(js,promise,error,true);return
    }
    if native_js_is_promise(value) {
        promise.reference.promise.resolving=true
        native_js_promise_react(js,value,{next=promise,adoption=true});return
    }
    native_js_promise_finish(js,promise,value,false)
}
native_js_promise_reject :: proc(js:^Native_JS,promise,value:Native_JS_Value) {
    if !native_js_is_promise(promise)||promise.reference.promise.resolving {return}
    native_js_promise_finish(js,promise,value,true)
}
native_js_promise_method :: proc(js:^Native_JS,promise:Native_JS_Value,name:string,args:[]Native_JS_Value)->(Native_JS_Value,bool) {
    reaction:=Native_JS_Reaction{}
    switch name {
    case "then":reaction.fulfilled=native_js_argument(args,0);reaction.rejected=native_js_argument(args,1)
    case "catch":reaction.rejected=native_js_argument(args,0)
    case "finally":reaction.fulfilled=native_js_argument(args,0);reaction.rejected=reaction.fulfilled;reaction.finally=true
    case:return {},false
    }
    reaction.next=native_js_promise(js);native_js_promise_react(js,promise,reaction)
    return reaction.next,true
}
native_js_promise_collection :: proc(js:^Native_JS,name:string,input:Native_JS_Value)->Native_JS_Value {
    result:=native_js_promise(js)
    if input.kind!=.Array||input.reference==nil {native_js_promise_reject(js,result,native_js_string(js,"Promise collection expects an array."));return result}
    collection:=new(Native_JS_Promise_Collection,native_js_allocator(js));collection.mode=name;collection.result=result;collection.remaining=len(input.reference.items)
    collection.values=native_js_array(js,nil);resize(&collection.values.reference.items,collection.remaining)
    collection.errors=native_js_array(js,nil);resize(&collection.errors.reference.items,collection.remaining)
    if collection.remaining==0 {if name=="Promise.all"||name=="Promise.allSettled" {native_js_promise_resolve(js,result,collection.values)} else if name=="Promise.any" {native_js_promise_reject(js,result,native_js_string(js,"All promises were rejected."))};return result}
    for value,index in input.reference.items {
        promise:=value;if !native_js_is_promise(value) {promise=native_js_promise(js);native_js_promise_resolve(js,promise,value)}
        native_js_promise_react(js,promise,{collection=collection,index=index})
    }
    return result
}
native_js_promise_collection_job :: proc(js:^Native_JS,job:Native_JS_Job) {
    collection:=job.collection;collection.remaining-=1
    if job.rejected {collection.errors.reference.items[job.index]=job.value} else {collection.fulfilled+=1;collection.values.reference.items[job.index]=job.value}
    switch collection.mode {
    case "Promise.race":if job.rejected {native_js_promise_reject(js,collection.result,job.value)} else {native_js_promise_resolve(js,collection.result,job.value)}
    case "Promise.all":if job.rejected {native_js_promise_reject(js,collection.result,job.value)} else if collection.remaining==0 {native_js_promise_resolve(js,collection.result,collection.values)}
    case "Promise.allSettled":
        item:=native_js_object(js);label:="fulfilled";property:="value";if job.rejected {label="rejected";property="reason"}
        item.reference.properties["status"]=native_js_string(js,label);item.reference.properties[property]=job.value;collection.values.reference.items[job.index]=item
        if collection.remaining==0 {native_js_promise_resolve(js,collection.result,collection.values)}
    case "Promise.any":
        if !job.rejected {native_js_promise_resolve(js,collection.result,job.value)}
        else if collection.remaining==0&&collection.fulfilled==0 {error:=native_js_builtin(js,"Error",[]Native_JS_Value{native_js_string(js,"All promises were rejected.")});error.reference.properties["name"]=native_js_string(js,"AggregateError");error.reference.properties["errors"]=collection.errors;native_js_promise_reject(js,collection.result,error)}
    }
}
// A bounded FIFO checkpoint. The document UI calls this after scripts, events,
// timers and completion of its network jobs, preserving microtask ordering.
native_js_run_jobs :: proc(js:^Native_JS)->string {
    if !js.initialized {return "JavaScript runtime is not initialized."}
    if js.running_jobs {return js.error}
    js.running_jobs=true;defer {js.running_jobs=false}
    js.error="";js.throwing=false;js.exception={};js.fuel=1000000
    first_error:=""
    processed:=0
    for js.job_offset<len(js.jobs)&&js.error=="" {
        if processed>=10000 {native_js_fail(js,"JavaScript microtask limit reached.");break}
        processed+=1;job:=js.jobs[js.job_offset];js.job_offset+=1
        if job.collection!=nil {native_js_promise_collection_job(js,job);continue}
        if job.resume!=nil {
            job.resume.resume_value=job.value;job.resume.resume_rejected=job.rejected;native_js_async_resume(js,job.resume);continue
        }
        if job.passthrough {
            if job.rejected {native_js_promise_reject(js,job.next,job.value)}
            else if job.retained_rejected {native_js_promise_reject(js,job.next,job.retained)} else {native_js_promise_resolve(js,job.next,job.retained)}
            continue
        }
        if job.adoption {
            job.next.reference.promise.resolving=false
            if job.rejected {native_js_promise_reject(js,job.next,job.value)} else {native_js_promise_resolve(js,job.next,job.value)}
            continue
        }
        if job.callback.kind!=.Function&&job.callback.kind!=.Builtin {
            if job.next.reference!=nil {if job.rejected {native_js_promise_reject(js,job.next,job.value)} else {native_js_promise_resolve(js,job.next,job.value)}}
            continue
        }
        args:=job.args;if args==nil&&!job.finally {args=[]Native_JS_Value{job.value}}
        value:=native_js_call_function(js,job.callback,args,job.this_value)
        if js.error!="" {
            message:=js.error;if first_error=="" {first_error=message};js.error=""
            if job.next.reference!=nil {native_js_promise_reject(js,job.next,native_js_builtin(js,"Error",[]Native_JS_Value{native_js_string(js,message)}))}
            continue
        }
        if js.throwing {exception:=js.exception;js.throwing=false;if job.next.reference!=nil {native_js_promise_reject(js,job.next,exception)} else {native_js_unhandled(js,{flow=.Throw,value=exception})};continue}
        if job.next.reference!=nil {
            if job.finally {
                if native_js_is_promise(value) {native_js_promise_react(js,value,{next=job.next,passthrough=true,retained=job.value,retained_rejected=job.rejected})}
                else if job.rejected {native_js_promise_reject(js,job.next,job.value)} else {native_js_promise_resolve(js,job.next,job.value)}
            } else {native_js_promise_resolve(js,job.next,value)}
        }
    }
    if js.job_offset==len(js.jobs) {clear(&js.jobs);js.job_offset=0}
    for rejected in js.rejected_promises {
        promise:=rejected.reference.promise
        if promise.state==.Rejected&&!promise.handled&&!promise.reported {
            promise.reported=true;native_js_unhandled(js,{flow=.Throw,value=promise.value})
        }
    }
    if first_error!=""&&js.error=="" {js.error=first_error}
    return js.error
}

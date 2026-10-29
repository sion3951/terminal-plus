#+build linux
package main

import "core:fmt"
import "core:c"
import "core:c/libc"
import "core:strconv"
import "core:strings"
import "core:time"
import posix "core:sys/posix"

// Use the platform's POSIX extended regular expressions, as Bash does.
// The native shell already targets Linux's GNU libc interfaces (fnmatch with
// FNM_EXTMATCH); this is the GNU regex_t ABI, including its final bitfield.
Native_Shell_Regex :: struct {
    buffer:rawptr,
    allocated,used,syntax:c.ulong,
    fastmap,translate:rawptr,
    nsub:c.size_t,
    flags:c.uint,
}
Native_Shell_Regex_Match :: struct {first,last:c.int}
foreign import native_shell_regex_lib "system:c"
foreign native_shell_regex_lib {
    @(link_name="regcomp") native_shell_regcomp :: proc(compiled:^Native_Shell_Regex,pattern:cstring,flags:c.int)->c.int ---
    @(link_name="regexec") native_shell_regexec :: proc(compiled:^Native_Shell_Regex,value:cstring,count:c.size_t,matches:^Native_Shell_Regex_Match,flags:c.int)->c.int ---
    @(link_name="regfree") native_shell_regfree :: proc(compiled:^Native_Shell_Regex) ---
}

// Bash 5.3 command substitutions retain ordinary side effects but introduce
// an anonymous local scope. A memory-backed descriptor avoids pipe deadlocks
// when the current process produces more than a pipe buffer of captured text.
native_shell_capture_current :: proc(shell:^Native_Shell,source:string,reply:bool)->(string,string) {
    capture_fd:posix.FD= -1
    saved_stdout:posix.FD= -1
    if !reply {
        saved_stdout=posix.FD(posix.fcntl(1,.DUPFD_CLOEXEC,c.int(10)))
        if saved_stdout<0&&posix.errno()!=.EBADF {return "","cannot save substitution output descriptor"}
        capture_fd=native_shell_memfd_create("terminal-shell-current-substitution",1)
        if capture_fd<0 {if saved_stdout>=0 {posix.close(saved_stdout)};return "","cannot create current-environment substitution output"}
        if posix.dup2(capture_fd,1)<0 {if saved_stdout>=0 {posix.close(saved_stdout)};posix.close(capture_fd);return "","cannot redirect substitution output"}
    }
    defer {
        if !reply {if saved_stdout>=0 {posix.dup2(saved_stdout,1);posix.close(saved_stdout)} else {posix.close(1)};posix.close(capture_fd)}
    }
    if !reply {append(&shell.script_fds,&capture_fd);if saved_stdout>=0 {append(&shell.script_fds,&saved_stdout)}}
    defer {if !reply {if saved_stdout>=0 {pop(&shell.script_fds)};pop(&shell.script_fds)}}
    previous_returning,previous_return_status:=shell.compat.returning,shell.compat.return_status
    previous_depth:=shell.compat.function_depth
    append(&shell.compat.frames,Native_Shell_Frame{locals=make(map[string]Native_Shell_Local,shell.allocator)})
    shell.compat.function_depth+=1
    shell.compat.returning=false;shell.compat.return_status=0
    defer {
        native_shell_local_frame_leave(shell)
        shell.compat.function_depth=previous_depth
        shell.compat.returning=previous_returning;shell.compat.return_status=previous_return_status
    }
    if reply {
        native_shell_local_save(shell,"REPLY")
        if error:=native_shell_value_unset(shell,"REPLY");error!="" {native_shell_diagnostic(shell,error)}
    }
    status:=native_shell_execute(shell,source)
    if shell.compat.returning {status=shell.compat.return_status}
    native_shell_capture_sequence+=1;native_shell_capture_status=status;shell.status=status
    if reply {value,_:=native_shell_value_get(shell,"REPLY");return strings.clone(value),""}
    if posix.lseek(capture_fd,0,.SET)<0 {return "","cannot read current-environment substitution output"}
    bytes:=make([dynamic]u8);buffer:[16384]u8
    for {
        amount:=posix.read(capture_fd,raw_data(buffer[:]),len(buffer))
        if amount<0&&posix.errno()==.EINTR {continue}
        if amount<0 {return "","cannot read current-environment substitution output"}
        if amount==0 {break}
        chunk:=buffer[:int(amount)]
        for byte in chunk {if byte!=0 {append(&bytes,byte)}}
    }
    end:=len(bytes);for end>0&&bytes[end-1]=='\n' {end-=1}
    return string(bytes[:end]),""
}

// Compound bodies are source slices owned by their enclosing command arena.
// Function definitions copy their body to persistent shell storage before that
// arena is released. Each invocation reparses in its own execution arena.
native_shell_call_function :: proc(shell:^Native_Shell,args:[]string)->int {
    if len(args)==0 {return 0}
    body,present:=shell.compat.functions[args[0]]
    if !present {return 127}
    if limit_text,exists:=native_shell_value_get(shell,"FUNCNEST");exists {
        limit,valid:=strconv.parse_int(limit_text)
        if valid&&limit>0&&shell.compat.function_depth>=limit {
            fmt.eprintf("%s: maximum function nesting level exceeded (%d)\n",args[0],limit)
            if !shell.interactive {shell.exiting=true;shell.exit_status=1}
            return 1
        }
    }
    if shell.compat.function_depth>=512 {fmt.eprintln("terminal+: function nesting limit reached");if !shell.interactive {shell.exiting=true;shell.exit_status=1};return 1}
    // A function may redefine itself while running. Keep the current body in
    // the caller's arena instead of retaining a pointer to its dictionary entry.
    source:=strings.clone(body)
    previous_loop,previous_break,previous_continue:=shell.compat.loop_depth,shell.compat.break_depth,shell.compat.continue_depth
    reset_loops:=native_shell_compat_level(shell)>43
    if reset_loops {shell.compat.loop_depth=0;shell.compat.break_depth=0;shell.compat.continue_depth=0}
    defer {if reset_loops {shell.compat.loop_depth=previous_loop;shell.compat.break_depth=previous_break;shell.compat.continue_depth=previous_continue}}
    previous:=native_shell_function_enter(shell,args)
    defer native_shell_function_leave(shell,previous)
    result:=native_shell_execute(shell,source)
    if shell.compat.returning {result=shell.compat.return_status}
    // RETURN runs while the function's parameters and locals still exist.
    // The trap dispatcher applies Bash's function tracing/inheritance rules.
    shell.status=result
    native_shell_run_trap(shell,-2)
    if shell.compat.returning {result=shell.compat.return_status}
    return result
}

native_shell_condition_execute :: proc(shell:^Native_Shell,source:string)->int {
    shell.compat.errexit_ignored+=1
    defer {shell.compat.errexit_ignored-=1}
    return native_shell_execute(shell,source)
}

native_shell_loop_finished :: proc(shell:^Native_Shell)->(stop,again:bool) {
    if shell.exiting||shell.compat.returning||native_shell_cancelled() {return true,false}
    if shell.compat.break_depth>0 {shell.compat.break_depth-=1;return true,false}
    if shell.compat.continue_depth>0 {shell.compat.continue_depth-=1;if shell.compat.continue_depth>0 {return true,false};return false,true}
    return false,false
}

native_shell_case_match :: proc(shell:^Native_Shell,text,pattern:string,extended:bool=false)->bool {
    previous_locale:=native_shell_text_locale(shell);defer native_shell_text_locale_restore(previous_locale)
    flags:=0
    if extended||shell.compat.shopts["extglob"] {flags+=32} // FNM_EXTMATCH
    if shell.compat.shopts["nocasematch"] {flags+=16} // FNM_CASEFOLD
    return posix.fnmatch(strings.clone_to_cstring(pattern),strings.clone_to_cstring(text),transmute(posix.FNM_Flags)i32(flags))==0
}

native_shell_compound_at :: proc(shell:^Native_Shell,compound:^Native_Shell_Compound,source:string,line:int,condition:bool=false)->int {
    previous:=shell.compat.current_line
    if line>0&&compound.line>0 {shell.compat.current_line=max(1,previous+line-compound.line)}
    defer {shell.compat.current_line=previous}
    if condition {return native_shell_condition_execute(shell,source)}
    return native_shell_execute(shell,source)
}
native_shell_compound_body :: proc(shell:^Native_Shell,compound:^Native_Shell_Compound,index:int)->int {
    line:=compound.line;if index<len(compound.body_lines) {line=compound.body_lines[index]}
    return native_shell_compound_at(shell,compound,compound.bodies[index],line)
}
native_shell_compound_condition :: proc(shell:^Native_Shell,compound:^Native_Shell_Compound,index:int)->int {
    line:=compound.line;if index<len(compound.condition_lines) {line=compound.condition_lines[index]}
    return native_shell_compound_at(shell,compound,compound.conditions[index],line,true)
}

native_shell_compound_execute :: proc(shell:^Native_Shell,compound:^Native_Shell_Compound)->int {
    switch compound.kind {
    case "group","subshell":return native_shell_compound_at(shell,compound,compound.source,compound.source_line)
    case "function":
        metadata:=strings.concatenate([]string{"BASH_FUNC_",compound.name,"%%"})
        if shell.compat.attributes[metadata]&NATIVE_SHELL_READONLY!=0 {fmt.eprintf("%s: readonly function\n",compound.name);return 1}
        native_shell_owned_text_set(&shell.compat.functions,compound.name,compound.source,shell.allocator)
        previous_line:=shell.compat.current_line
        shell.compat.current_line=max(1,previous_line+compound.source_line-compound.line)
        native_shell_function_record(shell,compound.name)
        shell.compat.current_line=previous_line
        return 0
    case "if":
        for _,i in compound.conditions {
            if native_shell_compound_condition(shell,compound,i)==0 {return native_shell_compound_body(shell,compound,i)}
            if shell.exiting||shell.compat.returning||native_shell_cancelled() {return shell.status}
        }
        if len(compound.bodies)>len(compound.conditions) {return native_shell_compound_body(shell,compound,len(compound.bodies)-1)}
        return 0
    case "while","until":
        shell.compat.loop_depth+=1;defer {shell.compat.loop_depth-=1}
        result:=0
        for !shell.exiting&&!native_shell_cancelled() {
            status:=native_shell_compound_condition(shell,compound,0)
            condition_stop,condition_again:=native_shell_loop_finished(shell)
            if condition_stop {break};if condition_again {continue}
            if (status==0)==(compound.kind=="until") {break}
            result=native_shell_compound_body(shell,compound,0)
            stop,_:=native_shell_loop_finished(shell);if stop {break}
        }
        return result
    case "for","for-args","select":
        values:=make([dynamic]string)
        if compound.kind=="for-args"||(compound.kind=="select"&&len(compound.words)==0) {append(&values,..shell.compat.parameters)}
        else {for word in compound.words {expanded,error:=native_shell_expand(shell,word);if error!="" {native_shell_diagnostic(shell,error);return 1};append(&values,..expanded)}}
        shell.compat.loop_depth+=1;defer {shell.compat.loop_depth-=1}
        result:=0
        if compound.kind=="select" {
            if len(values)==0 {return 0}
            for !shell.exiting&&!native_shell_cancelled() {
                for value,i in values {fmt.eprintf("%d) %s\n",i+1,value)}
                prompt,exists:=native_shell_value_get(shell,"PS3");if !exists {prompt="#? "};fmt.eprint(prompt)
                reply:=make([dynamic]u8)
                for {byte:u8;amount:=posix.read(0,&byte,1);if amount<=0 {return result};if byte=='\n' {break};append(&reply,byte)}
                _=native_shell_value_set(shell,"REPLY",string(reply[:]))
                if len(reply)==0 {continue}
                index,valid:=strconv.parse_int(string(reply[:]));value:="";if valid&&index>0&&index<=len(values) {value=values[index-1]}
                if error:=native_shell_value_set(shell,compound.name,value);error!="" {fmt.eprintln(error);if shell.compat.options["posix"]&&!shell.interactive {shell.exiting=true;shell.exit_status=127;return 127};return 1}
                result=native_shell_compound_body(shell,compound,0);stop,_:=native_shell_loop_finished(shell);if stop {break}
            }
            return result
        }
        for value in values {
            if error:=native_shell_value_set(shell,compound.name,value);error!="" {fmt.eprintln(error);if shell.compat.options["posix"]&&!shell.interactive {shell.exiting=true;shell.exit_status=127;return 127};return 1}
            result=native_shell_compound_body(shell,compound,0);stop,_:=native_shell_loop_finished(shell);if stop {break}
        }
        return result
    case "for-arithmetic":
        if len(compound.conditions)!=3 {return 2}
        if _,error:=native_shell_arithmetic(shell,compound.conditions[0],true);error!="" {native_shell_diagnostic(shell,error);return 1}
        shell.compat.loop_depth+=1;defer {shell.compat.loop_depth-=1}
        result:=0
        for !shell.exiting&&!native_shell_cancelled() {
            if strings.trim_space(compound.conditions[1])!="" {
                condition,error:=native_shell_arithmetic(shell,compound.conditions[1],true);if error!="" {fmt.eprintln(error);return 1};if condition==0 {break}
            }
            result=native_shell_compound_body(shell,compound,0);stop,_:=native_shell_loop_finished(shell);if stop {break}
            if _,error:=native_shell_arithmetic(shell,compound.conditions[2],true);error!="" {fmt.eprintln(error);return 1}
        }
        return result
    case "case":
        text,error:=native_shell_expand_assignment(shell,compound.words[0].raw);if error!="" {fmt.eprintln(error);return 1}
        result:=0;fallthrough_arm:=false
        for alternatives,i in compound.patterns {
            matches:=fallthrough_arm
            if !matches {for alternative in alternatives {pattern,pattern_error:=native_shell_expand_pattern(shell,alternative.raw);if pattern_error!="" {fmt.eprintln(pattern_error);return 1};if native_shell_case_match(shell,text,pattern) {matches=true;break}}}
            if !matches {continue}
            result=native_shell_compound_body(shell,compound,i)
            if shell.exiting||shell.compat.returning||shell.compat.break_depth>0||shell.compat.continue_depth>0 {break}
            if compound.terminators[i]==";&" {fallthrough_arm=true;continue}
            if compound.terminators[i]==";;&" {fallthrough_arm=false;continue}
            break
        }
        return result
    case "arithmetic":
        value,error:=native_shell_arithmetic(shell,compound.source,true);if error!="" {native_shell_diagnostic(shell,error);return 1}
        if value==0 {return 1};return 0
    case "conditional":return native_shell_conditional(shell,compound.source)
    case "coproc":
        previous_line:=shell.compat.current_line
        shell.compat.current_line=max(1,previous_line+compound.source_line-compound.line)
        defer {shell.compat.current_line=previous_line}
        return native_shell_coproc(shell,compound)
    case "time":
        before,children_before,after,children_after:posix.rusage
        _=posix.getrusage(.SELF,&before);_=posix.getrusage(.CHILDREN,&children_before)
        start:=time.tick_now();result:=native_shell_compound_at(shell,compound,compound.source,compound.source_line)
        elapsed:=time.duration_seconds(time.tick_diff(start,time.tick_now()))
        _=posix.getrusage(.SELF,&after);_=posix.getrusage(.CHILDREN,&children_after)
        user:=native_shell_timeval_seconds(after.ru_utime)-native_shell_timeval_seconds(before.ru_utime)+native_shell_timeval_seconds(children_after.ru_utime)-native_shell_timeval_seconds(children_before.ru_utime)
        system:=native_shell_timeval_seconds(after.ru_stime)-native_shell_timeval_seconds(before.ru_stime)+native_shell_timeval_seconds(children_after.ru_stime)-native_shell_timeval_seconds(children_before.ru_stime)
        if strings.trim_space(compound.source)=="" {user=native_shell_timeval_seconds(after.ru_utime)+native_shell_timeval_seconds(children_after.ru_utime);system=native_shell_timeval_seconds(after.ru_stime)+native_shell_timeval_seconds(children_after.ru_stime);elapsed=time.duration_seconds(time.tick_diff(shell.compat.started,time.tick_now()))}
        format,present:=native_shell_value_get(shell,"TIMEFORMAT")
        if !present {format="\nreal\t%3lR\nuser\t%3lU\nsys\t%3lS"}
        if compound.name=="-p" {format="real %2R\nuser %2U\nsys %2S"}
        if format!="" {fmt.eprintln(native_shell_time_format(format,elapsed,user,system))}
        return result
    }
    fmt.eprintf("terminal+: unknown compound command: %s\n",compound.kind)
    return 2
}

native_shell_timeval_seconds :: proc(value:posix.timeval)->f64 {return f64(value.tv_sec)+f64(value.tv_usec)/1000000}
native_shell_time_number :: proc(value:f64,precision:int,long:bool)->string {
    multiplier:=1;for _ in 0..<precision {multiplier*=10}
    rounded:=i64(max(0,value)*f64(multiplier)+0.5)
    whole:=rounded/i64(multiplier);fraction:=rounded%i64(multiplier)
    result:=fmt.aprintf("%d",whole)
    if long {result=fmt.aprintf("%dm%d",whole/60,whole%60)}
    if precision>0 {
        digits:=fmt.aprintf("%d",fraction)
        result=strings.concatenate([]string{result,"."})
        for _ in 0..<precision-len(digits) {result=strings.concatenate([]string{result,"0"})}
        result=strings.concatenate([]string{result,digits})
    }
    if long {result=strings.concatenate([]string{result,"s"})}
    return result
}
native_shell_time_format :: proc(format:string,real,user,system:f64)->string {
    output:=make([dynamic]u8)
    for i:=0;i<len(format);i+=1 {
        if format[i]!='%' {append(&output,format[i]);continue}
        i+=1;if i>=len(format) {break};if format[i]=='%' {append(&output,'%');continue}
        precision:=3
        if format[i]>='0'&&format[i]<='9' {precision=min(3,int(format[i]-'0'));i+=1;if i>=len(format) {break}}
        long:=false;if format[i]=='l' {long=true;i+=1;if i>=len(format) {break}}
        value:=real
        switch format[i] {case 'R':value=real;case 'U':value=user;case 'S':value=system;case 'P':value=0;if real>0 {value=100*(user+system)/real};case:append(&output,'%',format[i]);continue}
        append(&output,native_shell_time_number(value,precision,long))
    }
    return string(output[:])
}

Native_Shell_Conditional :: struct {shell:^Native_Shell, tokens:[]string, position:int, error:string}
native_shell_conditional_tokens :: proc(source:string)->(tokens:[dynamic]string,error:string) {
    for i:=0;i<len(source); {
        if native_shell_space(source[i])||source[i]=='\n' {i+=1;continue}
        start:=i;regex_word:=len(tokens)>0&&tokens[len(tokens)-1]=="=~"
        if !regex_word&&(source[i]=='('||source[i]==')') {i+=1;append(&tokens,source[start:i]);continue}
        if i+1<len(source)&&(source[i:i+2]=="&&"||source[i:i+2]=="||") {i+=2;append(&tokens,source[start:i]);continue}
        quote:u8
        for i<len(source) {
            ch:=source[i]
            if ch=='\\' {i+=2;continue}
            if quote!=0 {if ch==quote {quote=0};i+=1;continue}
            if ch=='\''||ch=='"' {quote=ch;i+=1;continue}
            if ch=='$'&&i+1<len(source)&&source[i+1]=='[' {end,scan_error:=native_shell_legacy_arithmetic_end(source,i);if scan_error!="" {return tokens,scan_error};i=end;continue}
            if ch=='$'&&i+1<len(source)&&(source[i+1]=='('||source[i+1]=='{') {end:int;scan_error:string;if source[i+1]=='(' {end,scan_error=native_shell_substitution_end(source,i)} else {end,scan_error=native_shell_parameter_end(source,i)};if scan_error!="" {return tokens,scan_error};i=end;continue}
            if native_shell_space(ch)||ch=='\n' {break}
            if !regex_word&&(ch==')'||ch=='('||i+1<len(source)&&(source[i:i+2]=="&&"||source[i:i+2]=="||")) {break}
            i+=1
        }
        if quote!=0 {return tokens,"Unclosed conditional quote."}
        if i==start {return tokens,"Invalid conditional expression."}
        append(&tokens,source[start:i])
    }
    return
}
native_shell_conditional_boundary :: proc(word:string)->bool {return word=="&&"||word=="||"||word==")"}
native_shell_conditional_peek :: proc(p:^Native_Shell_Conditional)->string {if p.position>=len(p.tokens) {return ""};return p.tokens[p.position]}
native_shell_conditional_expand :: proc(p:^Native_Shell_Conditional,raw:string,evaluate:bool)->string {
    if !evaluate {return ""}
    value,error:=native_shell_expand_assignment(p.shell,raw);if error!="" {p.error=error};return value
}
native_shell_conditional_atom :: proc(p:^Native_Shell_Conditional,evaluate:bool)->bool {
    first:=native_shell_conditional_peek(p)
    if first=="" {p.error="Expected a conditional operand.";return false}
    if first=="!" {p.position+=1;return !native_shell_conditional_atom(p,evaluate)}
    if first=="(" {p.position+=1;value:=native_shell_conditional_or(p,evaluate);if native_shell_conditional_peek(p)!=")" {p.error="Conditional group needs )."} else {p.position+=1};return value}
    p.position+=1
    if len(first)==2&&first[0]=='-'&&first!="--"&&p.position<len(p.tokens)&&!native_shell_conditional_boundary(p.tokens[p.position]) {
        raw:=native_shell_conditional_peek(p)
        if raw=="" {p.error="Unary conditional needs an operand.";return false};p.position+=1
        value:=native_shell_conditional_expand(p,raw,evaluate)
        if !evaluate {return false}
        if first=="-v"&&native_shell_legacy_array_expansion(p.shell) {
            _,_,indexed:=native_shell_reference(value)
            if indexed {expanded,expand_error:=native_shell_expand_assignment(p.shell,value);if expand_error!="" {p.error=expand_error;return false};value=expanded}
        }
        status,handled:=native_shell_compat_builtin(p.shell,[]string{"test",first,value})
        if !handled {p.error="Conditional predicate unavailable.";return false};if status>1 {p.error="Invalid conditional predicate."};return status==0
    }
    operator:=native_shell_conditional_peek(p)
    arithmetic_operator:=operator=="-eq"||operator=="-ne"||operator=="-lt"||operator=="-le"||operator=="-gt"||operator=="-ge"
    left:=""
    if !arithmetic_operator {left=native_shell_conditional_expand(p,first,evaluate)}
    switch operator {
    case "==","=","!=","=~","<",">","-eq","-ne","-lt","-le","-gt","-ge","-nt","-ot","-ef":
        p.position+=1;raw:=native_shell_conditional_peek(p)
        if raw=="" {p.error="Binary conditional needs a right operand.";return false};p.position+=1
        if !evaluate {return false}
        right:=""
        if !arithmetic_operator&&operator!="=="&&operator!="="&&operator!="!="&&operator!="=~" {right=native_shell_conditional_expand(p,raw,true)}
        switch operator {
        case "==","=","!=":
            pattern,error:=native_shell_expand_pattern(p.shell,raw);if error!="" {p.error=error;return false}
            matches:=native_shell_case_match(p.shell,left,pattern,true);if operator=="!=" {return !matches};return matches
        case "<",">":
            comparison:c.int
            if native_shell_compat_level(p.shell)<=40 {comparison=libc.strcmp(strings.clone_to_cstring(left),strings.clone_to_cstring(right))}
            else {comparison=libc.strcoll(strings.clone_to_cstring(left),strings.clone_to_cstring(right))}
            if operator=="<" {return comparison<0};return comparison>0
        case "=~":
            fields,field_error:=native_shell_expand_fields(p.shell,raw,false)
            if field_error!="" {p.error=field_error;return false}
            escaped:=make([dynamic]u8)
            for field,field_index in fields {
                if field_index>0 {append(&escaped,' ')}
                for byte,i in field.bytes {
                    if native_shell_compat_level(p.shell)>31&&i<len(field.quoted)&&field.quoted[i]&&strings.index_byte(".[](){}*+?^$|\\",byte)>=0 {append(&escaped,'\\')}
                    append(&escaped,byte)
                }
            }
            flags:c.int=1 // REG_EXTENDED
            if p.shell.compat.shopts["nocasematch"] {flags|=2} // REG_ICASE
            compiled:Native_Shell_Regex
            if native_shell_regcomp(&compiled,strings.clone_to_cstring(string(escaped[:])),flags)!=0 {p.error="Invalid conditional regular expression.";return false}
            defer native_shell_regfree(&compiled)
            matches:=make([]Native_Shell_Regex_Match,int(compiled.nsub)+1)
            for &match in matches {match={-1,-1}}
            result:=native_shell_regexec(&compiled,strings.clone_to_cstring(left),c.size_t(len(matches)),raw_data(matches),0)
            if result!=0&&result!=1 {p.error="Conditional regular expression could not be evaluated.";return false}
            native_shell_array_remove(p.shell,"BASH_REMATCH")
            native_shell_array_ensure(p.shell,"BASH_REMATCH").initialized=true
            if result==0 {
                for match,index in matches {
                    first_at,last_at:=int(match.first),int(match.last);capture:=""
                    if first_at>=0&&last_at>=first_at&&last_at<=len(left) {capture=left[first_at:last_at]}
                    _=native_shell_value_set(p.shell,fmt.tprintf("BASH_REMATCH[%d]",index),capture)
                }
            }
            return result==0
        case "-eq","-ne","-lt","-le","-gt","-ge":
            a,err_a:=native_shell_arithmetic(p.shell,first,true);b,err_b:=native_shell_arithmetic(p.shell,raw,true)
            if err_a!=""||err_b!="" {p.error="Invalid conditional arithmetic expression.";return false}
            switch operator {case "-eq":return a==b;case "-ne":return a!=b;case "-lt":return a<b;case "-le":return a<=b;case "-gt":return a>b;case "-ge":return a>=b}
        case:
            status,handled:=native_shell_compat_builtin(p.shell,[]string{"test",left,operator,right});if !handled||status>1 {p.error="Invalid conditional predicate."};return status==0
        }
    }
    return evaluate&&left!=""
}
native_shell_conditional_and :: proc(p:^Native_Shell_Conditional,evaluate:bool)->bool {
    value:=native_shell_conditional_atom(p,evaluate)
    for p.error==""&&native_shell_conditional_peek(p)=="&&" {p.position+=1;right:=native_shell_conditional_atom(p,evaluate&&value);value=value&&right}
    return value
}
native_shell_conditional_or :: proc(p:^Native_Shell_Conditional,evaluate:bool)->bool {
    value:=native_shell_conditional_and(p,evaluate)
    for p.error==""&&native_shell_conditional_peek(p)=="||" {p.position+=1;right:=native_shell_conditional_and(p,evaluate&&!value);value=value||right}
    return value
}
native_shell_conditional :: proc(shell:^Native_Shell,source:string)->int {
    previous_locale:=native_shell_text_locale(shell);defer native_shell_text_locale_restore(previous_locale)
    tokens,error:=native_shell_conditional_tokens(source)
    if error!="" {native_shell_diagnostic(shell,error);return 2}
    parser:=Native_Shell_Conditional{shell=shell,tokens=tokens[:]};value:=native_shell_conditional_or(&parser,true)
    if parser.error!=""||parser.position<len(tokens) {fmt.eprintf("terminal+: conditional syntax error: %s\n",parser.error);return 2}
    if value {return 0};return 1
}

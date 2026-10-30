#+build linux
package main

import "core:c"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import atomic "core:sync"
import posix "core:sys/posix"

NATIVE_SHELL_DESCRIPTOR_MAX :: 0x7fffffff // Linux descriptors use a signed C int.

Native_Shell_Job :: struct {
    id:int,
    pgid:posix.pid_t,
    pids:[]posix.pid_t,
    done,stopped:[]bool,
    status,stop_signal:int,
    statuses:[]int,
    command:string,
    notified,hidden,disowned,no_hup,interrupted,waited:bool,
    own_group:bool,
    terminal:posix.termios,
    terminal_saved:bool,
    coproc_name:string,
    coproc_fds:[2]posix.FD,
}
// Nested native execution shares its enclosing pipeline/substitution group.
native_shell_nested_group:posix.pid_t
native_shell_capture_interrupted:i32
native_shell_capture_sequence:u64
native_shell_capture_status:int
native_shell_wait_signal:i32
native_shell_hash_invalidation_suspended:int
native_shell_preparation_failed:bool
native_shell_child_trap_count:int
native_shell_command_sequence:u64
native_shell_exit_warning_sequence:u64
native_shell_exit_warning_active:bool
native_shell_wait_interrupt :: proc "c" (signal:posix.Signal) {atomic.atomic_store(&native_shell_wait_signal,i32(signal));native_shell_trap_signal(signal)}
native_shell_capture_interrupt :: proc "c" (signal:posix.Signal) {atomic.atomic_store(&native_shell_capture_interrupted,1);native_shell_trap_signal(signal)}

native_shell_fork_loop_scope :: proc(shell:^Native_Shell) {
    native_shell_child_trap_count=0
    if native_shell_compat_level(shell)>44 {shell.compat.loop_depth=0;shell.compat.break_depth=0;shell.compat.continue_depth=0}
}

// Keep internal pipes out of the standard streams even when the caller has
// explicitly closed one. Child dup2/close sequences must not alias fd 0..2.
native_shell_pipe :: proc(descriptors:^[2]posix.FD)->bool {
    if pty_pipe2(descriptors,c.int(posix.O_CLOEXEC))!=0 {return false}
    for &fd in descriptors^ {
        if fd>2 {continue}
        replacement:=posix.fcntl(fd,.DUPFD_CLOEXEC,c.int(3))
        if replacement<0 {posix.close(descriptors[0]);posix.close(descriptors[1]);return false}
        posix.close(fd);fd=posix.FD(replacement)
    }
    return true
}

Native_Shell_Process_Substitution :: struct {fd:posix.FD,pid:posix.pid_t}
native_shell_substitutions:[dynamic]Native_Shell_Process_Substitution

native_shell_substitutions_close :: proc(first:int) {
    for substitution in native_shell_substitutions[first:] {posix.close(substitution.fd)}
    resize(&native_shell_substitutions,first)
}

native_shell_process_substitute :: proc(shell:^Native_Shell,source:string,input:bool)->(string,string) {
    descriptors:[2]posix.FD
    if !native_shell_pipe(&descriptors) {return "","cannot create process substitution pipe"}
    keep,child_fd:=descriptors[0],descriptors[1]
    child_target:posix.FD=1
    if !input {keep=descriptors[1];child_fd=descriptors[0];child_target=0}
    pid:=posix.fork()
    if pid<0 {posix.close(descriptors[0]);posix.close(descriptors[1]);return "","cannot fork process substitution"}
    if pid==0 {
        shell.compat.subshell_depth+=1
        native_shell_fork_loop_scope(shell)
        _=posix.setpgid(0,0);native_shell_nested_group=posix.getpid()
        posix.close(keep)
        for substitution in native_shell_substitutions {posix.close(substitution.fd)}
        native_shell_substitutions=nil
        if posix.dup2(child_fd,child_target)<0 {posix._exit(1)}
        if child_fd!=child_target {posix.close(child_fd)}
        native_shell_child_signals(shell);native_shell_native_child_handlers(shell)
        shell.interactive=false;shell.exiting=false
        if shell.tty_fd>=0 {posix.close(shell.tty_fd);shell.tty_fd= -1}
        shell.jobs=make([dynamic]Native_Shell_Job,0,0,shell.allocator)
        status:=native_shell_execute(shell,source)
        shell.status=status
        native_shell_run_trap(shell,0)
        native_shell_shutdown(shell)
        if shell.exiting {status=shell.exit_status}
        posix._exit(c.int(status))
    }
    _=posix.setpgid(pid,pid)
    posix.close(child_fd)
    _=posix.fcntl(keep,.SETFD,c.int(0))
    if native_shell_substitutions.allocator.procedure==nil {native_shell_substitutions=make([dynamic]Native_Shell_Process_Substitution,0,0,shell.allocator)}
    append(&native_shell_substitutions,Native_Shell_Process_Substitution{keep,pid})
    index:=native_shell_job_add(shell,pid,[]posix.pid_t{pid},source);shell.jobs[index].hidden=true;shell.jobs[index].id=0
    shell.last_background=pid
    return fmt.aprintf("/dev/fd/%d",keep),""
}

Native_Shell_Assignment :: struct {name,value:string,array,append_value:bool}
Native_Shell_Prepared_Redirect :: struct {fd:int, operator,target,body:string,persistent,allocated:bool}
Native_Shell_Prepared :: struct {
    args:[dynamic]string,
    compound:^Native_Shell_Compound,
    deferred:^Native_Shell_Command,
    bypass_functions:bool,
    search_path:string,
    substitution_status:int,
    failure_kind:string,
    line:int,
    assignments:[dynamic]Native_Shell_Assignment,
    redirects:[dynamic]Native_Shell_Prepared_Redirect,
}
Native_Shell_Variable_Save :: struct {
    name,value:string,
    exists,exported,attributes_present,declared:bool,
    attributes:u32,
    array:^Native_Shell_Array,
}
Native_Shell_FD_Save :: struct {fd,saved:posix.FD}

// Variable keys and values live beyond the per-command arena. Export entries
// borrow those keys; removing a variable removes its export entry first.
native_shell_set_variable :: proc(shell:^Native_Shell,name,value:string,export_value:bool=false) {
    if name=="PATH"&&shell.compat!=nil&&native_shell_hash_invalidation_suspended==0 {native_shell_hash_clear(shell)}
    for key,old in shell.variables {
        if key==name {
            replacement:=strings.clone(value,shell.allocator)
            shell.variables[key]=replacement
            delete(old,shell.allocator)
            if export_value {shell.exported[key]=true}
            return
        }
    }
    key:=strings.clone(name,shell.allocator)
    shell.variables[key]=strings.clone(value,shell.allocator)
    if export_value {shell.exported[key]=true}
}

native_shell_unset_variable :: proc(shell:^Native_Shell,name:string) {
    if name=="PATH"&&shell.compat!=nil&&native_shell_hash_invalidation_suspended==0 {native_shell_hash_clear(shell)}
    for key,value in shell.variables {
        if key==name {
            delete_key(&shell.exported,key);delete_key(&shell.variables,key)
            delete(key,shell.allocator);delete(value,shell.allocator)
            return
        }
    }
}

native_shell_assignment_parts :: proc(raw:string)->(name,rhs:string,append_value,valid:bool) {
    if raw==""||!native_shell_name_start(raw[0]) {return}
    at:=1
    for at<len(raw)&&native_shell_name_byte(raw[at]) {at+=1}
    if at<len(raw)&&raw[at]=='[' {
        depth:=1;at+=1;quote:u8
        for at<len(raw)&&depth>0 {
            ch:=raw[at]
            if ch=='\\' {at+=2;continue}
            if quote=='\'' {if ch=='\'' {quote=0};at+=1;continue}
            if ch=='$'&&at+1<len(raw)&&(raw[at+1]=='('||raw[at+1]=='{') {
                end:int;error:string
                if raw[at+1]=='(' {end,error=native_shell_substitution_end(raw,at)} else {end,error=native_shell_parameter_end(raw,at)}
                if error!="" {return};at=end;continue
            }
            if ch=='"' {if quote=='"' {quote=0} else {quote='"'};at+=1;continue}
            if ch=='\''&&quote==0 {quote=ch;at+=1;continue}
            if quote==0 {if ch=='[' {depth+=1};if ch==']' {depth-=1}}
            at+=1
        }
        if depth!=0 {return}
    }
    end_name:=at
    if at<len(raw)&&raw[at]=='+' {append_value=true;at+=1}
    if at>=len(raw)||raw[at]!='=' {return}
    name=raw[:end_name];rhs=raw[at+1:];valid=true
    return
}

// Resolve an assignment subscript after its RHS expansion, exactly once. All
// preparation snapshots, overlays and final writes then use the canonical
// target so arithmetic side effects cannot repeat during those later phases.
native_shell_assignment_target :: proc(shell:^Native_Shell,name:string)->(string,string) {
    target:=name
    for _ in 0..<64 {
        base,key,indexed:=native_shell_reference(target)
        if shell.compat.attributes[base]&NATIVE_SHELL_NAMEREF!=0 {
            reference:=shell.variables[base]
            if reference==""||reference==base {break}
            if indexed {if _,_,already_indexed:=native_shell_reference(reference);!already_indexed {reference=strings.concatenate([]string{reference,"[",key,"]"})}}
            target=reference;continue
        }
        if !indexed {return target,""}
        array:=shell.compat.arrays[base]
        if array!=nil&&array.associative_mode||shell.compat.attributes[base]&NATIVE_SHELL_ASSOCIATIVE!=0 {
            expanded,error:=native_shell_expand_assignment(shell,key)
            if error!="" {return "",error}
            if expanded=="" {return "","bad array subscript"}
            return strings.concatenate([]string{base,"[",expanded,"]"}),""
        }
        number,error:=native_shell_arithmetic(shell,key)
        if error!="" {return "",error}
        if number<0 {
            maximum:=-1
            if array!=nil {for index,_ in array.indexed {maximum=max(maximum,index)}}
            number=i64(maximum)+1+number
        }
        if number<0 {return "","bad array subscript"}
        return fmt.aprintf("%s[%d]",base,number),""
    }
    return "","circular name reference"
}

native_shell_assignment_name :: proc(raw:string)->(string,string,bool) {
    name,rhs,_,valid:=native_shell_assignment_parts(raw)
    return name,rhs,valid
}

native_shell_variable_name :: proc(name:string)->bool {return native_shell_name(name)}

native_shell_assignment_context :: proc(name:string)->bool {
    switch name {case "export","declare","typeset","local","readonly":return true}
    return false
}

native_shell_prepare :: proc(shell:^Native_Shell,command:Native_Shell_Command)->(Native_Shell_Prepared,string) {
    result:=Native_Shell_Prepared{compound=command.compound,line=shell.compat.current_line,failure_kind="expansion"}
    capture_sequence:=native_shell_capture_sequence
    prefix:=true
    assignment_saves:=make([dynamic]Native_Shell_Variable_Save)
    overlay:=true
    defer {if overlay {native_shell_restore_variables(shell,assignment_saves[:])}}
    for word in command.words {
        if name,raw,append_value,assignment:=native_shell_assignment_parts(word.raw);(prefix||shell.compat.options["keyword"])&&assignment {
            if !overlay {clear(&assignment_saves);overlay=true}
            array:=strings.has_prefix(raw,"(")&&strings.has_suffix(raw,")")
            value:=raw
            if !array {expanded,error:=native_shell_expand_assignment(shell,raw);if error!="" {return result,error};value=expanded}
            target_name,target_error:=native_shell_assignment_target(shell,name)
            if target_error!="" {return result,target_error}
            snapshot_name:=native_shell_snapshot_base(shell,target_name)
            already_saved:=false
            for item in assignment_saves {if item.name==snapshot_name {already_saved=true;break}}
            if !already_saved {append(&assignment_saves,native_shell_snapshot_variable(shell,snapshot_name))}
            if !array {
                overlay_value:=value
                if append_value {
                    old,_:=native_shell_value_get(shell,target_name)
                    base:=target_name;if bracket:=strings.index_byte(base,'[');bracket>=0 {base=base[:bracket]}
                    if shell.compat.attributes[base]&NATIVE_SHELL_INTEGER!=0 {
                        if old=="" {old="0"};if value=="" {value="0"}
                        number,error:=native_shell_arithmetic(shell,strings.concatenate([]string{"(",old,") + (",value,")"}))
                        if error!="" {return result,error};overlay_value=fmt.aprintf("%d",number)
                    } else {overlay_value=strings.concatenate([]string{old,value})}
                }
                native_shell_hash_invalidation_suspended+=1
                overlay_error:=native_shell_value_set(shell,target_name,overlay_value)
                native_shell_hash_invalidation_suspended-=1
                if overlay_error!="" {
                    has_command:=false
                    for candidate in command.words {if _,_,_,is_assignment:=native_shell_assignment_parts(candidate.raw);!is_assignment {has_command=true;break}}
                    if has_command&&!shell.compat.options["posix"]&&strings.contains(overlay_error,"readonly") {fmt.eprintf("terminal+: %s\n",overlay_error);continue}
                    result.failure_kind="assignment";return result,overlay_error
                }
                base,_,_:=native_shell_reference(target_name)
                if base=="RANDOM"&&shell.compat.random_special||base=="SECONDS"&&shell.compat.seconds_special {
                    // These getters advance their state. Materialize the
                    // canonical assigned seed/offset instead of reading them.
                    value=shell.variables[base]
                } else {value,_=native_shell_value_get(shell,target_name)}
                value=strings.clone(value);append_value=false
            }
            append(&result.assignments,Native_Shell_Assignment{name=target_name,value=value,array=array,append_value=append_value})
            continue
        }
        prefix=false
        if overlay {native_shell_restore_variables(shell,assignment_saves[:]);overlay=false}
        assignment_context:=len(result.args)>0&&native_shell_assignment_context(result.args[0])
        if shell.compat.options["posix"]&&len(result.args)>1&&result.args[0]=="command" {
            index:=1
            for index<len(result.args)&&(result.args[index]=="--"||result.args[index]=="-p") {index+=1}
            assignment_context=index<len(result.args)&&native_shell_assignment_context(result.args[index])
        }
        if assignment_context {
            if name,raw,append_value,assignment:=native_shell_assignment_parts(word.raw);assignment {
                value:=raw
                if !(strings.has_prefix(raw,"(")&&strings.has_suffix(raw,")")) {expanded,error:=native_shell_expand_assignment(shell,raw);if error!="" {return result,error};value=expanded}
                operator:="=";if append_value {operator="+="}
                append(&result.args,strings.concatenate([]string{name,operator,value}));continue
            }
        }
        fields,error:=native_shell_expand(shell,word)
        if error!="" {return result,error}
        append(&result.args,..fields)
    }
    if overlay {native_shell_restore_variables(shell,assignment_saves[:]);overlay=false}
    result.failure_kind="redirection"
    redirection_only:=len(result.args)==0&&command.compound==nil
    redirection_variables:=make([dynamic]Native_Shell_Variable_Save)
    defer native_shell_restore_variables(shell,redirection_variables[:])
    for redirect in command.redirects {
        if shell.compat.restricted {
            switch redirect.operator {case ">",">>",">|","&>","&>>","<>":return result,"restricted: cannot redirect output"}
        }
        descriptor:=redirect.fd
        variable_descriptor:=redirect.variable!=""
        persistent:=variable_descriptor&&!shell.compat.shopts["varredir_close"]&&!redirection_only
        allocated_descriptor:=false
        if variable_descriptor {
            if redirection_only {
                found:=false;for item in redirection_variables {if item.name==redirect.variable {found=true;break}}
                if !found {append(&redirection_variables,native_shell_snapshot_variable(shell,redirect.variable))}
            }
            if (redirect.operator==">&"||redirect.operator=="<&")&&redirect.target.raw=="-" {
                value,_:=native_shell_value_get(shell,redirect.variable);number,valid:=strconv.parse_int(value)
                if !valid||number<0 {return result,"ambiguous descriptor variable"};descriptor=number
            } else {
                temporary:=posix.open("/dev/null",{.RDWR,.CLOEXEC})
                if temporary<0 {return result,"cannot allocate descriptor"}
                allocated:=posix.fcntl(temporary,.DUPFD,c.int(10));posix.close(temporary)
                if allocated<0 {return result,"cannot allocate descriptor"}
                descriptor=int(allocated)
                allocated_descriptor=true
                if error:=native_shell_value_set(shell,redirect.variable,fmt.aprintf("%d",descriptor));error!="" {posix.close(posix.FD(descriptor));result.failure_kind="assignment";return result,error}
            }
        }
        if descriptor<0||descriptor>NATIVE_SHELL_DESCRIPTOR_MAX {return result,"file descriptor is outside the Linux descriptor range"}
        if redirect.operator=="<<"||redirect.operator=="<<-" {
            body:=redirect.body
            if redirect.expand_body {expanded,error:=native_shell_expand_heredoc(shell,body);if error!="" {result.failure_kind="expansion";return result,error};body=expanded}
            append(&result.redirects,Native_Shell_Prepared_Redirect{fd=descriptor,operator=redirect.operator,body=body,persistent=persistent,allocated=allocated_descriptor});continue
        }
        if redirect.operator=="<<<" {
            body,error:=native_shell_expand_assignment(shell,redirect.target.raw)
            if error!="" {result.failure_kind="expansion";return result,error}
            append(&result.redirects,Native_Shell_Prepared_Redirect{fd=descriptor,operator=redirect.operator,body=strings.concatenate([]string{body,"\n"}),persistent=persistent,allocated=allocated_descriptor});continue
        }
        fields,error:=native_shell_expand(shell,redirect.target,!shell.compat.options["posix"],!shell.compat.options["posix"]||shell.interactive)
        if error!="" {result.failure_kind="expansion";return result,error}
        if len(fields)!=1 {return result,"ambiguous redirection"}
        operator:=redirect.operator
        if operator==">&"&&descriptor==1&&fields[0]!="-" {
            target:=strings.trim_suffix(fields[0],"-")
            if _,numeric:=strconv.parse_int(target);!numeric {operator="&>";if shell.compat.restricted {return result,"restricted: cannot redirect output"}}
        }
        append(&result.redirects,Native_Shell_Prepared_Redirect{fd=descriptor,operator=operator,target=fields[0],persistent=persistent,allocated=allocated_descriptor})
    }
    if native_shell_capture_sequence!=capture_sequence {result.substitution_status=native_shell_capture_status}
    return result,""
}

// Keep the shell's private controlling-terminal handle outside the user's
// descriptor namespace. A user redirection must not overwrite it or duplicate
// it as though it were an explicitly opened shell descriptor.
native_shell_protect_tty :: proc(shell:^Native_Shell,redirects:[]Native_Shell_Prepared_Redirect)->bool {
    if !native_shell_protect_readers(shell,redirects) {return false}
    if shell.tty_fd<0 {return true}
    mentioned:=make(map[int]bool)
    for redirect in redirects {
        mentioned[redirect.fd]=true
        if redirect.operator==">&"||redirect.operator=="<&" {
            value:=redirect.target
            if strings.has_suffix(value,"-") {value=value[:len(value)-1]}
            if target,ok:=strconv.parse_int(value);ok&&target>=0 {mentioned[target]=true}
        }
    }
    if !mentioned[int(shell.tty_fd)] {return true}
    minimum:=3
    for {
        candidate:=posix.fcntl(shell.tty_fd,.DUPFD_CLOEXEC,c.int(minimum))
        if candidate<0 {fmt.eprintln("terminal+: cannot preserve the controlling-terminal descriptor");return false}
        if !mentioned[int(candidate)] {
            posix.close(shell.tty_fd);shell.tty_fd=posix.FD(candidate)
            return true
        }
        posix.close(posix.FD(candidate));minimum=int(candidate)+1
    }
}

foreign import native_shell_exec_lib "system:c"
foreign native_shell_exec_lib {
    @(link_name="memfd_create") native_shell_memfd_create :: proc(name:cstring,flags:c.uint)->posix.FD ---
}

native_shell_here_fd :: proc(body:string)->posix.FD {
    fd:=native_shell_memfd_create("terminal-shell-input",1)
    if fd<0 {return -1}
    bytes:=transmute([]u8)body
    for len(bytes)>0 {
        count:=posix.write(fd,raw_data(bytes),c.size_t(len(bytes)))
        if count<0&&posix.errno()==.EINTR {continue}
        if count<=0 {posix.close(fd);return -1}
        bytes=bytes[int(count):]
    }
    if posix.lseek(fd,0,.SET)<0 {posix.close(fd);return -1}
    return fd
}

native_shell_apply_redirects :: proc(shell:^Native_Shell,redirects:[]Native_Shell_Prepared_Redirect)->bool {
    for redirect in redirects {
        descriptor:=posix.FD(redirect.fd)
        if redirect.operator==">&"||redirect.operator=="<&" {
            if redirect.target=="-" {posix.close(descriptor);continue}
            target:=redirect.target;moving:=strings.has_suffix(target,"-")
            if moving {target=target[:len(target)-1]}
            number,ok:=strconv.parse_int(target)
            if !ok||number<0||number>NATIVE_SHELL_DESCRIPTOR_MAX||posix.dup2(posix.FD(number),descriptor)<0 {
                fmt.eprintf("terminal+: bad file descriptor: %s\n",redirect.target);return false
            }
            if moving&&posix.FD(number)!=descriptor {posix.close(posix.FD(number))}
            continue
        }
        fd:posix.FD= -1
        if redirect.operator=="<<"||redirect.operator=="<<-"||redirect.operator=="<<<" {fd=native_shell_here_fd(redirect.body)} else {
            flags:posix.O_Flags
            verify_noclobber:=false
            switch redirect.operator {
            case "<":flags={}
            case "<>":flags={.RDWR,.CREAT}
            case ">",">|","&>":
                flags={.WRONLY,.CREAT,.TRUNC}
                if redirect.operator!=">|"&&shell.compat.options["noclobber"] {
                    info,error:=os.stat(redirect.target,context.allocator)
                    if error==nil&&info.type==.Regular {fmt.eprintf("terminal+: %s: cannot overwrite existing file\n",redirect.target);return false}
                    if error!=nil {flags={.WRONLY,.CREAT,.EXCL}} else {
                        // Do not truncate before checking the opened object:
                        // an existing device/FIFO can be replaced after stat.
                        flags={.WRONLY};verify_noclobber=true
                    }
                }
            case ">>","&>>":flags={.WRONLY,.CREAT,.APPEND}
            case:fmt.eprintf("terminal+: unsupported redirection: %s\n",redirect.operator);return false
            }
            path:=strings.clone_to_cstring(redirect.target)
            fd=posix.open(path,flags,{.IRUSR,.IWUSR,.IRGRP,.IWGRP,.IROTH,.IWOTH})
            if fd>=0&&verify_noclobber {
                info:posix.stat_t
                if posix.fstat(fd,&info)!=.OK||posix.S_ISREG(info.st_mode) {
                    posix.close(fd);fmt.eprintf("terminal+: %s: cannot overwrite existing file\n",redirect.target);return false
                }
            }
        }
        if fd<0 {fmt.eprintf("terminal+: cannot open %s: %v\n",redirect.target,posix.errno());return false}
        if fd!=descriptor {
            result:=posix.dup2(fd,descriptor);posix.close(fd)
            if result<0 {fmt.eprintf("terminal+: cannot redirect descriptor %d\n",redirect.fd);return false}
        } else {_=posix.fcntl(descriptor,.SETFD,c.int(0))}
        if redirect.operator=="&>"||redirect.operator=="&>>" {if posix.dup2(descriptor,2)<0 {return false}}
    }
    return true
}

native_shell_redirect_descriptors :: proc(redirects:[]Native_Shell_Prepared_Redirect)->[]posix.FD {
    descriptors:=make([dynamic]posix.FD)
    for redirect in redirects {
        if redirect.persistent {continue}
        append(&descriptors,posix.FD(redirect.fd))
        if redirect.operator=="&>"||redirect.operator=="&>>" {append(&descriptors,2)}
        if (redirect.operator==">&"||redirect.operator=="<&")&&strings.has_suffix(redirect.target,"-")&&len(redirect.target)>1 {
            if target,ok:=strconv.parse_int(redirect.target[:len(redirect.target)-1]);ok&&target>=0&&target<=NATIVE_SHELL_DESCRIPTOR_MAX {append(&descriptors,posix.FD(target))}
        }
    }
    return descriptors[:]
}

native_shell_save_fds :: proc(redirects:[]Native_Shell_Prepared_Redirect)->([]Native_Shell_FD_Save,bool) {
    saved:=make([dynamic]Native_Shell_FD_Save)
    descriptors:=native_shell_redirect_descriptors(redirects)
    mentioned:=make(map[int]bool)
    for descriptor in descriptors {mentioned[int(descriptor)]=true}
    for redirect in redirects {
        mentioned[redirect.fd]=true
        if redirect.operator==">&"||redirect.operator=="<&" {
            target:=redirect.target;if strings.has_suffix(target,"-") {target=target[:len(target)-1]}
            if number,ok:=strconv.parse_int(target);ok&&number>=0 {mentioned[number]=true}
        }
    }
    for descriptor in descriptors {
        found:=false
        for item in saved {if item.fd==descriptor {found=true;break}}
        if found {continue}
        minimum:=3;old:posix.FD= -1
        reserved:=false
        for redirect in redirects {if redirect.fd==int(descriptor)&&redirect.allocated&&!redirect.persistent {reserved=true;break}}
        if reserved {append(&saved,Native_Shell_FD_Save{descriptor,-1});continue}
        for {
            candidate:=posix.fcntl(descriptor,.DUPFD_CLOEXEC,c.int(minimum))
            if candidate<0 {
                if posix.errno()!=.EBADF {native_shell_restore_fds(saved[:]);return nil,false}
                break
            }
            if !mentioned[int(candidate)] {old=posix.FD(candidate);break}
            posix.close(posix.FD(candidate));minimum=int(candidate)+1
        }
        append(&saved,Native_Shell_FD_Save{descriptor,old})
    }
    return saved[:],true
}

native_shell_restore_fds :: proc(saved:[]Native_Shell_FD_Save) {
    for item in saved {
        if item.saved<0 {posix.close(item.fd)}
        else {posix.dup2(item.saved,item.fd);posix.close(item.saved)}
    }
}

native_shell_snapshot_base :: proc(shell:^Native_Shell,name:string)->string {
    base,_,_:=native_shell_reference(name)
    for _ in 0..<64 {
        if shell.compat.attributes[base]&NATIVE_SHELL_NAMEREF==0 {break}
        target:=shell.variables[base]
        if target==""||target==base {break}
        base,_,_=native_shell_reference(target)
    }
    return base
}

native_shell_snapshot_variable :: proc(shell:^Native_Shell,name:string)->Native_Shell_Variable_Save {
    value,exists:=shell.variables[name]
    attributes,present:=shell.compat.attributes[name]
    return Native_Shell_Variable_Save{
        name=strings.clone(name),value=strings.clone(value),exists=exists,
        exported=shell.exported[name],attributes=attributes,attributes_present=present,declared=shell.compat.declared[name],
        array=native_shell_array_clone(shell,shell.compat.arrays[name]),
    }
}

native_shell_saved_variables :: proc(shell:^Native_Shell,assignments:[]Native_Shell_Assignment)->[]Native_Shell_Variable_Save {
    saved:=make([dynamic]Native_Shell_Variable_Save)
    for assignment in assignments {
        base:=native_shell_snapshot_base(shell,assignment.name)
        duplicate:=false
        for item in saved {if item.name==base {duplicate=true;break}}
        if !duplicate {append(&saved,native_shell_snapshot_variable(shell,base))}
    }
    return saved[:]
}

native_shell_restore_variables :: proc(shell:^Native_Shell,saved:[]Native_Shell_Variable_Save) {
    native_shell_hash_invalidation_suspended+=1
    defer {native_shell_hash_invalidation_suspended-=1}
    for item in saved {
        // Bypass public setters: a temporary prefix may have gained readonly,
        // integer or nameref attributes during a function. Its complete prior
        // representation must be restored without re-evaluating its value.
        native_shell_unset_variable(shell,item.name)
        native_shell_array_remove(shell,item.name)
        if item.exists {native_shell_set_variable(shell,item.name,item.value,item.exported)}
        if item.attributes_present {native_shell_attribute_set(shell,item.name,item.attributes)} else {
            for key in shell.compat.attributes {if key==item.name {delete_key(&shell.compat.attributes,key);delete(key,shell.allocator);break}}
        }
        native_shell_bool_set(shell,&shell.compat.declared,item.name,item.declared)
        // Transfer ownership of the cloned array to the persistent state.
        // Removing its temporary replacement above also frees all changed
        // elements, keys and ordering metadata.
        if item.array!=nil {shell.compat.arrays[strings.clone(item.name,shell.allocator)]=item.array}
    }
}

native_shell_apply_assignments :: proc(shell:^Native_Shell,assignments:[]Native_Shell_Assignment,export_value:bool)->bool {
    for assignment in assignments {
        if export_value {
            _,_,indexed:=native_shell_reference(assignment.name)
            if indexed {fmt.eprintf("terminal+: `%s': not a valid identifier\n",assignment.name);continue}
        }
        if assignment.array {
            if error:=native_shell_array_assign(shell,assignment.name,assignment.value,assignment.append_value);error!="" {fmt.eprintln(error);return false}
            continue
        }
        value:=assignment.value
        if assignment.append_value {
            old,_:=native_shell_value_get(shell,assignment.name)
            base:=assignment.name;if bracket:=strings.index_byte(base,'[');bracket>=0 {base=base[:bracket]}
            if shell.compat!=nil&&shell.compat.attributes[base]&NATIVE_SHELL_INTEGER!=0 {
                number,error:=native_shell_arithmetic(shell,strings.concatenate([]string{"(",old,") + (",value,")"}))
                if error!="" {fmt.eprintln(error);return false};value=fmt.aprintf("%d",number)
            } else {value=strings.concatenate([]string{old,value})}
        }
        flags:u32;if export_value||shell.compat.options["allexport"] {flags|=NATIVE_SHELL_EXPORT}
        if error:=native_shell_value_set(shell,assignment.name,value,flags);error!="" {fmt.eprintln(error);return false}
    }
    return true
}

native_shell_environment :: proc(shell:^Native_Shell,assignments:[]Native_Shell_Assignment)->[]cstring {
    result:=make([dynamic]cstring)
    for name,value in shell.variables {
        if !shell.exported[name] {continue}
        if _,array:=shell.compat.arrays[name];array {continue}
        exported_value:=value
        switch name {case "SHELLOPTS","BASHOPTS","RANDOM","SRANDOM","SECONDS","EPOCHSECONDS","EPOCHREALTIME","BASHPID","LINENO","BASH_ARGV0":if current,present:=native_shell_value_get(shell,name);present {exported_value=current}}
        overridden:=false
        for assignment in assignments {if assignment.name==name {overridden=true;break}}
        if !overridden {append(&result,strings.clone_to_cstring(strings.concatenate([]string{name,"=",exported_value})))}
    }
    for assignment,i in assignments {
        if assignment.array||strings.contains(assignment.name,"[") {continue}
        duplicate:=false
        for j:=i+1;j<len(assignments);j+=1 {if assignments[j].name==assignment.name {duplicate=true;break}}
        if !duplicate {append(&result,strings.clone_to_cstring(strings.concatenate([]string{assignment.name,"=",assignment.value})))}
    }
    for name,body in shell.compat.functions {
        key:=strings.concatenate([]string{"BASH_FUNC_",name,"%%"})
        if shell.compat.attributes[key]&NATIVE_SHELL_EXPORT!=0 {append(&result,strings.clone_to_cstring(strings.concatenate([]string{key,"=() { ",body,"\n}"})))}
    }
    append(&result,cstring(nil))
    return result[:]
}

native_shell_paths :: proc(shell:^Native_Shell,args:[]string,assignments:[]Native_Shell_Assignment,search_path:string="")->[]cstring {
    paths:=make([dynamic]cstring)
    if strings.contains(args[0],"/") {append(&paths,strings.clone_to_cstring(args[0]));return paths[:]}
    path,path_exists:=shell.variables["PATH"]
    if !path_exists {path="/usr/local/bin:/usr/bin:/bin"}
    for assignment in assignments {if assignment.name=="PATH" {path=assignment.value}}
    if search_path!="" {path=search_path}
    for component in strings.split_iterator(&path,":") {
        directory:=component
        if directory=="" {directory="."}
        append(&paths,strings.clone_to_cstring(strings.concatenate([]string{directory,"/",args[0]})))
    }
    return paths[:]
}

native_shell_child_signals :: proc(shell:^Native_Shell) {
    for signal:=1;signal<len(native_shell_pending_signals);signal+=1 {
        atomic.atomic_store(&native_shell_pending_signals[signal],0)
        old:posix.sigaction_t
        if posix.sigaction(posix.Signal(signal),nil,&old)!=nil {continue}
        if old.sa_handler==native_shell_trap_signal {posix.signal(posix.Signal(signal),auto_cast posix.SIG_DFL)}
    }
    for signal in ([9]posix.Signal{.SIGINT,.SIGQUIT,.SIGTSTP,.SIGTTIN,.SIGTTOU,.SIGCHLD,.SIGPIPE,.SIGHUP,.SIGTERM}) {
        if source,explicit:=shell.compat.traps[int(signal)];explicit&&source=="" {continue}
        posix.signal(signal,auto_cast posix.SIG_DFL)
    }
}

native_shell_native_child_handlers :: proc(shell:^Native_Shell) {
    for signal in ([4]posix.Signal{.SIGHUP,.SIGTERM,.SIGINT,.SIGQUIT}) {
        if source,explicit:=shell.compat.traps[int(signal)];explicit&&source=="" {continue}
        action:posix.sigaction_t;action.sa_handler=native_shell_terminate
        posix.sigemptyset(&action.sa_mask);_=posix.sigaction(signal,&action,nil)
    }
}

native_shell_exec_external :: proc(shell:^Native_Shell,args:[]string,assignments:[]Native_Shell_Assignment,search_path:string="",arg0:string="",replace_arg0:bool=false,empty_environment:bool=false,missing_handler:bool=true)->int {
    if shell.compat.restricted&&strings.contains(args[0],"/") {fmt.eprintf("terminal+: %s: restricted: command names cannot contain /\n",args[0]);return 1}
    argv:=make([]cstring,len(args)+1)
    for arg,i in args {argv[i]=strings.clone_to_cstring(arg)}
    if replace_arg0 {argv[0]=strings.clone_to_cstring(arg0)}
    env:=native_shell_environment(shell,assignments)
    if empty_environment {env=[]cstring{nil}}
    paths:=native_shell_execution_paths(shell,args,assignments,search_path)
    denied:=false
    for path in paths {
        if !empty_environment {
            entry:=strings.clone_to_cstring(strings.concatenate([]string{"_=",string(path)}));found:=false
            for value,i in env {if value!=nil&&strings.has_prefix(string(value),"_=") {env[i]=entry;found=true;break}}
            if !found {expanded:=make([]cstring,len(env)+1);copy(expanded,env[:len(env)-1]);expanded[len(env)-1]=entry;env=expanded}
        }
        posix.execve(path,raw_data(argv),raw_data(env))
        error:=posix.errno()
        if error==.EACCES {denied=true;continue}
        if error==.ENOEXEC {
            if !native_shell_apply_assignments(shell,assignments,true) {return 1}
            if shell.compat.restricted {
                shell.compat.restricted=false;shell.compat.shopts["restricted_shell"]=false
                for name in ([]string{"SHELL","PATH","HISTFILE","ENV","BASH_ENV"}) {native_shell_attribute_set(shell,name,shell.compat.attributes[name]&~NATIVE_SHELL_READONLY)}
            }
            shell.compat.arg0=string(path);shell.compat.parameters=args[1:]
            status:=native_shell_run_file(shell,string(path))
            shell.exiting=true;shell.exit_status=status
            return status
        }
        if error!=.ENOENT&&error!=.ENOTDIR {
            fmt.eprintf("terminal+: cannot execute %s: %v\n",args[0],error);return 126
        }
    }
    if denied {fmt.eprintf("terminal+: permission denied: %s\n",args[0]);return 126}
    if missing_handler&&!strings.contains(args[0],"/")&&native_shell_has_function(shell,"command_not_found_handle") {
        values:=make([]string,len(args)+1);values[0]="command_not_found_handle";copy(values[1:],args)
        return native_shell_call_function(shell,values)
    }
    fmt.eprintf("terminal+: command not found: %s\n",args[0]);return 127
}

native_shell_builtin_name :: proc(name:string)->bool {
    switch name {
    case ":","true","false","cd","pwd","export","unset","exit","echo","printf","clear","tview","jobs","fg","bg","wait","exec","source",".","eval","command","type","help","history","disown":return true
    }
    return native_shell_compat_builtin_name(name)||native_shell_editor_builtin_name(name)
}

native_shell_job_done :: proc(job:^Native_Shell_Job)->bool {
    for done in job.done {if !done {return false}}
    return true
}

native_shell_job_stopped :: proc(job:^Native_Shell_Job)->bool {
    any:=false
    for done,i in job.done {if !done {any=true;if !job.stopped[i] {return false}}}
    return any
}

// Linux wait status is decoded here because the pinned Odin POSIX wrapper's
// WIFSTOPPED expression also classifies an ordinary exit(1) as a stop.
native_shell_wait_stopped :: proc(status:c.int)->bool {return status!=0xffff&&status&0xff==0x7f}
native_shell_wait_status :: proc(status:c.int)->int {
    if status&0x7f==0 {return int((status>>8)&0xff)}
    if native_shell_wait_stopped(status) {return 128+int((status>>8)&0xff)}
    if status==0xffff {return 0}
    return 128+int(status&0x7f)
}

native_shell_job_update :: proc(shell:^Native_Shell,job:^Native_Shell_Job,pid:posix.pid_t,status:c.int) {
    for process,i in job.pids {
        if process!=pid {continue}
        if status==0xffff {job.stopped[i]=false;return}
        if native_shell_wait_stopped(status) {job.stopped[i]=true;job.stop_signal=int((status>>8)&0xff);return}
        if status&0x7f==c.int(posix.Signal.SIGINT) {job.interrupted=true}
        if !job.done[i]&&!shell.compat.running_trap {
            if action,present:=shell.compat.traps[int(posix.Signal.SIGCHLD)];present&&action!=""&&shell.compat.trap_owners[int(posix.Signal.SIGCHLD)]==posix.getpid() {native_shell_child_trap_count+=1;atomic.atomic_store(&native_shell_pending_signals[int(posix.Signal.SIGCHLD)],1)}
        }
        job.done[i]=true;job.stopped[i]=false
        job.statuses[i]=native_shell_wait_status(status)
        if i==len(job.pids)-1 {job.status=job.statuses[i]}
        return
    }
}

native_shell_reap :: proc(shell:^Native_Shell,notify:bool=false) {
    for &job in shell.jobs {
        for pid,i in job.pids {
            if job.done[i] {continue}
            for {
                status:c.int
                result:=posix.waitpid(pid,&status,{.NOHANG,.UNTRACED,.CONTINUED})
                if result>0 {native_shell_job_update(shell,&job,result,status);continue}
                if result<0&&posix.errno()==.ECHILD {job.done[i]=true}
                break
            }
        }
        if native_shell_job_done(&job) {native_shell_coproc_close(shell,&job)}
        if shell.interactive&&(!shell.compat.options["posix"]||notify)&&!job.hidden&&!job.notified&&(native_shell_job_done(&job)||native_shell_job_stopped(&job)) {
            label:=native_shell_job_label(shell,&job)
            fmt.eprintf("[%d] %s\t%s\n",job.id,label,job.command);job.notified=true
            if shell.compat.options["posix"]&&native_shell_job_done(&job) {job.hidden=true;job.id=0}
        }
    }
}

native_shell_wait_job :: proc(shell:^Native_Shell,job:^Native_Shell_Job,foreground:bool,force:bool=false)->int {
    shell_group:=posix.getpgrp()
    term:posix.termios
    terminal:=foreground&&shell.tty_fd>=0
    if terminal {
        _=posix.tcgetattr(shell.tty_fd,&term)
        _=posix.tcsetpgrp(shell.tty_fd,job.pgid)
        if job.terminal_saved {_=posix.tcsetattr(shell.tty_fd,.TCSADRAIN,&job.terminal)}
    }
    for !native_shell_job_done(job)&&(force||!native_shell_job_stopped(job)) {
        if native_shell_cancelled() {shell.exiting=true;shell.exit_status=128+int(atomic.atomic_load(&native_shell_termination_signal));break}
        status:c.int
        result:=posix.waitpid(-job.pgid,&status,{.UNTRACED,.CONTINUED})
        if result<0 {
            if posix.errno()==.EINTR {
                if !foreground {if interrupted:=native_shell_wait_interruption(shell);interrupted>0 {return 128+interrupted}}
                continue
            }
            if posix.errno()==.ECHILD {for &done in job.done {done=true}}
            break
        }
        native_shell_job_update(shell,job,result,status)
    }
    if terminal {
        if native_shell_job_stopped(job) {job.terminal_saved=posix.tcgetattr(shell.tty_fd,&job.terminal)==.OK}
        _=posix.tcsetpgrp(shell.tty_fd,shell_group)
        _=posix.tcsetattr(shell.tty_fd,.TCSADRAIN,&term)
    }
    if foreground&&job.interrupted {
        // The shell can be outside the terminal's foreground process group.
        // Run its INT trap at the next safe command boundary when a child
        // actually died from SIGINT, rather than mistaking exit(130) for one.
        atomic.atomic_store(&native_shell_pending_signals[int(posix.Signal.SIGINT)],1)
        job.interrupted=false
    }
    if native_shell_job_stopped(job) {return 128+int(posix.Signal.SIGTSTP)}
    return job.status
}

native_shell_job_free :: proc(shell:^Native_Shell,job:^Native_Shell_Job) {
    native_shell_coproc_close(shell,job)
    delete(job.coproc_name,shell.allocator)
    delete(job.pids,shell.allocator);delete(job.done,shell.allocator);delete(job.stopped,shell.allocator);delete(job.statuses,shell.allocator);delete(job.command,shell.allocator)
}

native_shell_job_add :: proc(shell:^Native_Shell,pgid:posix.pid_t,pids:[]posix.pid_t,source:string)->int {
    id:=1
    for job in shell.jobs {id=max(id,job.id+1)}
    job:=Native_Shell_Job{id=id,pgid=pgid,command=strings.clone(source,shell.allocator),own_group=pgid!=native_shell_nested_group,coproc_fds={-1,-1}}
    job.pids=make([]posix.pid_t,len(pids),shell.allocator);copy(job.pids,pids)
    job.done=make([]bool,len(pids),shell.allocator);job.stopped=make([]bool,len(pids),shell.allocator);job.statuses=make([]int,len(pids),shell.allocator)
    append(&shell.jobs,job)
    return len(shell.jobs)-1
}

native_shell_job_index :: proc(shell:^Native_Shell,argument:string)->int {
    native_shell_reap(shell)
    if argument==""||argument=="%+"||argument=="%%" {
        for i:=len(shell.jobs)-1;i>=0;i-=1 {if !shell.jobs[i].hidden&&!native_shell_job_done(&shell.jobs[i]) {return i}}
        return -1
    }
    if argument=="%-" {
        current:=false
        for i:=len(shell.jobs)-1;i>=0;i-=1 {
            if shell.jobs[i].hidden||native_shell_job_done(&shell.jobs[i]) {continue}
            if current {return i};current=true
        }
        return -1
    }
    value:=argument
    by_id:=strings.has_prefix(value,"%")
    if by_id {value=value[1:]}
    number,valid:=strconv.parse_int(value)
    if !valid {
        if !by_id {return -1}
        substring:=strings.has_prefix(value,"?");if substring {value=value[1:]}
        found:= -1
        for job,i in shell.jobs {
            if job.hidden {continue}
            matches:=strings.has_prefix(job.command,value)
            if substring {matches=strings.contains(job.command,value)}
            if matches {if found>=0 {return -2};found=i}
        }
        return found
    }
    for job,i in shell.jobs {
        if !by_id&&shell.compat.options["posix"]&&job.waited {continue}
        if by_id&&!job.hidden&&job.id==number {return i}
        if !by_id {for pid in job.pids {if int(pid)==number {return i}}}
    }
    return -1
}

native_shell_job_label :: proc(shell:^Native_Shell,job:^Native_Shell_Job)->string {
    if native_shell_job_done(job) {if job.status==0 {return "Done"};if shell.compat.options["posix"] {return fmt.aprintf("Done(%d)",job.status)};return fmt.aprintf("Exit %d",job.status)}
    if native_shell_job_stopped(job) {
        if shell.compat.options["posix"] {signal:=job.stop_signal;if signal==0 {signal=int(posix.Signal.SIGTSTP)};return fmt.aprintf("Stopped(SIG%s)",native_shell_signal_name(signal))}
        return "Stopped"
    }
    return "Running"
}

native_shell_jobs_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    index:=1;long,pids,changed,running,stopped,execute:=false,false,false,false,false,false
    for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
        if args[index]=="--" {index+=1;break}
        for flag in args[index][1:] {switch flag {case 'l':long=true;case 'p':pids=true;case 'n':changed=true;case 'r':running=true;case 's':stopped=true;case 'x':execute=true;case:fmt.eprintf("jobs: invalid option: -%c\n",flag);return 2}}
        index+=1
    }
    if execute {
        if index==len(args) {return 0}
        values:=make([dynamic]string)
        for arg in args[index:] {
            if strings.has_prefix(arg,"%") {at:=native_shell_job_index(shell,arg);if at<0 {fmt.eprintf("jobs: %s: no such job\n",arg);return 1};append(&values,fmt.aprintf("%d",shell.jobs[at].pgid))} else {append(&values,arg)}
        }
        command:=[]Native_Shell_Prepared{{args=values,line=shell.compat.current_line}}
        return native_shell_pipeline_prepared(shell,Native_Shell_Pipeline{},command,strings.join(args[index:]," "))
    }
    native_shell_reap(shell)
    selected:=make([dynamic]int);result:=0
    if index==len(args) {for job,i in shell.jobs {if !job.hidden {append(&selected,i)}}} else {
        for arg in args[index:] {at:=native_shell_job_index(shell,arg);if at<0 {fmt.eprintf("jobs: %s: no such job\n",arg);result=1} else {append(&selected,at)}}
    }
    current,previous:= -1,-1
    for i:=len(shell.jobs)-1;i>=0;i-=1 {if shell.jobs[i].hidden {continue};if current<0 {current=i} else {previous=i;break}}
    for at in selected {
        job:=&shell.jobs[at]
        is_stopped:=native_shell_job_stopped(job);is_done:=native_shell_job_done(job)
        if changed&&job.notified||running&&(is_stopped||is_done)||stopped&&!is_stopped {continue}
        if pids {fmt.println(job.pgid);continue}
        label:=native_shell_job_label(shell,job)
        marker:=" ";if at==current {marker="+"} else if at==previous {marker="-"}
        if long&&len(job.pids)>1 {
            program,error:=native_shell_parse(job.command)
            for pid,i in job.pids {
                stage:=""
                if error==""&&len(program.pipelines)>0&&i<len(program.pipelines[0].commands) {
                    command:=program.pipelines[0].commands[i]
                    if command.compound!=nil {stage=command.compound.source} else {
                        words:=make([dynamic]string);for word in command.words {append(&words,word.raw)};stage=strings.join(words[:]," ")
                    }
                    for redirect in command.redirects {stage=strings.concatenate([]string{stage," ",redirect.operator," ",redirect.target.raw})}
                }
                if stage==""&&i==0 {stage=job.command}
                process:=job^;process.pids=job.pids[i:i+1];process.done=job.done[i:i+1];process.stopped=job.stopped[i:i+1];process.status=job.statuses[i]
                process_label:=native_shell_job_label(shell,&process)
                if i==0 {fmt.printf("[%d]%s %d %-24s%s\n",job.id,marker,pid,process_label,stage)} else {fmt.printf("     %d %-24s| %s\n",pid,process_label,stage)}
            }
            job.notified=true
            if shell.compat.options["posix"]&&is_done {job.hidden=true;job.id=0}
            continue
        }
        fmt.printf("[%d]%s ",job.id,marker)
        if long {fmt.printf("%d ",job.pgid)}
        fmt.printf("%-24s%s\n",label,job.command);job.notified=true
        if shell.compat.options["posix"]&&is_done {job.hidden=true;job.id=0}
    }
    return result
}

native_shell_escape :: proc(input:string)->(string,bool) {
    // echo requires a leading zero for octal escapes; printf's %b also
    // accepts non-zero octal digits. Protect those before sharing decoding.
    bytes:=make([dynamic]u8)
    for i:=0;i<len(input);i+=1 {
        if input[i]=='\\'&&i+1<len(input) {
            next:=input[i+1]
            if next>='1'&&next<='7' {append(&bytes,'\\','\\',next)} else {append(&bytes,input[i],next)}
            i+=1
        } else {append(&bytes,input[i])}
    }
    output,stop,_:=native_shell_printf_decode(string(bytes[:]))
    return output,!stop
}

native_shell_invoke :: proc(shell:^Native_Shell,args:[]string,bypass_functions:bool=false)->int {
    if len(args)==0 {return 0}
    if shell.compat.options["posix"]&&native_shell_special_builtin(args[0])&&!shell.compat.disabled[args[0]] {return native_shell_builtin(shell,args)}
    if !bypass_functions&&native_shell_has_function(shell,args[0]) {return native_shell_call_function(shell,args)}
    if native_shell_builtin_name(args[0])&&!shell.compat.disabled[args[0]] {return native_shell_builtin(shell,args)}
    return native_shell_exec_external(shell,args,nil)
}

native_shell_special_builtin :: proc(name:string)->bool {
    switch name {case ":",".","break","continue","eval","exec","exit","export","readonly","return","set","shift","times","trap","unset":return true}
    return false
}

native_shell_special_failure :: proc(shell:^Native_Shell,command:Native_Shell_Prepared,status:int) {
    if shell.interactive||!shell.compat.options["posix"]||len(command.args)==0 {return}
    if native_shell_special_builtin(command.args[0])&&!shell.compat.disabled[command.args[0]] {shell.exiting=true;shell.exit_status=status}
}

native_shell_diagnostic :: proc(shell:^Native_Shell,message:string) {
    if shell.compat.shopts["gnu_errfmt"] {
        source:=shell.compat.current_source;if source=="" {source=shell.compat.arg0};if source=="" {source="terminal+"}
        fmt.eprintf("%s:%d: %s\n",source,max(1,shell.compat.current_line),message)
    } else {fmt.eprintf("terminal+: %s\n",message)}
}

// Bash refuses the first interactive exit with stopped jobs, or with
// running jobs under checkjobs. A repeated exit/EOF is an explicit override;
// executing another command makes the next exit check the jobs again.
native_shell_exit_jobs_check :: proc(shell:^Native_Shell)->bool {
    if !shell.interactive {return true}
    if native_shell_exit_warning_active&&native_shell_command_sequence<=native_shell_exit_warning_sequence+1 {native_shell_exit_warning_active=false;return true}
    native_shell_exit_warning_active=false
    native_shell_reap(shell)
    stopped,running:bool
    for &job in shell.jobs {
        if job.disowned||job.hidden||native_shell_job_done(&job) {continue}
        if native_shell_job_stopped(&job) {stopped=true} else {running=true}
    }
    if !stopped&&!(running&&shell.compat.shopts["checkjobs"]) {return true}
    if stopped {fmt.eprintln("There are stopped jobs.")} else {fmt.eprintln("There are running jobs.")}
    if shell.compat.shopts["checkjobs"] {_=native_shell_jobs_builtin(shell,[]string{"jobs"})}
    native_shell_exit_warning_active=true;native_shell_exit_warning_sequence=native_shell_command_sequence
    return false
}

native_shell_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    if len(args)==0 {return 0}
    if native_shell_builtin_help(args) {return 2}
    if status,handled:=native_shell_editor_builtin(shell,args);handled {return status}
    if status,handled:=native_shell_compat_builtin(shell,args);handled {return status}
    switch args[0] {
    case ":","true":return 0
    case "false":return 1
    case "exit":
        index:=1;if index<len(args)&&args[index]=="--" {index+=1}
        status:=shell.status
        if index<len(args) {
            number,valid:=strconv.parse_i64(strings.trim_space(args[index]))
            if !valid {fmt.eprintln("exit: numeric argument required");return 2}
            status=int(number&255)
        }
        if len(args)-index>1 {fmt.eprintln("exit: too many arguments");shell.exiting=true;shell.exit_status=1;return 1}
        if !native_shell_exit_jobs_check(shell) {return 1}
        shell.exiting=true;shell.exit_status=status;return status
    case "cd":return native_shell_cd_builtin(shell,args)
    case "pwd":return native_shell_pwd_builtin(shell,args)
    case "export":
        index:=1;functions,remove,print_values:=false,false,false
        for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
            if args[index]=="--" {index+=1;break}
            for flag in args[index][1:] {switch flag {case 'f':functions=true;case 'n':remove=true;case 'p':print_values=true;case:fmt.eprintf("export: invalid option: -%c\n",flag);return 2}}
            index+=1
        }
        if index==len(args)||print_values {
            if functions {for name,body in shell.compat.functions {key:=strings.concatenate([]string{"BASH_FUNC_",name,"%%"});if shell.compat.attributes[key]&NATIVE_SHELL_EXPORT!=0 {fmt.printf("%s () { %s; }\n",name,body)}}} else {
                for name,value in shell.variables {if shell.exported[name] {if shell.compat.options["posix"] {fmt.printf("export %s=%s\n",name,explorer_quote(value))} else {fmt.printf("declare -x %s=%s\n",name,explorer_quote(value))}}}
            }
            if index==len(args) {return 0}
        }
        status:=0
        for raw in args[index:] {
            name,right,append_value,assignment:=native_shell_assignment_parts(raw)
            if !assignment {name=raw;right,_=native_shell_value_get(shell,name)}
            if functions {
                if assignment||!native_shell_function_name(name) {fmt.eprintf("export: %s: not a function\n",raw);status=1;continue}
                if !native_shell_has_function(shell,name) {fmt.eprintf("export: %s: not a function\n",name);status=1;continue}
                key:=strings.concatenate([]string{"BASH_FUNC_",name,"%%"});flags:=shell.compat.attributes[key]
                if remove {flags&~=NATIVE_SHELL_EXPORT} else {flags|=NATIVE_SHELL_EXPORT}
                native_shell_attribute_set(shell,key,flags);continue
            }
            if !native_shell_variable_name(name) {fmt.eprintf("export: invalid variable name: %s\n",name);status=1;continue}
            if append_value {old,_:=native_shell_value_get(shell,name);right=strings.concatenate([]string{old,right})}
            if remove {delete_key(&shell.exported,name);native_shell_attribute_set(shell,name,shell.compat.attributes[name]&~NATIVE_SHELL_EXPORT);continue}
            if !assignment {
                native_shell_attribute_set(shell,name,shell.compat.attributes[name]|NATIVE_SHELL_EXPORT)
                if _,array:=shell.compat.arrays[name];!array {native_shell_set_variable(shell,name,right,true)}
                continue
            }
            if error:=native_shell_value_set(shell,name,right,NATIVE_SHELL_EXPORT);error!="" {fmt.eprintln(error);status=1}
        }
        return status
    case "unset":
        status:=0;index:=1;functions,variables,nameref:=false,false,false
        for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
            if args[index]=="--" {index+=1;break}
            for flag in args[index][1:] {switch flag {case 'f':functions=true;case 'v':variables=true;case 'n':nameref=true;case:fmt.eprintf("unset: invalid option: -%c\n",flag);return 2}}
            index+=1
        }
        if functions&&variables {fmt.eprintln("unset: cannot simultaneously unset a function and a variable");return 1}
        for name in args[index:] {
            base,_,indexed:=native_shell_reference(name)
            _,value_exists:=shell.variables[base]
            remove_function:=functions||!variables&&!nameref&&!indexed&&!value_exists&&!shell.compat.declared[base]&&shell.compat.arrays[base]==nil&&native_shell_has_function(shell,name)
            if remove_function {
                key:=strings.concatenate([]string{"BASH_FUNC_",name,"%%"})
                if shell.compat.attributes[key]&NATIVE_SHELL_READONLY!=0 {fmt.eprintf("unset: %s: readonly function\n",name);status=1;continue}
                native_shell_owned_text_remove(&shell.compat.functions,name,shell.allocator)
                native_shell_owned_text_remove(&shell.compat.function_sources,name,shell.allocator)
                for line_key in shell.compat.function_lines {if line_key==name {delete_key(&shell.compat.function_lines,line_key);delete(line_key,shell.allocator);break}}
                native_shell_attribute_set(shell,key,0)
                continue
            }
            if nameref&&shell.compat.attributes[base]&NATIVE_SHELL_NAMEREF==0 {continue}
            if error:=native_shell_value_unset(shell,name,!nameref);error!="" {fmt.eprintln(error);status=1}
        }
        return status
    case "echo":
        previous_locale:=native_shell_text_locale(shell);defer native_shell_text_locale_restore(previous_locale)
        newline:=true;escape:=shell.compat.shopts["xpg_echo"];index:=1
        for index<len(args)&&!(shell.compat.options["posix"]&&escape) {
            option:=args[index]
            if len(option)<2||option[0]!='-' {break}
            valid:=true
            for byte in option[1:] {if byte!='n'&&byte!='e'&&byte!='E' {valid=false;break}}
            if !valid {break}
            for byte in option[1:] {switch byte {case 'n':newline=false;case 'e':escape=true;case 'E':escape=false}}
            index+=1
        }
        first:=true
        for value in args[index:] {
            if !first {fmt.print(" ")};first=false
            if escape {output,continuing:=native_shell_escape(value);fmt.print(output);if !continuing {return 0}} else {fmt.print(value)}
        }
        if newline {fmt.println()};return 0
    case "printf":return native_shell_printf(shell,args)
    case "clear":fmt.print("\x1b[H\x1b[2J\x1b[3J");return 0
    case "tview":
        if len(args)!=2||!native_shell_open_path(args[1]) {fmt.eprintln("tview: expected one readable document, image, video or audio filename");return 1}
        return 0
    case "history":return native_shell_history_builtin(shell,args)
    case "jobs":return native_shell_jobs_builtin(shell,args)
    case "fg","bg":
        if !shell.compat.options["monitor"] {fmt.eprintf("%s: no job control\n",args[0]);return 1}
        first:=1;if first<len(args)&&args[first]=="--" {first+=1}
        if args[0]=="bg" {
            targets:=args[first:];if len(targets)==0 {targets=[]string{""}}
            result:=0
            for target in targets {
                at:=native_shell_job_index(shell,target)
                if at<0||native_shell_job_done(&shell.jobs[at]) {fmt.eprintf("bg: %s: no such job\n",target);result=1;continue}
                resumed:=&shell.jobs[at]
                for &stopped in resumed.stopped {stopped=false};resumed.notified=false
                native_shell_signal_job(resumed,.SIGCONT)
                shell.last_background=resumed.pids[len(resumed.pids)-1]
                marker:="+";if shell.compat.options["posix"] {marker=""}
                fmt.printf("[%d]%s %s &\n",resumed.id,marker,resumed.command)
            }
            return result
        }
        if len(args)-first>1 {fmt.eprintf("fg: expected at most one job\n");return 2}
        argument:="";if first<len(args) {argument=args[first]}
        index:=native_shell_job_index(shell,argument)
        if index<0 {fmt.eprintf("%s: no such job\n",args[0]);return 1}
        job:=&shell.jobs[index]
        if native_shell_job_done(job) {return job.status}
        for &stopped in job.stopped {stopped=false};job.notified=false
        if args[0]=="fg" {
            if shell.tty_fd>=0 {_=posix.tcsetpgrp(shell.tty_fd,job.pgid)}
            _=posix.kill(-job.pgid,.SIGCONT)
            return native_shell_wait_job(shell,job,true)
        }
        _=posix.kill(-job.pgid,.SIGCONT);return 0
    case "disown":
        index:=1;all,running,hup_only:=false,false,false
        for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
            if args[index]=="--" {index+=1;break}
            for flag in args[index][1:] {switch flag {case 'a':all=true;case 'r':running=true;case 'h':hup_only=true;case:fmt.eprintf("disown: invalid option: -%c\n",flag);return 2}}
            index+=1
        }
        native_shell_reap(shell)
        if index==len(args)&&(all||running) {
            for &job in shell.jobs {if job.hidden||running&&native_shell_job_stopped(&job) {continue};if hup_only {job.no_hup=true} else {job.disowned=true;job.hidden=true;job.id=0}}
            return 0
        }
        targets:=args[index:]
        if len(targets)==0 {targets=[]string{""}}
        status:=0
        for argument in targets {
            job_index:=native_shell_job_index(shell,argument)
            if job_index<0 {fmt.eprintf("disown: %s: no such job\n",argument);status=1;continue}
            job:=&shell.jobs[job_index];if hup_only {job.no_hup=true} else {job.disowned=true;job.hidden=true;job.id=0}
        }
        return status
    case "wait":return native_shell_wait_builtin(shell,args)
    case "exec":
        index:=1;empty_environment,login,replace_arg0:=false,false,false;arg0:=""
        for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
            if args[index]=="--" {index+=1;break}
            for at:=1;at<len(args[index]);at+=1 {
                switch args[index][at] {
                case 'c':empty_environment=true
                case 'l':login=true
                case 'a':
                    arg0=args[index][at+1:]
                    if arg0=="" {index+=1;if index==len(args) {fmt.eprintln("exec: -a requires a name");return 2};arg0=args[index]}
                    replace_arg0=true;at=len(args[index])
                case:fmt.eprintf("exec: invalid option: -%c\n",args[index][at]);return 2
                }
            }
            index+=1
        }
        if index==len(args) {return 0}
        if shell.compat.restricted {fmt.eprintln("exec: restricted");return 1}
        if login {if !replace_arg0 {arg0=args[index]};arg0=strings.concatenate([]string{"-",arg0});replace_arg0=true}
        // Successful exec inherits normal application signals. A failed exec
        // must recover every shell disposition, including graceful cleanup.
        signals:=[9]posix.Signal{.SIGINT,.SIGQUIT,.SIGTSTP,.SIGTTIN,.SIGTTOU,.SIGCHLD,.SIGPIPE,.SIGHUP,.SIGTERM}
        saved:[9]posix.sigaction_t
        for signal,i in signals {_=posix.sigaction(signal,nil,&saved[i])}
        // execve resets caught handlers itself. Keep cleanup handlers active
        // until it succeeds, including when a signal arrives during PATH
        // lookup or a failed exec. Only ignored dispositions need resetting.
        for signal,i in signals {
            if saved[i].sa_handler==auto_cast posix.SIG_IGN {posix.signal(signal,auto_cast posix.SIG_DFL)}
        }
        status:=native_shell_exec_external(shell,args[index:],nil,"",arg0,replace_arg0,empty_environment,false)
        for signal,i in signals {_=posix.sigaction(signal,&saved[i],nil)}
        if !shell.interactive&&!shell.compat.shopts["execfail"] {shell.exiting=true;shell.exit_status=status}
        return status
    case "source",".":
        index:=1;search_path:="";explicit_path:=false
        for index<len(args)&&len(args[index])>1&&args[index][0]=='-' {
            option:=args[index]
            if option=="--" {index+=1;break}
            if !strings.has_prefix(option,"-p") {fmt.eprintf("%s: %s: invalid option\n",args[0],option);return 2}
            explicit_path=true;search_path=option[2:]
            if search_path=="" {index+=1;if index>=len(args) {fmt.eprintf("%s: -p: option requires an argument\n",args[0]);return 2};search_path=args[index]}
            index+=1
        }
        if index>=len(args) {fmt.eprintf("%s: filename argument required\n",args[0]);return 2}
        path:=args[index];index+=1
        if shell.compat.restricted&&strings.contains(path,"/") {fmt.eprintf("%s: %s: restricted\n",args[0],path);return 1}
        if shell.source_depth>=128 {fmt.eprintln("source: nesting limit reached");return 2}
        if !strings.contains(path,"/")&&(explicit_path||shell.compat.shopts["sourcepath"]) {
            if !explicit_path {var_exists:bool;search_path,var_exists=shell.variables["PATH"];if !var_exists {search_path="/usr/local/bin:/usr/bin:/bin"}}
            found:=false
            for component in strings.split_iterator(&search_path,":") {
                directory:=component;if directory=="" {directory="."}
                candidate:=strings.concatenate([]string{directory,"/",path})
                info,error:=os.stat(candidate,context.allocator)
                if error==nil&&info.type==.Regular&&posix.access(strings.clone_to_cstring(candidate),{.R_OK})==.OK {path=candidate;found=true;break}
            }
            if !found&&(explicit_path||shell.compat.options["posix"]) {fmt.eprintf("%s: %s: file not found\n",args[0],path);if shell.compat.options["posix"]&&!shell.interactive {shell.exiting=true;shell.exit_status=1};return 1}
        }
        if shell.compat.options["posix"]&&!shell.interactive&&posix.access(strings.clone_to_cstring(path),{.R_OK})!=.OK {fmt.eprintf("%s: %s: cannot read file\n",args[0],path);shell.exiting=true;shell.exit_status=1;return 1}
        previous:=shell.compat.parameters;generation:=shell.compat.parameter_generation
        supplied:=index<len(args)
        if supplied {shell.compat.parameters=args[index:]}
        shell.source_depth+=1
        defer {shell.source_depth-=1;if supplied&&generation==shell.compat.parameter_generation {shell.compat.parameters=previous}}
        status:=native_shell_run_file(shell,path)
        if shell.compat.returning {status=shell.compat.return_status;shell.compat.returning=false}
        shell.status=status;native_shell_run_trap(shell,-2)
        return status
    case "eval":return native_shell_run_source(shell,strings.join(args[1:]," "))
    case "command":return native_shell_command_builtin(shell,args)
    case "type":return native_shell_type_builtin(shell,args)
    case "help":return native_shell_help_builtin(shell,args)
    }
    return 127
}

native_shell_parent_builtin :: proc(shell:^Native_Shell,command:Native_Shell_Prepared)->int {
    previous_line:=shell.compat.current_line
    if command.line>0 {shell.compat.current_line=command.line}
    defer {shell.compat.current_line=previous_line}
    if !native_shell_protect_tty(shell,command.redirects[:]) {return 1}
    saved,ok:=native_shell_save_fds(command.redirects[:])
    if !ok {fmt.eprintln("terminal+: cannot save redirected descriptors");native_shell_special_failure(shell,command,1);return 1}
    restore:=true
    defer {if restore {native_shell_restore_fds(saved)}}
    if !native_shell_apply_redirects(shell,command.redirects[:]) {native_shell_special_failure(shell,command,1);return 1}
    if len(command.args)==0&&command.compound==nil {if !native_shell_apply_assignments(shell,command.assignments[:],false) {return 1};return command.substitution_status}
    variables:=native_shell_saved_variables(shell,command.assignments[:])
    keep_assignments:=len(command.args)>0&&!shell.compat.disabled[command.args[0]]&&shell.compat.options["posix"]&&native_shell_special_builtin(command.args[0])
    defer {
        if keep_assignments {for item in variables {native_shell_array_destroy(shell,item.array)}} else {
            for item in variables {
                keep_attribute:=false
                if len(command.args)>0&&(command.args[0]=="export"||command.args[0]=="readonly") {
                    for argument in command.args[1:] {
                        name:=argument;if equals:=strings.index_byte(name,'=');equals>=0 {name=name[:equals]};name=strings.trim_suffix(name,"+")
                        if name==item.name {keep_attribute=true;break}
                    }
                }
                if keep_attribute {native_shell_array_destroy(shell,item.array)} else {native_shell_restore_variables(shell,[]Native_Shell_Variable_Save{item})}
            }
        }
    }
    temporary_path:=false
    for item in variables {if item.name=="PATH"&&!keep_assignments {temporary_path=true}}
    previous_hash,previous_hits:=shell.compat.command_hash,shell.compat.command_hash_hits
    if temporary_path {shell.compat.command_hash=make(map[string]string,shell.allocator);shell.compat.command_hash_hits=make(map[string]int,shell.allocator)}
    defer {
        if temporary_path {
            native_shell_hash_clear(shell);delete(shell.compat.command_hash);delete(shell.compat.command_hash_hits)
            shell.compat.command_hash=previous_hash;shell.compat.command_hash_hits=previous_hits
        }
    }
    if !native_shell_apply_assignments(shell,command.assignments[:],true) {native_shell_special_failure(shell,command,1);return 1}
    result:int
    if command.compound!=nil {result=native_shell_compound_execute(shell,command.compound)} else {result=native_shell_invoke(shell,command.args[:],command.bypass_functions)}
    if keep_assignments&&result!=0&&!shell.interactive&&shell.compat.options["posix"] {
        switch command.args[0] {case "export","readonly","set","unset":shell.exiting=true;shell.exit_status=result}
    }
    // `exec >file` permanently changes the shell's descriptors.
    if len(command.args)>0&&command.args[0]=="exec"&&result==0 {
        restore=false;for item in saved {if item.saved>=0 {posix.close(item.saved)}}
    }
    return result
}

native_shell_pipeline :: proc(shell:^Native_Shell,pipeline:Native_Shell_Pipeline,source:string)->int {
    substitution_start:=len(native_shell_substitutions)
    defer native_shell_substitutions_close(substitution_start)
    prepared:=make([]Native_Shell_Prepared,len(pipeline.commands))
    pipeline_line:=shell.compat.current_line
    defer {shell.compat.current_line=pipeline_line}
    first_line:=1;if len(pipeline.commands)>0 {first_line=pipeline.commands[0].line}
    for command,i in pipeline.commands {
        shell.compat.current_line=pipeline_line+command.line-first_line
        // Expansions belong to the process executing this stage. Expanding
        // here would leak arithmetic/assignment side effects out of pipelines
        // and background jobs, and serialize independent substitutions.
        parent_stage:=!pipeline.background&&len(pipeline.commands)==1
        if !parent_stage {raw:=new(Native_Shell_Command);raw^=command;prepared[i]=Native_Shell_Prepared{compound=command.compound,deferred=raw,line=shell.compat.current_line};continue}
        value,error:=native_shell_prepare(shell,command)
        if error!="" {
            if error=="command substitution interrupted" {return 130}
            native_shell_preparation_failed=true
            native_shell_diagnostic(shell,error)
            failure:=1
            if strings.contains(error,"unbound variable") {failure=127}
            fatal:=false
            if value.failure_kind=="assignment" {
                command_name:=""
                for word in command.words {if _,_,_,assignment:=native_shell_assignment_parts(word.raw);!assignment {command_name=word.raw;break}}
                fatal=command_name==""||shell.compat.options["posix"]&&native_shell_special_builtin(command_name)
                if shell.compat.options["posix"]&&command_name!=""&&fatal {failure=127}
            } else if value.failure_kind=="expansion" {
                arithmetic:=strings.has_prefix(error,"arithmetic:")
                glob_error:=strings.has_prefix(error,"no match:")||strings.contains(error,"filename pattern")
                parameter:=!arithmetic&&!glob_error
                fatal=(parameter||shell.compat.options["posix"])&&native_shell_compat_level(shell)>43
                if parameter&&!strings.has_prefix(error,"bad substitution")&&!strings.has_prefix(error,"invalid indirect")&&!strings.has_prefix(error,"unsupported parameter") {fatal=true}
                if arithmetic&&shell.compat.options["posix"] {fatal=true}
                if parameter||shell.compat.options["posix"] {failure=127}
            }
            if !shell.interactive&&fatal {shell.exiting=true;shell.exit_status=failure}
            return failure
        }
        prepared[i]=value
    }
    shell.compat.current_line=pipeline_line
    return native_shell_pipeline_prepared(shell,pipeline,prepared,source)
}

native_shell_lastpipe_command :: proc(shell:^Native_Shell,command:Native_Shell_Prepared,input:posix.FD)->int {
    mentioned:=make(map[int]bool)
    for redirect in command.redirects {
        mentioned[redirect.fd]=true
        if redirect.operator==">&"||redirect.operator=="<&" {
            value:=redirect.target;if strings.has_suffix(value,"-") {value=value[:len(value)-1]}
            if number,ok:=strconv.parse_int(value);ok {mentioned[number]=true}
        }
    }
    backup:posix.FD= -1;minimum:=3
    for {
        candidate:=posix.fcntl(0,.DUPFD_CLOEXEC,c.int(minimum))
        if candidate<0 {
            if posix.errno()!=.EBADF {posix.close(input);fmt.eprintln("terminal+: cannot preserve pipeline stdin");return 1}
            break
        }
        if !mentioned[int(candidate)] {backup=posix.FD(candidate);break}
        posix.close(posix.FD(candidate));minimum=int(candidate)+1
    }
    defer {
        if backup>=0 {posix.dup2(backup,0);posix.close(backup)} else {posix.close(0)}
    }
    if input!=0 {
        duplicated:=posix.dup2(input,0);posix.close(input)
        if duplicated<0 {fmt.eprintln("terminal+: cannot redirect pipeline stdin");return 1}
    }
    if command.deferred!=nil {
        // lastpipe expands its final command only after the other stages
        // have forked. External final commands still execute in a child.
        append(&shell.script_fds,&backup);defer pop(&shell.script_fds)
        previous_line:=shell.compat.current_line;shell.compat.current_line=command.line;defer {shell.compat.current_line=previous_line}
        commands:=make([dynamic]Native_Shell_Command);append(&commands,command.deferred^)
        return native_shell_pipeline(shell,Native_Shell_Pipeline{commands=commands},"")
    }
    return native_shell_parent_builtin(shell,command)
}

native_shell_trace_prepared :: proc(shell:^Native_Shell,command:Native_Shell_Prepared) {
    if !shell.compat.options["xtrace"] {return}
    prefix,_:=native_shell_value_get(shell,"PS4");if prefix=="" {prefix="+ "}
    if expanded,error:=native_shell_expand_assignment(shell,prefix);error=="" {prefix=expanded}
    descriptor:=posix.FD(2)
    if value,exists:=native_shell_value_get(shell,"BASH_XTRACEFD");exists {number,valid:=strconv.parse_int(value);if valid&&number>=0 {descriptor=posix.FD(number)}}
    output:=make([dynamic]u8);append(&output,prefix)
    for assignment in command.assignments {append(&output,fmt.aprintf("%s=%s ",assignment.name,explorer_quote(assignment.value)))}
    if command.compound!=nil {append(&output,command.compound.source)} else {for argument,i in command.args {if i>0 {append(&output,' ')};append(&output,explorer_quote(argument))}}
    append(&output,'\n');remaining:=output[:]
    for len(remaining)>0 {count:=posix.write(descriptor,raw_data(remaining),len(remaining));if count<0&&posix.errno()==.EINTR {continue};if count<=0 {break};remaining=remaining[int(count):]}
}

native_shell_pipeline_prepared :: proc(shell:^Native_Shell,pipeline:Native_Shell_Pipeline,prepared:[]Native_Shell_Prepared,source:string)->(result:int) {
    statuses:[]int
    defer {
        if statuses==nil {statuses=[]int{result}}
        _=native_shell_value_unset(shell,"PIPESTATUS")
        for status,i in statuses {_=native_shell_value_set(shell,fmt.aprintf("PIPESTATUS[%d]",i),fmt.aprintf("%d",status))}
    }
    for command in prepared {if command.deferred==nil {native_shell_trace_prepared(shell,command)}}
    if len(prepared)==0 {return 0}
    for command in prepared {if command.deferred==nil {native_shell_hash_command(shell,command)}}
    update_last_argument:=len(prepared)==1&&!pipeline.background&&prepared[0].compound==nil
    last_argument:=""
    if update_last_argument&&len(prepared[0].args)>0 {last_argument=prepared[0].args[len(prepared[0].args)-1]}
    defer {if update_last_argument {native_shell_set_variable(shell,"_",last_argument)}}
    all_redirects:=make([dynamic]Native_Shell_Prepared_Redirect)
    for command in prepared {append(&all_redirects,..command.redirects[:])}
    if !native_shell_protect_tty(shell,all_redirects[:]) {return 1}
    if len(prepared)==1&&!pipeline.background {
        command:=prepared[0]
        internal:=command.compound!=nil&&command.compound.kind!="subshell"
        if command.compound==nil&&(len(command.args)==0||native_shell_builtin_name(command.args[0])&&!shell.compat.disabled[command.args[0]]||!command.bypass_functions&&len(command.args)>0&&native_shell_has_function(shell,command.args[0])) {internal=true}
        if internal {return native_shell_parent_builtin(shell,command)}
        if command.compound==nil&&shell.interactive&&len(command.args)==1&&len(command.redirects)==0&&len(command.assignments)==0&&native_shell_open_path(command.args[0]) {return 0}
    }
    lastpipe:=len(prepared)>1&&!pipeline.background&&shell.compat.shopts["lastpipe"]&&!shell.compat.options["monitor"]
    child_count:=len(prepared);if lastpipe {child_count-=1}
    // The gate prevents children from reading the tty before the complete
    // pipeline has acquired its foreground process group.
    gate:[2]posix.FD
    if !native_shell_pipe(&gate) {fmt.eprintln("terminal+: cannot create process gate");return 1}
    pipes:=make([][2]posix.FD,max(0,len(prepared)-1))
    opened:=0
    defer {
        posix.close(gate[0]);if gate[1]>=0 {posix.close(gate[1])}
        for pair in pipes[:opened] {posix.close(pair[0]);posix.close(pair[1])}
    }
    for &pair in pipes {
        if !native_shell_pipe(&pair) {fmt.eprintln("terminal+: cannot create pipeline");return 1}
        opened+=1
    }
    pids:=make([dynamic]posix.pid_t)
    group:posix.pid_t
    if !pipeline.background {group=native_shell_nested_group}
    for stage,i in prepared[:child_count] {
        command:=stage
        pid:=posix.fork()
        if pid<0 {
            fmt.eprintln("terminal+: cannot fork command")
            if group>0&&group!=native_shell_nested_group {_=posix.kill(-group,.SIGKILL)} else {for child in pids {_=posix.kill(child,.SIGKILL)}}
            for child in pids {status:c.int;for posix.waitpid(child,&status,{})<0&&posix.errno()==.EINTR {}}
            return 1
        }
        if pid==0 {
            shell.compat.subshell_depth+=1
        native_shell_fork_loop_scope(shell)
            posix.close(gate[1]);_=posix.setpgid(0,group)
            native_shell_child_signals(shell)
            if pipeline.background&&!shell.compat.options["monitor"]&&i==0 {
                null:=posix.open("/dev/null",{})
                if null<0||posix.dup2(null,0)<0 {posix._exit(1)}
                if null!=0 {posix.close(null)}
            }
            if pipeline.background&&!shell.compat.options["monitor"] {posix.signal(.SIGINT,auto_cast posix.SIG_IGN);posix.signal(.SIGQUIT,auto_cast posix.SIG_IGN)}
            if i>0 {if posix.dup2(pipes[i-1][0],0)<0 {posix._exit(1)}}
            if i+1<len(prepared) {if posix.dup2(pipes[i][1],1)<0 {posix._exit(1)}}
            for pair in pipes {posix.close(pair[0]);posix.close(pair[1])}
            byte:u8
            for posix.read(gate[0],&byte,1)<0&&posix.errno()==.EINTR {}
            posix.close(gate[0])
            if shell.tty_fd>=0 {posix.close(shell.tty_fd);shell.tty_fd= -1}
            shell.interactive=false
            shell.jobs=make([dynamic]Native_Shell_Job,0,0,shell.allocator)
            native_shell_nested_group=posix.getpgrp()
            if command.line>0 {shell.compat.current_line=command.line}
            if command.deferred!=nil {
                value,prepare_error:=native_shell_prepare(shell,command.deferred^)
                if prepare_error!="" {native_shell_diagnostic(shell,prepare_error);failure:=1;if strings.contains(prepare_error,"unbound variable") {failure=127};posix._exit(c.int(failure))}
                command=value
                native_shell_hash_command(shell,command)
                native_shell_trace_prepared(shell,command)
            }
            if !native_shell_apply_redirects(shell,command.redirects[:]) {posix._exit(1)}
            if i<len(pipeline.pipe_stderr)&&pipeline.pipe_stderr[i] {if posix.dup2(1,2)<0 {posix._exit(1)}}
            if command.compound==nil&&len(command.args)==0 {if !native_shell_apply_assignments(shell,command.assignments[:],false) {posix._exit(1)};posix._exit(c.int(command.substitution_status))}
            internal:=command.compound!=nil
            if len(command.args)>0&&(native_shell_builtin_name(command.args[0])&&!shell.compat.disabled[command.args[0]]||!command.bypass_functions&&native_shell_has_function(shell,command.args[0])) {internal=true}
            if internal {
                native_shell_native_child_handlers(shell)
                if pipeline.background&&!shell.compat.options["monitor"] {posix.signal(.SIGINT,auto_cast posix.SIG_IGN);posix.signal(.SIGQUIT,auto_cast posix.SIG_IGN)}
                if !native_shell_apply_assignments(shell,command.assignments[:],true) {posix._exit(1)}
                status:int
                if command.compound!=nil {status=native_shell_compound_execute(shell,command.compound)} else {status=native_shell_invoke(shell,command.args[:],command.bypass_functions)}
                shell.status=status
                native_shell_run_trap(shell,0)
                native_shell_shutdown(shell)
                if shell.exiting {status=shell.exit_status}
                posix._exit(c.int(status))
            }
            posix._exit(c.int(native_shell_exec_external(shell,command.args[:],command.assignments[:],command.search_path)))
        }
        if group==0 {group=pid}
        _=posix.setpgid(pid,group)
        append(&pids,pid)
    }
    last_input:posix.FD= -1
    for &pair,i in pipes {
        if lastpipe&&i==len(pipes)-1 {last_input=pair[0]} else {posix.close(pair[0])}
        posix.close(pair[1]);pair={-1,-1}
    }
    opened=0
    for command in prepared {for redirect in command.redirects {if redirect.allocated&&!redirect.persistent {posix.close(posix.FD(redirect.fd))}}}
    job_source:=source;if pipeline.source!="" {job_source=pipeline.source}
    index:=native_shell_job_add(shell,group,pids[:],job_source)
    if !pipeline.background&&shell.tty_fd>=0 {_=posix.tcsetpgrp(shell.tty_fd,group)}
    posix.close(gate[1]);gate[1]= -1
    if pipeline.background {shell.last_background=pids[len(pids)-1];if shell.interactive {fmt.eprintf("[%d] %d\n",shell.jobs[index].id,group)};return 0}
    parent_status:=0
    if lastpipe {parent_status=native_shell_lastpipe_command(shell,prepared[len(prepared)-1],last_input)}
    // A function or compound last stage can add jobs and grow the vector.
    // Acquire its address only after parent execution has completed.
    job:=&shell.jobs[index]
    status:=0
    if !shell.exiting {status=native_shell_wait_job(shell,job,true)}
    if lastpipe {
        statuses=make([]int,len(job.statuses)+1);copy(statuses,job.statuses)
        statuses[len(statuses)-1]=parent_status;status=parent_status
    } else {statuses=make([]int,len(job.statuses));copy(statuses,job.statuses)}
    if shell.compat.options["pipefail"] {for value in statuses {if value!=0 {status=value}}}
    if native_shell_job_done(job) {native_shell_job_free(shell,job);ordered_remove(&shell.jobs,index)}
    else if shell.interactive&&!shell.compat.options["posix"] {fmt.eprintf("[%d] Stopped\t%s\n",job.id,job.command);job.notified=true}
    return status
}

native_shell_wait_interruption :: proc(shell:^Native_Shell)->int {
    _=shell
    if signal:=atomic.atomic_load(&native_shell_wait_signal);signal>0 {return int(signal)}
    for signal:=1;signal<len(native_shell_pending_signals);signal+=1 {if atomic.atomic_load(&native_shell_pending_signals[signal])!=0 {return signal}}
    return 0
}

native_shell_wait_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    index:=1;next,force:=false,false;variable:=""
    for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
        if args[index]=="--" {index+=1;break}
        for at:=1;at<len(args[index]);at+=1 {
            switch args[index][at] {
            case 'n':next=true
            case 'f':force=true
            case 'p':
                variable=args[index][at+1:]
                if variable=="" {index+=1;if index>=len(args) {fmt.eprintln("wait: -p requires a variable name");return 2};variable=args[index]}
                if !native_shell_name(variable) {fmt.eprintln("wait: invalid variable name");return 2};at=len(args[index])
            case:fmt.eprintf("wait: invalid option: -%c\n",args[index][at]);return 2
            }
        }
        index+=1
    }
    if variable!="" {if error:=native_shell_value_unset(shell,variable);error!="" {fmt.eprintf("wait: %s\n",error);return 1}}
    atomic.atomic_store(&native_shell_wait_signal,0)
    old:posix.sigaction_t;installed:=false
    ignore,explicit:=shell.compat.traps[int(posix.Signal.SIGINT)]
    if !explicit||ignore!="" {
        action:posix.sigaction_t;action.sa_handler=native_shell_wait_interrupt;posix.sigemptyset(&action.sa_mask)
        installed=posix.sigaction(.SIGINT,&action,&old)==nil
    }
    defer {if installed {_=posix.sigaction(.SIGINT,&old,nil)};atomic.atomic_store(&native_shell_wait_signal,0)}
    if next {
        selected:=make([]bool,len(shell.jobs));any:=false
        if index==len(args) {for &job,i in shell.jobs {selected[i]=!job.hidden&&!job.disowned&&!job.waited;any=any||selected[i]}} else {
            for argument in args[index:] {job:=native_shell_job_index(shell,argument);if job>=0&&!shell.jobs[job].waited {selected[job]=true;any=true} else {fmt.eprintf("wait: %s: no unwaited child\n",argument)}}
        }
        if !any {return 127}
        for {
            for &job,i in shell.jobs {
                if i<len(selected)&&selected[i]&&native_shell_job_done(&job) {
                    job.waited=true
                    if shell.compat.options["posix"] {job.hidden=true;job.id=0}
                    if variable!="" {_=native_shell_value_set(shell,variable,fmt.aprintf("%d",job.pids[len(job.pids)-1]))}
                    return job.status
                }
            }
            if native_shell_cancelled() {shell.exiting=true;shell.exit_status=128+int(atomic.atomic_load(&native_shell_termination_signal));return shell.exit_status}
            status:c.int;pid:=posix.waitpid(-1,&status,{.UNTRACED,.CONTINUED})
            if pid<0 {if posix.errno()==.EINTR {if signal:=native_shell_wait_interruption(shell);signal>0 {return 128+signal};continue};return 127}
            for &job in shell.jobs {native_shell_job_update(shell,&job,pid,status)}
        }
    }
    result:=0
    if index==len(args) {
        for &job in shell.jobs {
            if job.disowned {continue}
            result=native_shell_wait_job(shell,&job,false,force)
            if native_shell_wait_interruption(shell)>0||shell.exiting {return result}
            job.waited=native_shell_job_done(&job)
            if shell.compat.options["posix"]&&job.waited {job.hidden=true;job.id=0}
        }
        return 0
    }
    for argument in args[index:] {
        job:=native_shell_job_index(shell,argument)
        if job<0 {fmt.eprintf("wait: no such child: %s\n",argument);result=127;continue}
        result=native_shell_wait_job(shell,&shell.jobs[job],false,force)
        if variable!="" {_=native_shell_value_set(shell,variable,fmt.aprintf("%d",shell.jobs[job].pids[len(shell.jobs[job].pids)-1]))}
        if native_shell_wait_interruption(shell)>0||shell.exiting {return result}
        shell.jobs[job].waited=native_shell_job_done(&shell.jobs[job])
        if shell.compat.options["posix"]&&shell.jobs[job].waited {shell.jobs[job].hidden=true;shell.jobs[job].id=0}
    }
    return result
}

native_shell_alias_source :: proc(shell:^Native_Shell,source:string,active:map[string]bool,depth:int=0)->(string,string) {
    if (!shell.compat.shopts["expand_aliases"]&&!shell.compat.options["posix"])||len(shell.compat.aliases)==0 {return source,""}
    if depth>=64 {return "","alias expansion nesting limit reached"}
    active_values:=active
    tokens,error:=native_shell_tokens(source)
    if error!="" {return "",error}
    output:=make([dynamic]u8);position:=0;command_word:=true;next_word:=false;skip_for:=false
    for token,i in tokens {
        append(&output,source[position:token.start]);replacement:=token.raw
        redirect_operand:=i>0&&native_shell_redirect_operator(tokens[i-1].raw)
        io_number:=native_shell_digits(token.raw)&&i+1<len(tokens)&&token.end==tokens[i+1].start&&native_shell_redirect_operator(tokens[i+1].raw)
        eligible:=(command_word||next_word)&&!redirect_operand&&!io_number
        if shell.compat.options["posix"]&&command_word&&native_shell_command_keyword(token.raw) {eligible=false}
        next_word=false
        if eligible&&!token.operator&&!active[token.raw] {
            if alias,exists:=shell.compat.aliases[token.raw];exists {
                active_values[token.raw]=true
                expanded,expand_error:=native_shell_alias_source(shell,alias,active,depth+1)
                delete_key(&active_values,token.raw)
                if expand_error!="" {return "",expand_error}
                replacement=expanded
                next_word=len(alias)>0&&(alias[len(alias)-1]==' '||alias[len(alias)-1]=='\t')
            }
        }
        append(&output,replacement);position=token.end
        if token.operator {
            switch token.raw {case ";","\n","&&","||","|","|&","&","(","{":command_word=!skip_for;case ")","}":command_word=false}
            continue
        }
        if redirect_operand||io_number {continue}
        if skip_for {if token.raw=="do" {skip_for=false;command_word=true};continue}
        if command_word {
            switch token.raw {
            case "if","then","elif","else","while","until","do","!","time":command_word=true
            case "for","select","case":skip_for=true;command_word=false
            case "fi","done","esac":command_word=false
            case:
                if _,_,_,assignment:=native_shell_assignment_parts(token.raw);!assignment {command_word=false}
            }
        }
    }
    append(&output,source[position:])
    return string(output[:]),""
}

native_shell_execute :: proc(shell:^Native_Shell,source:string,syntax_error:^bool=nil)->int {
    if syntax_error!=nil {syntax_error^=false}
    entry_line:=shell.compat.current_line
    defer {shell.compat.current_line=entry_line}
    arena:vmem.Arena
    if vmem.arena_init_growing(&arena)!=nil {fmt.eprintln("terminal+: cannot allocate shell command memory");shell.status=1;return 1}
    defer vmem.arena_destroy(&arena)
    context.allocator=vmem.arena_allocator(&arena)
    context.temp_allocator=context.allocator
    expanded,alias_error:=native_shell_alias_source(shell,source,make(map[string]bool))
    if alias_error!="" {if syntax_error!=nil {syntax_error^=true};fmt.eprintf("terminal+: %s\n",alias_error);shell.status=2;return 2}
    program,error:=native_shell_parse(expanded)
    if error!="" {if syntax_error!=nil {syntax_error^=true};native_shell_diagnostic(shell,error);shell.status=2;if shell.compat.options["posix"]&&!shell.interactive {shell.exiting=true;shell.exit_status=2};return 2}
    if shell.compat.options["verbose"] {fmt.eprintln(source)}
    native_shell_reap(shell)
    for pipeline,index in program.pipelines {
        native_shell_dispatch_traps(shell)
        if native_shell_cancelled() {shell.exiting=true;shell.exit_status=128+int(atomic.atomic_load(&native_shell_termination_signal))}
        if shell.exiting||shell.compat.returning||shell.compat.break_depth>0||shell.compat.continue_depth>0 {break}
        if pipeline.connector=="&&"&&shell.status!=0 {continue}
        if pipeline.connector=="||"&&shell.status==0 {continue}
        if shell.compat.options["noexec"]&&!shell.interactive {continue}
        native_shell_command_sequence+=1
        if len(pipeline.commands)>0 {shell.compat.current_line=entry_line+pipeline.commands[0].line-1}
        conditional:=pipeline.negate
        if index+1<len(program.pipelines) {next:=program.pipelines[index+1].connector;if next=="&&"||next=="||" {conditional=true}}
        if conditional {shell.compat.errexit_ignored+=1}
        if !shell.compat.running_trap&&pipeline.source!="" {native_shell_set_variable(shell,"BASH_COMMAND",pipeline.source)}
        debug_status:=native_shell_run_trap(shell,-1)
        if shell.compat.shopts["extdebug"]&&debug_status!=0 {
            if conditional {shell.compat.errexit_ignored-=1}
            if debug_status==2&&(shell.compat.function_depth>0||shell.source_depth>0) {shell.compat.returning=true;shell.compat.return_status=shell.status;break}
            continue
        }
        native_shell_preparation_failed=false
        status:=native_shell_pipeline(shell,pipeline,expanded)
        if native_shell_preparation_failed {shell.status=status;if conditional {shell.compat.errexit_ignored-=1};break}
        if pipeline.negate {if status==0 {status=1} else {status=0}}
        shell.status=status
        if conditional {shell.compat.errexit_ignored-=1}
        native_shell_dispatch_traps(shell)
        if status!=0&&!conditional&&shell.compat.errexit_ignored==0 {
            native_shell_run_trap(shell,-3)
            if shell.compat.options["errexit"] {shell.exiting=true;shell.exit_status=status}
        }
    }
    if native_shell_cancelled() {shell.exiting=true;shell.exit_status=128+int(atomic.atomic_load(&native_shell_termination_signal))}
    return shell.status
}

native_shell_capture :: proc(shell:^Native_Shell,source:string)->(string,string) {
    native_shell_capture_sequence+=1
    output:[2]posix.FD
    if !native_shell_pipe(&output) {return "","cannot create command substitution pipe"}
    // Substitutions execute while the shell still owns the foreground tty.
    // Catch Ctrl+C here instead of allowing an ignored prompt signal to hang.
    atomic.atomic_store(&native_shell_capture_interrupted,0)
    previous:posix.sigaction_t
    action:posix.sigaction_t
    action.sa_handler=native_shell_capture_interrupt
    if trap,explicit:=shell.compat.traps[int(posix.Signal.SIGINT)];explicit&&trap=="" {action.sa_handler=auto_cast posix.SIG_IGN}
    posix.sigemptyset(&action.sa_mask)
    _=posix.sigaction(.SIGINT,&action,&previous)
    defer {_=posix.sigaction(.SIGINT,&previous,nil)}
    pid:=posix.fork()
    if pid<0 {posix.close(output[0]);posix.close(output[1]);return "","cannot fork command substitution"}
    if pid==0 {
        shell.compat.subshell_depth+=1
        native_shell_fork_loop_scope(shell)
        _=posix.setpgid(0,0);native_shell_nested_group=posix.getpid()
        posix.close(output[0]);if posix.dup2(output[1],1)<0 {posix._exit(1)};posix.close(output[1])
        for substitution in native_shell_substitutions {posix.close(substitution.fd)}
        native_shell_substitutions=nil
        native_shell_child_signals(shell)
        // Native child execution retains graceful termination so background
        // jobs started within the substitution are also cleaned up.
        native_shell_native_child_handlers(shell)
        shell.interactive=false;shell.exiting=false
        if !shell.compat.shopts["inherit_errexit"]&&!shell.compat.options["posix"] {shell.compat.options["errexit"]=false}
        if shell.tty_fd>=0 {posix.close(shell.tty_fd);shell.tty_fd= -1}
        shell.jobs=make([dynamic]Native_Shell_Job,0,0,shell.allocator)
        status:=native_shell_run_source(shell,source)
        shell.status=status
        native_shell_run_trap(shell,0)
        native_shell_shutdown(shell)
        if shell.exiting {status=shell.exit_status}
        posix._exit(c.int(status))
    }
    _=posix.setpgid(pid,pid)
    posix.close(output[1])
    bytes:=make([dynamic]u8)
    buffer:[16384]u8
    interrupted:=false
    for {
        if native_shell_cancelled()||atomic.atomic_load(&native_shell_capture_interrupted)!=0 {
            interrupted=true;_=posix.kill(-pid,.SIGHUP);break
        }
        // A signal may arrive after the cancellation check. Poll with a
        // bounded timeout so that race cannot leave the shell blocked in read.
        ready:=posix.pollfd{fd=output[0],events={.IN}}
        polled:=posix.poll(&ready,1,50)
        if polled==0 {continue}
        if polled<0 {if posix.errno()==.EINTR {continue};break}
        amount:=posix.read(output[0],raw_data(buffer[:]),len(buffer))
        if amount<0 {if posix.errno()==.EINTR {continue};break}
        if amount==0 {break}
        chunk:=buffer[:int(amount)]
        if strings.index_byte(string(chunk),0)<0 {append(&bytes,..chunk)} else {for byte in chunk {if byte!=0 {append(&bytes,byte)}}}
    }
    posix.close(output[0])
    status:c.int
    if !interrupted {
        for {
            if native_shell_cancelled()||atomic.atomic_load(&native_shell_capture_interrupted)!=0 {
                interrupted=true;_=posix.kill(-pid,.SIGHUP);break
            }
            result:=posix.waitpid(pid,&status,{.NOHANG})
            if result==pid||result<0&&posix.errno()==.ECHILD {break}
            if result<0&&posix.errno()==.EINTR {continue}
            if result<0 {break}
            // A bounded poll also covers a signal delivered between checking
            // the atomic flag and entering the wait syscall.
            _=posix.poll(nil,0,50)
        }
    }
    // The child can close stdout before it exits. Cancellation while waiting
    // after that EOF follows the same bounded shutdown as read interruption.
    if interrupted {
        deadline:=time.tick_now()
        for {
            result:=posix.waitpid(pid,&status,{.NOHANG})
            if result==pid||result<0&&posix.errno()==.ECHILD {break}
            if time.tick_diff(deadline,time.tick_now())>=250*time.Millisecond {
                _=posix.kill(-pid,.SIGKILL)
                for posix.waitpid(pid,&status,{})<0&&posix.errno()==.EINTR {}
                break
            }
            time.sleep(5*time.Millisecond)
        }
    }
    native_shell_capture_status=native_shell_wait_status(status)
    if !shell.compat.options["posix"] {shell.status=native_shell_capture_status}
    if interrupted {native_shell_capture_status=130;return "","command substitution interrupted"}
    end:=len(bytes)
    for end>0&&bytes[end-1]=='\n' {end-=1}
    resize(&bytes,end)
    return string(bytes[:]),""
}

native_shell_coproc :: proc(shell:^Native_Shell,compound:^Native_Shell_Compound)->int {
    input,output:[2]posix.FD
    if !native_shell_pipe(&input) {fmt.eprintln("coproc: cannot create input pipe");return 1}
    if !native_shell_pipe(&output) {posix.close(input[0]);posix.close(input[1]);fmt.eprintln("coproc: cannot create output pipe");return 1}
    pid:=posix.fork()
    if pid<0 {for fd in ([4]posix.FD{input[0],input[1],output[0],output[1]}) {posix.close(fd)};fmt.eprintln("coproc: cannot fork");return 1}
    if pid==0 {
        shell.compat.subshell_depth+=1
        native_shell_fork_loop_scope(shell)
        _=posix.setpgid(0,0);native_shell_nested_group=posix.getpid()
        posix.close(input[1]);posix.close(output[0])
        if posix.dup2(input[0],0)<0||posix.dup2(output[1],1)<0 {posix._exit(1)}
        if input[0]>1 {posix.close(input[0])};if output[1]>1 {posix.close(output[1])}
        for substitution in native_shell_substitutions {posix.close(substitution.fd)}
        native_shell_substitutions=nil
        native_shell_child_signals(shell);native_shell_native_child_handlers(shell)
        shell.interactive=false;shell.exiting=false
        if shell.tty_fd>=0 {posix.close(shell.tty_fd);shell.tty_fd= -1}
        shell.jobs=make([dynamic]Native_Shell_Job,0,0,shell.allocator)
        status:=native_shell_execute(shell,compound.source)
        shell.status=status
        native_shell_run_trap(shell,0)
        native_shell_shutdown(shell)
        if shell.exiting {status=shell.exit_status}
        posix._exit(c.int(status))
    }
    _=posix.setpgid(pid,pid)
    posix.close(input[0]);posix.close(output[1])
    read_fd:=posix.fcntl(output[0],.DUPFD_CLOEXEC,c.int(10));posix.close(output[0])
    write_fd:=posix.fcntl(input[1],.DUPFD_CLOEXEC,c.int(10));posix.close(input[1])
    if read_fd<0||write_fd<0 {
        if read_fd>=0 {posix.close(posix.FD(read_fd))};if write_fd>=0 {posix.close(posix.FD(write_fd))}
        _=posix.kill(-pid,.SIGKILL);status:c.int;for posix.waitpid(pid,&status,{})<0&&posix.errno()==.EINTR {}
        fmt.eprintln("coproc: cannot preserve descriptors");return 1
    }
    name:=compound.name;if name=="" {name="COPROC"}
    index:=native_shell_job_add(shell,pid,[]posix.pid_t{pid},compound.source)
    shell.jobs[index].coproc_name=strings.clone(name,shell.allocator)
    shell.jobs[index].coproc_fds={posix.FD(read_fd),posix.FD(write_fd)}
    _=native_shell_value_unset(shell,name)
    _=native_shell_value_set(shell,fmt.aprintf("%s[0]",name),fmt.aprintf("%d",read_fd))
    _=native_shell_value_set(shell,fmt.aprintf("%s[1]",name),fmt.aprintf("%d",write_fd))
    _=native_shell_value_set(shell,strings.concatenate([]string{name,"_PID"}),fmt.aprintf("%d",pid))
    shell.last_background=pid
    if shell.interactive {fmt.eprintf("[%d] %d\n",shell.jobs[index].id,pid)}
    return 0
}

native_shell_coproc_close :: proc(shell:^Native_Shell,job:^Native_Shell_Job) {
    if job.coproc_name=="" {return}
    for &fd in job.coproc_fds {if fd>=0 {posix.close(fd);fd= -1}}
    variable:=strings.concatenate([]string{job.coproc_name,"_PID"})
    pid,_:=native_shell_value_get(shell,variable)
    if pid==fmt.aprintf("%d",job.pgid) {_=native_shell_value_unset(shell,job.coproc_name);_=native_shell_value_unset(shell,variable)}
}

native_shell_signal_job :: proc(job:^Native_Shell_Job,signal:posix.Signal) {
    if job.own_group {_=posix.kill(-job.pgid,signal)}
    else {for pid,i in job.pids {if !job.done[i] {_=posix.kill(pid,signal)}}}
}

native_shell_shutdown :: proc(shell:^Native_Shell) {
    native_shell_substitutions_close(0)
    delete(native_shell_substitutions);native_shell_substitutions=nil
    native_shell_reap(shell)
    terminating:=native_shell_cancelled()
    hangup_all:=terminating||shell.interactive&&shell.compat.shopts["login_shell"]&&shell.compat.shopts["huponexit"]
    targets:=make([]bool,len(shell.jobs));defer delete(targets)
    for &job,i in shell.jobs {
        targets[i]=!job.disowned&&!job.no_hup&&!native_shell_job_done(&job)&&(hangup_all||shell.interactive&&native_shell_job_stopped(&job))
        if targets[i] {native_shell_signal_job(&job,.SIGHUP);native_shell_signal_job(&job,.SIGCONT)}
    }
    // Ordinary shell exit preserves running background jobs. A login shell
    // with huponexit sends HUP, while actual session termination retains a
    // bounded cleanup window for native wrappers and ignored-HUP children.
    if terminating {
        deadline:=time.tick_now()
        for {
            native_shell_reap(shell)
            running:=false
            for &job,i in shell.jobs {if targets[i]&&!native_shell_job_done(&job) {running=true;break}}
            if !running||time.tick_diff(deadline,time.tick_now())>=150*time.Millisecond {break}
            time.sleep(5*time.Millisecond)
        }
        for &job,i in shell.jobs {
            if !targets[i] {continue}
            if !native_shell_job_done(&job) {native_shell_signal_job(&job,.SIGKILL)}
            for pid,index in job.pids {
                if job.done[index] {continue}
                status:c.int
                for posix.waitpid(pid,&status,{})<0&&posix.errno()==.EINTR {}
            }
        }
    }
    for &job in shell.jobs {native_shell_job_free(shell,&job)}
    delete(shell.jobs);shell.jobs=nil
}

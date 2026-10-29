#+build linux
package main

import "core:fmt"
import "core:crypto"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import posix "core:sys/posix"

NATIVE_SHELL_READONLY :: u32(1)
NATIVE_SHELL_INTEGER :: u32(2)
NATIVE_SHELL_EXPORT :: u32(4)
NATIVE_SHELL_INDEXED :: u32(8)
NATIVE_SHELL_ASSOCIATIVE :: u32(16)
NATIVE_SHELL_UPPER :: u32(32)
NATIVE_SHELL_LOWER :: u32(64)
NATIVE_SHELL_NAMEREF :: u32(128)
NATIVE_SHELL_TRACE :: u32(256)

Native_Shell_Array :: struct {
    indexed:map[int]string,
    associative:map[string]string,
    associative_mode,initialized:bool,
    order:[dynamic]string,
    buckets:int,
}
Native_Shell_Local :: struct {
    value:string,
    exists,exported,declared,removed:bool,
    attributes:u32,
    array:^Native_Shell_Array,
}
Native_Shell_Frame :: struct {locals:map[string]Native_Shell_Local, options:map[string]bool, save_options:bool, posix_shopts:[3]bool, editing_mode:string}
Native_Shell_Global_Scope :: struct {frame:int, name:string, local:Native_Shell_Local, active:bool}
Native_Shell_Function_Frame :: struct {
    parameters:[]string,
    parameter_generation:int,
    returning:bool,
    return_status:int,
    current_source:string,
    current_line:int,
}
Native_Shell_Compat :: struct {
    parameters:[]string,
    parameter_generation:int,
    parameter_blocks:[dynamic][]string,
    arg0:string,
    arg0_owned:string,
    pid,ppid:posix.pid_t,
    subshell_depth:int,
    functions,aliases:map[string]string,
    function_sources:map[string]string,
    function_lines:map[string]int,
    current_source,top_source:string,
    current_line:int,
    script_mode,restricted,command_mode,stdin_mode:bool,
    dirstack_special,aliases_special,commands_special,argv0_special,groups_special:bool,
    compat_version:int,
    call_names,call_sources:[dynamic]string,
    call_lines:[dynamic]int,
    argument_frames:[dynamic][]string,
    argument_traced:[dynamic]bool,
    debug_parameters:[]string,
    debug_parameters_initialized:bool,
    options,shopts:map[string]bool,
    arrays:map[string]^Native_Shell_Array,
    attributes:map[string]u32,
    declared:map[string]bool,
    special_disabled:map[string]bool,
    command_hash:map[string]string,
    command_hash_hits:map[string]int,
    frames:[dynamic]Native_Shell_Frame,
    traps:map[int]string,
    trap_owners:map[int]posix.pid_t,
    trap_depths:map[int]int,
    directories:[dynamic]string,
    disabled:map[string]bool,
    bool_keys:[dynamic]string,
    loop_depth,break_depth,continue_depth,function_depth:int,
    returning,running_trap,read_interrupted:bool,
    return_status,errexit_ignored:int,
    getopts_index,getopts_last_index,arithmetic_depth:int,
    random:u64,
    last_random:u32,
    random_special,seconds_special,srandom_special:bool,
    seconds_offset:i64,
    seconds_reset:time.Tick,
    reference_depth:int,
    started:time.Tick,
    started_wall:posix.time_t,
}

native_shell_compat_init :: proc(shell:^Native_Shell) {
    original:=context.allocator;context.allocator=shell.allocator;defer {context.allocator=original}
    state:=new(Native_Shell_Compat);shell.compat=state
    state.arg0="terminal+";state.pid=posix.getpid();state.ppid=posix.getppid()
    state.dirstack_special=true;state.aliases_special=true;state.commands_special=true;state.argv0_special=true;state.groups_special=true;state.compat_version=53
    state.functions=make(map[string]string);state.aliases=make(map[string]string)
    state.function_sources=make(map[string]string);state.function_lines=make(map[string]int)
    state.call_names=make([dynamic]string);state.call_sources=make([dynamic]string);state.call_lines=make([dynamic]int)
    state.argument_frames=make([dynamic][]string);state.argument_traced=make([dynamic]bool)
    state.current_line=1
    state.options=make(map[string]bool);state.shopts=make(map[string]bool)
    for name in native_shell_option_names() {state.options[name]=false}
    for name in native_shell_shopt_names() {state.shopts[name]=false}
    state.arrays=make(map[string]^Native_Shell_Array);state.attributes=make(map[string]u32)
    state.declared=make(map[string]bool)
    state.special_disabled=make(map[string]bool)
    state.command_hash=make(map[string]string);state.command_hash_hits=make(map[string]int)
    state.traps=make(map[int]string);state.trap_owners=make(map[int]posix.pid_t);state.trap_depths=make(map[int]int);state.disabled=make(map[string]bool)
    state.bool_keys=make([dynamic]string)
    state.parameter_blocks=make([dynamic][]string)
    state.frames=make([dynamic]Native_Shell_Frame);state.directories=make([dynamic]string)
    state.options["braceexpand"]=true;state.options["hashall"]=true;state.options["interactive-comments"]=true
    state.shopts["expand_aliases"]=shell.interactive;state.shopts["promptvars"]=true;state.options["history"]=shell.interactive;state.options["emacs"]=shell.interactive
    for name in ([]string{"patsub_replacement","globskipdots","extquote","sourcepath","progcomp","checkwinsize","cmdhist","complete_fullquote","force_fignore","globasciiranges","hostcomplete","interactive_comments"}) {state.shopts[name]=true}
    state.random=(u64(posix.getpid())*2862933555777941757)%2147483647;state.started=time.tick_now();state.started_wall=posix.time(nil);state.seconds_reset=state.started;state.random_special=true;state.seconds_special=true;state.srandom_special=true
    version:=native_shell_array_ensure(shell,"BASH_VERSINFO")
    for value,index in ([]string{"5","3","20","1","release","x86_64-pc-linux-gnu"}) {version.indexed[index]=strings.clone(value,shell.allocator)}
    native_shell_attribute_set(shell,"BASH_VERSINFO",NATIVE_SHELL_INDEXED|NATIVE_SHELL_READONLY)
    native_shell_attribute_set(shell,"BASHOPTS",NATIVE_SHELL_READONLY);native_shell_attribute_set(shell,"SHELLOPTS",NATIVE_SHELL_READONLY)
    native_shell_attribute_set(shell,"RANDOM",NATIVE_SHELL_INTEGER);native_shell_attribute_set(shell,"SECONDS",NATIVE_SHELL_INTEGER);native_shell_attribute_set(shell,"SRANDOM",NATIVE_SHELL_INTEGER)
    for name in ([]string{"UID","EUID","PPID"}) {native_shell_attribute_set(shell,name,NATIVE_SHELL_INTEGER|NATIVE_SHELL_READONLY)}
    for name in ([]string{"BASHPID","BASH_SUBSHELL","LINENO"}) {native_shell_attribute_set(shell,name,NATIVE_SHELL_INTEGER)}
    for name in ([]string{"BASH_ALIASES","BASH_CMDS"}) {native_shell_array_ensure(shell,name,true).initialized=true;native_shell_attribute_set(shell,name,NATIVE_SHELL_ASSOCIATIVE)}
    for name in ([]string{"BASH_ARGV","BASH_ARGC","DIRSTACK","GROUPS"}) {native_shell_array_ensure(shell,name).initialized=true;native_shell_attribute_set(shell,name,NATIVE_SHELL_INDEXED)}
}

native_shell_owned_text_set :: proc(values:^map[string]string,name,value:string,allocator:mem.Allocator) {
    for key,old in values^ {if key==name {values^[key]=strings.clone(value,allocator);delete(old,allocator);return}}
    values^[strings.clone(name,allocator)]=strings.clone(value,allocator)
}
native_shell_owned_text_remove :: proc(values:^map[string]string,name:string,allocator:mem.Allocator) {
    for key,value in values^ {if key==name {delete_key(values,key);delete(key,allocator);delete(value,allocator);return}}
}
native_shell_attribute_set :: proc(shell:^Native_Shell,name:string,value:u32) {
    for key,_ in shell.compat.attributes {if key==name {shell.compat.attributes[key]=value;return}}
    shell.compat.attributes[strings.clone(name,shell.allocator)]=value
}
native_shell_array_destroy :: proc(shell:^Native_Shell,array:^Native_Shell_Array) {
    if array==nil {return}
    for _,value in array.indexed {delete(value,shell.allocator)}
    for key,value in array.associative {delete(key,shell.allocator);delete(value,shell.allocator)}
    for key in array.order {delete(key,shell.allocator)}
    delete(array.order);delete(array.indexed);delete(array.associative);free(array,shell.allocator)
}
native_shell_array_clone :: proc(shell:^Native_Shell,array:^Native_Shell_Array)->^Native_Shell_Array {
    if array==nil {return nil}
    copy:=new(Native_Shell_Array,shell.allocator);copy.associative_mode=array.associative_mode;copy.initialized=array.initialized;copy.buckets=array.buckets
    copy.order=make([dynamic]string,0,len(array.order),shell.allocator);for key in array.order {append(&copy.order,strings.clone(key,shell.allocator))}
    copy.indexed=make(map[int]string,shell.allocator);copy.associative=make(map[string]string,shell.allocator)
    for key,value in array.indexed {copy.indexed[key]=strings.clone(value,shell.allocator)}
    for key,value in array.associative {native_shell_owned_text_set(&copy.associative,key,value,shell.allocator)}
    return copy
}
native_shell_array_remove :: proc(shell:^Native_Shell,name:string) {
    for key,array in shell.compat.arrays {if key==name {delete_key(&shell.compat.arrays,key);delete(key,shell.allocator);native_shell_array_destroy(shell,array);return}}
}
native_shell_array_ensure :: proc(shell:^Native_Shell,name:string,associative:bool=false)->^Native_Shell_Array {
    if array,exists:=shell.compat.arrays[name];exists {return array}
    array:=new(Native_Shell_Array,shell.allocator);array.associative_mode=associative;array.buckets=1024;array.order=make([dynamic]string,0,0,shell.allocator)
    array.indexed=make(map[int]string,shell.allocator);array.associative=make(map[string]string,shell.allocator)
    shell.compat.arrays[strings.clone(name,shell.allocator)]=array
    if !associative {if scalar,exists:=shell.variables[name];exists {array.indexed[0]=strings.clone(scalar,shell.allocator);array.initialized=true}}
    return array
}
native_shell_reference :: proc(name:string)->(string,string,bool) {
    open:=strings.index_byte(name,'[')
    if open>0&&strings.has_suffix(name,"]") {return name[:open],name[open+1:len(name)-1],true}
    return name,"",false
}
native_shell_array_index :: proc(shell:^Native_Shell,array:^Native_Shell_Array,key:string)->(int,string) {
    value,error:=native_shell_arithmetic(shell,key)
    if error!="" {return 0,error}
    index:=int(value)
    if index<0 {maximum:=-1;for at,_ in array.indexed {maximum=max(maximum,at)};index=maximum+1+index}
    if index<0 {return 0,"bad array subscript"}
    return index,""
}
native_shell_value_get :: proc(shell:^Native_Shell,name:string)->(string,bool) {
    if shell.compat==nil {value,exists:=shell.variables[name];return value,exists}
    if shell.compat.reference_depth>=64 {return "",false}
    shell.compat.reference_depth+=1;defer {shell.compat.reference_depth-=1}
    base,key,indexed:=native_shell_reference(name)
    attributes:=shell.compat.attributes[base]
    if attributes&NATIVE_SHELL_NAMEREF!=0 {if target:=shell.variables[base];target!=""&&target!=base {resolved:=target;if indexed {resolved=strings.concatenate([]string{target,"[",key,"]"})};return native_shell_value_get(shell,resolved)}}
    if shell.compat.special_disabled[base] {value,present:=shell.variables[base];return value,present}
    if base=="BASH_ARGV0"&&shell.compat.argv0_special {return shell.compat.arg0,true}
    if base=="BASH_ALIASES"&&shell.compat.aliases_special {if !indexed {key="0"};value,present:=shell.compat.aliases[key];return value,present}
    if base=="BASH_CMDS"&&shell.compat.commands_special {if !indexed {key="0"};value,present:=shell.compat.command_hash[key];return value,present}
    if values,special:=native_shell_stack_values(shell,base);special {
        if !indexed {key="0"};number,index_error:=native_shell_arithmetic(shell,key);if index_error!="" {return "",false};at:=int(number);if at<0 {at+=len(values)};if at>=0&&at<len(values) {return values[at],true};return "",false
    }
    if array,exists:=shell.compat.arrays[base];exists {
        if !indexed {key="0"}
        if array.associative_mode {value,found:=array.associative[key];return value,found}
        index,error:=native_shell_array_index(shell,array,key);if error!="" {return "",false}
        value,found:=array.indexed[index];return value,found
    }
    if indexed&&key!="0" {return "",false}
    switch base {
    case "SHELLOPTS":return native_shell_option_string(shell.compat.options),true
    case "BASHOPTS":return native_shell_option_string(shell.compat.shopts),true
    case "BASH_VERSION":if version,exists:=shell.variables["BASH_VERSION"];exists {return version,true};return "5.3-compatible-odin",true
    case "LINENO":return fmt.tprintf("%d",shell.compat.current_line),true
    case "EPOCHSECONDS":return fmt.tprintf("%d",posix.time(nil)),true
    case "BASH_MONOSECONDS":
        stamp:posix.timespec
        if posix.clock_gettime(.MONOTONIC,&stamp)==.OK {return fmt.tprintf("%d",stamp.tv_sec),true}
        return fmt.tprintf("%d",posix.time(nil)),true
    case "EPOCHREALTIME":
        stamp:posix.timeval
        if posix.gettimeofday(&stamp,nil)==.OK {return fmt.tprintf("%d.%06d",stamp.tv_sec,stamp.tv_usec),true}
        return fmt.tprintf("%d.000000",posix.time(nil)),true
    case "SRANDOM":
        if shell.compat.srandom_special {bytes:[4]u8;crypto.rand_bytes(bytes[:]);number:=u32(bytes[0])|u32(bytes[1])<<8|u32(bytes[2])<<16|u32(bytes[3])<<24;return fmt.tprintf("%d",number),true}
    case "RANDOM":
        if shell.compat.random_special {
            // MINSTD recurrence, with Bash's 15-bit folding and suppression
            // of consecutive equal values. Seed normalization is uint32 then
            // modulo 2^31-1; a zero state uses the deterministic nonzero seed.
            for {
                if shell.compat.random==0 {shell.compat.random=123459876}
                shell.compat.random=(shell.compat.random*16807)%2147483647
                output:=u32(shell.compat.random~(shell.compat.random>>16))&32767
                if native_shell_compat_level(shell)<=50 {output=u32(shell.compat.random)&32767}
                if output==shell.compat.last_random {continue}
                shell.compat.last_random=output;return fmt.tprintf("%d",output),true
            }
        }
    case "SECONDS":
        if shell.compat.seconds_special {elapsed:=i64(time.duration_seconds(time.tick_diff(shell.compat.seconds_reset,time.tick_now())));return fmt.tprintf("%d",shell.compat.seconds_offset+elapsed),true}
    case "UID":return fmt.tprintf("%d",posix.getuid()),true
    case "EUID":return fmt.tprintf("%d",posix.geteuid()),true
    case "BASH_SUBSHELL":return fmt.tprintf("%d",shell.compat.subshell_depth),true
    case "BASHPID":return fmt.tprintf("%d",posix.getpid()),true
    case "PPID":return fmt.tprintf("%d",shell.compat.ppid),true
    }
    value,exists:=shell.variables[base];return value,exists
}
native_shell_value_set :: proc(shell:^Native_Shell,name,value:string,flags:u32=0)->string {
    if shell.compat==nil {native_shell_set_variable(shell,name,value,flags&NATIVE_SHELL_EXPORT!=0);return ""}
    if shell.compat.reference_depth>=64 {return "circular name reference"}
    shell.compat.reference_depth+=1;defer {shell.compat.reference_depth-=1}
    base,key,indexed:=native_shell_reference(name)
    if !native_shell_name(base) {return fmt.tprintf("%s: not a valid identifier",base)}
    flags_value:=flags&~u32(1<<31)
    attributes:=shell.compat.attributes[base]
    if attributes&NATIVE_SHELL_READONLY!=0 {return fmt.tprintf("%s: readonly variable",base)}
    if attributes&NATIVE_SHELL_NAMEREF!=0 {if target:=shell.variables[base];target!=""&&target!=base {resolved:=target;if indexed {resolved=strings.concatenate([]string{target,"[",key,"]"})};return native_shell_value_set(shell,resolved,value,flags)}}
    if base=="GLOBIGNORE"&&value!="" {native_shell_bool_set(shell,&shell.compat.shopts,"dotglob",true)}
    if base=="BASH_COMPAT" {native_shell_compat_set(shell,value)}
    if base=="GROUPS"&&shell.compat.groups_special {return ""}
    if base=="POSIXLY_CORRECT" {native_shell_option_set(shell,"posix",true)}
    if base=="BASH_ARGV0"&&shell.compat.argv0_special {copy:=strings.clone(value,shell.allocator);delete(shell.compat.arg0_owned,shell.allocator);shell.compat.arg0_owned=copy;shell.compat.arg0=copy}
    if base=="BASH_ALIASES"&&shell.compat.aliases_special {if !indexed {key="0"};if key=="" {return "bad array subscript"};native_shell_owned_text_set(&shell.compat.aliases,key,value,shell.allocator);return ""}
    if base=="BASH_CMDS"&&shell.compat.commands_special {if !indexed {key="0"};if key=="" {return "bad array subscript"};native_shell_hash_store(shell,key,value);return ""}
    if base=="DIRSTACK"&&shell.compat.dirstack_special {index:=0;if indexed {number,error:=native_shell_arithmetic(shell,key);if error!="" {return error};index=int(number)};return native_shell_directory_stack_set(shell,index,value)}
    updated:=value;special_numeric:=false
    if (base=="RANDOM"&&shell.compat.random_special)||(base=="SECONDS"&&shell.compat.seconds_special) {
        number,error:=native_shell_arithmetic(shell,value);if error!="" {return error}
        updated=fmt.tprintf("%d",number);special_numeric=true
        if base=="RANDOM" {shell.compat.random=u64(u32(number))%2147483647;shell.compat.last_random=0} else {shell.compat.seconds_offset=number;shell.compat.seconds_reset=time.tick_now()}
    }
    if !special_numeric&&(attributes&NATIVE_SHELL_INTEGER!=0||flags&NATIVE_SHELL_INTEGER!=0)&&flags&u32(1<<31)==0 {number,error:=native_shell_arithmetic(shell,value);if error!="" {return error};updated=fmt.tprintf("%d",number)}
    if (attributes|flags)&(NATIVE_SHELL_UPPER|NATIVE_SHELL_LOWER)!=0 {
        previous_locale:=native_shell_text_locale(shell)
        updated=native_shell_text_case(updated,(attributes|flags)&NATIVE_SHELL_UPPER!=0)
        native_shell_text_locale_restore(previous_locale)
    }
    array,has_array:=shell.compat.arrays[base]
    if indexed||has_array||flags&(NATIVE_SHELL_INDEXED|NATIVE_SHELL_ASSOCIATIVE)!=0 {
        if !has_array {array=native_shell_array_ensure(shell,base,flags&NATIVE_SHELL_ASSOCIATIVE!=0)}
        array.initialized=true
        if !indexed {key="0"}
        if key==""||!array.associative_mode&&(key=="@"||key=="*") {return "bad array subscript"}
        if array.associative_mode {if _,found:=array.associative[key];!found {native_shell_associative_insert(shell,array,key)};native_shell_owned_text_set(&array.associative,key,updated,shell.allocator)} else {
            index,error:=native_shell_array_index(shell,array,key);if error!="" {return error}
            if old,exists:=array.indexed[index];exists {delete(old,shell.allocator)}
            array.indexed[index]=strings.clone(updated,shell.allocator)
        }
    } else {
        native_shell_set_variable(shell,base,updated,flags&NATIVE_SHELL_EXPORT!=0||shell.compat.options["allexport"])
        if base=="HISTFILESIZE" {native_shell_history_file_limit(shell)}
        if base=="HISTSIZE"&&native_shell_editor.loaded {native_shell_history_limit()}
    }
    if flags_value!=0 {native_shell_attribute_set(shell,base,attributes|flags_value)}
    return ""
}
native_shell_value_unset :: proc(shell:^Native_Shell,name:string,nameref:bool=true)->string {
    if shell.compat.reference_depth>=64 {return "circular name reference"}
    shell.compat.reference_depth+=1;defer {shell.compat.reference_depth-=1}
    base,key,indexed:=native_shell_reference(name)
    if nameref&&shell.compat.attributes[base]&NATIVE_SHELL_NAMEREF!=0 {if target:=shell.variables[base];target!=""&&target!=base {resolved:=target;if indexed {resolved=strings.concatenate([]string{target,"[",key,"]"})};return native_shell_value_unset(shell,resolved)}}
    if shell.compat.attributes[base]&NATIVE_SHELL_READONLY!=0 {return fmt.tprintf("%s: readonly variable",base)}
    if base=="BASH_ALIASES"&&shell.compat.aliases_special {if indexed {return ""};shell.compat.aliases_special=false}
    if base=="BASH_CMDS"&&shell.compat.commands_special {if indexed {return ""};shell.compat.commands_special=false}
    if base=="GLOBIGNORE" {native_shell_bool_set(shell,&shell.compat.shopts,"dotglob",false)}
    if base=="BASH_COMPAT" {native_shell_compat_set(shell,"")}
    if base=="POSIXLY_CORRECT" {native_shell_option_set(shell,"posix",false)}
    if base=="BASH_ARGV0" {shell.compat.argv0_special=false}
    if base=="GROUPS" {shell.compat.groups_special=false}
    if base=="LINENO"||base=="BASHPID"||base=="EPOCHSECONDS"||base=="EPOCHREALTIME"||base=="BASH_MONOSECONDS" {native_shell_bool_set(shell,&shell.compat.special_disabled,base,true)}
    if indexed&&(key=="@"||key=="*")&&native_shell_compat_level(shell)<=51 {return native_shell_value_unset(shell,base,nameref)}
    if array,exists:=shell.compat.arrays[base];exists&&indexed {
        if array.associative_mode {native_shell_owned_text_remove(&array.associative,key,shell.allocator);for item,index in array.order {if item==key {delete(item,shell.allocator);ordered_remove(&array.order,index);break}}} else {
            if key=="@"||key=="*" {for at,value in array.indexed {delete(value,shell.allocator);delete_key(&array.indexed,at)}} else {
                index,error:=native_shell_array_index(shell,array,key);if error!="" {return error}
                if value,found:=array.indexed[index];found {delete_key(&array.indexed,index);delete(value,shell.allocator)}
            }
        }
        return ""
    }
    if base=="RANDOM" {shell.compat.random_special=false};if base=="SECONDS" {shell.compat.seconds_special=false};if base=="SRANDOM" {shell.compat.srandom_special=false}
    if base=="DIRSTACK" {shell.compat.dirstack_special=false}
    native_shell_unset_variable(shell,base);native_shell_array_remove(shell,base)
    native_shell_bool_set(shell,&shell.compat.declared,base,false)
    native_shell_attribute_set(shell,base,0)
    for index:=len(shell.compat.frames)-1;index>=0;index-=1 {
        frame:=&shell.compat.frames[index];item,local:=frame.locals[base]
        if !local||item.removed {continue}
        if index==len(shell.compat.frames)-1||shell.compat.shopts["localvar_unset"] {
            native_shell_bool_set(shell,&shell.compat.declared,base,true)
        } else {
            item.removed=true;frame.locals[base]=item
            native_shell_attribute_set(shell,base,item.attributes);native_shell_bool_set(shell,&shell.compat.declared,base,item.declared)
            if item.exists {native_shell_set_variable(shell,base,item.value,item.exported)}
            if item.array!=nil {shell.compat.arrays[strings.clone(base,shell.allocator)]=native_shell_array_clone(shell,item.array)}
        }
        break
    }
    return ""
}
native_shell_array_values :: proc(shell:^Native_Shell,name:string,keys:bool=false)->[]string {
    if name=="BASH_ALIASES"&&shell.compat.aliases_special||name=="BASH_CMDS"&&shell.compat.commands_special {
        values:=shell.compat.aliases;if name=="BASH_CMDS" {values=shell.compat.command_hash}
        order:=make([dynamic]string);for key,_ in values {native_shell_associative_place(&order,key,1024)}
        result:=make([]string,len(order));for key,index in order {result[index]=key;if !keys {result[index]=values[key]}};return result
    }
    if values,special:=native_shell_stack_values(shell,name);special {if keys {result:=make([]string,len(values));for _,index in values {result[index]=fmt.tprintf("%d",index)};return result};return values}
    if shell.compat.reference_depth>=64 {return nil}
    shell.compat.reference_depth+=1;defer {shell.compat.reference_depth-=1}
    if shell.compat.attributes[name]&NATIVE_SHELL_NAMEREF!=0 {if target:=shell.variables[name];target!=""&&target!=name {return native_shell_array_values(shell,target,keys)}}
    array,exists:=shell.compat.arrays[name]
    if !exists {if value,found:=native_shell_value_get(shell,name);found {result:=make([]string,1);result[0]=value;if keys {result[0]="0"};return result};return nil}
    result:=make([dynamic]string)
    if array.associative_mode {
        for key in array.order {if keys {append(&result,key)} else {append(&result,array.associative[key])}}
    } else {
        indices:=make([dynamic]int);for key,_ in array.indexed {append(&indices,key)};slice.sort(indices[:])
        for key in indices {if keys {append(&result,fmt.tprintf("%d",key))} else {append(&result,array.indexed[key])}}
    }
    return result[:]
}
native_shell_parameters :: proc(shell:^Native_Shell)->[]string {if shell.compat==nil {return nil};return shell.compat.parameters}
native_shell_parameter :: proc(shell:^Native_Shell,name:string)->(string,bool) {
    if shell.compat==nil {return "",false}
    switch name {
    case "0":return shell.compat.arg0,true
    case "#":return fmt.tprintf("%d",len(shell.compat.parameters)),true
    case "@","*":return strings.join(shell.compat.parameters," "),len(shell.compat.parameters)>0
    case "-":
        flags:=make([dynamic]u8)
        options:=[]string{"allexport","notify","errexit","noglob","hashall","interactive","keyword","monitor","noexec","privileged","restricted","onecmd","nounset","verbose","xtrace","braceexpand","noclobber","errtrace","histexpand","physical","functrace"}
        letters:="abefhikmnprtuvxBCEHPT"
        for option,index in options {
            enabled:=shell.compat.options[option]
            if option=="interactive" {enabled=shell.interactive};if option=="restricted" {enabled=shell.compat.restricted}
            if enabled {append(&flags,letters[index])}
        }
        if shell.compat.command_mode {append(&flags,'c')};if shell.compat.stdin_mode {append(&flags,'s')}
        return string(flags[:]),true
    }
    number,valid:=strconv.parse_int(name)
    if valid&&number>0&&number<=len(shell.compat.parameters) {return shell.compat.parameters[number-1],true}
    return "",false
}
native_shell_local_save :: proc(shell:^Native_Shell,name:string) {
    if len(shell.compat.frames)==0 {return}
    frame:=&shell.compat.frames[len(shell.compat.frames)-1]
    if item,saved:=frame.locals[name];saved {
        if !item.removed {return}
        delete(item.value,shell.allocator);native_shell_array_destroy(shell,item.array)
        for owned,_ in frame.locals {if owned==name {delete_key(&frame.locals,owned);delete(owned,shell.allocator);break}}
    }
    value,exists:=shell.variables[name]
    item:=Native_Shell_Local{value=strings.clone(value,shell.allocator),exists=exists,exported=shell.exported[name],declared=shell.compat.declared[name],attributes=shell.compat.attributes[name],array=native_shell_array_clone(shell,shell.compat.arrays[name])}
    frame.locals[strings.clone(name,shell.allocator)]=item
}

// The outermost saved binding is the global variable hidden by dynamically
// scoped locals. Temporarily expose it for declare -g, then save its updated
// binding and put the active local back without changing function visibility.
native_shell_global_enter :: proc(shell:^Native_Shell,name:string)->Native_Shell_Global_Scope {
    for frame,index in shell.compat.frames {
        item,found:=frame.locals[name];if !found||item.removed {continue}
        value,exists:=shell.variables[name]
        current:=Native_Shell_Local{value=strings.clone(value,shell.allocator),exists=exists,exported=shell.exported[name],declared=shell.compat.declared[name],attributes=shell.compat.attributes[name],array=native_shell_array_clone(shell,shell.compat.arrays[name])}
        native_shell_unset_variable(shell,name);native_shell_array_remove(shell,name)
        native_shell_attribute_set(shell,name,item.attributes);native_shell_bool_set(shell,&shell.compat.declared,name,item.declared)
        if item.exists {native_shell_set_variable(shell,name,item.value,item.exported)}
        if item.array!=nil {shell.compat.arrays[strings.clone(name,shell.allocator)]=native_shell_array_clone(shell,item.array)}
        return Native_Shell_Global_Scope{index,name,current,true}
    }
    return Native_Shell_Global_Scope{}
}
native_shell_global_leave :: proc(shell:^Native_Shell,scope:Native_Shell_Global_Scope) {
    if !scope.active {return}
    name:=scope.name;frame:=&shell.compat.frames[scope.frame]
    old:=frame.locals[name];delete(old.value,shell.allocator);native_shell_array_destroy(shell,old.array)
    value,exists:=shell.variables[name]
    frame.locals[name]=Native_Shell_Local{value=strings.clone(value,shell.allocator),exists=exists,exported=shell.exported[name],declared=shell.compat.declared[name],attributes=shell.compat.attributes[name],array=native_shell_array_clone(shell,shell.compat.arrays[name])}
    native_shell_unset_variable(shell,name);native_shell_array_remove(shell,name)
    item:=scope.local
    native_shell_attribute_set(shell,name,item.attributes);native_shell_bool_set(shell,&shell.compat.declared,name,item.declared)
    if item.exists {native_shell_set_variable(shell,name,item.value,item.exported)}
    if item.array!=nil {shell.compat.arrays[strings.clone(name,shell.allocator)]=item.array}
    delete(item.value,shell.allocator)
}
native_shell_function_enter :: proc(shell:^Native_Shell,args:[]string)->Native_Shell_Function_Frame {
    previous:=Native_Shell_Function_Frame{parameters=shell.compat.parameters,parameter_generation=shell.compat.parameter_generation,returning=shell.compat.returning,return_status=shell.compat.return_status,current_source=shell.compat.current_source,current_line=shell.compat.current_line}
    traced:=shell.compat.shopts["extdebug"]||native_shell_compat_level(shell)<=44
    if traced&&!shell.compat.debug_parameters_initialized&&len(shell.compat.argument_frames)==0 {native_shell_debug_parameters_init(shell)}
    append(&shell.compat.argument_frames,args[1:]);append(&shell.compat.argument_traced,traced)
    source:=shell.compat.function_sources[args[0]];if source=="" {source=shell.compat.current_source};if source=="" {source=shell.compat.arg0}
    append(&shell.compat.call_names,strings.clone(args[0],shell.allocator));append(&shell.compat.call_sources,strings.clone(source,shell.allocator));append(&shell.compat.call_lines,shell.compat.current_line)
    shell.compat.current_source=source;if line,exists:=shell.compat.function_lines[args[0]];exists {shell.compat.current_line=line}
    shell.compat.parameters=args[1:];shell.compat.returning=false;shell.compat.return_status=0;shell.compat.function_depth+=1
    frame:=Native_Shell_Frame{locals=make(map[string]Native_Shell_Local,shell.allocator)}
    append(&shell.compat.frames,frame)
    return previous
}
native_shell_function_leave :: proc(shell:^Native_Shell,previous:Native_Shell_Function_Frame) {
    native_shell_local_frame_leave(shell)
    shell.compat.parameters=previous.parameters;shell.compat.parameter_generation=previous.parameter_generation;shell.compat.returning=previous.returning;shell.compat.return_status=previous.return_status;shell.compat.function_depth-=1
    delete(pop(&shell.compat.call_names),shell.allocator);delete(pop(&shell.compat.call_sources),shell.allocator);pop(&shell.compat.call_lines)
    pop(&shell.compat.argument_frames);pop(&shell.compat.argument_traced)
    shell.compat.current_source=previous.current_source;shell.compat.current_line=previous.current_line
}
native_shell_local_frame_leave :: proc(shell:^Native_Shell) {
    frame:=shell.compat.frames[len(shell.compat.frames)-1]
    for name,item in frame.locals {
        if item.removed {delete(name,shell.allocator);delete(item.value,shell.allocator);native_shell_array_destroy(shell,item.array);continue}
        native_shell_unset_variable(shell,name);native_shell_array_remove(shell,name)
        native_shell_attribute_set(shell,name,item.attributes)
        native_shell_bool_set(shell,&shell.compat.declared,name,item.declared)
        if item.exists {native_shell_set_variable(shell,name,item.value,item.exported)}
        if item.array!=nil {shell.compat.arrays[strings.clone(name,shell.allocator)]=item.array}
        delete(name,shell.allocator);delete(item.value,shell.allocator)
    }
    if frame.save_options {
        for name,_ in shell.compat.options {if shell.compat.options[name]!=frame.options[name] {native_shell_option_set(shell,name,frame.options[name])}}
        for name,value in frame.options {native_shell_bool_set(shell,&shell.compat.options,name,value)}
        // Bash saves the POSIX-dependent shopt values along with set options.
        for name,index in ([]string{"inherit_errexit","shift_verbose","interactive_comments"}) {native_shell_bool_set(shell,&shell.compat.shopts,name,frame.posix_shopts[index])}
        native_shell_editing_mode=frame.editing_mode
        delete(frame.options)
    }
    delete(frame.locals);pop(&shell.compat.frames)
}

native_shell_function_traced :: proc(shell:^Native_Shell)->bool {
    if len(shell.compat.call_names)==0 {return false}
    name:=shell.compat.call_names[len(shell.compat.call_names)-1]
    key:=strings.concatenate([]string{"BASH_FUNC_",name,"%%"})
    return shell.compat.attributes[key]&NATIVE_SHELL_TRACE!=0
}
native_shell_compat_destroy :: proc(shell:^Native_Shell) {
    state:=shell.compat;if state==nil {return}
    delete(state.arg0_owned,shell.allocator)
    for name,_ in state.arrays {native_shell_array_destroy(shell,state.arrays[name]);delete(name,shell.allocator)}
    for name,_ in state.attributes {delete(name,shell.allocator)}
    for name,value in state.functions {delete(name,shell.allocator);delete(value,shell.allocator)}
    for name,value in state.command_hash {delete(name,shell.allocator);delete(value,shell.allocator)}
    delete(state.command_hash);delete(state.command_hash_hits);delete(state.declared);delete(state.special_disabled)
    for name,value in state.function_sources {delete(name,shell.allocator);delete(value,shell.allocator)}
    for name,_ in state.function_lines {delete(name,shell.allocator)}
    for value in state.call_names {delete(value,shell.allocator)}
    for value in state.call_sources {delete(value,shell.allocator)}
    delete(state.function_sources);delete(state.function_lines);delete(state.call_names);delete(state.call_sources);delete(state.call_lines)
    delete(state.argument_frames);delete(state.argument_traced)
    for value in state.debug_parameters {delete(value,shell.allocator)};delete(state.debug_parameters,shell.allocator)
    for name,value in state.aliases {delete(name,shell.allocator);delete(value,shell.allocator)}
    for _,value in state.traps {delete(value,shell.allocator)}
    for path in state.directories {delete(path,shell.allocator)}
    for block in state.parameter_blocks {for value in block {delete(value,shell.allocator)};delete(block,shell.allocator)}
    for name in state.bool_keys {delete(name,shell.allocator)}
    delete(state.bool_keys)
    delete(state.parameter_blocks)
    delete(state.arrays);delete(state.attributes);delete(state.functions);delete(state.aliases);delete(state.options);delete(state.shopts);delete(state.traps);delete(state.trap_owners);delete(state.trap_depths);delete(state.disabled);delete(state.frames);delete(state.directories)
    free(state,shell.allocator);shell.compat=nil
}

// Option names may originate in an execution arena; map keys must survive it.
native_shell_bool_set :: proc(shell:^Native_Shell,values:^map[string]bool,name:string,enabled:bool) {
    native_shell_bool_set_raw(shell,values,name,enabled)
    if values==&shell.compat.shopts {
        if name=="array_expand_once" {native_shell_bool_set_raw(shell,values,"assoc_expand_once",enabled)}
        if name=="assoc_expand_once" {native_shell_bool_set_raw(shell,values,"array_expand_once",enabled)}
    }
}
native_shell_bool_set_raw :: proc(shell:^Native_Shell,values:^map[string]bool,name:string,enabled:bool) {
    for key,_ in values^ {if key==name {values^[key]=enabled;return}}
    owned:=strings.clone(name,shell.allocator);values^[owned]=enabled;append(&shell.compat.bool_keys,owned)
}

// Associative traversal follows bucket chains. The interoperable hash is the
// published 32-bit FNV-1 algorithm; chain insertion and load growth are tracked
// explicitly so traversal does not depend on Odin's own map implementation.
native_shell_associative_hash :: proc(key:string)->u32 {
    hash:=u32(2166136261)
    for byte in transmute([]u8)key {hash=hash*16777619~u32(byte)}
    return hash
}
native_shell_associative_place :: proc(order:^[dynamic]string,key:string,buckets:int) {
    bucket:=native_shell_associative_hash(key)%u32(buckets)
    at:=len(order^)
    for item,index in order^ {if native_shell_associative_hash(item)%u32(buckets)>=bucket {at=index;break}}
    append(order,"")
    for index:=len(order^)-1;index>at;index-=1 {order^[index]=order^[index-1]}
    order^[at]=key
}
native_shell_associative_insert :: proc(shell:^Native_Shell,array:^Native_Shell_Array,key:string) {
    if len(array.order)>=array.buckets*2 {
        array.buckets*=4
        replacement:=make([dynamic]string,0,len(array.order),shell.allocator)
        for existing in array.order {native_shell_associative_place(&replacement,existing,array.buckets)}
        delete(array.order);array.order=replacement
    }
    native_shell_associative_place(&array.order,strings.clone(key,shell.allocator),array.buckets)
}
native_shell_array_clear :: proc(shell:^Native_Shell,array:^Native_Shell_Array) {
    array.initialized=true
    for at,value in array.indexed {delete_key(&array.indexed,at);delete(value,shell.allocator)}
    for key,value in array.associative {delete_key(&array.associative,key);delete(key,shell.allocator);delete(value,shell.allocator)}
    for key in array.order {delete(key,shell.allocator)};clear(&array.order)
}

native_shell_option_string :: proc(options:map[string]bool)->string {
    names:=make([dynamic]string);for name,enabled in options {if enabled {append(&names,name)}};slice.sort(names[:]);return strings.join(names[:],":")
}
native_shell_compat_level :: proc(shell:^Native_Shell)->int {if shell==nil||shell.compat==nil||shell.compat.compat_version==0 {return 53};return shell.compat.compat_version}
native_shell_option_set :: proc(shell:^Native_Shell,name:string,enabled:bool) {
    if name=="restricted" {
        if enabled {
            shell.compat.restricted=true
            for variable in ([]string{"SHELL","PATH","HISTFILE","ENV","BASH_ENV"}) {native_shell_attribute_set(shell,variable,shell.compat.attributes[variable]|NATIVE_SHELL_READONLY)}
        }
        return
    }
    native_shell_bool_set(shell,&shell.compat.options,name,enabled)
    if name=="posix" {
        if enabled {native_shell_set_variable(shell,"POSIXLY_CORRECT","y");native_shell_bool_set(shell,&shell.compat.shopts,"inherit_errexit",true);native_shell_bool_set(shell,&shell.compat.shopts,"interactive_comments",true)} else {native_shell_unset_variable(shell,"POSIXLY_CORRECT")}
        native_shell_bool_set(shell,&shell.compat.shopts,"shift_verbose",enabled)
    }
    if name=="emacs"&&enabled {native_shell_bool_set(shell,&shell.compat.options,"vi",false);native_shell_editing_mode="emacs"}
    if name=="vi"&&enabled {native_shell_bool_set(shell,&shell.compat.options,"emacs",false);native_shell_editing_mode="vi"}
}
native_shell_compat_set :: proc(shell:^Native_Shell,value:string) {
    version:=53
    if value!="" {
        normalized,_:=strings.replace_all(value,".","");number,ok:=strconv.parse_int(normalized)
        if !ok||number<31||number>53 {fmt.eprintf("BASH_COMPAT: %s: compatibility value out of range\n",value)} else {version=number}
    }
    shell.compat.compat_version=version
    for name in ([]string{"compat31","compat32","compat40","compat41","compat42","compat43","compat44"}) {number,_:=strconv.parse_int(name[6:]);native_shell_bool_set(shell,&shell.compat.shopts,name,number==version)}
}
native_shell_function_record :: proc(shell:^Native_Shell,name:string) {
    source:=shell.compat.current_source;if source=="" {source=shell.compat.arg0}
    native_shell_owned_text_set(&shell.compat.function_sources,name,source,shell.allocator)
    for key,_ in shell.compat.function_lines {if key==name {shell.compat.function_lines[key]=shell.compat.current_line;return}}
    shell.compat.function_lines[strings.clone(name,shell.allocator)]=shell.compat.current_line
}
native_shell_stack_values :: proc(shell:^Native_Shell,name:string)->([]string,bool) {
    if name=="GROUPS"&&shell.compat.groups_special {
        count:=posix.getgroups(0,nil);groups:=make([]posix.gid_t,max(0,int(count)))
        if count>0 {_=posix.getgroups(count,raw_data(groups))}
        values:=make([dynamic]string);primary:=posix.getgid();append(&values,fmt.tprintf("%d",primary))
        for group in groups {if group!=primary {append(&values,fmt.tprintf("%d",group))}}
        return values[:],true
    }
    if name=="DIRSTACK"&&shell.compat.dirstack_special {return native_shell_directory_stack_values(shell),true}
    if name=="BASH_ARGV"||name=="BASH_ARGC" {
        if !shell.compat.debug_parameters_initialized {if shell.compat.function_depth>0 {return nil,true};native_shell_debug_parameters_init(shell)}
        values:=make([dynamic]string)
        for at:=len(shell.compat.argument_frames)-1;at>=0;at-=1 {
            if !shell.compat.argument_traced[at] {continue}
            args:=shell.compat.argument_frames[at]
            if name=="BASH_ARGC" {append(&values,fmt.tprintf("%d",len(args)))} else {for index:=len(args)-1;index>=0;index-=1 {append(&values,args[index])}}
        }
        if name=="BASH_ARGC" {append(&values,fmt.tprintf("%d",len(shell.compat.debug_parameters)))} else {for index:=len(shell.compat.debug_parameters)-1;index>=0;index-=1 {append(&values,shell.compat.debug_parameters[index])}}
        return values[:],true
    }
    if name!="FUNCNAME"&&name!="BASH_SOURCE"&&name!="BASH_LINENO" {return nil,false}
    values:=make([dynamic]string)
    for at:=len(shell.compat.call_names)-1;at>=0;at-=1 {
        switch name {case "FUNCNAME":append(&values,shell.compat.call_names[at]);case "BASH_SOURCE":append(&values,shell.compat.call_sources[at]);case "BASH_LINENO":append(&values,fmt.tprintf("%d",shell.compat.call_lines[at]))}
    }
    if shell.compat.script_mode {
        switch name {case "FUNCNAME":if len(shell.compat.call_names)>0 {append(&values,"main")};case "BASH_SOURCE":append(&values,shell.compat.top_source);case "BASH_LINENO":append(&values,"0")}
    } else if name=="BASH_SOURCE"&&len(values)==0&&shell.compat.current_source!="" {append(&values,shell.compat.current_source)}
    return values[:],true
}
native_shell_debug_parameters_init :: proc(shell:^Native_Shell) {
    if shell.compat.debug_parameters_initialized {return}
    shell.compat.debug_parameters_initialized=true
    shell.compat.debug_parameters=make([]string,len(shell.compat.parameters),shell.allocator)
    for value,index in shell.compat.parameters {shell.compat.debug_parameters[index]=strings.clone(value,shell.allocator)}
}

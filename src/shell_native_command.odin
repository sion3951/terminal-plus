#+build linux
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"

Native_Shell_Command_Description :: struct {kind,value:string}

native_shell_hash_clear :: proc(shell:^Native_Shell) {
    for name,path in shell.compat.command_hash {delete(name,shell.allocator);delete(path,shell.allocator)}
    clear(&shell.compat.command_hash);clear(&shell.compat.command_hash_hits)
}

native_shell_hash_remove :: proc(shell:^Native_Shell,name:string)->bool {
    for key,path in shell.compat.command_hash {
        if key!=name {continue}
        delete_key(&shell.compat.command_hash_hits,key);delete_key(&shell.compat.command_hash,key)
        delete(key,shell.allocator);delete(path,shell.allocator);return true
    }
    return false
}

native_shell_hash_store :: proc(shell:^Native_Shell,name,path:string) {
    native_shell_hash_remove(shell,name)
    key:=strings.clone(name,shell.allocator)
    shell.compat.command_hash[key]=strings.clone(path,shell.allocator)
    shell.compat.command_hash_hits[key]=0
}

native_shell_hash_search :: proc(shell:^Native_Shell,name:string,assignments:[]Native_Shell_Assignment=nil,search_path:string="")->string {
    for path in native_shell_paths(shell,[]string{name},assignments,search_path) {
        info,error:=os.stat(string(path),context.allocator)
        if error==nil&&info.type!=.Directory&&posix.access(path,{.X_OK})==.OK {return string(path)}
    }
    return ""
}

native_shell_hash_eligible :: proc(name:string,assignments:[]Native_Shell_Assignment,search_path:string)->bool {
    if search_path!=""||strings.contains(name,"/") {return false}
    for assignment in assignments {if assignment.name=="PATH" {return false}}
    return true
}

// Resolve in the parent before fork so automatic command hashing persists.
native_shell_hash_command :: proc(shell:^Native_Shell,command:Native_Shell_Prepared) {
    if !shell.compat.options["hashall"]||command.compound!=nil||len(command.args)==0 {return}
    name:=command.args[0]
    if native_shell_builtin_name(name)&&!shell.compat.disabled[name]||!command.bypass_functions&&native_shell_has_function(shell,name) {return}
    if !native_shell_hash_eligible(name,command.assignments[:],command.search_path) {return}
    path,present:=shell.compat.command_hash[name]
    if present&&(shell.compat.shopts["checkhash"]||shell.compat.options["posix"])&&posix.access(strings.clone_to_cstring(path),{})!=.OK {native_shell_hash_remove(shell,name);present=false}
    if !present {path=native_shell_hash_search(shell,name);if path!="" {native_shell_hash_store(shell,name,path);present=true}}
    if present {shell.compat.command_hash_hits[name]+=1}
}

native_shell_execution_paths :: proc(shell:^Native_Shell,args:[]string,assignments:[]Native_Shell_Assignment,search_path:string)->[]cstring {
    if shell.compat.options["hashall"]&&native_shell_hash_eligible(args[0],assignments,search_path) {
        if path,present:=shell.compat.command_hash[args[0]];present {result:=make([]cstring,1);result[0]=strings.clone_to_cstring(path);return result}
    }
    return native_shell_paths(shell,args,assignments,search_path)
}

native_shell_hash_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    if !shell.compat.options["hashall"] {fmt.eprintln("hash: hashing disabled");return 1}
    index:=1;remove,lookup,reusable,reset:=false,false,false,false;path:="";provided_path:=false
    for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
        if args[index]=="--" {index+=1;break}
        for at:=1;at<len(args[index]);at+=1 {
            switch args[index][at] {
            case 'r':reset=true
            case 'l':reusable=true
            case 'd':remove=true
            case 't':lookup=true
            case 'p':
                path=args[index][at+1:]
                if path=="" {index+=1;if index==len(args) {fmt.eprintln("hash: -p requires a pathname");return 2};path=args[index]}
                provided_path=true;at=len(args[index])
            case:fmt.eprintf("hash: invalid option: -%c\n",args[index][at]);return 2
            }
        }
        index+=1
    }
    if reset {native_shell_hash_clear(shell)}
    if provided_path&&shell.compat.restricted&&strings.contains(path,"/") {fmt.eprintf("hash: %s: restricted\n",path);return 1}
    if index==len(args) {
        if remove||lookup {fmt.eprintln("hash: command name required");return 1}
        if reset||provided_path {return 0}
        names:=make([dynamic]string);for name in shell.compat.command_hash {append(&names,name)};slice.sort(names[:])
        if len(names)==0 {if !reusable||native_shell_compat_level(shell)<=50 {fmt.println("hash: hash table empty")};return 0}
        if !reusable {fmt.println("hits\tcommand")}
        for name in names {if reusable {fmt.printf("builtin hash -p %s %s\n",explorer_quote(shell.compat.command_hash[name]),explorer_quote(name))} else {fmt.printf("%4d\t%s\n",shell.compat.command_hash_hits[name],shell.compat.command_hash[name])}}
        return 0
    }
    result:=0
    for name in args[index:] {
        if remove {if !native_shell_hash_remove(shell,name) {fmt.eprintf("hash: %s: not found\n",name);result=1};continue}
        if lookup {
            value,exists:=shell.compat.command_hash[name]
            if !exists {fmt.eprintf("hash: %s: not found\n",name);result=1;continue}
            if len(args)-index>1 {fmt.printf("%s\t",name)};fmt.println(value);continue
        }
        if provided_path {native_shell_hash_store(shell,name,path);continue}
        if native_shell_builtin_name(name)&&!shell.compat.disabled[name]||native_shell_has_function(shell,name) {continue}
        if strings.contains(name,"/") {continue}
        value:=native_shell_hash_search(shell,name)
        if value=="" {fmt.eprintf("hash: %s: not found\n",name);result=1;continue}
        native_shell_hash_store(shell,name,value)
    }
    return result
}

native_shell_standard_path :: proc()->string {
    count:=posix.confstr(._PATH,nil,0)
    if count==0 {return "/bin:/usr/bin"}
    bytes:=make([]u8,int(count))
    if posix.confstr(._PATH,raw_data(bytes),count)==0 {return "/bin:/usr/bin"}
    end:=strings.index_byte(string(bytes),0)
    if end<0 {end=len(bytes)}
    return string(bytes[:end])
}

native_shell_command_keyword :: proc(name:string)->bool {
    return native_shell_reserved(name)||name=="[["||name=="]]"
}

native_shell_command_descriptions :: proc(shell:^Native_Shell,name:string,all,force_path,ignore_functions:bool,search_path:string="")->[]Native_Shell_Command_Description {
    descriptions:=make([dynamic]Native_Shell_Command_Description)
    if !force_path&&!strings.contains(name,"/") {
        if shell.compat.shopts["expand_aliases"]||shell.compat.options["posix"] {
            if value,exists:=shell.compat.aliases[name];exists {
                append(&descriptions,Native_Shell_Command_Description{"alias",value})
                if !all {return descriptions[:]}
            }
        }
        if native_shell_command_keyword(name) {
            append(&descriptions,Native_Shell_Command_Description{"keyword",name})
            if !all {return descriptions[:]}
        }
        special:=shell.compat.options["posix"]&&native_shell_special_builtin(name)&&!shell.compat.disabled[name]
        if special {append(&descriptions,Native_Shell_Command_Description{"builtin",name});if !all {return descriptions[:]}}
        if !ignore_functions&&(!(shell.compat.options["posix"]||shell.compat.restricted)||!strings.contains(name,"/")) {
            if body,exists:=shell.compat.functions[name];exists {
                append(&descriptions,Native_Shell_Command_Description{"function",body})
                if !all {return descriptions[:]}
            }
        }
        if !special&&native_shell_builtin_name(name)&&!shell.compat.disabled[name] {
            append(&descriptions,Native_Shell_Command_Description{"builtin",name})
            if !all {return descriptions[:]}
        }
    }
    if !all&&search_path=="" {
        if path,present:=shell.compat.command_hash[name];present {append(&descriptions,Native_Shell_Command_Description{"file",path});return descriptions[:]}
    }
    for path in native_shell_paths(shell,[]string{name},nil,search_path) {
        info,error:=os.stat(string(path),context.allocator)
        if error!=nil||info.type==.Directory||posix.access(path,{.X_OK})!=.OK {continue}
        append(&descriptions,Native_Shell_Command_Description{"file",string(path)})
        if !all {break}
    }
    return descriptions[:]
}

native_shell_print_description :: proc(name:string,description:Native_Shell_Command_Description,special:bool=false) {
    switch description.kind {
    case "alias":fmt.printf("%s is aliased to %s\n",name,explorer_quote(description.value))
    case "keyword":fmt.printf("%s is a shell keyword\n",name)
    case "function":fmt.printf("%s is a function\n%s ()\n{\n%s\n}\n",name,name,description.value)
    case "builtin":if special {fmt.printf("%s is a special shell builtin\n",name)} else {fmt.printf("%s is a shell builtin\n",name)}
    case "file":fmt.printf("%s is %s\n",name,description.value)
    }
}

native_shell_type_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    index:=1;all,force_path,ignore_functions:=false,false,false
    output:="description"
    for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
        if args[index]=="--" {index+=1;break}
        for flag in args[index][1:] {
            switch flag {
            case 'a':all=true
            case 'f':ignore_functions=true
            case 't':output="kind"
            case 'p':output="path"
            case 'P':output="path";force_path=true
            case:fmt.eprintf("type: invalid option: -%c\n",flag);return 2
            }
        }
        index+=1
    }
    status:=0
    for name in args[index:] {
        descriptions:=native_shell_command_descriptions(shell,name,all,force_path,ignore_functions)
        if len(descriptions)==0 {
            status=1
            if output=="description" {fmt.eprintf("type: %s: not found\n",name)}
            continue
        }
        for description in descriptions {
            switch output {
            case "kind":fmt.println(description.kind)
            case "path":if description.kind=="file" {fmt.println(description.value)}
            case:native_shell_print_description(name,description,shell.compat.options["posix"]&&native_shell_special_builtin(name))
            }
        }
    }
    return status
}

native_shell_command_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    index:=1;standard:=false;query:=""
    for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
        if args[index]=="--" {index+=1;break}
        for flag in args[index][1:] {
            switch flag {
            case 'p':standard=true
            case 'v':query="short"
            case 'V':query="description"
            case:fmt.eprintf("command: invalid option: -%c\n",flag);return 2
            }
        }
        index+=1
    }
    if index==len(args) {return 0}
    if standard&&shell.compat.restricted {fmt.eprintln("command: -p: restricted");return 1}
    search_path:=""
    if standard {search_path=native_shell_standard_path()}
    if query!="" {
        found:=false
        for name in args[index:] {
            descriptions:=native_shell_command_descriptions(shell,name,false,false,false,search_path)
            if len(descriptions)==0 {if query=="description" {fmt.eprintf("command: %s: not found\n",name)};continue}
            found=true;description:=descriptions[0]
            if query=="description" {native_shell_print_description(name,description,shell.compat.options["posix"]&&native_shell_special_builtin(name));continue}
            switch description.kind {
            case "alias":fmt.printf("alias %s=%s\n",name,explorer_quote(description.value))
            case "file":fmt.println(description.value)
            case:fmt.println(name)
            }
        }
        if found {return 0}
        return 1
    }
    // Bypass functions for execution while retaining parent-shell semantics
    // for builtins such as cd, read and export. A standardized search path
    // affects lookup only; the external command's PATH remains unchanged.
    name:=args[index]
    if native_shell_builtin_name(name)&&!shell.compat.disabled[name] {return native_shell_builtin(shell,args[index:])}
    values:=make([dynamic]string);append(&values,..args[index:])
    prepared:=[]Native_Shell_Prepared{{args=values,bypass_functions=true,search_path=search_path,line=shell.compat.current_line}}
    return native_shell_pipeline_prepared(shell,Native_Shell_Pipeline{},prepared,strings.join(args[index:]," "))
}

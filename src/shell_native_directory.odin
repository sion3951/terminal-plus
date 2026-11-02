#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"

// PWD can be supplied or modified by a script. Use its logical spelling only
// while it still names the directory the process actually occupies.
native_shell_logical_directory :: proc(shell:^Native_Shell)->string {
    logical,_:=native_shell_value_get(shell,"PWD")
    if strings.has_prefix(logical,"/")&&!strings.contains(logical,"\x00") {
        cleaned,error:=os.clean_path(logical,context.allocator)
        if error==nil {
            expected,actual:posix.stat_t
            name:=strings.clone_to_cstring(cleaned,context.allocator)
            same:=posix.stat(name,&expected)==.OK&&posix.stat(".",&actual)==.OK&&expected.st_dev==actual.st_dev&&expected.st_ino==actual.st_ino
            delete(name)
            if same {
                return cleaned
            }
            delete(cleaned)
        }
    }
    physical,error:=os.get_working_directory(context.allocator)
    if error!=nil {return ""}
    return physical
}

native_shell_directory_path :: proc(root:string,components:[]string)->string {
    if len(components)==0 {return root}
    return strings.concatenate([]string{root,strings.join(components,"/")})
}

native_shell_directory_normalize :: proc(path:string)->(string,string) {
    if !strings.has_prefix(path,"/") {return path,""}
    root:="/"
    if strings.has_prefix(path,"//")&&!strings.has_prefix(path,"///") {root="//"}
    components:=make([dynamic]string)
    remaining:=path
    for component in strings.split_iterator(&remaining,"/") {
        switch component {
        case "", ".":continue
        case "..":
            // Logical .. removes a symlink component without traversing its
            // physical parent, but nonexistent/non-directory components must
            // still fail rather than disappear through lexical cleaning.
            prefix:=native_shell_directory_path(root,components[:])
            info,error:=os.stat(prefix,context.allocator)
            if error!=nil||info.type!=.Directory {return "",fmt.aprintf("%s: not a directory",prefix)}
            if len(components)>0 {pop(&components)}
        case:append(&components,component)
        }
    }
    return native_shell_directory_path(root,components[:]),""
}

native_shell_directory_change :: proc(shell:^Native_Shell,path,previous:string,physical:bool)->(string,string) {
    destination:=path
    if !physical {
        if !strings.has_prefix(destination,"/")&&previous!="" {destination=strings.concatenate([]string{previous,"/",destination})}
        normalized,error:=native_shell_directory_normalize(destination)
        if error!="" {return "",error}
        destination=normalized
    }
    if error:=os.change_directory(destination);error!=nil {return "",fmt.aprintf("%s: %v",path,error)}
    if !physical&&strings.has_prefix(destination,"/") {return destination,""}
    current,error:=os.get_working_directory(context.allocator)
    if error!=nil {return "","cannot determine working directory"}
    return current,""
}

// Bash's cdspell repairs a single insertion, deletion, replacement or adjacent
// transposition in each pathname component. Exact existing names always win.
native_shell_directory_spelling_distance :: proc(requested,candidate:string)->int {
    if requested==candidate {return 0}
    if abs(len(requested)-len(candidate))>1 {return 3}
    at:=0
    for at<min(len(requested),len(candidate))&&requested[at]==candidate[at] {at+=1}
    if len(requested)==len(candidate) {
        if at+1<len(requested)&&requested[at]==candidate[at+1]&&requested[at+1]==candidate[at]&&requested[at+2:]==candidate[at+2:] {return 1}
        if at<len(requested)&&requested[at+1:]==candidate[at+1:] {return 2}
    } else if len(requested)>len(candidate) {
        if requested[at+1:]==candidate[at:] {return 2}
    } else if requested[at:]==candidate[at+1:] {return 2}
    return 3
}

native_shell_directory_correct :: proc(path:string)->(string,bool) {
    corrected:="";search:="."
    if strings.has_prefix(path,"/") {corrected="/";search="/"}
    remaining:=path;changed:=false
    for component in strings.split_iterator(&remaining,"/") {
        if component=="" {continue}
        candidate:=component
        joined:=strings.concatenate([]string{search,"/",candidate})
        info,error:=os.stat(joined,context.allocator)
        if error!=nil||info.type!=.Directory {
            entries,read_error:=os.read_all_directory_by_path(search,context.allocator)
            if read_error!=nil {return "",false}
            distance:=3;replacement:=""
            for entry in entries {
                next:=native_shell_directory_spelling_distance(component,entry.name)
                if next>=distance {continue}
                entry_info,entry_error:=os.stat(strings.concatenate([]string{search,"/",entry.name}),context.allocator)
                if entry_error!=nil||entry_info.type!=.Directory {continue}
                replacement=entry.name;distance=next
            }
            if replacement=="" {return "",false}
            candidate=replacement;changed=true
        }
        if corrected!=""&&!strings.has_suffix(corrected,"/") {corrected=strings.concatenate([]string{corrected,"/"})}
        corrected=strings.concatenate([]string{corrected,candidate})
        search=strings.concatenate([]string{search,"/",candidate})
    }
    return corrected,changed
}

native_shell_cd_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    if shell.compat.restricted {fmt.eprintln("cd: restricted");return 1}
    index:=1;physical:=shell.compat.options["physical"];require_physical:=false
    for index<len(args)&&strings.has_prefix(args[index],"-")&&args[index]!="-" {
        if args[index]=="--" {index+=1;break}
        for flag in args[index][1:] {
            switch flag {
            case 'L':physical=false
            case 'P':physical=true
            case 'e':require_physical=true
            case:fmt.eprintf("cd: invalid option: -%c\n",flag);return 2
            }
        }
        index+=1
    }
    if len(args)-index>1 {fmt.eprintln("cd: too many arguments");return 1}
    requested:="";print_path:=false;search_cdpath:=false
    if index==len(args) {
        home,exists:=native_shell_value_get(shell,"HOME")
        if !exists {fmt.eprintln("cd: HOME not set");return 1}
        requested=home;if requested=="" {return 0}
    } else {
        requested=args[index]
        if requested=="-" {
            old,exists:=native_shell_value_get(shell,"OLDPWD")
            if !exists {fmt.eprintln("cd: OLDPWD not set");return 1}
            requested=old;print_path=true
            if requested=="" {fmt.println();return 0}
        } else {search_cdpath=true}
    }
    if requested=="" {fmt.eprintln("cd: null directory");return 1}
    previous:=native_shell_logical_directory(shell)
    current:="";failure:="";changed:=false
    if search_cdpath&&!strings.has_prefix(requested,"/") {
        first:=requested
        if slash:=strings.index_byte(first,'/');slash>=0 {first=first[:slash]}
        if first!="."&&first!=".." {
            if search,exists:=native_shell_value_get(shell,"CDPATH");exists {
                for component in strings.split_iterator(&search,":") {
                    candidate:=requested
                    if component!="" {candidate=strings.concatenate([]string{component,"/",requested})}
                    resolved,error:=native_shell_directory_change(shell,candidate,previous,physical)
                    if error!="" {failure=error;continue}
                    current=resolved;changed=true
                    if component!="" {print_path=true}
                    break
                }
            }
        }
    }
    if !changed {
        resolved,error:=native_shell_directory_change(shell,requested,previous,physical)
        if error!="" {failure=error} else {current=resolved;changed=true}
    }
    if !changed&&shell.compat.shopts["cdable_vars"] {
        if destination,exists:=native_shell_value_get(shell,requested);exists&&destination!="" {
            resolved,error:=native_shell_directory_change(shell,destination,previous,physical)
            if error=="" {current=resolved;changed=true;print_path=true} else {failure=error}
        }
    }
    if !changed&&shell.interactive&&shell.compat.shopts["cdspell"] {
        if corrected,found:=native_shell_directory_correct(requested);found {
            resolved,error:=native_shell_directory_change(shell,corrected,previous,physical)
            if error=="" {fmt.println(corrected);current=resolved;changed=true} else {failure=error}
        }
    }
    if !changed {fmt.eprintf("cd: %s\n",failure);return 1}
    status:=0
    if error:=native_shell_value_set(shell,"OLDPWD",previous,NATIVE_SHELL_EXPORT);error!="" {fmt.eprintf("cd: %s\n",error);status=1}
    if error:=native_shell_value_set(shell,"PWD",current,NATIVE_SHELL_EXPORT);error!="" {fmt.eprintf("cd: %s\n",error);status=1}
    if print_path {fmt.println(current)}
    if physical&&require_physical&&current=="" {return 1}
    return status
}

native_shell_pwd_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    physical:=shell.compat.options["physical"]
    for index:=1;index<len(args);index+=1 {
        argument:=args[index]
        if argument=="--" {break}
        if !strings.has_prefix(argument,"-")||argument=="-" {break}
        for flag in argument[1:] {
            switch flag {case 'L':physical=false;case 'P':physical=true;case:fmt.eprintf("pwd: invalid option: -%c\n",flag);return 2}
        }
    }
    directory:=""
    if physical {
        current,error:=os.get_working_directory(context.allocator)
        if error!=nil {fmt.eprintln("pwd: cannot determine working directory");return 1}
        directory=current
    } else {directory=native_shell_logical_directory(shell)}
    if directory=="" {fmt.eprintln("pwd: cannot determine working directory");return 1}
    fmt.println(directory);return 0
}

// DIRSTACK is a view of the current logical directory followed by the saved
// entries. Saved strings always belong to the shell heap, never a command arena.
native_shell_directory_stack_values :: proc(shell:^Native_Shell)->[]string {
    values:=make([]string,len(shell.compat.directories)+1)
    values[0]=native_shell_logical_directory(shell)
    for directory,index in shell.compat.directories {values[index+1]=directory}
    return values
}

native_shell_directory_stack_set :: proc(shell:^Native_Shell,index:int,value:string)->string {
    at:=index;if at<0 {at+=len(shell.compat.directories)+1}
    if at==0 {return ""} // Assignment never changes the working directory.
    if at<1||at>len(shell.compat.directories) {return ""}
    replacement:=strings.clone(value,shell.allocator)
    delete(shell.compat.directories[at-1],shell.allocator)
    shell.compat.directories[at-1]=replacement
    return ""
}

native_shell_directory_stack_replace :: proc(shell:^Native_Shell,values:[]string) {
    // Clone first: values may reference entries in the old stack.
    replacement:=make([dynamic]string,0,len(values),shell.allocator)
    for value in values {append(&replacement,strings.clone(value,shell.allocator))}
    for value in shell.compat.directories {delete(value,shell.allocator)}
    delete(shell.compat.directories)
    shell.compat.directories=replacement
}

native_shell_directory_stack_index :: proc(argument:string,length:int)->(index:int,valid:bool) {
    if len(argument)<2||(argument[0]!='+'&&argument[0]!='-') {return 0,false}
    for byte in transmute([]u8)argument[1:] {if byte<'0'||byte>'9' {return 0,false}}
    number,ok:=strconv.parse_int(argument[1:]);if !ok {return 0,false}
    if argument[0]=='-' {return length-1-number,true}
    return number,true
}

native_shell_directory_display :: proc(shell:^Native_Shell,directory:string,full:bool)->string {
    if full {return directory}
    home,exists:=native_shell_value_get(shell,"HOME")
    if exists&&home!="" {
        if directory==home {return "~"}
        if strings.has_prefix(directory,home)&&len(directory)>len(home)&&directory[len(home)]=='/' {return strings.concatenate([]string{"~",directory[len(home):]})}
    }
    return directory
}

native_shell_directory_stack_print :: proc(shell:^Native_Shell,full,lines,numbered:bool,selection:int= -1)->int {
    values:=native_shell_directory_stack_values(shell)
    if selection>=len(values) {fmt.eprintln("dirs: directory stack index out of range");return 1}
    for directory,index in values {
        if selection>=0&&selection!=index {continue}
        if numbered {fmt.printf("%2d  ",index)}
        fmt.print(native_shell_directory_display(shell,directory,full))
        if lines||numbered||selection>=0||index==len(values)-1 {fmt.println()} else {fmt.print(" ")}
    }
    return 0
}

native_shell_directory_stack_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    if args[0]=="dirs" {
        full,lines,numbered,clear_stack,end_options,have_selection:bool
        selection:=-1
        for argument in args[1:] {
            if argument=="--" {end_options=true;continue}
            if !end_options {
                switch argument {
                case "-c":clear_stack=true;continue
                case "-l":full=true;continue
                case "-p":lines=true;continue
                case "-v":numbered=true;continue
                }
            }
            at,valid:=native_shell_directory_stack_index(argument,len(shell.compat.directories)+1)
            if !valid {if end_options {continue};fmt.eprintf("dirs: %s: invalid %s\n",argument,"number" if strings.has_prefix(argument,"-")||strings.has_prefix(argument,"+") else "option");return 2}
            selection=at;have_selection=true
        }
        if clear_stack {native_shell_directory_stack_replace(shell,nil);return 0}
        if have_selection&&(selection<0||selection>len(shell.compat.directories)) {fmt.eprintln("dirs: directory stack index out of range");return 1}
        return native_shell_directory_stack_print(shell,full,lines,numbered,selection)
    }
    no_change,end_options:bool
    argument:="";has_argument:=false
    for value in args[1:] {
        if !end_options&&value=="--" {end_options=true;continue}
        if !end_options&&value=="-n" {no_change=true;continue}
        if !end_options&&len(value)>1&&value[0]=='-'&&!(value[1]>='0'&&value[1]<='9') {fmt.eprintf("%s: %s: invalid number\n",args[0],value);return 2}
        if has_argument {fmt.eprintf("%s: too many arguments\n",args[0]);return 2}
        argument=value;has_argument=true
    }
    values:=native_shell_directory_stack_values(shell)
    if values[0]=="" {fmt.eprintf("%s: cannot determine working directory\n",args[0]);return 1}
    at,rotation:=native_shell_directory_stack_index(argument,len(values))
    if has_argument&&!rotation&&!end_options&&len(argument)>1&&(argument[0]=='+'||argument[0]=='-') {fmt.eprintf("%s: %s: invalid number\n",args[0],argument);return 2}
    if rotation&&(at<0||at>=len(values)) {fmt.eprintf("%s: directory stack index out of range\n",args[0]);return 1}
    if args[0]=="pushd" {
        if !has_argument {
            if no_change {return 0}
            if len(values)<2 {fmt.eprintln("pushd: no other directory");return 1}
            if status:=native_shell_cd_builtin(shell,[]string{"cd","--",values[1]});status!=0 {return status}
            values[0],values[1]=values[1],values[0]
            native_shell_directory_stack_replace(shell,values[1:])
        } else if rotation {
            if at>0 {
                rotated:=make([]string,len(values))
                for index in 0..<len(values) {rotated[index]=values[(index+at)%len(values)]}
                if !no_change {if status:=native_shell_cd_builtin(shell,[]string{"cd","--",rotated[0]});status!=0 {return status}}
                native_shell_directory_stack_replace(shell,rotated[1:])
            }
            if no_change {return 0}
        } else {
            if !no_change {if status:=native_shell_cd_builtin(shell,[]string{"cd","--",argument});status!=0 {return status}}
            saved:=make([]string,len(values))
            if no_change {saved[0]=argument;copy(saved[1:],values[1:])} else {copy(saved,values)}
            native_shell_directory_stack_replace(shell,saved)
        }
    } else {
        if len(values)<2 {fmt.eprintln("popd: directory stack empty");return 1}
        if has_argument&&!rotation {fmt.eprintf("popd: %s: invalid argument\n",argument);return 2}
        if !rotation {at=0}
        if at==0 {
            if !no_change {if status:=native_shell_cd_builtin(shell,[]string{"cd","--",values[1]});status!=0 {return status}}
            native_shell_directory_stack_replace(shell,values[2:])
        } else {
            saved:=make([dynamic]string,0,len(values)-2)
            for value,index in values[1:] {if index+1!=at {append(&saved,value)}}
            native_shell_directory_stack_replace(shell,saved[:])
        }
    }
    return native_shell_directory_stack_print(shell,false,false,false)
}

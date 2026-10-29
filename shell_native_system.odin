#+build linux
package main

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"

native_shell_alias_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    index:=1;explicit_prefix:=false
    for index<len(args)&&len(args[index])>1&&args[index][0]=='-' {
        if args[index]=="--" {index+=1;break}
        if args[index]!="-p" {fmt.eprintf("alias: %s: invalid option\n",args[index]);return 2}
        explicit_prefix=true;index+=1
    }
    prefix:="alias ";if shell.compat.options["posix"]&&!explicit_prefix {prefix=""}
    arguments:=args[index:]
    if len(arguments)==0 {names:=make([dynamic]string);for name in shell.compat.aliases {append(&names,name)};slice.sort(names[:]);arguments=names[:]}
    status:=0
    for argument in arguments {
        equals:=strings.index_byte(argument,'=')
        if equals>=0 {
            name:=argument[:equals]
            if name==""||strings.contains_any(name," /$`='\";&|<>()\t\n") {fmt.eprintf("alias: %s: invalid alias name\n",name);status=1;continue}
            native_shell_owned_text_set(&shell.compat.aliases,name,argument[equals+1:],shell.allocator)
        } else {
            value,present:=shell.compat.aliases[argument]
            if !present {fmt.eprintf("alias: %s: not found\n",argument);status=1;continue}
            quoted,_:=strings.replace_all(value,"'","'\\''")
            fmt.printf("%s%s='%s'\n",prefix,argument,quoted)
        }
    }
    return status
}

// These are Linux's resource identifiers. Odin's POSIX wrapper only names the
// portable subset, but getrlimit/setrlimit expose all sixteen kernel resources.
Native_Shell_Limit :: struct {flag:u8,resource:int,unit:u64,label:string}
native_shell_limits :: proc()->[]Native_Shell_Limit {
    result:=make([]Native_Shell_Limit,17)
    copy(result,[]Native_Shell_Limit{
        {'R',15,1,"real-time non-blocking time  (microseconds, -R)"},
        {'c',4,1024,"core file size              (blocks, -c)"},
        {'d',2,1024,"data seg size               (kbytes, -d)"},
        {'e',13,1,"scheduling priority                 (-e)"},
        {'f',1,1024,"file size                   (blocks, -f)"},
        {'i',11,1,"pending signals                     (-i)"},
        {'l',8,1024,"max locked memory           (kbytes, -l)"},
        {'m',5,1024,"max memory size             (kbytes, -m)"},
        {'n',7,1,"open files                          (-n)"},
        {'p',-1,512,"pipe size                (512 bytes, -p)"},
        {'q',12,1,"POSIX message queues         (bytes, -q)"},
        {'r',14,1,"real-time priority                  (-r)"},
        {'s',3,1024,"stack size                  (kbytes, -s)"},
        {'t',0,1,"cpu time                   (seconds, -t)"},
        {'u',6,1,"max user processes                  (-u)"},
        {'v',9,1024,"virtual memory              (kbytes, -v)"},
        {'x',10,1,"file locks                          (-x)"},
    })
    return result
}

native_shell_system_ulimit :: proc(shell:^Native_Shell,args:[]string)->int {
    limits:=native_shell_limits();hard,soft,all:bool;selected:=make([dynamic]int);i:=1
    for i<len(args)&&len(args[i])>1&&args[i][0]=='-' {
        if args[i]=="--" {i+=1;break}
        for flag in transmute([]u8)args[i][1:] {
            if flag=='H' {hard=true;continue};if flag=='S' {soft=true;continue};if flag=='a' {all=true;continue}
            found:=false
            for limit,index in limits {if limit.flag==flag {append(&selected,index);found=true;break}}
            if !found {fmt.eprintf("ulimit: -%c: invalid option\n",flag);return 2}
        }
        i+=1
    }
    if all {clear(&selected);for _,index in limits {append(&selected,index)}}
    if len(selected)==0 {append(&selected,4)} // -f is the default resource.
    if i+1<len(args) {fmt.eprintln("ulimit: too many arguments");return 1}
    setting:=i<len(args)&&!all
    if setting&&len(selected)>1 {fmt.eprintln("ulimit: too many arguments");return 1}
    for index in selected {
        limit:=limits[index]
        if shell.compat.options["posix"]&&(limit.flag=='c'||limit.flag=='f') {limit.unit=512}
        if limit.resource<0 {
            if setting {fmt.eprintln("ulimit: pipe size: cannot modify limit");return 1}
            if len(selected)>1 {fmt.printf("%s ",limit.label)};fmt.println(8);continue
        }
        resource:=posix.Resource(limit.resource);current:posix.rlimit
        if posix.getrlimit(resource,&current)!=.OK {fmt.eprintf("ulimit: %v\n",posix.errno());return 1}
        if !setting {
            value:=current.rlim_cur;if hard&&!soft {value=current.rlim_max}
            if len(selected)>1 {fmt.printf("%s ",limit.label)}
            if value==posix.RLIM_INFINITY {fmt.println("unlimited")} else {fmt.printf("%d\n",u64(value)/limit.unit)}
            continue
        }
        value:=posix.RLIM_INFINITY
        switch args[i] {
        case "unlimited":
        case "soft":value=current.rlim_cur
        case "hard":value=current.rlim_max
        case:
            number,ok:=strconv.parse_u64(args[i]);if !ok||number>max(u64)/limit.unit {fmt.eprintln("ulimit: invalid number");return 1};value=posix.rlim_t(number*limit.unit)
        }
        if !hard&&!soft {hard=true;soft=true}
        if hard {current.rlim_max=value};if soft {current.rlim_cur=value}
        if posix.setrlimit(resource,&current)!=.OK {fmt.eprintf("ulimit: %v\n",posix.errno());return 1}
    }
    return 0
}

native_shell_builtin_inventory :: proc()->[]string {
    // The inventory is shared by enable, help and command discovery; retain its
    // sorted order, including the two native viewer convenience builtins.
    return strings.fields(". : [ alias bg bind break builtin caller cd clear command compgen complete compopt continue declare dirs disown echo enable eval exec exit export false fc fg getopts hash help history jobs kill let local logout mapfile popd printf pushd pwd read readarray readonly return set shift shopt source suspend test times trap true tview type typeset ulimit umask unalias unset wait")
}

native_shell_enable_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    all,disable,special,printing:bool;i:=1
    for i<len(args)&&len(args[i])>1&&args[i][0]=='-' {
        if args[i]=="--" {i+=1;break}
        for flag in transmute([]u8)args[i][1:] {
            switch flag {case 'a':all=true;case 'n':disable=true;case 's':special=true;case 'p':printing=true;case:fmt.eprintf("enable: -%c: invalid option\n",flag);return 2}
        }
        i+=1
    }
    if i==len(args)||printing {
        for name in native_shell_builtin_inventory() {
            if special&&!native_shell_special_builtin(name)&&name!="source" {continue}
            disabled:=shell.compat.disabled[name]
            if !all&&disabled!=disable {continue}
            if disabled {fmt.printf("enable -n %s\n",name)} else {fmt.printf("enable %s\n",name)}
        }
        return 0
    }
    status:=0
    for name in args[i:] {
        if !native_shell_builtin_name(name) {fmt.eprintf("enable: %s: not a shell builtin\n",name);status=1;continue}
        if shell.compat.restricted&&!disable {fmt.eprintln("enable: restricted");status=1;continue}
        native_shell_bool_set(shell,&shell.compat.disabled,name,disable)
    }
    return status
}

native_shell_kill_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    i:=1;signal:=15
    if i<len(args)&&(args[i]=="-l"||args[i]=="-L") {
        i+=1
        if i==len(args) {
            count:=0
            for number:=1;number<=64;number+=1 {
                name:=native_shell_signal_name(number);if name=="" {continue}
                if shell.compat.options["posix"] {if count>0 {fmt.print(" ")};fmt.print(name);count+=1;continue}
                fmt.printf("%2d) SIG%s",number,name);count+=1
                if count%5==0 {fmt.println()} else {fmt.print("\t")}
            }
            if shell.compat.options["posix"]||count%5!=0 {fmt.println()};return 0
        }
        status:=0
        for value in args[i:] {
            if number,ok:=strconv.parse_int(value);ok {
                if number==128 {fmt.eprintf("kill: %s: invalid signal specification\n",value);status=1;continue}
                if number>=128 {number-=128};name:=native_shell_signal_name(number)
                if name=="" {fmt.eprintf("kill: %s: invalid signal specification\n",value);status=1} else {fmt.println(name)}
            } else {signal_number,valid:=native_shell_signal_number(value);if shell.compat.options["posix"]&&strings.has_prefix(value,"SIG") {valid=false};if !valid||signal_number<=0 {fmt.eprintf("kill: %s: invalid signal specification\n",value);status=1} else {fmt.println(signal_number)}}
        }
        return status
    }
    explicit_signal:=false
    for i<len(args)&&len(args[i])>1&&args[i][0]=='-' {
        if args[i]=="--" {i+=1;break}
        if args[i]=="-l"||args[i]=="-L" {
            listing:=make([dynamic]string);append(&listing,"kill");append(&listing,..args[i:])
            return native_shell_kill_builtin(shell,listing[:])
        }
        if args[i]=="-s"||args[i]=="-n" {
            i+=1;if i==len(args) {fmt.eprintln("kill: option requires an argument");return 2}
            if shell.compat.options["posix"]&&strings.has_prefix(args[i],"SIG") {fmt.eprintf("kill: %s: invalid signal specification\n",args[i]);return 1}
            number,ok:=native_shell_signal_number(args[i]);if !ok||number<0 {fmt.eprintf("kill: %s: invalid signal specification\n",args[i]);return 1};signal=number;i+=1;explicit_signal=true;continue
        }
        // Once a signal has been supplied, a negative numeric operand is a
        // process group, rather than another shorthand signal specification.
        if explicit_signal {if _,numeric:=strconv.parse_int(args[i]);numeric {break}}
        if shell.compat.options["posix"]&&strings.has_prefix(args[i][1:],"SIG") {fmt.eprintf("kill: %s: invalid signal specification\n",args[i]);return 1}
        number,ok:=native_shell_signal_number(args[i][1:]);if !ok||number<0 {fmt.eprintf("kill: %s: invalid signal specification\n",args[i]);return 1};signal=number;i+=1;explicit_signal=true
    }
    if i==len(args) {fmt.eprintln("kill: pid or job specification required");return 2}
    status:=0;sent,send_failed:bool
    for value in args[i:] {
        pid:posix.pid_t
        if strings.has_prefix(value,"%") {index:=native_shell_job_index(shell,value);if index<0 {fmt.eprintf("kill: %s: no such job\n",value);status=1;continue};pid= -shell.jobs[index].pgid} else {
            number,ok:=strconv.parse_int(value);if !ok||number< -2147483648||number>2147483647 {fmt.eprintf("kill: %s: arguments must be process or job IDs\n",value);status=1;continue};pid=posix.pid_t(number)
        }
        if posix.kill(pid,posix.Signal(signal))!=.OK {fmt.eprintf("kill: (%d): %v\n",pid,posix.errno());status=1;send_failed=true} else {sent=true}
    }
    if sent&&(!shell.compat.options["posix"]||!send_failed) {return 0}
    return status
}

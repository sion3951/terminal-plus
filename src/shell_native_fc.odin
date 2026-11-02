#+build linux
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"

Native_Shell_FC_Entry :: struct {number:int,text:string}

native_shell_fc_entries :: proc(shell:^Native_Shell)->[]Native_Shell_FC_Entry {
    entries:=make([dynamic]Native_Shell_FC_Entry)
    current:=native_shell_editor.current_submission
    for text,index in native_shell_editor.history {
        if current==index {continue}
        // The explicit submitted index handles fc inside functions or command
        // lists. This also excludes a direct invocation from older callers.
        if current<0&&shell.interactive&&index==len(native_shell_editor.history)-1 {
            tokens,error:=native_shell_tokens(text)
            if error==""&&len(tokens)>0&&tokens[0].raw=="fc" {continue}
        }
        append(&entries,Native_Shell_FC_Entry{native_shell_editor.history_base+index,text})
    }
    return entries[:]
}

native_shell_fc_index :: proc(entries:[]Native_Shell_FC_Entry,selector:string)->(int,bool) {
    if len(entries)==0 {return 0,false}
    if selector=="" {return len(entries)-1,true}
    number,valid:=strconv.parse_int(selector)
    if valid {
        if number<0 {at:=len(entries)+number;return at,at>=0&&at<len(entries)}
        for entry,index in entries {if entry.number==number {return index,true}}
        return 0,false
    }
    for at:=len(entries)-1;at>=0;at-=1 {if strings.has_prefix(entries[at].text,selector) {return at,true}}
    return 0,false
}

native_shell_fc_edit_index :: proc(entries:[]Native_Shell_FC_Entry,selector:string)->(int,bool) {
    if len(entries)==0 {return 0,false}
    if number,numeric:=strconv.parse_int(selector);numeric {
        if number<0 {return clamp(len(entries)+number,0,len(entries)-1),true}
        number=clamp(number,entries[0].number,entries[len(entries)-1].number)
        for entry,index in entries {if entry.number>=number {return index,true}}
        return len(entries)-1,true
    }
    return native_shell_fc_index(entries,selector)
}

native_shell_fc_record :: proc(shell:^Native_Shell,source:string) {
    // Bash replaces the invoking history entry with the commands it executes.
    // In noninteractive shells fc is not automatically recorded, so the latest
    // history entry is the replacement slot instead.
    index:=native_shell_editor.current_submission
    if index<0&&len(native_shell_editor.history)>0 {index=len(native_shell_editor.history)-1}
    if index>=0&&index<len(native_shell_editor.history) {
        native_shell_history_remove(index)
    }
    native_shell_editor.current_submission=-1
    native_shell_history_add_for(shell,strings.trim_suffix(source,"\n"))
}

native_shell_fc_read :: proc(path:string)->(string,bool) {
    name:=strings.clone_to_cstring(path,context.temp_allocator)
    fd:=posix.open(name,{.CLOEXEC,.NOFOLLOW,.NONBLOCK})
    if fd<0 {return "",false};defer posix.close(fd)
    stat:posix.stat_t
    if posix.fstat(fd,&stat)!=.OK||!posix.S_ISREG(stat.st_mode)||stat.st_uid!=posix.getuid() {return "",false}
    bytes:=make([dynamic]u8)
    buffer:[16384]u8
    for {
        amount:=posix.read(fd,raw_data(buffer[:]),len(buffer))
        if amount<0 {if posix.errno()==.EINTR {continue};return "",false}
        if amount==0 {break}
        append(&bytes,..buffer[:int(amount)])
    }
    return string(bytes[:]),true
}

native_shell_fc_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    native_shell_editor.shell=shell;native_shell_editor_load_history()
    listing,numbers,reverse,substitute:=false,true,false,false
    editor:="";editor_selected:=false
    index:=1
    for index<len(args) {
        argument:=args[index]
        if argument=="--" {index+=1;break}
        if len(argument)<2||argument[0]!='-' {break}
        if _,numeric:=strconv.parse_int(argument);numeric {break}
        for at:=1;at<len(argument);at+=1 {
            switch argument[at] {
            case 'l':listing=true
            case 'n':numbers=false
            case 'r':reverse=true
            case 's':substitute=true
            case 'e':
                if at+1<len(argument) {editor=argument[at+1:];at=len(argument)} else {index+=1;if index>=len(args) {fmt.eprintln("fc: -e requires an editor");return 2};editor=args[index]}
                editor_selected=true
            case:fmt.eprintf("fc: invalid option: -%c\n",argument[at]);return 2
            }
        }
        index+=1
    }
    selectors:=args[index:]
    // Bash's edit path removes the presumed invoking history entry before
    // choosing a range. A noninteractive fc has no auto-recorded invocation,
    // but Bash still excludes its latest entry here. Listing and -s/-e - use
    // the complete history instead; interactive submission tracking already
    // excludes the actual invoking entry.
    immediate_editor:=editor_selected&&editor=="-"
    if immediate_editor {substitute=true;if len(selectors)>1 {selectors=selectors[:1]}}
    entries:=native_shell_fc_entries(shell)
    if !listing&&!substitute&&native_shell_editor.current_submission<0&&len(entries)>0 {entries=entries[:len(entries)-1]}
    if len(entries)==0 {if substitute {fmt.eprintln("fc: no command found");return 1};return 0}
    if substitute {
        old,replacement:="",""
        if len(selectors)>0 {if equals:=strings.index_byte(selectors[0],'=');equals>=0 {old=selectors[0][:equals];replacement=selectors[0][equals+1:];selectors=selectors[1:]}}
        if len(selectors)>1 {fmt.eprintln("fc: too many arguments");return 2}
        selector:="";if len(selectors)>0 {selector=selectors[0]}
        selected,found:=native_shell_fc_index(entries,selector)
        if !found {fmt.eprintln("fc: history specification out of range");return 1}
        source:=strings.clone(entries[selected].text)
        if old!="" {source,_=strings.replace_all(source,old,replacement)}
        fmt.eprintln(source)
        native_shell_fc_record(shell,source)
        return native_shell_run_source(shell,source)
    }
    if len(selectors)>2 {fmt.eprintln("fc: too many arguments");return 2}
    first:=len(entries)-1;last:=first
    if listing {first=max(0,len(entries)-16)}
    if len(selectors)>0 {value,found:=native_shell_fc_index(entries,selectors[0]);if !listing {value,found=native_shell_fc_edit_index(entries,selectors[0])};if !found {fmt.eprintln("fc: history specification out of range");return 1};first=value;if !listing {last=first}}
    if len(selectors)>1 {value,found:=native_shell_fc_index(entries,selectors[1]);if !listing {value,found=native_shell_fc_edit_index(entries,selectors[1])};if !found {fmt.eprintln("fc: history specification out of range");return 1};last=value}
    if reverse {first,last=last,first}
    step:=1;if first>last {step=-1}
    source:=make([dynamic]u8)
    for at:=first;true;at+=step {
        entry:=entries[at]
        if listing {
            if numbers {fmt.print(entry.number)}
            fmt.printf("\t %s\n",entry.text)
        } else {append(&source,entry.text);append(&source,'\n')}
        if at==last {break}
    }
    if listing {return 0}
    if !editor_selected {editor=shell.variables["FCEDIT"];if editor=="" {editor=shell.variables["EDITOR"]};if editor=="" {editor="vi";if shell.compat.options["posix"] {editor="ed"}}}
    program:=string(source[:])
    if editor!="-" {
        temporary:=shell.variables["TMPDIR"];if temporary=="" {temporary="/tmp"}
        template:=strings.clone_to_cstring(strings.concatenate([]string{temporary,"/terminal-fc.XXXXXX"}))
        fd:=posix.mkstemp(template)
        if fd<0 {fmt.eprintln("fc: cannot create edit file");return 1}
        _=posix.fcntl(fd,.SETFD,c.int(posix.FD_CLOEXEC))
        path:=string(template)
        defer os.remove(path)
        remaining:=source[:]
        for len(remaining)>0 {
            amount:=posix.write(fd,raw_data(remaining),c.size_t(len(remaining)))
            if amount<0&&posix.errno()==.EINTR {continue}
            if amount<=0 {posix.close(fd);fmt.eprintln("fc: cannot write edit file");return 1}
            remaining=remaining[int(amount):]
        }
        posix.close(fd)
        command:=strings.concatenate([]string{editor," ",explorer_quote(path)})
        result:=native_shell_execute(shell,command)
        if result!=0||shell.exiting {return result}
        edited,ok:=native_shell_fc_read(path)
        if !ok {fmt.eprintln("fc: cannot read edit file");return 1}
        program=edited
    }
    if strings.trim_space(program)=="" {return 0}
    native_shell_fc_record(shell,program)
    fmt.eprint(program);if !strings.has_suffix(program,"\n") {fmt.eprintln()}
    return native_shell_run_source(shell,program)
}

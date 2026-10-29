#+build linux
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"

Native_Shell_Mail_State :: struct {
    exists:bool,
    size:i64,
    modified,accessed:posix.timespec,
}
native_shell_mail_files:map[string]Native_Shell_Mail_State
native_shell_mail_configuration:string
native_shell_mail_initialized:bool
native_shell_mail_checked:posix.time_t

native_shell_mail_destroy :: proc(shell:^Native_Shell) {
    for path in native_shell_mail_files {delete(path,shell.allocator)}
    delete(native_shell_mail_files);native_shell_mail_files=nil
    delete(native_shell_mail_configuration,shell.allocator);native_shell_mail_configuration=""
    native_shell_mail_initialized=false;native_shell_mail_checked=0
}

native_shell_mail_later :: proc(left,right:posix.timespec)->bool {
    return left.tv_sec>right.tv_sec||left.tv_sec==right.tv_sec&&left.tv_nsec>right.tv_nsec
}

native_shell_mail_stat :: proc(path:string)->(state:Native_Shell_Mail_State) {
    info:posix.stat_t
    if posix.stat(strings.clone_to_cstring(path),&info)!=.OK {return}
    if posix.S_ISREG(info.st_mode) {
        return {exists=true,size=i64(info.st_size),modified=info.st_mtim,accessed=info.st_atim}
    }
    if !posix.S_ISDIR(info.st_mode) {return}
    // Maildir messages are individual files in new/ and cur/. Checking their
    // metadata never opens mail or marks it read.
    for directory in ([]string{"new","cur"}) {
        folder:=strings.concatenate([]string{path,"/",directory})
        entries,error:=os.read_all_directory_by_path(folder,context.allocator)
        if error!=nil {continue}
        state.exists=true
        for entry in entries {
            filename:=strings.clone_to_cstring(strings.concatenate([]string{folder,"/",entry.name}))
            message:posix.stat_t
            if posix.stat(filename,&message)!=.OK||!posix.S_ISREG(message.st_mode) {continue}
            state.size+=i64(message.st_size)
            if native_shell_mail_later(message.st_mtim,state.modified) {state.modified=message.st_mtim}
            if native_shell_mail_later(message.st_atim,state.accessed) {state.accessed=message.st_atim}
        }
    }
    return
}

native_shell_mail_check :: proc(shell:^Native_Shell) {
    if !shell.interactive {return}
    interval,present:=native_shell_value_get(shell,"MAILCHECK")
    seconds,valid:=strconv.parse_int(interval)
    if !present||!valid||seconds<0 {return}
    now:=posix.time(nil)
    paths,multiple:=native_shell_value_get(shell,"MAILPATH")
    if !multiple {paths,_=native_shell_value_get(shell,"MAIL")}
    configuration:=strings.concatenate([]string{("path:" if multiple else "file:"),paths},context.temp_allocator)
    changed:=!native_shell_mail_initialized||configuration!=native_shell_mail_configuration
    if !changed&&now>=native_shell_mail_checked&&now-native_shell_mail_checked<posix.time_t(seconds) {return}
    if changed {
        native_shell_mail_destroy(shell)
        native_shell_mail_configuration=strings.clone(configuration,shell.allocator)
        native_shell_mail_files=make(map[string]Native_Shell_Mail_State,shell.allocator)
        native_shell_mail_initialized=true
    }
    native_shell_mail_checked=now
    // Expansion and directory scanning use a short-lived arena; snapshots and
    // map keys alone survive until the next prompt.
    arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
    original_allocator,original_temp:=context.allocator,context.temp_allocator
    context.allocator=mem.dynamic_arena_allocator(&arena);context.temp_allocator=context.allocator
    defer {context.allocator=original_allocator;context.temp_allocator=original_temp}
    saved_status:=shell.status
    defer {shell.status=saved_status}
    entries:=make([dynamic]string)
    if multiple {for entry in strings.split_iterator(&paths,":") {append(&entries,entry)}} else {append(&entries,paths)}
    for entry in entries {
        filename,message:=entry,""
        custom:=false
        if multiple {if question:=strings.index_byte(entry,'?');question>=0 {filename=entry[:question];message=entry[question+1:];custom=true}}
        if filename=="" {continue}
        path,path_error:=os.get_absolute_path(filename,context.allocator)
        if path_error!=nil {continue}
        previous,known:=native_shell_mail_files[path]
        current:=native_shell_mail_stat(path)
        if !known {native_shell_mail_files[strings.clone(path,shell.allocator)]=current} else {native_shell_mail_files[path]=current}
        if changed {continue}
        if current.exists&&current.size>0&&(!previous.exists||native_shell_mail_later(current.modified,previous.modified)||current.size>previous.size) {
            if native_shell_mail_later(current.modified,current.accessed)||current.size>previous.size {
                if custom {
                    last:=native_shell_snapshot_variable(shell,"_")
                    native_shell_set_variable(shell,"_",filename)
                    // Notification text is expanded as text: quote characters
                    // belong to the message and are not shell quoting syntax.
                    expanded,expand_error:=native_shell_expand_heredoc(shell,message)
                    native_shell_restore_variables(shell,[]Native_Shell_Variable_Save{last})
                    if expand_error==""&&expanded!="" {fmt.eprintln(expanded)}
                } else {fmt.eprintf("You have new mail in %s\n",filename)}
            }
        } else if known&&shell.compat.shopts["mailwarn"]&&current.exists&&current.size>0&&native_shell_mail_later(current.accessed,previous.accessed) {
            fmt.eprintf("The mail in %s has been read\n",filename)
        }
    }
}

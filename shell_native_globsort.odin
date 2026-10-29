#+build linux
package main

import libc "core:c/libc"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"

Native_Shell_Glob_Sort :: struct {criterion:string,reverse:bool}
Native_Shell_Glob_Entry :: struct {name:string,c_name:cstring,stat:posix.stat_t}

native_shell_glob_numeric :: proc(left,right:string)->int {
    a,b:=native_shell_digits(left),native_shell_digits(right)
    if a!=b {if a {return -1};return 1}
    if !a {return 0}
    first,second:=strings.trim_left(left,"0"),strings.trim_left(right,"0")
    if len(first)<len(second) {return -1};if len(first)>len(second) {return 1}
    if first<second {return -1};if first>second {return 1}
    return 0
}

native_shell_glob_compare :: proc(left,right:Native_Shell_Glob_Entry,data:rawptr)->bool {
    options:=(^Native_Shell_Glob_Sort)(data)
    comparison:=0
    switch options.criterion {
    case "numeric":comparison=native_shell_glob_numeric(left.name,right.name)
    case "size":if left.stat.st_size<right.stat.st_size {comparison= -1} else if left.stat.st_size>right.stat.st_size {comparison=1}
    case "blocks":if left.stat.st_blocks<right.stat.st_blocks {comparison= -1} else if left.stat.st_blocks>right.stat.st_blocks {comparison=1}
    case "mtime","atime","ctime":
        a,b:=left.stat.st_mtim,right.stat.st_mtim
        if options.criterion=="atime" {a=left.stat.st_atim;b=right.stat.st_atim}
        if options.criterion=="ctime" {a=left.stat.st_ctim;b=right.stat.st_ctim}
        if a.tv_sec<b.tv_sec||a.tv_sec==b.tv_sec&&a.tv_nsec<b.tv_nsec {comparison= -1} else if a.tv_sec>b.tv_sec||a.tv_sec==b.tv_sec&&a.tv_nsec>b.tv_nsec {comparison=1}
    }
    if comparison==0 {
        comparison=int(libc.strcoll(left.c_name,right.c_name))
        // Different byte spellings may collate equally; keep their ordering
        // deterministic without dropping either filename.
        if comparison==0 {if left.name<right.name {comparison= -1} else if left.name>right.name {comparison=1}}
    }
    if options.reverse {return comparison>0}
    return comparison<0
}

native_shell_glob_sort :: proc(shell:^Native_Shell,paths:[]string) {
    if len(paths)<2 {return}
    value,_:=native_shell_value_get(shell,"GLOBSORT")
    options:=Native_Shell_Glob_Sort{criterion="name"}
    if value!="" {
        if value[0]=='+'||value[0]=='-' {options.reverse=value[0]=='-';value=value[1:]}
        switch value {case "":case "name","numeric","size","mtime","atime","ctime","blocks":options.criterion=value;case "nosort":return;case:options.reverse=false}
    }
    previous:=native_shell_text_locale(shell);defer native_shell_text_locale_restore(previous)
    entries:=make([]Native_Shell_Glob_Entry,len(paths))
    defer {for entry in entries {delete(entry.c_name)};delete(entries)}
    for name,index in paths {
        entries[index].name=name
        entries[index].c_name=strings.clone_to_cstring(name)
        if options.criterion!="name"&&options.criterion!="numeric" {_=posix.stat(entries[index].c_name,&entries[index].stat)}
    }
    slice.sort_by_with_data(entries,native_shell_glob_compare,&options)
    for entry,index in entries {paths[index]=entry.name}
}

#+build linux, darwin
package main

import "core:os"
import "core:strings"
import "core:sys/posix"

// Reject special files and symlinks before bounded metadata reads.
updater_open_regular :: proc(path:string)->(^os.File,bool) {
    fd:=posix.open(strings.clone_to_cstring(path,context.temp_allocator),{.NOFOLLOW,.NONBLOCK,.CLOEXEC})
    if fd<0 {return nil,false}
    info:posix.stat_t
    if posix.fstat(fd,&info)!=nil||!posix.S_ISREG(info.st_mode) {posix.close(fd);return nil,false}
    file:=os.new_file(uintptr(fd),path)
    if file==nil {posix.close(fd);return nil,false}
    return file,true
}
updater_private_path :: proc(path:string,directory:bool)->bool {
    info:posix.stat_t
    if posix.lstat(strings.clone_to_cstring(path,context.temp_allocator),&info)!=nil||info.st_uid!=posix.getuid() {return false}
    if directory {return posix.S_ISDIR(info.st_mode)&&(info.st_mode&posix.mode_t{.IRGRP,.IWGRP,.IXGRP,.IROTH,.IWOTH,.IXOTH})=={}}
    return posix.S_ISREG(info.st_mode)&&(info.st_mode&posix.mode_t{.IWGRP,.IWOTH})=={}
}

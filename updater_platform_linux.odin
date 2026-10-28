#+build linux
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
updater_portable_owned :: proc(path:string)->bool {
    if path==""||path[0]!='/'||posix.getuid()==0 {return false}
    info:posix.stat_t
    if posix.lstat(strings.clone_to_cstring(path,context.temp_allocator),&info)!=nil||
        !posix.S_ISREG(info.st_mode)||info.st_uid!=posix.getuid()||
        (info.st_mode&posix.mode_t{.IWGRP,.IWOTH})!={} {return false}
    directory:=filepath.dir(path)
    for {
        if posix.lstat(strings.clone_to_cstring(directory,context.temp_allocator),&info)!=nil||
            !posix.S_ISDIR(info.st_mode)||(info.st_mode&posix.mode_t{.IWGRP,.IWOTH})!={} {return false}
        if directory==filepath.dir(path)&&info.st_uid!=posix.getuid() {return false}
        if info.st_uid!=0&&info.st_uid!=posix.getuid() {return false}
        if directory=="/" {break}
        directory=filepath.dir(directory)
    }
    return true
}
updater_platform_target :: proc()->(Update_Target,string) {
    executable,error:=os.get_executable_path(context.temp_allocator)
    if error!=nil {return {},"Could not locate this installation."}
    architecture:=""
    when ODIN_ARCH==.amd64 {architecture="amd64"} else when ODIN_ARCH==.arm64 {architecture="arm64"}
    if architecture=="" {return {},"Updates support Linux x64 and ARM64 AppImages."}
    appdir:=os.get_env("APPDIR",context.temp_allocator)
    image:=os.get_env("APPIMAGE",context.temp_allocator)
    if appdir==""||image==""||executable!=fmt.tprintf("%s/usr/bin/terminal+",appdir) {
        return {},"Run the release AppImage to enable automatic updates. Source builds can check and download releases."
    }
    if !updater_portable_owned(image) {return {},"This AppImage or its directory is not safely writable by your account. Install a release AppImage in your own Applications folder to enable updates."}
    return Update_Target{os="linux",arch=architecture,kind="appimage",executable=executable,portable_path=image},""
}
updater_platform_install :: proc(target:^Update_Target,package_path,stage:string,parent_pid:i32)->(bool,string) {
    current,error:=updater_platform_target()
    if error!="" {return false,error}
    if current.portable_path!=target.portable_path {return false,"The AppImage installation changed. Check for updates again."}
    // Recheck the bytes immediately before handing the private stage to our helper.
    if !updater_verify_package(package_path,target.size,target.sha256) {return false,"The staged update changed. Check for updates again."}
    helper:=fmt.tprintf("%s/update-install.sh",stage)
    if os.write_entire_file(helper,#load("scripts/update-install.sh"),{.Read_User,.Write_User})!=nil||!updater_private_path(helper,false) {
        return false,"Could not stage the portable update helper."
    }
    log,error_log:=os.open(fmt.tprintf("%s/install.log",stage),{.Write,.Create,.Trunc},{.Read_User,.Write_User})
    if error_log!=nil {return false,"Could not open the update installation log."}
    defer os.close(log)
    child,start_error:=os.process_start({command=[]string{"/bin/sh",helper,current.portable_path,package_path,stage,fmt.tprintf("%d",parent_pid),target.sha256,fmt.tprintf("%d",target.size)},stdout=log,stderr=log})
    if start_error!=nil {return false,fmt.tprintf("Could not start the update installer: %v",start_error)}
    // The helper deliberately outlives this UI, waiting for its normal shutdown.
    if child.handle!=0 {posix.close(posix.FD(child.handle))}
    return true,""
}

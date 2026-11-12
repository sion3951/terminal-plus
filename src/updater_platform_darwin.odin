package main

import "core:fmt"
import "core:os"
import "core:strings"

// macOS releases ship as a disk image holding Terminal+.app. The updater
// checks, downloads and verifies the signed image, then opens it in Finder
// for the standard drag-to-Applications install.
updater_platform_target :: proc()->(Update_Target,string) {
    when ODIN_ARCH!=.arm64 {return {},"Updates support Apple silicon Macs."}
    executable,error:=os.get_executable_path(context.temp_allocator)
    if error!=nil {return {},"Could not locate this installation."}
    if !strings.has_suffix(executable,".app/Contents/MacOS/terminal+") {
        return {},"Run Terminal+.app from the release disk image to enable automatic updates. Source builds can check and download releases."
    }
    return Update_Target{os="macos",arch="arm64",kind="dmg",executable=executable},""
}
updater_platform_install :: proc(target:^Update_Target,package_path,stage:string,parent_pid:i32)->(bool,string) {
    if !updater_verify_package(package_path,target.size,target.sha256) {return false,"The staged update changed. Check for updates again."}
    // The staged package keeps its release name, including the .dmg extension.
    if !strings.has_suffix(package_path,".dmg") {return false,"The downloaded update is not a disk image."}
    child,start_error:=os.process_start({command=[]string{"/usr/bin/open",package_path}})
    if start_error!=nil {return false,fmt.tprintf("Could not open the update: %v",start_error)}
    state,wait_error:=os.process_wait(child)
    if wait_error!=nil||state.exit_code!=0 {return false,"Could not open the downloaded disk image."}
    return false,"The verified update is open in Finder. Quit Terminal+, drag it to Applications to replace this version, then reopen it."
}

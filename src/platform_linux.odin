package main

import "core:c"
import "core:fmt"
import "core:os"
import posix "core:sys/posix"

// Kernel and libc details that differ between Linux and macOS. Call sites use
// these names so socket, PTY and process code stays shared between platforms.
PLATFORM_SOCK_CLOEXEC :: 0x80000
PLATFORM_SOCK_NONBLOCK :: 0x800
PLATFORM_MSG_NOSIGNAL :: 0x4000
PLATFORM_MSG_DONTWAIT :: 0x40
PLATFORM_SOL_SOCKET :: 1
PLATFORM_SO_ERROR :: 4
PLATFORM_TIOCSCTTY :: 0x540e
PLATFORM_TIOCSWINSZ :: 0x5414
PLATFORM_TIOCGWINSZ :: 0x5413

// Bash identity variables reported by the native shell.
PLATFORM_OSTYPE :: "linux-gnu"
PLATFORM_HOSTTYPE :: "x86_64"
PLATFORM_MACHTYPE :: "x86_64-pc-linux-gnu"
// glob(3) and fnmatch(3) flags used by the native shell.
PLATFORM_GLOB_NOSORT :: 4
PLATFORM_GLOB_PERIOD :: 128
PLATFORM_GLOB_NOMATCH :: 3
PLATFORM_FNM_CASEFOLD :: 16
PLATFORM_FNM_EXTMATCH :: 32

Local_Session_Address :: struct {family:u16,path:[108]u8}
Local_Session_Credentials :: struct {pid:c.int,uid,gid:c.uint}

Native_Shell_Glob :: struct {
    pathc:c.size_t,pathv:^cstring,offs:c.size_t,flags:c.int,
    closedir,readdir,opendir,lstat,stat:rawptr,
}
Native_Shell_Regex :: struct {
    buffer:rawptr,
    allocated,used,syntax:c.ulong,
    fastmap,translate:rawptr,
    nsub:c.size_t,
    flags:c.uint,
}
Native_Shell_Regex_Match :: struct {first,last:c.int}

foreign import platform_lib "system:c"
foreign platform_lib {
    @(link_name="socket") local_socket :: proc(domain,kind,protocol:c.int)->posix.FD ---
    @(link_name="accept4") local_accept :: proc(fd:posix.FD,address:rawptr,length:rawptr,flags:c.int)->posix.FD ---
    @(link_name="socketpair") file_socketpair :: proc(domain,kind,protocol:c.int,fds:^[2]posix.FD)->c.int ---
    @(link_name="pipe2") pty_pipe2 :: proc(fds:^[2]posix.FD,flags:c.int)->c.int ---
    @(link_name="memfd_create") platform_memfd_create :: proc(name:cstring,flags:c.uint)->posix.FD ---
    @(link_name="dgettext") native_shell_dgettext :: proc(domain,message:cstring)->cstring ---
    @(link_name="bindtextdomain") native_shell_bindtextdomain :: proc(domain,directory:cstring)->cstring ---
}

// Anonymous, close-on-exec storage for here-documents and captured output.
platform_memfd :: proc(name:cstring)->posix.FD {return platform_memfd_create(name,1)}

// The kernel resolves this link at exec time, even after the binary is replaced.
platform_self_exe :: proc()->string {return "/proc/self/exe"}

platform_peer_uid :: proc(fd:posix.FD)->(uid:posix.uid_t,ok:bool) {
    credentials:Local_Session_Credentials;length:=c.uint(size_of(credentials))
    if local_sockopt(fd,PLATFORM_SOL_SOCKET,17,&credentials,&length)!=0 {return}
    return posix.uid_t(credentials.uid),true
}

platform_process_cwd :: proc(pid:posix.pid_t,allocator:=context.temp_allocator)->string {
    current,error:=os.read_link(fmt.tprintf("/proc/%d/cwd",pid),allocator)
    if error!=nil {return ""}
    return current
}

platform_socket_address :: proc(path:string)->(address:Local_Session_Address,ok:bool) {
    if len(path)>=len(address.path) {return}
    address.family=1;copy(address.path[:],transmute([]u8)path);ok=true;return
}

// Launchers already provide the session environment on Linux.
platform_prepare_environment :: proc() {}

// Linux shortcuts use Ctrl and Ctrl+Shift directly.
platform_shortcut_mods :: proc(key,mods:c.int)->(c.int,bool) {return mods,true}

platform_poll :: posix.poll

platform_prepare_gui :: proc() {}

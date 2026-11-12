package main

import "core:c"
import "core:os"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"
import glfw "vendor:glfw"

// macOS has no SOCK_CLOEXEC/SOCK_NONBLOCK socket type flags, accept4, pipe2
// or memfd_create. Shared call sites pass these private high bits; the
// wrappers below strip them and apply the equivalent fcntl flags.
PLATFORM_SOCK_CLOEXEC :: 0x10000000
PLATFORM_SOCK_NONBLOCK :: 0x20000000
PLATFORM_MSG_NOSIGNAL :: 0x80000
PLATFORM_MSG_DONTWAIT :: 0x80
PLATFORM_SOL_SOCKET :: 0xffff
PLATFORM_SO_ERROR :: 0x1007
PLATFORM_SO_NOSIGPIPE :: 0x1022
PLATFORM_TIOCSCTTY :: 0x20007461
PLATFORM_TIOCSWINSZ :: 0x80087467
PLATFORM_TIOCGWINSZ :: 0x40087468

// Bash identity variables, matching Homebrew's Bash on Apple silicon so
// scripts testing [[ $OSTYPE == darwin* ]] take their macOS paths.
PLATFORM_OSTYPE :: "darwin"
PLATFORM_HOSTTYPE :: "aarch64"
PLATFORM_MACHTYPE :: "aarch64-apple-darwin"
// BSD glob has no GLOB_PERIOD; dotglob uses the native matcher instead.
PLATFORM_GLOB_NOSORT :: 0x20
PLATFORM_GLOB_PERIOD :: 0
PLATFORM_GLOB_NOMATCH :: -3
PLATFORM_FNM_CASEFOLD :: 0x10
// BSD fnmatch has no extended patterns: extglob syntax is matched literally.
PLATFORM_FNM_EXTMATCH :: 0

Local_Session_Address :: struct {length,family:u8,path:[104]u8}

Native_Shell_Glob :: struct {
    pathc:c.size_t,matchc:c.int,offs:c.size_t,flags:c.int,pathv:^cstring,
    errfunc,closedir,readdir,opendir,lstat,stat:rawptr,
}
Native_Shell_Regex :: struct {
    magic:c.int,
    nsub:c.size_t,
    endp:cstring,
    guts:rawptr,
}
// regoff_t is off_t on macOS.
Native_Shell_Regex_Match :: struct {first,last:i64}

foreign import platform_lib "system:System"
foreign platform_lib {
    @(link_name="socket") platform_socket_raw :: proc(domain,kind,protocol:c.int)->posix.FD ---
    @(link_name="accept") platform_accept_raw :: proc(fd:posix.FD,address:rawptr,length:rawptr)->posix.FD ---
    @(link_name="socketpair") platform_socketpair_raw :: proc(domain,kind,protocol:c.int,fds:^[2]posix.FD)->c.int ---
    @(link_name="setsockopt") platform_setsockopt :: proc(fd:posix.FD,level,name:c.int,value:rawptr,length:c.uint)->c.int ---
    @(link_name="getpeereid") platform_getpeereid :: proc(fd:posix.FD,uid:^posix.uid_t,gid:^posix.gid_t)->c.int ---
    @(link_name="proc_pidinfo") platform_proc_pidinfo :: proc(pid:c.int,flavor:c.int,arg:u64,buffer:rawptr,size:c.int)->c.int ---
    @(link_name="mkstemp") platform_mkstemp :: proc(template:[^]u8)->posix.FD ---
}

platform_fd_flags :: proc(fd:posix.FD,cloexec,nonblock:bool)->bool {
    if cloexec&&posix.fcntl(fd,.SETFD,c.int(posix.FD_CLOEXEC))<0 {return false}
    if nonblock {
        flags:=posix.fcntl(fd,.GETFL)
        if flags<0||posix.fcntl(fd,.SETFL,flags|c.int(posix.O_NONBLOCK))<0 {return false}
    }
    return true
}
// Sockets never raise SIGPIPE; a closed peer is an ordinary EPIPE result.
platform_nosigpipe :: proc(fd:posix.FD) {
    enabled:c.int=1
    platform_setsockopt(fd,PLATFORM_SOL_SOCKET,PLATFORM_SO_NOSIGPIPE,&enabled,size_of(enabled))
}

local_socket :: proc(domain,kind,protocol:c.int)->posix.FD {
    fd:=platform_socket_raw(domain,kind&~c.int(PLATFORM_SOCK_CLOEXEC|PLATFORM_SOCK_NONBLOCK),protocol)
    if fd<0 {return fd}
    if !platform_fd_flags(fd,kind&PLATFORM_SOCK_CLOEXEC!=0,kind&PLATFORM_SOCK_NONBLOCK!=0) {posix.close(fd);return -1}
    platform_nosigpipe(fd)
    return fd
}
local_accept :: proc(fd:posix.FD,address:rawptr,length:rawptr,flags:c.int)->posix.FD {
    client:=platform_accept_raw(fd,address,length)
    if client<0 {return client}
    // Accepted sockets do not inherit O_NONBLOCK on every BSD; set it explicitly.
    if !platform_fd_flags(client,flags&PLATFORM_SOCK_CLOEXEC!=0,flags&PLATFORM_SOCK_NONBLOCK!=0) {posix.close(client);return -1}
    if flags&PLATFORM_SOCK_NONBLOCK==0 {
        current:=posix.fcntl(client,.GETFL)
        if current>=0 {posix.fcntl(client,.SETFL,current&~c.int(posix.O_NONBLOCK))}
    }
    platform_nosigpipe(client)
    return client
}
file_socketpair :: proc(domain,kind,protocol:c.int,fds:^[2]posix.FD)->c.int {
    if platform_socketpair_raw(domain,kind&~c.int(PLATFORM_SOCK_CLOEXEC|PLATFORM_SOCK_NONBLOCK),protocol,fds)!=0 {return -1}
    for fd in fds^ {
        if !platform_fd_flags(fd,kind&PLATFORM_SOCK_CLOEXEC!=0,kind&PLATFORM_SOCK_NONBLOCK!=0) {
            posix.close(fds[0]);posix.close(fds[1]);return -1
        }
        platform_nosigpipe(fd)
    }
    return 0
}
pty_pipe2 :: proc(fds:^[2]posix.FD,flags:c.int)->c.int {
    if posix.pipe(fds)!=.OK {return -1}
    cloexec:=flags&c.int(posix.O_CLOEXEC)!=0
    nonblock:=flags&c.int(posix.O_NONBLOCK)!=0
    for fd in fds^ {
        if !platform_fd_flags(fd,cloexec,nonblock) {posix.close(fds[0]);posix.close(fds[1]);return -1}
    }
    return 0
}

// An unlinked temporary file gives the same seekable, anonymous storage as a
// Linux memfd. Only a fixed stack template is used, so no allocation occurs.
platform_memfd :: proc(name:cstring)->posix.FD {
    template:[1024]u8
    directory:=string(posix.getenv("TMPDIR"))
    if directory==""||len(directory)>900 {directory="/tmp"}
    used:=copy(template[:],directory)
    if template[used-1]!='/' {template[used]='/';used+=1}
    used+=copy(template[used:],"terminal-plus-XXXXXX")
    template[used]=0
    fd:=platform_mkstemp(raw_data(template[:]))
    if fd<0 {return fd}
    posix.unlink(cstring(raw_data(template[:])))
    posix.fcntl(fd,.SETFD,c.int(posix.FD_CLOEXEC))
    return fd
}

// macOS has no /proc. Resolve once so forked children exec a prepared path.
platform_self_exe_path:string
platform_self_exe :: proc()->string {
    if platform_self_exe_path=="" {
        path,error:=os.get_executable_path(context.allocator)
        if error==nil {platform_self_exe_path=path}
    }
    return platform_self_exe_path
}

platform_peer_uid :: proc(fd:posix.FD)->(uid:posix.uid_t,ok:bool) {
    gid:posix.gid_t
    if platform_getpeereid(fd,&uid,&gid)!=0 {return}
    return uid,true
}

// proc_pidinfo(PROC_PIDVNODEPATHINFO): the current directory's vnode_info
// (152 bytes) precedes its MAXPATHLEN path; the root directory follows.
platform_process_cwd :: proc(pid:posix.pid_t,allocator:=context.temp_allocator)->string {
    info:[2*(152+1024)]u8
    if platform_proc_pidinfo(c.int(pid),9,0,&info,c.int(len(info)))<=0 {return ""}
    path:=string(cstring(&info[152]))
    if path=="" {return ""}
    return strings.clone(path,allocator)
}

platform_socket_address :: proc(path:string)->(address:Local_Session_Address,ok:bool) {
    if len(path)>=len(address.path) {return}
    address.length=u8(size_of(address));address.family=1
    copy(address.path[:],transmute([]u8)path);ok=true;return
}

// macOS libc has no gettext. Untranslated text is returned unchanged.
native_shell_dgettext :: proc(domain,message:cstring)->cstring {return nil}
native_shell_bindtextdomain :: proc(domain,directory:cstring)->cstring {return nil}

// Finder and the Dock start apps with launchd's minimal environment:
// PATH=/usr/bin:/bin:/usr/sbin:/sbin and no locale. Rebuild PATH the way
// path_helper does for login shells (keeping any inherited order first) so
// shells, ssh and FFmpeg find Homebrew tools, and default to a UTF-8 locale.
platform_prepare_environment :: proc() {
    entries:=make([dynamic]string,context.temp_allocator)
    add :: proc(entries:^[dynamic]string,raw:string) {
        entry:=strings.trim_space(raw)
        if entry==""||entry[0]!='/' {return}
        for existing in entries^ {if existing==entry {return}}
        append(entries,entry)
    }
    inherited:=string(posix.getenv("PATH"))
    for entry in strings.split_iterator(&inherited,":") {add(&entries,entry)}
    add(&entries,"/opt/homebrew/bin");add(&entries,"/opt/homebrew/sbin");add(&entries,"/usr/local/bin")
    add_file :: proc(entries:^[dynamic]string,path:string) {
        data,error:=os.read_entire_file(path,context.temp_allocator)
        if error!=nil {return}
        text:=string(data)
        for line in strings.split_lines_iterator(&text) {add(entries,line)}
    }
    add_file(&entries,"/etc/paths")
    if listing,error:=os.read_all_directory_by_path("/etc/paths.d",context.temp_allocator);error==nil {
        names:=make([dynamic]string,context.temp_allocator)
        for info in listing {if info.type!=.Directory {append(&names,info.fullpath)}}
        slice.sort(names[:])
        for name in names {add_file(&entries,name)}
    }
    for fallback in ([]string{"/usr/bin","/bin","/usr/sbin","/sbin"}) {add(&entries,fallback)}
    path:=strings.join(entries[:],":",context.temp_allocator)
    posix.setenv("PATH",strings.clone_to_cstring(path,context.temp_allocator),true)
    if posix.getenv("LANG")==nil&&posix.getenv("LC_ALL")==nil&&posix.getenv("LC_CTYPE")==nil {
        posix.setenv("LANG","en_US.UTF-8",true)
    }
}

// Map Command shortcuts onto the existing Ctrl/Ctrl+Shift bindings: ⌘C/⌘V copy
// and paste, ⌘N new window, ⌘W close, ⌘K clear, ⌘T remote picker, ⌘E/⌘F files;
// ⌘1…9 and ⌘=/⌘-/⌘0 select tabs and zoom. Any other ⌘ key is dropped so it can
// never reach the shell as a control byte (⌘D must not send EOF). Ctrl keeps
// its terminal meaning, and Cocoa never delivers ⌘ combinations as text.
platform_shortcut_mods :: proc(key,mods:c.int)->(c.int,bool) {
    if mods&glfw.MOD_SUPER==0 {return mods,true}
    result:=mods&~c.int(glfw.MOD_SUPER)|glfw.MOD_CONTROL
    switch key {
    case glfw.KEY_0..=glfw.KEY_9,glfw.KEY_EQUAL,glfw.KEY_MINUS,glfw.KEY_KP_0..=glfw.KEY_KP_EQUAL:
        return result,true
    case glfw.KEY_C,glfw.KEY_V,glfw.KEY_N,glfw.KEY_W,glfw.KEY_K,glfw.KEY_T,glfw.KEY_E,glfw.KEY_F,
        glfw.KEY_HOME,glfw.KEY_END,glfw.KEY_PAGE_UP,glfw.KEY_PAGE_DOWN:
        return result|glfw.MOD_SHIFT,true
    }
    return mods,false
}

// macOS poll(2) "does not support devices" (see its BUGS section), which
// includes PTY masters and terminal stdin. Sockets and pipes keep native poll
// and its HUP reporting; a set containing a terminal uses select(2), where a
// hangup appears as readability and the following read returns EOF or EIO.
platform_poll :: proc(fds:[^]posix.pollfd,count:posix.nfds_t,timeout:c.int)->c.int {
    descriptors:=fds[:int(count)]
    terminal:=false
    for &descriptor in descriptors {
        if descriptor.fd<0 {continue}
        if descriptor.fd>=posix.FD_SETSIZE {return posix.poll(fds,count,timeout)}
        if posix.isatty(descriptor.fd) {terminal=true}
    }
    if !terminal {return posix.poll(fds,count,timeout)}
    readable,writable:posix.fd_set
    highest:posix.FD= -1
    for &descriptor in descriptors {
        descriptor.revents={}
        if descriptor.fd<0 {continue}
        if .IN in descriptor.events||.RDNORM in descriptor.events {posix.FD_SET(descriptor.fd,&readable)}
        if .OUT in descriptor.events||.WRNORM in descriptor.events {posix.FD_SET(descriptor.fd,&writable)}
        highest=max(highest,descriptor.fd)
    }
    wait:posix.timeval
    wait_pointer:^posix.timeval
    if timeout>=0 {wait={tv_sec=posix.time_t(timeout/1000),tv_usec=posix.suseconds_t((timeout%1000)*1000)};wait_pointer=&wait}
    result:=posix.select(c.int(highest)+1,&readable,&writable,nil,wait_pointer)
    if result<0 {
        if posix.errno()!=.EBADF {return -1}
        // Report POLLNVAL only for descriptors that are actually closed;
        // native poll would also flag the live terminals in the set.
        invalid:c.int
        for &descriptor in descriptors {
            if descriptor.fd>=0&&posix.fcntl(descriptor.fd,.GETFD)<0 {descriptor.revents={.NVAL};invalid+=1}
        }
        return invalid
    }
    ready:c.int
    for &descriptor in descriptors {
        if descriptor.fd<0 {continue}
        if posix.FD_ISSET(descriptor.fd,&readable) {descriptor.revents+={.IN}}
        if posix.FD_ISSET(descriptor.fd,&writable) {descriptor.revents+={.OUT}}
        if descriptor.revents!={} {ready+=1}
    }
    return ready
}

// launchd starts Finder and Dock launches in "/". Shells would inherit it, so
// start the window process in the home directory as Linux launchers do.
platform_prepare_gui :: proc() {
    if posix.isatty(0) {return}
    buffer:[2]u8
    if posix.getcwd(raw_data(buffer[:]),len(buffer))==nil||buffer[0]!='/'||buffer[1]!=0 {return}
    if home:=posix.getenv("HOME");home!=nil {posix.chdir(home)}
}

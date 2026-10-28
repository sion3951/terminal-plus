package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"
import glfw "vendor:glfw"

// One private tmux server per stable tab ID. User tmux configuration and
// sessions are independent, and ending one tab cannot terminate another tab.
// All interpolated shell values are quoted, even though IDs are validated.
remote_session_command :: proc(id:string,directory:string="")->string {
    if !session_id_valid(id) {return "printf '%s\\n' 'Invalid persistent session ID.' >&2; exit 1"}
    socket:=explorer_quote(strings.concatenate([]string{"minor-terminal-",id},context.temp_allocator))
    shell:=explorer_quote(strings.concatenate([]string{"export COLORTERM=truecolor TERM_PROGRAM=terminal-plus\n",shell_remote_command(directory)},context.temp_allocator))
    return strings.concatenate([]string{REMOTE_SESSION_SETUP,`
minor_tmux() { command tmux -L `,socket,` -f /dev/null "$@"; }
if ! minor_tmux has-session -t '=terminal' 2>/dev/null; then
    # A second attaching client may win the create race. Only fail if neither
    # created the session; never replace an existing running shell.
    # Set TERM before creating the pane so applications retain 256-color
    # support even on tmux builds whose compiled default is plain "screen".
    minor_tmux start-server \; set-option -s default-terminal screen-256color \; new-session -d -s terminal `,shell,` 2>/dev/null || minor_tmux has-session -t '=terminal' || exit 1
fi
minor_tmux set-option -g status off || exit 1
minor_tmux set-option -g prefix None || exit 1
minor_tmux set-option -g prefix2 None || exit 1
minor_tmux set-option -g mouse off || exit 1
minor_tmux set-option -g destroy-unattached off || exit 1
minor_tmux set-option -g set-titles on || exit 1
minor_tmux set-option -g set-titles-string '#{pane_title}' || exit 1
minor_overrides=$(minor_tmux show-options -sv terminal-overrides) || exit 1
case "$minor_overrides" in
    *xterm-256color:Tc*) ;;
    *) minor_tmux set-option -as terminal-overrides ',xterm-256color:Tc' || exit 1 ;;
esac
# Before 3.3, passthrough was allowed without this option.
minor_tmux set-window-option -g allow-passthrough on 2>/dev/null || :
minor_tmux set-window-option -g xterm-keys on || exit 1
# Prompt OSC metadata emitted before a client attached was not forwarded.
# Read the live pane directory on every attach, without injecting shell input.
minor_path=$(minor_tmux display-message -p -t 'terminal:0.0' '#{pane_current_path}'; printf x)
minor_path=${minor_path%x}
minor_path=${minor_path%?}
if [ -n "$minor_path" ]; then
    minor_hex=$(printf '%s' "$minor_path" | od -An -tx1 | tr -d ' \n')
    printf '\033]777;minor-cwd;%s\007' "$minor_hex"
fi
# Exec removes the remote command wrapper; SSH loss only detaches this client.
exec tmux -L `,socket,` -f /dev/null attach-session -d -t '=terminal'
`},context.temp_allocator)
}

// Run through a separate SSH channel before disposing the attached PTY. The
// private server only owns this tab's session, so kill-server is unambiguous.
pty_remote_end_command :: proc(id:string)->string {
    if !session_id_valid(id) {return "exit 1"}
    socket:=explorer_quote(strings.concatenate([]string{"minor-terminal-",id},context.temp_allocator))
    return strings.concatenate([]string{"if command -v tmux >/dev/null 2>&1 && command tmux -L ",socket," -f /dev/null has-session -t '=terminal' 2>/dev/null; then command tmux -L ",socket," -f /dev/null kill-server; else exit 0; fi"},context.temp_allocator)
}

Remote_Session_End :: struct {
    worker:^thread.Thread,
    mutex:sync.Mutex,
    arguments:[]cstring,
    stopping,done,success:bool,
}

remote_session_end_start :: proc(profile:Device_Profile)->^Remote_Session_End {
    target,parsed_port,error:=device_target_parse(profile.target)
    if error!=""||parsed_port!=0||target!=profile.target||!session_id_valid(profile.control_id) {return nil}
    arguments:=make([dynamic]string,context.temp_allocator)
    append(&arguments,"ssh","-T","-o","ControlMaster=no","-o","BatchMode=yes","-o","ConnectTimeout=5","-o","ConnectionAttempts=1","-o","ServerAliveInterval=2","-o","ServerAliveCountMax=2","-o","PermitLocalCommand=no","-o","RemoteCommand=none","-o","ClearAllForwardings=yes")
    control:=ssh_control_path(profile)
    info,stat_error:=os.lstat(control,context.temp_allocator)
    if control!=""&&stat_error==nil&&info.type==.Socket {
        // Reuse the already authenticated connection and prohibit a silent
        // network fallback if that master disappears during the close.
        append(&arguments,"-S",control,"-o","ProxyCommand=false")
    } else {
        // A detached session may outlive this app's old control socket. Reuse
        // the normal host/key/jump configuration, without interactive prompts.
        append(&arguments,"-S","none")
    }
    if profile.port>0 {append(&arguments,"-p",fmt.tprintf("%d",profile.port))}
    append(&arguments,"--",profile.target,pty_remote_end_command(profile.control_id))
    state:=new(Remote_Session_End)
    state.arguments=make([]cstring,len(arguments)+1)
    for argument,i in arguments {state.arguments[i]=strings.clone_to_cstring(argument)}
    state.worker=thread.create(remote_session_end_worker)
    if state.worker==nil {remote_session_end_destroy(state);return nil}
    state.worker.data=state;thread.start(state.worker)
    return state
}

remote_session_end_worker :: proc(worker:^thread.Thread) {
    state:=cast(^Remote_Session_End)worker.data
    success:=false
    defer {
        sync.mutex_lock(&state.mutex)
        state.success=success;state.done=true
        sync.mutex_unlock(&state.mutex)
        glfw.PostEmptyEvent()
    }
    null:=posix.open("/dev/null",{.RDWR,.CLOEXEC})
    if null<0 {return}
    argv:=raw_data(state.arguments);env:=posix.environ
    pid:=posix.fork()
    if pid==0 {
        // Prepared argv and async-signal-safe libc calls only after fork.
        posix.setsid()
        posix.dup2(null,0);posix.dup2(null,1);posix.dup2(null,2)
        if null>2 {posix.close(null)}
        posix.execve("/usr/bin/ssh",argv,env);posix._exit(127)
    }
    posix.close(null)
    if pid<0 {return}
    began:=time.tick_now()
    status:c.int
    for {
        result:=posix.waitpid(pid,&status,{.NOHANG})
        if result==pid {success=posix.WIFEXITED(status)&&posix.WEXITSTATUS(status)==0;return}
        if result<0&&posix.errno()!=.EINTR {return}
        sync.mutex_lock(&state.mutex);stopping:=state.stopping;sync.mutex_unlock(&state.mutex)
        if stopping||time.duration_seconds(time.tick_diff(began,time.tick_now()))>=7 {
            // Also reap any SSH proxy helpers spawned by the close channel.
            posix.kill(-pid,.SIGKILL);posix.kill(pid,.SIGKILL)
            for posix.waitpid(pid,&status,{})<0&&posix.errno()==.EINTR {}
            return
        }
        time.sleep(10*time.Millisecond)
    }
}

remote_session_end_poll :: proc(state:^Remote_Session_End)->(done,success:bool) {
    if state==nil {return true,false}
    sync.mutex_lock(&state.mutex);defer sync.mutex_unlock(&state.mutex)
    return state.done,state.success
}

remote_session_end_destroy :: proc(state:^Remote_Session_End) {
    if state==nil {return}
    sync.mutex_lock(&state.mutex);state.stopping=true;sync.mutex_unlock(&state.mutex)
    if state.worker!=nil {thread.join(state.worker);thread.destroy(state.worker)}
    for argument in state.arguments {if argument!=nil {delete(argument)}}
    delete(state.arguments);free(state)
}

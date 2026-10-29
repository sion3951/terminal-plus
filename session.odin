package main

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"
import glfw "vendor:glfw"

Session_Record :: struct {
    id,name,target,path:string,
    port:u16,
    remote:bool,
    session_owned:bool `json:"session_owned,omitempty"`,
    files:bool `json:"files,omitempty"`,
    source:string `json:"source,omitempty"`,
    document:string `json:"document,omitempty"`,
    label:string `json:"label,omitempty"`,
    group:u64 `json:"group,omitempty"`,
    group_label:string `json:"group_label,omitempty"`,
    groups:[]Tab_Group_Ref `json:"groups,omitempty"`,
}
Session_Window :: struct {
    tabs:[]Session_Record,
    active:int,
    explorer_visible:bool,
    explorer_width:f32,
    explorer_width_custom:bool,
    font_index:int,
    // Read legacy window positions for session compatibility; Wayland places windows.
    x:int `json:"x,omitempty"`,
    y:int `json:"y,omitempty"`,
    width,height:int,
    maximized:bool,
}
Session_State :: struct {
    version:int,
    windows:[]Session_Window,
    focused_window:int,
    // Version 1 fields are read for migration and omitted in new manifests.
    tabs:[]Session_Record `json:"tabs,omitempty"`,
    active:int `json:"active,omitempty"`,
    explorer_visible:bool `json:"explorer_visible,omitempty"`,
    explorer_width:f32 `json:"explorer_width,omitempty"`,
    explorer_width_custom:bool `json:"explorer_width_custom,omitempty"`,
}
SESSION_VERSION :: 5
SESSION_FILE_LIMIT :: 2*1024*1024
Session_Writer :: struct {
    mutex:sync.Mutex,
    cond:sync.Cond,
    worker:^thread.Thread,
    path:string,
    pending:[]u8,
    changed:time.Tick,
    stopping:bool,
}
session_writer:^Session_Writer
session_error_mutex:sync.Mutex
session_error_buffer:[256]u8
session_error_length:int

session_error_set :: proc(message:string) {
    sync.mutex_lock(&session_error_mutex)
    session_error_length=copy(session_error_buffer[:],transmute([]u8)message)
    sync.mutex_unlock(&session_error_mutex)
}
session_status_error :: proc()->string {
    sync.mutex_lock(&session_error_mutex);defer sync.mutex_unlock(&session_error_mutex)
    return strings.clone(string(session_error_buffer[:session_error_length]),context.temp_allocator)
}
session_path :: proc()->string {
    root,error:=os.user_config_dir(context.temp_allocator)
    if error!=nil||root=="" {return ""}
    path,_:=filepath.join([]string{root,"minor-terminal","session.json"},context.temp_allocator)
    return path
}
session_id_valid :: proc(id:string)->bool {
    if len(id)!=32 {return false}
    for ch in id {if !((ch>='0'&&ch<='9')||(ch>='a'&&ch<='f')) {return false}}
    return true
}
session_new_id :: proc()->string {
    random:[16]u8;crypto.rand_bytes(random[:])
    encoded:[32]u8
    digits:="0123456789abcdef"
    for b,i in random {encoded[i*2]=digits[int(b>>4)];encoded[i*2+1]=digits[int(b&15)]}
    return strings.clone(string(encoded[:]))
}
session_state_destroy :: proc(state:^Session_State) {
    for &record in state.tabs {session_record_destroy(&record)}
    delete(state.tabs)
    for window in state.windows {
        for &record in window.tabs {session_record_destroy(&record)}
        delete(window.tabs)
    }
    delete(state.windows);state^={}
}
session_record_destroy :: proc(record:^Session_Record) {
    delete(record.id);delete(record.name);delete(record.target);delete(record.path);delete(record.source);delete(record.document);delete(record.label);delete(record.group_label)
    for group in record.groups {delete(group.label)};delete(record.groups)
}
session_window_validate :: proc(window:Session_Window,ids:^map[string]bool)->bool {
    if len(window.tabs)>MAX_TABS||window.active<0||(len(window.tabs)>0&&window.active>=len(window.tabs)) {return false}
    if !(window.explorer_width>=180&&window.explorer_width<=2000) {return false}
    if window.font_index<0||window.font_index>=len(FONT_SIZES) {return false}
    if window.width<440||window.width>16384||window.height<200||window.height>16384 {return false}
    if window.x< -1000000||window.x>1000000||window.y< -1000000||window.y>1000000 {return false}
    parents:=make(map[u64]u64,context.temp_allocator)
    labels:=make(map[u64]string,context.temp_allocator)
    for record in window.tabs {
        if !session_id_valid(record.id)||len(record.name)==0||len(record.name)>512||len(record.path)>65536||strings.contains_any(record.name,"\r\n\x00")||strings.contains(record.path,"\x00") {return false}
        if ids^[record.id] {return false};ids^[record.id]=true
        if record.files&&(!session_id_valid(record.source)||record.source==record.id) {return false}
        if !record.files&&record.source!="" {return false}
        if record.document!=""&&(!record.files||len(record.document)>65536||strings.contains(record.document,"\x00")||document_kind(record.document)==.None) {return false}
        if len(record.label)>512||strings.contains_any(record.label,"\r\n\x00") {return false}
        if len(record.group_label)>512||strings.contains_any(record.group_label,"\r\n\x00") {return false}
        if record.group==0&&record.group_label!="" {return false}
        if len(record.groups)>0&&record.group!=0 {return false}
        path:=record.groups
        legacy:=[1]Tab_Group_Ref{{id=record.group,label=record.group_label}}
        if record.group!=0 {path=legacy[:]}
        seen:=make(map[u64]bool,context.temp_allocator)
        parent:u64
        for group in path {
            if group.id==0||seen[group.id]||len(group.label)>512||strings.contains_any(group.label,"\r\n\x00") {return false}
            seen[group.id]=true
            if previous,exists:=parents[group.id];exists {
                if previous!=parent||labels[group.id]!=group.label {return false}
            } else {parents[group.id]=parent;labels[group.id]=group.label}
            parent=group.id
        }
        if record.remote {
            target,port,error:=device_target_parse(record.target)
            if error!=""||port!=0||target!=record.target {return false}
        } else if record.target!=""||record.port!=0 {return false}
    }
    return true
}
session_validate :: proc(state:Session_State)->bool {
    ids:=make(map[string]bool,context.temp_allocator)
    if state.version==1 {
        return session_window_validate(Session_Window{tabs=state.tabs,active=state.active,explorer_visible=state.explorer_visible,explorer_width=state.explorer_width,explorer_width_custom=state.explorer_width_custom,font_index=4,width=1200,height=800},&ids)
    }
    if state.version<2||state.version>SESSION_VERSION||state.focused_window<0||(len(state.windows)>0&&state.focused_window>=len(state.windows)) {return false}
    for window in state.windows {if !session_window_validate(window,&ids) {return false}}
    return true
}
session_clone_tabs :: proc(tabs:[]Session_Record)->[]Session_Record {
    result:=make([]Session_Record,len(tabs))
    for record,i in tabs {
        result[i]=record
        result[i].id=strings.clone(record.id);result[i].name=strings.clone(record.name)
        result[i].target=strings.clone(record.target);result[i].path=strings.clone(record.path)
        result[i].source=strings.clone(record.source)
        result[i].document=strings.clone(record.document)
        result[i].label=strings.clone(record.label)
        result[i].group_label=strings.clone(record.group_label)
        result[i].groups=make([]Tab_Group_Ref,len(record.groups))
        for group,j in record.groups {result[i].groups[j]={id=group.id,label=strings.clone(group.label)}}
    }
    return result
}
session_load :: proc()->(state:Session_State,found:bool) {
    path:=session_path()
    if path=="" {session_error_set("Cannot locate session settings.");return}
    file,error:=os.open(path)
    if error!=nil {
        if error!=.Not_Exist {session_error_set("Cannot read saved tabs; existing settings were left intact.")}
        return
    }
    defer os.close(file)
    info,stat_error:=os.fstat(file,context.temp_allocator)
    if stat_error!=nil||info.type!=.Regular||info.size<=0||info.size>SESSION_FILE_LIMIT {session_error_set("Saved tabs are invalid; existing settings were left intact.");return}
    bytes:=make([]u8,int(info.size),context.temp_allocator)
    used:=0
    for used<len(bytes) {
        amount,read_error:=os.read(file,bytes[used:])
        if read_error!=nil||amount<=0 {session_error_set("Cannot read saved tabs; existing settings were left intact.");return}
        used+=amount
    }
    parsed:Session_State
    if json.unmarshal(bytes,&parsed,allocator=context.temp_allocator)!=nil||!session_validate(parsed) {
        session_error_set("Saved tabs are invalid; existing settings were left intact.")
        return
    }
    state.version=SESSION_VERSION;state.focused_window=parsed.focused_window
    if parsed.version==1 {
        state.windows=make([]Session_Window,1)
        state.windows[0]=Session_Window{tabs=session_clone_tabs(parsed.tabs),active=parsed.active,explorer_visible=parsed.explorer_visible,explorer_width=parsed.explorer_width,explorer_width_custom=parsed.explorer_width_custom,font_index=4,width=1200,height=800}
    } else {
        state.windows=make([]Session_Window,len(parsed.windows))
        for window,i in parsed.windows {state.windows[i]=window;state.windows[i].tabs=session_clone_tabs(window.tabs)}
    }
    return state,true
}

session_write_bytes :: proc(path:string,bytes:[]u8)->bool {
    directory:=filepath.dir(path)
    error:=os.mkdir_all(directory,{.Read_User,.Write_User,.Execute_User})
    if error!=nil&&error!=.Exist {return false}
    directory_c:=strings.clone_to_cstring(directory,context.temp_allocator)
    if posix.chmod(directory_c,{.IRUSR,.IWUSR,.IXUSR})!=nil {return false}
    temporary:=fmt.tprintf("%s.tmp-%d-%d",path,os.get_pid(),time.tick_now()._nsec)
    file,open_error:=os.open(temporary,{.Write,.Create,.Excl},{.Read_User,.Write_User})
    if open_error!=nil {return false}
    committed:=false
    defer {if !committed {os.remove(temporary)}}
    offset:=0
    for offset<len(bytes) {
        amount,write_error:=os.write(file,bytes[offset:])
        if write_error!=nil||amount<=0 {os.close(file);return false}
        offset+=amount
    }
    sync_error:=os.sync(file);close_error:=os.close(file)
    if sync_error!=nil||close_error!=nil||os.rename(temporary,path)!=nil {return false}
    committed=true
    // Persist the rename as well as the manifest contents across a reboot.
    fd:=posix.open(directory_c,{.DIRECTORY,.CLOEXEC})
    if fd<0 {return false}
    result:=posix.fsync(fd);posix.close(fd)
    return result==nil
}
session_writer_proc :: proc(worker:^thread.Thread) {
    writer:=cast(^Session_Writer)worker.data
    for {
        sync.mutex_lock(&writer.mutex)
        for !writer.stopping&&writer.pending==nil {sync.cond_wait(&writer.cond,&writer.mutex)}
        if writer.stopping&&writer.pending==nil {sync.mutex_unlock(&writer.mutex);break}
        for !writer.stopping {
            elapsed:=time.duration_seconds(time.tick_diff(writer.changed,time.tick_now()))
            if elapsed>=0.3 {break}
            sync.cond_wait_with_timeout(&writer.cond,&writer.mutex,time.Duration((0.3-elapsed)*f64(time.Second)))
        }
        bytes:=writer.pending;writer.pending=nil
        sync.mutex_unlock(&writer.mutex)
        if session_write_bytes(writer.path,bytes) {session_error_set("")}
        else {session_error_set("Could not save tabs. Check session storage permissions and free space.");fmt.eprintln("Could not save terminal session settings.")}
        delete(bytes);free_all(context.temp_allocator)
    }
}
session_writer_init :: proc()->bool {
    if session_writer!=nil {return true}
    path:=session_path()
    if path=="" {session_error_set("Cannot locate session settings.");return false}
    writer:=new(Session_Writer);writer.path=strings.clone(path)
    writer.worker=thread.create(session_writer_proc)
    if writer.worker==nil {delete(writer.path);free(writer);session_error_set("Cannot start session settings writer.");return false}
    writer.worker.data=writer;session_writer=writer;thread.start(writer.worker)
    return true
}
session_window_destroy :: proc(window:Session_Window) {
    for record in window.tabs {copy:=record;session_record_destroy(&copy)}
    delete(window.tabs)
}
session_capture_window :: proc(window:^App,own:bool=false)->Session_Window {
    saved:=Session_Window{active=window.active,explorer_width=window.explorer_width,explorer_width_custom=window.explorer_width_custom,font_index=window.font_index}
    width,height:=glfw.GetWindowSize(window.renderer.window)
    saved.width=max(440,int(width));saved.height=max(200,int(height))
    saved.maximized=glfw.GetWindowAttrib(window.renderer.window,glfw.MAXIMIZED)!=0
    saved.tabs=make([]Session_Record,len(window.tabs),context.temp_allocator)
    for tab,j in window.tabs {
        path:=tab.restore_path
        if tab.files {
            path=tab.explorer.listing.path
            if !tab.explorer.loaded&&tab.explorer.waiting {path=tab.explorer.requested_directory}
            else if path=="" {path=tab.restore_path}
        } else if !tab.remote&&tab.started&&!tab.exited&&tab.pty.pid>0 {
            // Read the shell's actual cwd as a final close/save safeguard,
            // including output whose prompt metadata is still in the PTY.
            current,error:=os.read_link(fmt.tprintf("/proc/%d/cwd",tab.pty.pid),context.temp_allocator)
            if error==nil&&strings.has_prefix(current,"/") {path=current}
        }
        saved.tabs[j]=Session_Record{id=tab.session_id,name=tab.device.name,target=tab.device.target,path=path,port=tab.device.port,remote=tab.remote,session_owned=tab.session_owned,files=tab.files,source=tab.source_id,document=tab.document_path,label=tab.label,groups=tab_group_copy_path(tab)}
    }
    if own {saved.tabs=session_clone_tabs(saved.tabs)}
    return saved
}

session_schedule :: proc(a:^App)->bool {
    writer:=session_writer
    if writer==nil {return false}
    state:=Session_State{version=SESSION_VERSION}
    state.windows=make([]Session_Window,len(workspace_windows)+len(workspace_detached),context.temp_allocator)
    for window,i in workspace_windows {
        state.windows[i]=session_capture_window(window)
        if window==workspace_focused {state.focused_window=i}
    }
    for window,i in workspace_detached {state.windows[len(workspace_windows)+i]=window}
    if !session_validate(state) {session_error_set("Cannot save invalid tab state.");return false}
    bytes,error:=json.marshal(state,{pretty=true},context.allocator)
    if error!=nil||len(bytes)>SESSION_FILE_LIMIT {delete(bytes);session_error_set("Cannot encode session settings.");return false}
    sync.mutex_lock(&writer.mutex)
    if writer.stopping {sync.mutex_unlock(&writer.mutex);delete(bytes);return false}
    delete(writer.pending);writer.pending=bytes;writer.changed=time.tick_now()
    sync.mutex_unlock(&writer.mutex);sync.cond_signal(&writer.cond)
    workspace_dirty=false
    for window in workspace_windows {window.session_dirty=false}
    return true
}
session_writer_destroy :: proc() {
    writer:=session_writer;if writer==nil {return}
    sync.mutex_lock(&writer.mutex);writer.stopping=true;sync.mutex_unlock(&writer.mutex);sync.cond_signal(&writer.cond)
    thread.join(writer.worker);thread.destroy(writer.worker)
    delete(writer.pending);delete(writer.path);free(writer);session_writer=nil
}

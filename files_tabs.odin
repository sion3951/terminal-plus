package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import glfw "vendor:glfw"

tab_title :: proc(tab:^Tab)->string {
    if tab.label!="" {return tab.label}
    if tab.document_path!="" {return filepath.base(tab.document_path)}
    if !tab.files {return tab.device.name}
    if tab.remote {return fmt.tprintf("Files: %s",tab.device.name)}
    return "Files"
}

app_sync_tab_view :: proc(a:^App) {
    tab:=active_tab(a)
    if a.tab_rename.tab!=tab {tab_rename_finish(a,true)}
    a.explorer_visible=tab!=nil&&tab.files
    a.explorer_focus=a.explorer_visible
    a.selected=false;a.selecting=false;a.dirty=true
}

// Files owns its browsing state, with no extra shell or scrollback archive.
// The source session ID stays valid when tabs are reordered or moved.
app_new_files_tab :: proc(a:^App,profile:Device_Profile,remote:bool,source_id,path:string,session_id:string="")->int {
    if len(a.tabs)>=MAX_TABS {return -1}
    tab:=new(Tab)
    tab.files=true;tab.remote=remote;tab.device=profile_clone(profile)
    tab.source_id=strings.clone(source_id);tab.restore_path=strings.clone(path)
    tab.session_id=session_new_id()
    if session_id!="" {delete(tab.session_id);tab.session_id=strings.clone(session_id)}
    tab.device.control_id=tab.source_id
    a.next_number+=1;tab.number=a.next_number
    append(&a.tabs,tab);session_touch(a);a.dirty=true
    return len(a.tabs)-1
}

document_open_tab :: proc(a:^App,source:^Tab,path:string)->bool {
    source_id:=source.session_id;if source.files {source_id=source.source_id}
    index:=app_new_files_tab(a,source.device,source.remote,source_id,filepath.dir(path))
    if index<0 {
        if source.files {explorer_set_error(&source.explorer,"Close a tab before opening a document.")}
        else {delete(source.input_error);source.input_error=strings.clone("Close a tab before opening a document.")}
        a.dirty=true;return false
    }
    a.tabs[index].document_path=strings.clone(path)
    app_select_device(a,index)
    return true
}

explorer_open_tab :: proc(a:^App)->bool {
    source:=active_tab(a);if source==nil {return false}
    source_id:=source.session_id;if source.files {source_id=source.source_id}
    path:=source.explorer.listing.path
    if path=="" {path=source.restore_path}
    index:=app_new_files_tab(a,source.device,source.remote,source_id,path)
    if index<0 {a.menu.error="Close a tab before opening Files.";a.menu.open=true;a.dirty=true;return false}
    app_select_device(a,index)
    return true
}

explorer_find_terminal :: proc(files:^Tab)->(owner:^App,source:^Tab,index:int) {
    if files==nil||!files.files {return nil,nil,-1}
    for window in workspace_windows {
        for tab,i in window.tabs {
            if !tab.files&&tab.session_id==files.source_id {return window,tab,i}
        }
    }
    return nil,nil,-1
}

explorer_return_terminal :: proc(a:^App)->^App {
    files:=active_tab(a);if files==nil||!files.files {return a}
    owner,source,index:=explorer_find_terminal(files)
    if source==nil {
        // Closing a terminal does not close its Files tab. Reopen that session
        // only when the user explicitly returns to it.
        owner=a
        if files.remote {index=app_device_tab(a,files.device,files.source_id)}
        else if app_new_tab(a,"",files.source_id) {index=len(a.tabs)-1}
        if index<0 {explorer_set_error(&files.explorer,"Close a tab before reopening the terminal.");a.dirty=true;return nil}
    }
    app_select_device(owner,index)
    if owner!=a {glfw.FocusWindow(owner.renderer.window);workspace_focused=owner}
    return owner
}

explorer_set_visible :: proc(a:^App,visible:bool) {
    source:=active_tab(a);if source==nil {return}
    if !visible {explorer_return_terminal(a);return}
    if source.files {return}
    for tab,index in a.tabs {
        if tab.files&&tab.document_path==""&&tab.source_id==source.session_id {app_select_device(a,index);return}
    }
    explorer_open_tab(a)
}

explorer_toggle :: proc(a:^App) {explorer_set_visible(a,!a.explorer_visible)}

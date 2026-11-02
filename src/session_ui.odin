package main

import "core:strings"
import glfw "vendor:glfw"

session_touch :: proc(a:^App) {
    if a.session_loading||workspace_loading {return}
    a.session_dirty=true;a.session_save_allowed=true
    workspace_dirty=true;workspace_save_allowed=true
}

session_restore_window :: proc(a:^App,saved:Session_Window,command:string)->bool {
    a.explorer_width=clamp(saved.explorer_width,180,800)
    a.explorer_width_custom=saved.explorer_width_custom
    a.font_index=clamp(saved.font_index,0,len(FONT_SIZES)-1)
    if saved.maximized {glfw.MaximizeWindow(a.renderer.window)}
    app_metrics(a)
    command_used:=false
    for record in saved.tabs {
        index:= -1
        if record.files {
            index=app_new_files_tab(a,Device_Profile{name=record.name,target=record.target,port=record.port},record.remote,record.source,record.path,record.id)
        } else if record.remote {
            index=app_device_tab(a,Device_Profile{name=record.name,target=record.target,port=record.port},record.id)
        } else {
            shell_command:=""
            if !command_used {shell_command=command;command_used=true}
            if app_new_tab(a,shell_command,record.id,record.path) {index=len(a.tabs)-1}
        }
        if index<0 {return false}
        a.tabs[index].session_owned=record.session_owned
        a.tabs[index].document_path=strings.clone(record.document)
        a.tabs[index].label=strings.clone(record.label)
        if len(record.groups)>0 {tab_set_path(a.tabs[index],record.groups)}
        else {tab_set_group(a.tabs[index],record.group,record.group_label)}
        if record.remote&&!record.files {a.tabs[index].restore_path=strings.clone(record.path)}
    }
    if len(a.tabs)==0 {if !app_new_tab(a,command) {return false}}
    a.active=clamp(saved.active,0,len(a.tabs)-1)
    tab_groups_pack(a)
    if command!="" {
        local:= -1
        for tab,index in a.tabs {if !tab.files&&!tab.remote {local=index;break}}
        if local<0 {if !app_new_tab(a,command) {return false};local=len(a.tabs)-1}
        a.active=local
    }
    // Migrate the old full-window explorer into its own tab beside its shell.
    if saved.explorer_visible&&command=="" {explorer_open_tab(a)}
    app_sync_tab_view(a)
    return true
}

workspace_restore_session :: proc(command:string)->bool {
    workspace_loading=true
    defer {workspace_loading=false}
    saved,found:=session_load()
    defer session_state_destroy(&saved)
    workspace_save_allowed=found||session_status_error()==""
    if found&&len(saved.windows)>0 {
        for window in saved.windows {
            a:=workspace_create_window(window.width,window.height)
            if a==nil {return false}
            if !session_restore_window(a,window,"") {return false}
        }
        workspace_focused=workspace_windows[clamp(saved.focused_window,0,len(workspace_windows)-1)]
        if command!="" {
            // A command-line invocation starts a new session; attaching an
            // existing live shell must neither replace it nor ignore -e.
            target:=workspace_windows[0]
            if len(target.tabs)>=MAX_TABS {
                width,height:=glfw.GetWindowSize(target.renderer.window)
                target=workspace_create_window(int(width),int(height),target)
                if target==nil {return false}
            }
            if !app_new_tab(target,command) {return false}
            workspace_focused=target
        }
    } else {
        a:=workspace_create_window(1200,800)
        if a==nil||!app_new_tab(a,command) {return false}
        for profile in a.profiles {if profile.configured||profile.saved {app_device_tab(a,profile)}}
        workspace_focused=a
    }
    for a in workspace_windows {
        // All source terminals exist now, including those in another window.
        app_select_device(a,a.active)
        a.session_loading=false;a.session_save_allowed=workspace_save_allowed
        a.session_dirty=workspace_save_allowed
    }
    workspace_dirty=workspace_save_allowed
    return true
}

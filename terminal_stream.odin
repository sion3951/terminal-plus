package main

import "core:time"
import "core:strings"

app_process_input :: proc(a:^App) {
    a.input_delay=60
    for tab in a.tabs {
        if tab.files {continue}
        if tab.input_offset==len(tab.pending_input) {continue}
        if !pty_alive(&tab.pty) {
            delete(tab.pending_input);tab.pending_input=nil;tab.input_offset=0
            delete(tab.input_error);tab.input_error=strings.clone("Queued input was cancelled: the session ended.");a.dirty=true;continue
        }
        for _ in 0..<2 {
            end:=min(len(tab.pending_input),tab.input_offset+32768)
            if !pty_write(&tab.pty,tab.pending_input[tab.input_offset:end]) {a.input_delay=min(a.input_delay,0.01);break}
            tab.input_offset=end
            if end==len(tab.pending_input) {
                delete(tab.pending_input);tab.pending_input=nil;tab.input_offset=0;a.dirty=true;break
            }
            a.input_delay=min(a.input_delay,0.001)
        }
    }
}

// Parsing and archival admission are bounded per UI turn. PTY backpressure and
// a retained byte offset keep arbitrarily large output intact between turns.
app_process_output :: proc(a:^App,hold_local:bool,budget:f64=0.006) {
    for index:=len(a.tabs)-1;index>=0;index-=1 {
        tab:=a.tabs[index]
        if tab.remote_end==nil {continue}
        done,success:=remote_session_end_poll(tab.remote_end)
        if !done {continue}
        remote_session_end_destroy(tab.remote_end);tab.remote_end=nil
        if success {app_finish_close_tab(a,index)}
        else {delete(tab.input_error);tab.input_error=strings.clone("Could not end the remote session. Reconnect and try closing the tab again.");a.dirty=true}
    }
    a.output_work=false
    count:=len(a.tabs)
    if count==0 {return}
    start:=a.output_next%count
    began:=time.tick_now()
    visited:=0
    for visited<count {
        index:=(start+visited)%count;tab:=a.tabs[index];visited+=1
        if tab.files {continue}
        if terminal_history_poll(&tab.terminal)&&index==a.active {a.dirty=true}
        error:=terminal_history_error(&tab.terminal)
        if error!=tab.history_error_seen {
            delete(tab.history_error_seen);tab.history_error_seen=strings.clone(error)
            if index==a.active {a.dirty=true}
        }
        if !tab.started||tab.exited {continue}
        if tab.pty.persistent {
            generation:=tab.terminal.history_generation
            if local_session_poll(&tab.pty,&tab.terminal,&tab.output,&tab.output_offset) {
                app_terminal_directory(a,tab)
                if tab.scroll>0 {tab.scroll+=int(tab.terminal.history_generation-generation)}
                tab.scroll=min(tab.scroll,terminal_history_count(&tab.terminal))
                if index==a.active {a.dirty=true;if tab.pty.session_state.screen_changed {a.selected=false}}
                else if tab.pty.session_state.screen_changed&&!tab.unread {tab.unread=true;a.dirty=true}
            }
            if local_session_pending(&tab.pty) {a.output_work=true}
            if !pty_alive(&tab.pty)&&!local_session_pending(&tab.pty) {
                if local_session_ended(&tab.pty) {tab.output_eof=true}
                else {
                    tab.exited=true
                    delete(tab.input_error);tab.input_error=strings.clone("Session connection lost. Press Enter to reattach.");a.dirty=true
                }
            }
            continue
        }
        processed:=0
        for processed<65536 {
            if len(tab.terminal.replies)>0 {
                if pty_alive(&tab.pty)&&!pty_write(&tab.pty,tab.terminal.replies[:]) {a.input_delay=min(a.input_delay,0.01);break}
                clear(&tab.terminal.replies)
            }
            if tab.output_offset==len(tab.output) {
                clear(&tab.output);tab.output_offset=0
                if !pty_drain(&tab.pty,&tab.output) {
                    if !pty_alive(&tab.pty) {
                        // The final bytes may have arrived between drain and EOF.
                        if !pty_drain(&tab.pty,&tab.output) {tab.output_eof=true}
                    }
                    if len(tab.output)==0 {break}
                }
            }
            end:=min(len(tab.output),tab.output_offset+16384)
            generation:=tab.terminal.history_generation
            used:=terminal_feed(&tab.terminal,tab.output[tab.output_offset:end])
            if used==0 {break} // Archive worker will wake us when storage has room.
            app_terminal_directory(a,tab)
            tab.output_offset+=used;processed+=used
            if tab.scroll>0 {tab.scroll+=int(tab.terminal.history_generation-generation)}
            tab.scroll=min(tab.scroll,terminal_history_count(&tab.terminal))
            if index==a.active {a.dirty=true;a.selected=false}
            else if !tab.unread {tab.unread=true;a.dirty=true}
            if time.duration_seconds(time.tick_diff(began,time.tick_now()))>=budget {break}
        }
        if processed>0&&tab.output_offset<len(tab.output) {a.output_work=true}
        if time.duration_seconds(time.tick_diff(began,time.tick_now()))>=budget {
            a.output_work=true
            break
        }
    }
    a.output_next=(start+visited)%count
    // Defer removals until the round-robin pass is complete.
    for index:=len(a.tabs)-1;index>=0;index-=1 {
        tab:=a.tabs[index]
        if !tab.started||tab.exited||!tab.output_eof {continue}
        if tab.remote {
            if !tab.end_notice {
                tab.end_notice=true;tab.output_eof=false;tab.output_offset=0;clear(&tab.output)
                append(&tab.output,"\x1b[?1049l\x1b[?25h\x1b[?2004l\x1b[0m\r\nSSH session ended. Press Enter or select this device to reconnect.\r\n")
                tab.terminal.application_cursor=false;a.output_work=true
                continue
            }
            pty_destroy(&tab.pty);tab.exited=true;a.dirty=true
        } else if !hold_local {app_close_tab(a,index)}
    }
    app_shell_documents(a)
}

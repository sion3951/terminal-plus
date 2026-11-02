package main

import "core:c"
import "core:fmt"
import glfw "vendor:glfw"

app_zoom :: proc(a:^App,steps:int=0,reset:bool=false) {
    previous:=a.font_index
    if reset {a.font_index=4} else {a.font_index=clamp(a.font_index+steps,0,len(FONT_SIZES)-1)}
    if a.font_index!=previous {a.selected=false;a.dirty=true;session_touch(a)}
}

app_zoom_key :: proc(a:^App,key,mods:c.int)->bool {
    if mods&glfw.MOD_CONTROL==0||mods&glfw.MOD_ALT!=0 {return false}
    switch key {
    case glfw.KEY_EQUAL,glfw.KEY_KP_ADD,glfw.KEY_KP_EQUAL:app_zoom(a,1)
    case glfw.KEY_MINUS,glfw.KEY_KP_SUBTRACT:app_zoom(a,-1)
    case glfw.KEY_0,glfw.KEY_KP_0:app_zoom(a,reset=true)
    case:return false
    }
    return true
}

// xterm modifier parameters retain Ctrl/Shift/Alt for editors and SSH apps.
// In particular Delete must not collapse Ctrl+Delete into an ordinary Delete.
terminal_key_sequence :: proc(key,mods:c.int,application_cursor:bool)->string {
    ctrl:=mods&glfw.MOD_CONTROL!=0;shift:=mods&glfw.MOD_SHIFT!=0;alt:=mods&glfw.MOD_ALT!=0
    modifier:=1;if shift {modifier+=1};if alt {modifier+=2};if ctrl {modifier+=4}
    final:u8
    tilde:=0
    function:u8
    sequence:string
    switch key {
    case glfw.KEY_ENTER,glfw.KEY_KP_ENTER:sequence="\r"
    case glfw.KEY_BACKSPACE:
        if ctrl {return "\x1b\x7f"} // Readline's backward-kill-word, also over SSH.
        sequence="\x7f"
    case glfw.KEY_TAB:if shift {return "\x1b[Z"} else {sequence="\t"}
    case glfw.KEY_ESCAPE:sequence="\x1b"
    case glfw.KEY_UP:final='A'
    case glfw.KEY_DOWN:final='B'
    case glfw.KEY_RIGHT:final='C'
    case glfw.KEY_LEFT:final='D'
    case glfw.KEY_HOME:final='H'
    case glfw.KEY_END:final='F'
    case glfw.KEY_INSERT:tilde=2
    case glfw.KEY_DELETE:tilde=3
    case glfw.KEY_PAGE_UP:tilde=5
    case glfw.KEY_PAGE_DOWN:tilde=6
    case glfw.KEY_F1:function='P'
    case glfw.KEY_F2:function='Q'
    case glfw.KEY_F3:function='R'
    case glfw.KEY_F4:function='S'
    case glfw.KEY_F5:tilde=15
    case glfw.KEY_F6:tilde=17
    case glfw.KEY_F7:tilde=18
    case glfw.KEY_F8:tilde=19
    case glfw.KEY_F9:tilde=20
    case glfw.KEY_F10:tilde=21
    case glfw.KEY_F11:tilde=23
    case glfw.KEY_F12:tilde=24
    }
    if final!=0 {
        if modifier>1 {return fmt.tprintf("\x1b[1;%d%c",modifier,final)}
        if application_cursor {return fmt.tprintf("\x1bO%c",final)}
        return fmt.tprintf("\x1b[%c",final)
    }
    if function!=0 {
        if modifier>1 {return fmt.tprintf("\x1b[1;%d%c",modifier,function)}
        return fmt.tprintf("\x1bO%c",function)
    }
    if tilde!=0 {
        if modifier>1 {return fmt.tprintf("\x1b[%d;%d~",tilde,modifier)}
        return fmt.tprintf("\x1b[%d~",tilde)
    }
    if alt&&sequence!="" {return fmt.tprintf("\x1b%s",sequence)}
    return sequence
}

package main

import "core:c"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import glfw "vendor:glfw"

text_word_class :: proc(ch:rune)->int {
    if unicode.is_space(ch) {return 0}
    if ch=='_'||unicode.is_letter(ch)||unicode.is_number(ch)||unicode.is_nonspacing_mark(ch)||unicode.is_spacing_mark(ch)||unicode.is_enclosing_mark(ch) {return 1}
    return 2
}
text_word_left :: proc(bytes:[]u8,position:int)->int {
    cursor:=clamp(position,0,len(bytes))
    for cursor>0 {
        ch,n:=utf8.decode_last_rune(bytes[:cursor])
        if !unicode.is_space(ch) {break};cursor-=max(1,n)
    }
    if cursor==0 {return 0}
    ch,_:=utf8.decode_last_rune(bytes[:cursor]);kind:=text_word_class(ch)
    for cursor>0 {
        previous,n:=utf8.decode_last_rune(bytes[:cursor])
        if text_word_class(previous)!=kind {break};cursor-=max(1,n)
    }
    return cursor
}
text_word_right :: proc(bytes:[]u8,position:int)->int {
    cursor:=clamp(position,0,len(bytes))
    if cursor>=len(bytes) {return len(bytes)}
    ch,_:=utf8.decode_rune(bytes[cursor:]);kind:=text_word_class(ch)
    for cursor<len(bytes) {
        next,n:=utf8.decode_rune(bytes[cursor:])
        if text_word_class(next)!=kind {break};cursor+=max(1,n)
    }
    for cursor<len(bytes) {
        next,n:=utf8.decode_rune(bytes[cursor:])
        if !unicode.is_space(next) {break};cursor+=max(1,n)
    }
    return cursor
}
text_edit_selection :: proc(bytes:[]u8,position,mark:int,selecting,all:bool)->(first,last:int) {
    if all {return 0,len(bytes)}
    cursor:=clamp(position,0,len(bytes));anchor:=clamp(mark,0,len(bytes))
    if selecting {return min(cursor,anchor),max(cursor,anchor)}
    return cursor,cursor
}
// Return the byte range to delete. The caller owns fixed/dynamic storage and
// updates its length; shared movement never splits a UTF-8 sequence.
text_edit_key :: proc(a:^App,bytes:[]u8,cursor,anchor:^int,selecting,all:^bool,key,mods:c.int)->(handled:bool,first,last:int) {
    ctrl:=mods&glfw.MOD_CONTROL!=0;shift:=mods&glfw.MOD_SHIFT!=0;alt:=mods&glfw.MOD_ALT!=0
    if alt {return}
    cursor^=clamp(cursor^,0,len(bytes))
    lo,hi:=text_edit_selection(bytes,cursor^,anchor^,selecting^,all^)
    if ctrl&&key==glfw.KEY_A {all^=true;selecting^=false;cursor^=len(bytes);return true,0,0}
    if ctrl&&(key==glfw.KEY_C||key==glfw.KEY_X) {
        if hi>lo {glfw.SetClipboardString(a.renderer.window,strings.clone_to_cstring(string(bytes[lo:hi]),context.temp_allocator))}
        if key==glfw.KEY_C {return true,0,0}
        cursor^=lo;selecting^=false;all^=false;return true,lo,hi
    }
    moving:=key==glfw.KEY_LEFT||key==glfw.KEY_RIGHT||key==glfw.KEY_HOME||key==glfw.KEY_END
    if moving {
        if shift {
            if all^ {anchor^=0;cursor^=len(bytes)} else if !selecting^ {anchor^=cursor^}
            selecting^=true
        } else if hi>lo&&(key==glfw.KEY_LEFT||key==glfw.KEY_RIGHT)&&!ctrl {
            cursor^=lo;if key==glfw.KEY_RIGHT {cursor^=hi}
            selecting^=false;all^=false;return true,0,0
        }
        all^=false
        switch key {
        case glfw.KEY_HOME:cursor^=0
        case glfw.KEY_END:cursor^=len(bytes)
        case glfw.KEY_LEFT:
            if ctrl {cursor^=text_word_left(bytes,cursor^)}
            else if cursor^>0 {_,n:=utf8.decode_last_rune(bytes[:cursor^]);cursor^-=max(1,n)}
        case glfw.KEY_RIGHT:
            if ctrl {cursor^=text_word_right(bytes,cursor^)}
            else if cursor^<len(bytes) {_,n:=utf8.decode_rune(bytes[cursor^:]);cursor^+=max(1,n)}
        }
        if !shift {selecting^=false}
        return true,0,0
    }
    deleting:=key==glfw.KEY_BACKSPACE||key==glfw.KEY_DELETE||(ctrl&&(key==glfw.KEY_U||key==glfw.KEY_K||key==glfw.KEY_W))
    if deleting {
        first,last=lo,hi
        if first==last {
            switch key {
            case glfw.KEY_BACKSPACE:
                if ctrl {first=text_word_left(bytes,cursor^)}
                else if cursor^>0 {_,n:=utf8.decode_last_rune(bytes[:cursor^]);first=cursor^-max(1,n)}
            case glfw.KEY_DELETE:
                if ctrl {last=text_word_right(bytes,cursor^)}
                else if cursor^<len(bytes) {_,n:=utf8.decode_rune(bytes[cursor^:]);last=cursor^+max(1,n)}
            case glfw.KEY_U:first=0
            case glfw.KEY_K:last=len(bytes)
            case glfw.KEY_W:first=text_word_left(bytes,cursor^)
            }
        }
        cursor^=first;selecting^=false;all^=false
        return true,first,last
    }
    return
}
text_edit_remove :: proc(bytes:[]u8,lo,hi:int)->int {
    first:=clamp(lo,0,len(bytes));last:=clamp(hi,first,len(bytes))
    copy(bytes[first:],bytes[last:]);return len(bytes)-(last-first)
}
text_edit_selection_render :: proc(a:^App,bytes:[]u8,start,cursor,anchor:int,selecting,all:bool,x,y,size,width,height:f32) {
    first,last:=text_edit_selection(bytes,cursor,anchor,selecting,all)
    if first==last||last<=start {return}
    first=max(start,first)
    font:=renderer_font_size(&a.renderer,size*a.scale)
    measure :: proc(a:^App,font:^Font_Size,text:[]u8,limit:f32)->f32 {
        result:f32
        for ch in string(text) {result+=renderer_glyph(&a.renderer,font,ch).advance/a.scale;if result>=limit {return limit}}
        return result
    }
    left:=measure(a,font,bytes[start:first],width)
    right:=measure(a,font,bytes[start:last],width)
    if right>left {ui_rect(a,x+left,y,right-left,height,SELECTION)}
}

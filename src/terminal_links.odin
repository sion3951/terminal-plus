package main

import "core:strings"
import glfw "vendor:glfw"

// Ctrl+click opens URLs printed in terminal output. Pages and media open in
// the native document and media viewers inside this window.
Terminal_Link :: struct {
    lo, hi: int, // absolute positions (scrollback row * cols + column), inclusive
    url: string, // temp allocator
}

TERMINAL_LINK_SCHEMES :: [?]string{"https://","http://","file://"}
TERMINAL_LINK_MAX_ROWS :: 8

terminal_link_rune :: proc(ch:rune)->bool {
    if ch<=' '||ch==0x7f||ch==0xa0||ch==0x3000 {return false}
    if ch>=0x2500&&ch<=0x259f {return false} // box drawing and block elements
    switch ch {case '"','<','>','`','{','}','|','\\','^':return false}
    return true
}

terminal_link_row_full :: proc(row:[]Cell)->bool {
    if len(row)==0 {return false}
    last:=row[len(row)-1]
    if last.width==0 {return true} // trailing half of a wide character
    return last.ch!=0&&last.ch!=' '
}

terminal_link_scheme :: proc(text:[]rune,at:int)->int {
    for scheme in TERMINAL_LINK_SCHEMES {
        if at+len(scheme)>len(text) {continue}
        matched:=true
        for i in 0..<len(scheme) {
            ch:=text[at+i];if ch>='A'&&ch<='Z' {ch+='a'-'A'}
            if ch!=rune(scheme[i]) {matched=false;break}
        }
        if matched {return len(scheme)}
    }
    return 0
}

terminal_link_pointer :: proc(a:^App,x,y:f64)->(row,col:int,ok:bool) {
    px,py:=f32(x)*a.scale,f32(y)*a.scale
    if px<a.origin_x||py<a.origin_y {return}
    row=int((py-a.origin_y)/a.cell_h);col=int((px-a.origin_x)/a.cell_w)
    ok=row>=0&&row<a.rows&&col>=0&&col<a.cols
    return
}

terminal_link_at :: proc(a:^App,x,y:f64)->(link:Terminal_Link,ok:bool) {
    tab:=active_tab(a)
    if tab==nil||tab.files||tab.media!=nil||a.explorer_visible {return}
    row,col:=terminal_link_pointer(a,x,y) or_return
    terminal_history_prepare(&tab.terminal,tab.scroll)
    return terminal_link_find(&tab.terminal,tab.scroll,row,col,a.cols,a.rows)
}

terminal_link_find :: proc(t:^Terminal,scroll,row,col,cols,rows:int)->(link:Terminal_Link,ok:bool) {
    // Rows carry no soft-wrap flag; a row filled to its last column is treated
    // as continuing onto the next one so wrapped URLs stay whole.
    first,last:=row,row
    for first>0&&row-first<TERMINAL_LINK_MAX_ROWS&&terminal_link_row_full(terminal_row(t,first-1,scroll)) {first-=1}
    for last<rows-1&&last-row<TERMINAL_LINK_MAX_ROWS&&terminal_link_row_full(terminal_row(t,last,scroll)) {last+=1}
    base:=terminal_history_count(t)-scroll
    text:=make([dynamic]rune,context.temp_allocator)
    positions:=make([dynamic]int,context.temp_allocator)
    target:=-1
    for yy in first..=last {
        cells:=terminal_row(t,yy,scroll)
        for cell,xx in cells {
            if cell.width==0 {
                if yy==row&&xx==col {target=len(text)-1}
                continue
            }
            if yy==row&&xx==col {target=len(text)}
            ch:=cell.ch;if ch==0 {ch=' '}
            append(&text,ch);append(&positions,(base+yy)*cols+xx)
        }
        if len(cells)==0 {append(&text,' ');append(&positions,(base+yy)*cols)}
    }
    if target<0||target>=len(text)||!terminal_link_rune(text[target]) {return}
    start,end:=target,target+1
    for start>0&&terminal_link_rune(text[start-1]) {start-=1}
    for end<len(text)&&terminal_link_rune(text[end]) {end+=1}
    // The nearest scheme at or before the pointer begins the URL; a later one ends it.
    scheme_at,scheme_len:=-1,0
    for i in start..=target {if n:=terminal_link_scheme(text[:end],i);n>0 {scheme_at,scheme_len=i,n}}
    if scheme_at<0 {return}
    for i in target+1..<end {if terminal_link_scheme(text[:end],i)>0 {end=i;break}}
    // Prose punctuation after a URL is not part of it, except balanced brackets.
    for end>scheme_at+scheme_len {
        ch:=text[end-1]
        if ch=='.'||ch==','||ch==';'||ch==':'||ch=='!'||ch=='?'||ch=='\''||ch=='*' {end-=1;continue}
        if ch==')'||ch==']' {
            open:=ch==')'?'(':'['
            depth:=0
            for c in text[scheme_at:end] {if c==open {depth+=1} else if c==ch {depth-=1}}
            if depth<0 {end-=1;continue}
        }
        break
    }
    if end<=scheme_at+scheme_len||target>=end {return}
    builder:=strings.builder_make(context.temp_allocator)
    for ch,i in text[scheme_at:end] {
        c:=ch;if i<scheme_len&&c>='A'&&c<='Z' {c+='a'-'A'}
        strings.write_rune(&builder,c)
    }
    link.url=strings.to_string(builder)
    link.lo=positions[scheme_at];link.hi=positions[end-1]
    return link,true
}

terminal_link_open :: proc(a:^App,url:string) {
    tab:=active_tab(a);if tab==nil {return}
    path:=url
    if strings.has_prefix(url,"file://") {
        rest:=url[len("file://"):]
        slash:=strings.index_byte(rest,'/')
        if slash<0 {terminal_link_error(a,tab,"This file link has no path.");return}
        decoded,valid:=document_url_decode(native_url_without_fragment(rest[slash:]))
        if !valid {terminal_link_error(a,tab,"This file link is malformed.");return}
        path=strings.clone(decoded,context.temp_allocator);delete(decoded)
        if document_kind(path)==.None&&media_kind(path)==.None {terminal_link_error(a,tab,"Terminal+ cannot open this file type.");return}
    }
    a.selected=false;a.selecting=false
    if media_kind(path)!=.None {media_view_open(a,tab,path)} else {document_open_tab(a,tab,path)}
    a.dirty=true
}

terminal_link_error :: proc(a:^App,tab:^Tab,message:string) {
    delete(tab.input_error);tab.input_error=strings.clone(message);a.dirty=true
}

terminal_link_ctrl_held :: proc(a:^App)->bool {
    w:=a.renderer.window
    return glfw.GetKey(w,glfw.KEY_LEFT_CONTROL)==glfw.PRESS||glfw.GetKey(w,glfw.KEY_RIGHT_CONTROL)==glfw.PRESS
}

// Underline the link under the pointer while Ctrl is held and show a hand cursor.
terminal_link_hover :: proc(a:^App,x,y:f64,ctrl:bool) {
    link,ok:=Terminal_Link{},false
    if ctrl&&!a.selecting {link,ok=terminal_link_at(a,x,y)}
    if ok!=a.link_active||(ok&&(link.lo!=a.link_lo||link.hi!=a.link_hi)) {
        a.link_active=ok;a.link_lo=link.lo;a.link_hi=link.hi;a.dirty=true
    }
    if ok!=a.link_cursor_shown {
        a.link_cursor_shown=ok
        if ok&&a.link_cursor==nil {a.link_cursor=glfw.CreateStandardCursor(glfw.HAND_CURSOR)}
        glfw.SetCursor(a.renderer.window,ok?a.link_cursor:nil)
    }
}

terminal_link_refresh :: proc(a:^App,ctrl:bool) {
    x,y:=glfw.GetCursorPos(a.renderer.window)
    terminal_link_hover(a,x,y,ctrl)
}

terminal_link_selfcheck :: proc()->bool {
    t:Terminal;terminal_init(&t,20,4);defer terminal_destroy(&t)
    // Row 0: prose punctuation; rows 1-2: a URL wrapped at the last column.
    terminal_feed(&t,transmute([]u8)string("(see https://a.io/x)\r\nhttps://example.com/ab/cd\r\nno link here"))
    link,ok:=terminal_link_find(&t,0,0,8,20,4)
    if !ok||link.url!="https://a.io/x"||link.lo!=5||link.hi!=18 {return false}
    if _,miss:=terminal_link_find(&t,0,0,1,20,4);miss {return false}
    link,ok=terminal_link_find(&t,0,2,3,20,4)
    if !ok||link.url!="https://example.com/ab/cd"||link.lo!=20||link.hi!=44 {return false}
    if _,miss:=terminal_link_find(&t,0,3,4,20,4);miss {return false}
    return true
}

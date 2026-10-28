package main

import "core:fmt"
import "core:unicode/utf8"

TERMINAL_FG :: u32(0xededed)
TERMINAL_BG :: u32(0x000000)
TERMINAL_HISTORY_LIMIT :: 10000

Cell :: struct {
    ch: rune,
    combining: [3]rune,
    fg, bg: u32,
    bold, italic, underline, inverse: bool,
    width: u8,
}
Terminal_Cursor :: struct { x,y:int, style:Cell, origin,wrap:bool }
Terminal_Parse :: enum { Ground, Escape, CSI, OSC, OSC_Escape, Charset, Ignore, Ignore_Escape }
Terminal :: struct {
    cols,rows,cursor_x,cursor_y:int,
    screen:[]Cell,
    dirty:bool,
    title:[256]u8,
    title_len:int,
    cwd:[4097]u8,
    cwd_len:int,
    cwd_changed:bool,
    cursor_visible, alternate, bracketed_paste, application_cursor:bool,
    replies:[dynamic]u8,
    document_requests:[dynamic]string,
    normal_screen, alternate_screen:[]Cell,
    normal_cursor, saved:Terminal_Cursor,
    style:Cell,
    scroll_top,scroll_bottom:int,
    origin,autowrap,wrap_pending,insert_mode:bool,
    history:[TERMINAL_HISTORY_LIMIT][]Cell,
    history_start,history_count,history_recent_count,history_recent_bytes:int,
    history_epoch:u64,
    history_checkpointed:bool,
    history_feed_budget:int,
    history_encoded:[dynamic]u8,
    history_view:History_Page,
    history_notify:proc(),
    archive:^Terminal_History,
    persistent:^PTY,
    history_generation:u64,
    tabs:[]bool,
    parser:Terminal_Parse,
    params:[32]int,
    param_count:int,
    private:u8,
    osc:[16*1024]u8,
    osc_len:int,
    utf_value:rune,
    utf_remaining:int,
    utf_min:rune,
    dec_graphics,charset_g0:bool,
}
terminal_blank :: proc(t:^Terminal)->Cell {
    return Cell{ch=' ',fg=t.style.fg,bg=t.style.bg,width=1}
}
terminal_default_style :: proc()->Cell { return {ch=' ',fg=TERMINAL_FG,bg=TERMINAL_BG,width=1} }
terminal_fill :: proc(t:^Terminal,cells:[]Cell) { for &cell in cells {cell=terminal_blank(t)} }
terminal_safe_dimensions :: proc(width,height:int)->(cols,rows:int) {
    cols=clamp(width,1,TERMINAL_MAX_COLS);rows=clamp(height,1,TERMINAL_MAX_COLS)
    if cols>TERMINAL_MAX_CELLS/rows {rows=max(1,TERMINAL_MAX_CELLS/cols)}
    return
}
terminal_init :: proc(t:^Terminal,cols,rows:int) {
    safe_cols,safe_rows:=terminal_safe_dimensions(cols,rows)
    t^={cols=safe_cols,rows=safe_rows,style=terminal_default_style(),cursor_visible=true,autowrap=true}
    t.screen=make([]Cell,t.cols*t.rows)
    t.normal_screen=t.screen
    t.scroll_bottom=t.rows-1
    t.tabs=make([]bool,t.cols)
    for i in 0..<t.cols {t.tabs[i]=i>0&&i%8==0}
    terminal_fill(t,t.screen)
    t.saved=terminal_cursor_save(t)
    t.dirty=true
}
terminal_destroy :: proc(t:^Terminal) {
    terminal_history_checkpoint(t)
    terminal_history_destroy(t)
    delete(t.normal_screen);delete(t.alternate_screen);delete(t.tabs);delete(t.replies)
    for path in t.document_requests {delete(path)};delete(t.document_requests)
    for line in t.history {delete(line)}
    t^={}
}
terminal_history_count :: proc(t:^Terminal)->int {if t.alternate {return 0};return t.history_count}

// Unused trailing screen rows are padding, rather than selectable output.
// Resolve once at drag start; mouse motion then clamps without scanning cells.
// Archived rows and blank lines between actual output remain selectable.
terminal_selection_last_row :: proc(t:^Terminal,scroll_offset:int)->int {
    offset:=0
    if !t.alternate {offset=clamp(scroll_offset,0,t.history_count)}
    if t.cursor_y+offset>=t.rows-1 {return t.rows-1}
    for y:=t.rows-1;y>t.cursor_y;y-=1 {
        for cell in t.screen[y*t.cols:(y+1)*t.cols] {
            if (cell.ch!=0&&cell.ch!=' ')||cell.underline||cell.combining[0]!=0||cell.combining[1]!=0||cell.combining[2]!=0 {
                return min(t.rows-1,y+offset)
            }
        }
    }
    return clamp(t.cursor_y+offset,0,t.rows-1)
}
terminal_history_push :: proc(t:^Terminal,line:[]Cell) {
    if t.alternate {return}
    history_enqueue(t,line)
    t.history_generation+=1
    t.history_count+=1
    bytes:=len(line)*size_of(Cell)
    // Evict only the recent RAM copy: the complete row is already queued for
    // disk storage and remains addressable by its absolute history index.
    reuse:[]Cell
    for t.history_recent_count>0&&(t.history_recent_count>=TERMINAL_HISTORY_LIMIT||t.history_recent_bytes+bytes>HISTORY_RECENT_BYTES) {
        index:=t.history_start
        t.history_recent_bytes-=len(t.history[index])*size_of(Cell)
        if reuse==nil&&len(t.history[index])==len(line) {reuse=t.history[index]} else {delete(t.history[index])}
        t.history[index]=nil
        t.history_start=(t.history_start+1)%TERMINAL_HISTORY_LIMIT;t.history_recent_count-=1
    }
    index:=(t.history_start+t.history_recent_count)%TERMINAL_HISTORY_LIMIT
    if reuse!=nil {delete(t.history[index]);t.history[index]=reuse}
    else if len(t.history[index])!=len(line) {delete(t.history[index]);t.history[index]=make([]Cell,len(line))}
    copy(t.history[index],line)
    t.history_recent_count+=1;t.history_recent_bytes+=bytes
}
// A renderer can resolve scrollback once per visible row rather than once per
// cell. Historical rows can be shorter after a resize; callers pad their tail.
terminal_row :: proc(t:^Terminal,y,scroll_offset:int)->[]Cell {
    if y<0||y>=t.rows {return nil}
    offset:=0
    if !t.alternate {offset=clamp(scroll_offset,0,t.history_count)}
    row:=y-offset
    if row>=0 {return t.screen[row*t.cols:(row+1)*t.cols]}
    history_row:=t.history_count+row
    if history_row<0 {return nil}
    recent_first:=t.history_count-t.history_recent_count
    if history_row>=recent_first {
        line:=t.history[(t.history_start+history_row-recent_first)%TERMINAL_HISTORY_LIMIT]
        return line[:min(t.cols,len(line))]
    }
    view:=&t.history_view
    if view.epoch==t.history_epoch&&history_row>=view.start&&history_row<view.start+len(view.rows) {
        line:=view.rows[history_row-view.start]
        return line[:min(t.cols,len(line))]
    }
    return nil
}
terminal_cell :: proc(t:^Terminal,x,y,scroll_offset:int)->Cell {
    if x<0||x>=t.cols {return terminal_default_style()}
    row:=terminal_row(t,y,scroll_offset)
    if x<len(row) {return row[x]}
    return terminal_default_style()
}

terminal_scroll :: proc(t:^Terminal,count:int) {
    top,bottom:=t.scroll_top,t.scroll_bottom
    amount:=min(abs(count),bottom-top+1)
    if amount<=0 {return}
    if count>0 {
        if top==0&&bottom==t.rows-1 {for y in 0..<amount {terminal_history_push(t,t.screen[y*t.cols:(y+1)*t.cols])}}
        copy(t.screen[top*t.cols:(bottom-amount+1)*t.cols],t.screen[(top+amount)*t.cols:(bottom+1)*t.cols])
        terminal_fill(t,t.screen[(bottom-amount+1)*t.cols:(bottom+1)*t.cols])
    } else {
        for y:=bottom;y>=top+amount;y-=1 {copy(t.screen[y*t.cols:(y+1)*t.cols],t.screen[(y-amount)*t.cols:(y-amount+1)*t.cols])}
        terminal_fill(t,t.screen[top*t.cols:(top+amount)*t.cols])
    }
    t.dirty=true
}
terminal_linefeed :: proc(t:^Terminal) {
    t.wrap_pending=false
    if t.cursor_y==t.scroll_bottom {terminal_scroll(t,1)}
    else {t.cursor_y=min(t.cursor_y+1,t.rows-1)}
}
terminal_reverse_index :: proc(t:^Terminal) {
    t.wrap_pending=false
    if t.cursor_y==t.scroll_top {terminal_scroll(t,-1)}
    else {t.cursor_y=max(t.cursor_y-1,0)}
}
terminal_cursor_save :: proc(t:^Terminal)->Terminal_Cursor {return {t.cursor_x,t.cursor_y,t.style,t.origin,t.autowrap}}
terminal_cursor_restore :: proc(t:^Terminal,saved:Terminal_Cursor) {
    t.cursor_x=clamp(saved.x,0,t.cols-1);t.cursor_y=clamp(saved.y,0,t.rows-1)
    t.style=saved.style;t.origin=saved.origin;t.autowrap=saved.wrap;t.wrap_pending=false
}
terminal_resize_buffer :: proc(t:^Terminal,old:[]Cell,old_cols,old_rows,cols,rows,shift:int)->[]Cell {
    next:=make([]Cell,cols*rows);terminal_fill(t,next)
    for y in 0..<min(rows,old_rows-shift) {copy(next[y*cols:y*cols+min(cols,old_cols)],old[(y+shift)*old_cols:(y+shift)*old_cols+min(cols,old_cols)])}
    for y in 0..<rows {terminal_repair_wide(t,next[y*cols:(y+1)*cols])}
    return next
}
terminal_resize :: proc(t:^Terminal,new_cols,new_rows:int)->bool {
    cols,rows:=terminal_safe_dimensions(new_cols,new_rows)
    if cols==t.cols&&rows==t.rows {return true}
    shift:=min(max(0,t.cursor_y-rows+1),max(0,t.rows-rows))
    normal_shift:=shift
    if t.alternate {normal_shift=min(max(0,t.normal_cursor.y-rows+1),max(0,t.rows-rows))}
    alternate:=t.alternate;t.alternate=false
    terminal_history_feed_begin(t)
    if !terminal_history_allow(t,normal_shift) {t.alternate=alternate;return false}
    for y in 0..<normal_shift {terminal_history_push(t,t.normal_screen[y*t.cols:(y+1)*t.cols])}
    t.alternate=alternate
    normal:=terminal_resize_buffer(t,t.normal_screen,t.cols,t.rows,cols,rows,normal_shift)
    delete(t.normal_screen);t.normal_screen=normal
    if len(t.alternate_screen)>0 {alt:=terminal_resize_buffer(t,t.alternate_screen,t.cols,t.rows,cols,rows,shift);delete(t.alternate_screen);t.alternate_screen=alt}
    if t.alternate {t.normal_cursor.y=clamp(t.normal_cursor.y-normal_shift,0,rows-1);t.normal_cursor.x=min(t.normal_cursor.x,cols-1)}
    tabs:=make([]bool,cols)
    for i in 0..<cols {if i<len(t.tabs) {tabs[i]=t.tabs[i]} else {tabs[i]=i%8==0}}
    delete(t.tabs);t.tabs=tabs
    t.cols,t.rows=cols,rows;t.cursor_x=min(t.cursor_x,cols-1);t.cursor_y=clamp(t.cursor_y-shift,0,rows-1)
    t.scroll_top=0;t.scroll_bottom=rows-1;t.wrap_pending=false
    if t.alternate {t.screen=t.alternate_screen} else {t.screen=t.normal_screen}
    if h:=t.archive;h!=nil {
        terminal_history_update_limit(t)
    }
    t.dirty=true
    return true
}
terminal_wide :: proc(ch:rune)->bool {
    return ch>=0x1100&&((ch<=0x115f)||ch==0x2329||ch==0x232a||(ch>=0x2e80&&ch<=0xa4cf&&ch!=0x303f)||(ch>=0xac00&&ch<=0xd7a3)||(ch>=0xf900&&ch<=0xfaff)||(ch>=0xfe10&&ch<=0xfe19)||(ch>=0xfe30&&ch<=0xfe6f)||(ch>=0xff00&&ch<=0xff60)||(ch>=0xffe0&&ch<=0xffe6)||(ch>=0x1f300&&ch<=0x1faff)||(ch>=0x20000&&ch<=0x3fffd))
}
terminal_combining :: proc(ch:rune)->bool {
    return (ch>=0x300&&ch<=0x36f)||(ch>=0x1ab0&&ch<=0x1aff)||(ch>=0x1dc0&&ch<=0x1dff)||(ch>=0x20d0&&ch<=0x20ff)||(ch>=0xfe00&&ch<=0xfe0f)||(ch>=0xfe20&&ch<=0xfe2f)||ch==0x200d||(ch>=0xe0100&&ch<=0xe01ef)
}
terminal_unlink_wide :: proc(t:^Terminal,x,y:int) {
    i:=y*t.cols+x
    if t.screen[i].width==0&&x>0 {t.screen[i-1]=terminal_blank(t)}
    if t.screen[i].width==2&&x+1<t.cols {t.screen[i+1]=terminal_blank(t)}
}
terminal_put :: proc(t:^Terminal,input_ch:rune) {
    ch:=input_ch
    if terminal_combining(ch) {
        x,y:=t.cursor_x-1,t.cursor_y
        if t.wrap_pending {x=t.cursor_x}
        if x<0 {x=t.cols-1;y-=1}
        if y>=0 {
            cell:=&t.screen[y*t.cols+x]
            if cell.width==0&&x>0 {cell=&t.screen[y*t.cols+x-1]}
            for &mark in cell.combining {if mark==0 {mark=ch;break}}
            t.dirty=true
        }
        return
    }
    if t.dec_graphics&&ch>=0x60&&ch<=0x7e {
        DEC := [31]rune{'◆','▒','␉','␌','␍','␊','°','±','␤','␋','┘','┐','┌','└','┼','⎺','⎻','─','⎼','⎽','├','┤','┴','┬','│','≤','≥','π','≠','£','·'}
        ch=DEC[ch-0x60]
    }
    width:=1
    if terminal_wide(ch)&&t.cols>1 {width=2}
    if t.wrap_pending||(width==2&&t.cursor_x==t.cols-1&&t.autowrap) {if t.autowrap {t.cursor_x=0;terminal_linefeed(t)};t.wrap_pending=false}
    if width==2&&t.cursor_x==t.cols-1 {width=1}
    if t.insert_mode {terminal_insert_chars(t,width)}
    terminal_unlink_wide(t,t.cursor_x,t.cursor_y)
    if width==2 {terminal_unlink_wide(t,t.cursor_x+1,t.cursor_y)}
    cell:=t.style;cell.ch=ch;cell.width=u8(width)
    t.screen[t.cursor_y*t.cols+t.cursor_x]=cell
    if width==2 {cell.ch=0;cell.width=0;t.screen[t.cursor_y*t.cols+t.cursor_x+1]=cell}
    t.cursor_x+=width
    if t.cursor_x>=t.cols {t.cursor_x=t.cols-1;t.wrap_pending=t.autowrap}
    t.dirty=true
}
terminal_repair_wide :: proc(t:^Terminal,row:[]Cell) {
    for x:=0;x<len(row);x+=1 {
        if row[x].width==0 {row[x]=terminal_blank(t)}
        else if row[x].width==2 {
            if x+1<len(row)&&row[x+1].width==0 {x+=1}
            else {row[x]=terminal_blank(t)}
        }
    }
}
terminal_erase_range :: proc(t:^Terminal,start,end:int) {
    if start>=end {return}
    terminal_unlink_wide(t,start%t.cols,start/t.cols)
    terminal_unlink_wide(t,(end-1)%t.cols,(end-1)/t.cols)
    terminal_fill(t,t.screen[start:end])
}
terminal_insert_chars :: proc(t:^Terminal,count:int) {
    n:=min(count,t.cols-t.cursor_x)
    row:=t.screen[t.cursor_y*t.cols:(t.cursor_y+1)*t.cols]
    for x:=t.cols-1;x>=t.cursor_x+n;x-=1 {row[x]=row[x-n]}
    terminal_fill(t,row[t.cursor_x:t.cursor_x+n]);terminal_repair_wide(t,row)
}
terminal_delete_chars :: proc(t:^Terminal,count:int) {
    n:=min(count,t.cols-t.cursor_x)
    row:=t.screen[t.cursor_y*t.cols:(t.cursor_y+1)*t.cols]
    copy(row[t.cursor_x:t.cols-n],row[t.cursor_x+n:])
    terminal_fill(t,row[t.cols-n:]);terminal_repair_wide(t,row)
}
terminal_palette :: proc(raw_index:int)->u32 {
    ANSI := [16]u32{0x22252e,0xf07178,0x9acb8b,0xe6c384,0x7aa2f7,0xbdbdbd,0x73daca,0xd7dce5,0x677185,0xff9b9e,0xb8e3a8,0xf5dcaa,0x9bbdff,0xededed,0x9fe8eb,0xffffff}
    index:=clamp(raw_index,0,255)
    if index<16 {return ANSI[index]}
    if index>=232 {n:=u32(8+(index-232)*10);return (n<<16)|(n<<8)|n}
    cube := [6]u32{0,95,135,175,215,255}
    n:=index-16;return (cube[n/36]<<16)|(cube[(n/6)%6]<<8)|cube[n%6]
}
terminal_sgr :: proc(t:^Terminal) {
    for i:=0;i<t.param_count;i+=1 {
        p:=t.params[i]
        switch p {
        case 0: t.style=terminal_default_style()
        case 1: t.style.bold=true
        case 3: t.style.italic=true
        case 4,21: t.style.underline=true
        case 7: t.style.inverse=true
        case 22: t.style.bold=false
        case 23: t.style.italic=false
        case 24: t.style.underline=false
        case 27: t.style.inverse=false
        case 39: t.style.fg=TERMINAL_FG
        case 49: t.style.bg=TERMINAL_BG
        case 38,48:
            color:u32
            valid:=false
            if i+2<t.param_count&&t.params[i+1]==5 {color=terminal_palette(t.params[i+2]);i+=2;valid=true}
            else if i+4<t.param_count&&t.params[i+1]==2 {color=u32(clamp(t.params[i+2],0,255))<<16|u32(clamp(t.params[i+3],0,255))<<8|u32(clamp(t.params[i+4],0,255));i+=4;valid=true}
            if valid {if p==38 {t.style.fg=color} else {t.style.bg=color}}
        case:
            if p>=30&&p<=37 {t.style.fg=terminal_palette(p-30)}
            else if p>=40&&p<=47 {t.style.bg=terminal_palette(p-40)}
            else if p>=90&&p<=97 {t.style.fg=terminal_palette(p-90+8)}
            else if p>=100&&p<=107 {t.style.bg=terminal_palette(p-100+8)}
        }
    }
}
terminal_alternate :: proc(t:^Terminal,enabled,save:bool) {
    if enabled==t.alternate {return}
    if enabled {
        if save {t.normal_cursor=terminal_cursor_save(t)}
        if len(t.alternate_screen)==0 {t.alternate_screen=make([]Cell,t.cols*t.rows)}
        terminal_fill(t,t.alternate_screen);t.screen=t.alternate_screen;t.cursor_x=0;t.cursor_y=0
    } else {t.screen=t.normal_screen;if save {terminal_cursor_restore(t,t.normal_cursor)}}
    t.alternate=enabled;t.scroll_top=0;t.scroll_bottom=t.rows-1;t.wrap_pending=false;t.dirty=true
}
terminal_mode :: proc(t:^Terminal,set:bool) {
    for i in 0..<t.param_count {
        p:=t.params[i]
        if t.private=='?' {
            switch p {
            case 1:t.application_cursor=set
            case 6:t.origin=set;t.cursor_x=0;t.cursor_y=0;if set {t.cursor_y=t.scroll_top}
            case 7:t.autowrap=set
            case 25:t.cursor_visible=set
            case 47,1047:terminal_alternate(t,set,false)
            case 1048:if set {t.saved=terminal_cursor_save(t)} else {terminal_cursor_restore(t,t.saved)}
            case 1049:terminal_alternate(t,set,true)
            case 2004:t.bracketed_paste=set
            }
        } else if p==4 {t.insert_mode=set}
    }
}
terminal_csi :: proc(t:^Terminal,command:u8) {
    p:=t.params[0];n:=max(p,1)
    low,high:=0,t.rows-1
    if t.origin {low=t.scroll_top;high=t.scroll_bottom}
    if command!='m' {t.wrap_pending=false}
    switch command {
    case 'A':t.cursor_y=max(low,t.cursor_y-n)
    case 'B','e':t.cursor_y=min(high,t.cursor_y+n)
    case 'C','a':t.cursor_x=min(t.cols-1,t.cursor_x+n)
    case 'D':t.cursor_x=max(0,t.cursor_x-n)
    case 'E':t.cursor_y=min(high,t.cursor_y+n);t.cursor_x=0
    case 'F':t.cursor_y=max(low,t.cursor_y-n);t.cursor_x=0
    case 'G','`':t.cursor_x=clamp(n-1,0,t.cols-1)
    case 'd':t.cursor_y=clamp(low+n-1,low,high)
    case 'H','f':t.cursor_y=clamp(low+n-1,low,high);t.cursor_x=clamp(max(t.params[1],1)-1,0,t.cols-1)
    case 'J':
        index:=t.cursor_y*t.cols+t.cursor_x
        if p==0 {terminal_erase_range(t,index,len(t.screen))}
        else if p==1 {terminal_erase_range(t,0,index+1)}
        else if p==2 {terminal_fill(t,t.screen)}
        else if p==3 {terminal_clear_history(t)}
    case 'K':
        start:=t.cursor_y*t.cols
        if p==0 {terminal_erase_range(t,start+t.cursor_x,start+t.cols)}
        else if p==1 {terminal_erase_range(t,start,start+t.cursor_x+1)}
        else if p==2 {terminal_fill(t,t.screen[start:start+t.cols])}
    case 'm':terminal_sgr(t)
    case 'h':terminal_mode(t,true)
    case 'l':terminal_mode(t,false)
    case 's':t.saved=terminal_cursor_save(t)
    case 'u':terminal_cursor_restore(t,t.saved)
    case 'r':
        if t.private==0 {
            top:=max(p,1)-1;bottom:=t.rows-1
            if t.params[1]>0 {bottom=t.params[1]-1}
            if top>=0&&bottom<t.rows&&top<bottom {t.scroll_top=top;t.scroll_bottom=bottom;t.cursor_x=0;t.cursor_y=0;if t.origin {t.cursor_y=top}}
        }
    case 'S':terminal_scroll(t,n)
    case 'T':terminal_scroll(t,-n)
    case '@':terminal_insert_chars(t,n)
    case 'P':terminal_delete_chars(t,n)
    case 'X':index:=t.cursor_y*t.cols+t.cursor_x;terminal_erase_range(t,index,index+min(n,t.cols-t.cursor_x))
    case 'L','M':
        if t.cursor_y>=t.scroll_top&&t.cursor_y<=t.scroll_bottom {
            old_top:=t.scroll_top;t.scroll_top=t.cursor_y
            if command=='L' {terminal_scroll(t,-n)} else {terminal_scroll(t,n)}
            t.scroll_top=old_top
        }
    case 'g':if p==0 {t.tabs[t.cursor_x]=false} else if p==3 {for &tab in t.tabs {tab=false}}
    case 'I':for _ in 0..<min(n,t.cols) {terminal_tab(t,1)}
    case 'Z':for _ in 0..<min(n,t.cols) {terminal_tab(t,-1)}
    case 'n':
        if p==5 {append(&t.replies, "\x1b[0n")}
        else if p==6 {buffer:[64]u8;response:=fmt.bprintf(buffer[:],"\x1b[%d;%dR",t.cursor_y+1,t.cursor_x+1);append(&t.replies, ..transmute([]u8)response)}
    case 'c':
        // DA1 and DA2 have different reply formats. Sending DA1 for DA2
        // leaves tmux's second reply unclaimed and forwards it to the shell.
        // Reports and unsupported DA requests must not generate more replies.
        if p==0&&t.param_count==1 {
            if t.private==0 {append(&t.replies, "\x1b[?1;2c")}
            else if t.private=='>' {append(&t.replies, "\x1b[>0;0;0c")}
        }
    }
    t.dirty=true
}
terminal_tab :: proc(t:^Terminal,direction:int) {
    x:=t.cursor_x+direction
    for x>0&&x<t.cols-1&&!t.tabs[x] {x+=direction}
    t.cursor_x=clamp(x,0,t.cols-1);t.wrap_pending=false
}
terminal_metadata_copy :: proc(buffer:[]u8,value:[]u8)->int {
    used,offset:=0,0
    for offset<len(value) {
        ch,n:=utf8.decode_rune(value[offset:]);offset+=max(1,n)
        bytes,count:=utf8.encode_rune(ch)
        if used+count>len(buffer) {break}
        copy(buffer[used:used+count],bytes[:count]);used+=count
    }
    return used
}
terminal_osc_finish :: proc(t:^Terminal) {
    split:=-1
    for b,i in t.osc[:t.osc_len] {if b==';' {split=i;break}}
    if split<1 {return}
    command:=0
    for b in t.osc[:split] {if b<'0'||b>'9' {return};command=min(9999,command*10+int(b-'0'))}
    value:=t.osc[split+1:t.osc_len]
    if command==0||command==2 {t.title_len=terminal_metadata_copy(t.title[:len(t.title)-1],value);t.title[t.title_len]=0;t.dirty=true}
    else if command==7 {terminal_directory_uri(t,string(value))}
    else if command==777 {terminal_shell_metadata(t,value)}
}
terminal_reset :: proc(t:^Terminal) {
    if t.alternate {terminal_alternate(t,false,true)}
    t.style=terminal_default_style();t.cursor_x=0;t.cursor_y=0;t.scroll_top=0;t.scroll_bottom=t.rows-1
    t.cursor_visible=true;t.application_cursor=false;t.bracketed_paste=false;t.origin=false;t.autowrap=true;t.insert_mode=false;t.wrap_pending=false;t.dec_graphics=false
    terminal_fill(t,t.screen)
    for &tab,i in t.tabs {tab=i>0&&i%8==0}
    t.dirty=true
}
// Printable text is by far the common case in shell output. Write a row span
// with one parser/style decision, retaining the general path for UTF-8, escape
// sequences, insertion and DEC graphics. Only the span's boundaries can split
// an existing wide character; interior cells are replaced together.
terminal_ascii_span :: proc(t:^Terminal,data:[]u8)->int {
    if len(data)==0||data[0]<32||data[0]>=127 {return 0}
    if t.wrap_pending {
        if t.autowrap {t.cursor_x=0;terminal_linefeed(t)}
        t.wrap_pending=false
    }
    available:=min(len(data),t.cols-t.cursor_x)
    count:=0
    for count<available&&data[count]>=32&&data[count]<127 {count+=1}
    if count==0 {return 0}
    terminal_unlink_wide(t,t.cursor_x,t.cursor_y)
    terminal_unlink_wide(t,t.cursor_x+count-1,t.cursor_y)
    start:=t.cursor_y*t.cols+t.cursor_x
    style:=t.style;style.width=1
    for i in 0..<count {style.ch=rune(data[i]);t.screen[start+i]=style}
    t.cursor_x+=count
    if t.cursor_x>=t.cols {t.cursor_x=t.cols-1;t.wrap_pending=t.autowrap}
    t.dirty=true
    return count
}
terminal_archive_rows_needed :: proc(t:^Terminal,b:u8)->int {
    if t.alternate||t.scroll_top!=0||t.scroll_bottom!=t.rows-1 {return 0}
    #partial switch t.parser {
    case .Ground:
        if t.cursor_y!=t.scroll_bottom {return 0}
        if b==10||b==11||b==12 {return 1}
        if b>=32&&b!=127&&(t.wrap_pending||t.cursor_x>=t.cols-2) {return 2}
    case .Escape:
        if t.cursor_y==t.scroll_bottom&&(b=='D'||b=='E') {return 1}
    case .CSI:
        if b=='S'||(b=='M'&&t.cursor_y==0) {return min(t.rows,max(t.params[0],1))}
    case:
    }
    return 0
}
// Return the exact consumed prefix. A bounded disk spool can apply output
// backpressure without losing bytes or blocking the UI thread on storage.
terminal_feed :: proc(t:^Terminal,data:[]u8)->int {
    if terminal_history_is_restoring(t) {return 0}
    terminal_history_feed_begin(t)
    offset:=0
    for offset<len(data) {
        if !terminal_history_allow(t,terminal_archive_rows_needed(t,data[offset])) {return offset}
        if t.parser==.Ground&&t.utf_remaining==0&&!t.dec_graphics&&!t.insert_mode {
            count:=terminal_ascii_span(t,data[offset:])
            if count>0 {offset+=count;continue}
        }
        b:=data[offset];offset+=1
        if t.parser==.OSC||t.parser==.OSC_Escape {
            if b==7||(t.parser==.OSC_Escape&&b=='\\') {terminal_osc_finish(t);t.parser=.Ground;continue}
            if b==0x1b {t.parser=.OSC_Escape;continue}
            t.parser=.OSC
            if b>=32&&t.osc_len<len(t.osc) {t.osc[t.osc_len]=b;t.osc_len+=1}
            continue
        }
        if t.parser==.Ignore||t.parser==.Ignore_Escape {
            if t.parser==.Ignore_Escape&&b=='\\' {t.parser=.Ground} else if b==0x1b {t.parser=.Ignore_Escape} else {t.parser=.Ignore}
            continue
        }
        if b==0x1b {t.parser=.Escape;t.utf_remaining=0;continue}
        if b==0x18||b==0x1a {t.parser=.Ground;t.utf_remaining=0;continue}
        if b<32||b==127 {
            switch b {
            case 8:t.cursor_x=max(0,t.cursor_x-1);t.wrap_pending=false
            case 9:terminal_tab(t,1)
            case 10,11,12:terminal_linefeed(t)
            case 13:t.cursor_x=0;t.wrap_pending=false
            case 14:t.dec_graphics=true
            case 15:t.dec_graphics=false
            }
            t.dirty=true;continue
        }
        #partial switch t.parser {
        case .Escape:
            t.parser=.Ground
            switch b {
            case '[':t.parser=.CSI;t.params={};t.param_count=1;t.private=0
            case ']':t.parser=.OSC;t.osc_len=0
            case 'P','^','_':t.parser=.Ignore
            case '(' , ')', '*', '+':t.parser=.Charset;t.charset_g0=b=='('
            case '7':t.saved=terminal_cursor_save(t)
            case '8':terminal_cursor_restore(t,t.saved)
            case 'D':terminal_linefeed(t)
            case 'E':t.cursor_x=0;terminal_linefeed(t)
            case 'M':terminal_reverse_index(t)
            case 'H':t.tabs[t.cursor_x]=true
            case 'c':terminal_reset(t)
            case '=':t.application_cursor=true
            case '>':t.application_cursor=false
            }
            t.dirty=true
        case .Charset:if t.charset_g0 {t.dec_graphics=b=='0'};t.parser=.Ground
        case .CSI:
            if b>='0'&&b<='9' {i:=t.param_count-1;t.params[i]=min(100000,t.params[i]*10+int(b-'0'))}
            else if b==';'||b==':' {if t.param_count<len(t.params) {t.param_count+=1}}
            else if b=='?'||b=='>'||b=='='||b=='!' {t.private=b}
            else if b>=0x40&&b<=0x7e {terminal_csi(t,b);t.parser=.Ground}
        case .Ground:
            if t.utf_remaining>0 {
                if b&0xc0==0x80 {
                    t.utf_value=(t.utf_value<<6)|rune(b&0x3f);t.utf_remaining-=1
                    if t.utf_remaining==0 {ch:=t.utf_value;if ch<t.utf_min||ch>0x10ffff||(ch>=0xd800&&ch<=0xdfff) {ch=0xfffd};terminal_put(t,ch)}
                    continue
                }
                t.utf_remaining=0;terminal_put(t,0xfffd)
            }
            if b<128 {terminal_put(t,rune(b))}
            else if b>=0xc2&&b<=0xdf {t.utf_value=rune(b&0x1f);t.utf_remaining=1;t.utf_min=0x80}
            else if b>=0xe0&&b<=0xef {t.utf_value=rune(b&0x0f);t.utf_remaining=2;t.utf_min=0x800}
            else if b>=0xf0&&b<=0xf4 {t.utf_value=rune(b&7);t.utf_remaining=3;t.utf_min=0x10000}
            else {terminal_put(t,0xfffd)}
        }
    }
    return offset
}
terminal_selfcheck :: proc()->bool {
    t:Terminal;terminal_init(&t,12,3);defer terminal_destroy(&t)
    terminal_feed(&t,transmute([]u8)string("\x1b[c\x1b[>"))
    terminal_feed(&t,transmute([]u8)string("0c"))
    if string(t.replies[:])!="\x1b[?1;2c\x1b[>0;0;0c" {return false}
    clear(&t.replies)
    terminal_feed(&t,transmute([]u8)string("\x1b[?1;2c\x1b[>0;0;0c\x1b[=c\x1b[1c\x1b[>1c"))
    if len(t.replies)!=0 {return false}
    terminal_feed(&t,transmute([]u8)string("hello\r\n\x1b[31mred\x1b[0m"))
    if t.screen[0].ch!='h'||t.screen[12].ch!='r'||t.screen[12].fg!=terminal_palette(1) {return false}
    terminal_feed(&t,transmute([]u8)string("\x1b[?1049hALT\x1b[?1049l"))
    if t.alternate||t.screen[0].ch!='h' {return false}
    terminal_feed(&t,transmute([]u8)string("\r\na\r\nb\r\nc"))
    if t.history_count<1 {return false}
    terminal_resize(&t,8,2)
    return t.cols==8&&t.rows==2&&len(t.screen)==16
}

package main

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import glfw "vendor:glfw"

EXPLORER_TILE_HEIGHT :: 124
EXPLORER_TILE_WIDTH :: 144
Explorer_Control :: enum {None,Up,Home,Reload,Path,Search,Clear_Search,Hidden,Close,Copy,Insert}
Explorer_Rect :: struct {x,y,w,h:f32}
Explorer_Layout :: struct {
    width,bottom,margin,rows_y,table_y,footer_y:f32,
    rows,columns:int,
    tile_width:f32,
    controls:[Explorer_Control]Explorer_Rect,
}
Explorer_Crumb :: struct {rect:Explorer_Rect,label,path:string,current:bool}

explorer_contains :: proc(rect:Explorer_Rect,x,y:f32)->bool {
    return rect.w>0&&rect.h>0&&x>=rect.x&&x<rect.x+rect.w&&y>=rect.y&&y<rect.y+rect.h
}
explorer_layout :: proc(a:^App)->Explorer_Layout {
    box:=Explorer_Layout{width=explorer_panel_width(a),bottom=f32(a.renderer.height)/a.scale}
    box.margin=16;if box.width>=760 {box.margin=24}
    edge:=box.width-box.margin
    c:=&box.controls
    c[.Close]={edge-32,HEADER+14,32,32}
    c[.Hidden]={edge-160,HEADER+14,116,32}
    for control,i in ([3]Explorer_Control{.Up,.Home,.Reload}) {c[control]={box.margin+f32(i)*36,HEADER+62,32,36}}
    path_x:=box.margin+116
    c[.Path]={path_x,HEADER+62,edge-path_x,36}
    box.table_y=HEADER+116
    if box.width>=760 {
        search_width:=min(280,box.width*0.27)
        c[.Search]={edge-search_width,HEADER+62,search_width,36}
        c[.Path].w-=search_width+12
    } else {
        c[.Search]={box.margin,HEADER+108,edge-box.margin,36}
        box.table_y+=46
    }
    search:=c[.Search]
    c[.Clear_Search]={search.x+search.w-32,search.y+4,28,28}
    box.rows_y=box.table_y+12
    box.footer_y=max(HEADER,box.bottom-56)
    box.columns=max(1,int((box.width-2*box.margin)/EXPLORER_TILE_WIDTH))
    box.tile_width=max(0,box.width-2*box.margin)/f32(box.columns)
    box.rows=max(0,int((box.footer_y-box.rows_y-8)/EXPLORER_TILE_HEIGHT))
    // Tiny windows retain the full footer without drawing controls underneath it.
    for control in Explorer_Control {
        if c[control].y+c[control].h>box.footer_y {c[control]={}}
    }
    c[.Copy]={edge-236,box.footer_y+12,118,32}
    c[.Insert]={edge-108,box.footer_y+12,108,32}
    return box
}
explorer_max_scroll :: proc(box:Explorer_Layout,count:int)->int {
    return max(0,(count+box.columns-1)/box.columns-box.rows)*box.columns
}
explorer_grid_scroll :: proc(box:Explorer_Layout,scroll,count:int)->int {
    return clamp(scroll/box.columns*box.columns,0,explorer_max_scroll(box,count))
}
explorer_tile_rect :: proc(box:Explorer_Layout,slot:int)->Explorer_Rect {
    return {box.margin+f32(slot%box.columns)*box.tile_width+4,
            box.rows_y+f32(slot/box.columns)*EXPLORER_TILE_HEIGHT+4,
            max(0,box.tile_width-8),EXPLORER_TILE_HEIGHT-8}
}
explorer_grid_hit :: proc(box:Explorer_Layout,e:^Explorer_State,x,y:f32)->int {
    if box.tile_width<=0||x<box.margin||x>=box.width-box.margin||y<box.rows_y||y>=box.rows_y+f32(box.rows)*EXPLORER_TILE_HEIGHT {return -1}
    slot:=int((y-box.rows_y)/EXPLORER_TILE_HEIGHT)*box.columns+int((x-box.margin)/box.tile_width)
    index:=explorer_grid_scroll(box,e.scroll,explorer_count(e))+slot
    if index>=explorer_count(e)||!explorer_contains(explorer_tile_rect(box,slot),x,y) {return -1}
    return index
}
explorer_control_at :: proc(box:Explorer_Layout,e:^Explorer_State,x,y:f32)->Explorer_Control {
    for control in ([10]Explorer_Control{.Up,.Home,.Reload,.Clear_Search,.Search,.Path,.Hidden,.Close,.Copy,.Insert}) {
        if control==.Clear_Search&&len(e.search)==0 {continue}
        if explorer_contains(box.controls[control],x,y) {return control}
    }
    return .None
}

// All chrome uses the shared antialiased primitives from ui_style.odin.
explorer_round_rect :: proc(a:^App,rect:Explorer_Rect,color:Color,radius:f32=5) {
    ui_round(a,rect.x,rect.y,rect.w,rect.h,radius,color)
}
explorer_stroke :: proc(a:^App,x0,y0,x1,y1:f32,color:Color,thickness:f32=1.3) {
    ui_stroke(a,x0,y0,x1,y1,color,thickness)
}
explorer_folder_icon :: proc(a:^App,x,y:f32,color:Color,background:Color) {
    _=background
    ui_icon(a,.Folder,x+1,y-1,color)
}
explorer_tile_icon :: proc(a:^App,entry:File_Entry,x,y:f32,color,surface:Color) {
    if entry.directory {
        // Back plate with tab, then a lightly tinted front body.
        ui_stroke(a,x+1,y+12,x+1,y+4.5,color,1.5);ui_stroke(a,x+1,y+4.5,x+3.5,y+2,color,1.5)
        ui_stroke(a,x+3.5,y+2,x+16,y+2,color,1.5);ui_stroke(a,x+16,y+2,x+20.5,y+7.5,color,1.5)
        ui_round(a,x+1,y+7.5,46,34.5,4,color*Color{1,1,1,0.10})
        ui_round_outline(a,x+0.25,y+7.5,47.5,34.5,4.5,color,1.5)
    } else {
        left,right,top,bottom:=x+8,x+40,y,y+42
        explorer_stroke(a,left,top,right-10,top,color,1.5)
        explorer_stroke(a,right-10,top,right,top+10,color,1.5)
        explorer_stroke(a,right,top+10,right,bottom,color,1.5)
        explorer_stroke(a,right,bottom,left,bottom,color,1.5)
        explorer_stroke(a,left,bottom,left,top,color,1.5)
        explorer_stroke(a,right-10,top,right-10,top+10,color,1.5)
        explorer_stroke(a,right-10,top+10,right,top+10,color,1.5)
        switch explorer_kind_label(entry) {
        case "Image":
            explorer_stroke(a,left+6,top+31,left+13,top+22,color)
            explorer_stroke(a,left+13,top+22,left+19,top+28,color)
            explorer_stroke(a,left+19,top+28,left+24,top+23,color)
            ui_rect(a,left+8,top+16,3,3,color)
        case "Source file","HTML document","Configuration":
            explorer_stroke(a,left+11,top+19,left+6,top+24,color)
            explorer_stroke(a,left+6,top+24,left+11,top+29,color)
            explorer_stroke(a,left+21,top+19,left+26,top+24,color)
            explorer_stroke(a,left+26,top+24,left+21,top+29,color)
            explorer_stroke(a,left+18,top+18,left+14,top+30,color)
        case:
            for line in 0..<3 {ui_rect(a,left+7,top+18+f32(line)*6,18-f32(line)*3,1.3,color)}
        }
    }
    if entry.symlink {
        ui_round(a,x+32,y+29,18,18,9,surface)
        ui_round_outline(a,x+32,y+29,18,18,9,color,1.2)
        ui_stroke(a,x+37.5,y+41.5,x+44.5,y+34.5,color);ui_stroke(a,x+39.5,y+34.5,x+44.5,y+34.5,color);ui_stroke(a,x+44.5,y+34.5,x+44.5,y+39.5,color)
    }
}
explorer_icon :: proc(a:^App,control:Explorer_Control,x,y:f32,color:Color) {
    switch control {
    case .Up:
        explorer_stroke(a,x+8,y+14,x+8,y+2,color)
        explorer_stroke(a,x+3,y+7,x+8,y+2,color);explorer_stroke(a,x+8,y+2,x+13,y+7,color)
    case .Home:
        explorer_stroke(a,x+1,y+7,x+8,y+1,color);explorer_stroke(a,x+8,y+1,x+15,y+7,color)
        explorer_stroke(a,x+3,y+6,x+3,y+14,color);explorer_stroke(a,x+13,y+6,x+13,y+14,color)
        explorer_stroke(a,x+3,y+14,x+13,y+14,color)
        explorer_stroke(a,x+7,y+14,x+7,y+9,color);explorer_stroke(a,x+7,y+9,x+10,y+9,color)
        explorer_stroke(a,x+10,y+9,x+10,y+14,color)
    case .Reload:
        // Rotate-clockwise: an arc from three o'clock round to twelve, a short
        // lead into the top-right corner, and an L-shaped arrowhead there.
        cx,cy,r:=x+8,y+8.5,f32(5.5)
        steps:=18
        for step in 0..<steps {
            angle:=f32(step)/f32(steps)*1.5*math.PI;next:=f32(step+1)/f32(steps)*1.5*math.PI
            explorer_stroke(a,cx+math.cos(angle)*r,cy+math.sin(angle)*r,cx+math.cos(next)*r,cy+math.sin(next)*r,color,1.4)
        }
        explorer_stroke(a,cx,cy-r,cx+2.6,cy-r+0.7,color,1.4);explorer_stroke(a,cx+2.6,cy-r+0.7,cx+r,cy-r+3.1,color,1.4)
        explorer_stroke(a,cx+r,cy-r+3.1,cx+r,cy-r-0.2,color,1.4);explorer_stroke(a,cx+r,cy-r+3.1,cx+r-3.3,cy-r+3.1,color,1.4)
    case .Search:
        for step in 0..<16 {
            angle:=f32(step)*math.PI/8;next:=angle+math.PI/8
            explorer_stroke(a,x+6+math.cos(angle)*4.5,y+6+math.sin(angle)*4.5,x+6+math.cos(next)*4.5,y+6+math.sin(next)*4.5,color)
        }
        explorer_stroke(a,x+9.5,y+9.5,x+14,y+14,color)
    case .Close,.Clear_Search:
        explorer_stroke(a,x+4,y+4,x+12,y+12,color);explorer_stroke(a,x+12,y+4,x+4,y+12,color)
    case .Copy:
        ui_stroke(a,x+2.5,y+11,x+2.5,y+3.5,color);ui_stroke(a,x+2.5,y+3.5,x+3.5,y+2.5,color);ui_stroke(a,x+3.5,y+2.5,x+10,y+2.5,color)
        ui_round_outline(a,x+5,y+5,9.5,10.5,2,color)
    case .Insert:
        explorer_stroke(a,x+2,y+4,x+6,y+8,color);explorer_stroke(a,x+6,y+8,x+2,y+12,color)
        explorer_stroke(a,x+8,y+12,x+14,y+12,color)
    case .Path:
        explorer_stroke(a,x+3,y+12,x+12,y+3,color);explorer_stroke(a,x+3,y+12,x+2,y+15,color)
        explorer_stroke(a,x+2,y+15,x+5,y+14,color);explorer_stroke(a,x+10,y+3,x+13,y+6,color)
    case .None,.Hidden: // Non-icon controls use text.
    }
}
explorer_field :: proc(a:^App,rect:Explorer_Rect,focused:bool,hover:bool) {
    ui_field(a,rect.x,rect.y,rect.w,rect.h,focused,hover)
}
explorer_button :: proc(a:^App,rect:Explorer_Rect,control:Explorer_Control,label:string,hover:bool,enabled:bool=true,active:bool=false) {
    if rect.w<=0 {return}
    color:=SOFT
    outlined:=control==.Copy||control==.Insert
    if control==.Hidden {
        updater_switch(a,label,rect.x+4,rect.y+1,active,hover)
        return
    }
    ui_control(a,rect.x,rect.y,rect.w,rect.h,.Outline if outlined else .Ghost,hover,enabled,active)
    if active||(hover&&enabled) {color=TEXT}
    if !enabled {color=FAINT}
    if label=="" {explorer_icon(a,control,rect.x+(rect.w-16)/2,rect.y+(rect.h-16)/2,color)}
    else {
        offset:f32=12
        if outlined {explorer_icon(a,control,rect.x+11,rect.y+(rect.h-16)/2,color);offset=34}
        ui_text_mid(a,label,rect.x+offset,rect.y+rect.h/2,13,rect.w-offset-8,color)
    }
}
explorer_text_width :: proc(a:^App,text:string,limit:f32)->f32 {
    font:=renderer_font_size(&a.renderer,13*a.scale);width:f32
    for ch in text {
        width+=renderer_glyph(&a.renderer,font,ch).advance/a.scale
        if width>=limit {return limit}
    }
    return width
}
explorer_breadcrumbs :: proc(a:^App,e:^Explorer_State,rect:Explorer_Rect)->[]Explorer_Crumb {
    crumbs:=make([dynamic]Explorer_Crumb,context.temp_allocator)
    if rect.w<=70||e.listing.path=="" {return crumbs[:]}
    path:=e.listing.path
    parts:=make([dynamic]Explorer_Crumb,context.temp_allocator)
    for start:=1;start<len(path); {
        end:=start
        for end<len(path)&&path[end]!='/' {end+=1}
        if end>start {append(&parts,Explorer_Crumb{label=path[start:end],path=path[:end],current=end==len(path)})}
        start=end+1
    }
    available:=rect.w-68
    first:=len(parts);used:f32
    for first>0 {
        width:=explorer_text_width(a,parts[first-1].label,min(180,max(24,available-40)))+24
        if used+width>available&&first<len(parts) {break}
        used+=width;first-=1
    }
    x:=rect.x+8
    append(&crumbs,Explorer_Crumb{rect={x,rect.y+4,24,rect.h-8},label="/",path="/",current=len(parts)==0})
    x+=28
    if first>0 {
        append(&crumbs,Explorer_Crumb{rect={x,rect.y+4,26,rect.h-8},label="…",path=parts[first-1].path})
        x+=30
    }
    for part in parts[first:] {
        crumb:=part
        width:=min(explorer_text_width(a,part.label,180)+16,max(0,rect.x+rect.w-30-x))
        crumb.rect={x,rect.y+4,width,rect.h-8}
        append(&crumbs,crumb);x+=width+12
    }
    return crumbs[:]
}
explorer_hover_key :: proc(a:^App,x,y:f32)->u64 {
    e:=&active_tab(a).explorer;box:=explorer_layout(a)
    control:=explorer_control_at(box,e,x,y)
    if control==.Path&&!e.editing {
        for crumb,i in explorer_breadcrumbs(a,e,box.controls[.Path]) {
            if explorer_contains(crumb.rect,x,y) {return (u64(11)<<32)|u64(i+1)}
        }
    }
    if control!=.None {return (u64(10)<<32)|u64(control)}
    index:=explorer_grid_hit(box,e,x,y)
    if index>=0&&explorer_page_entry(e,index)!=nil {return (u64(4)<<32)|u64(index+1)}
    return 0
}
explorer_kind_label :: proc(entry:File_Entry)->string {
    if entry.directory {if entry.symlink {return "Folder link"};return "Folder"}
    if entry.symlink {return "Symbolic link"}
    extension:=filepath.ext(entry.name)
    switch strings.to_lower(extension,context.temp_allocator) {
    case ".md",".markdown",".mdown",".mkd",".mkdn",".mdwn":return "Markdown"
    case ".html",".htm",".xhtml":return "HTML document"
    case ".txt",".log":return "Text document"
    case ".png",".jpg",".jpeg",".webp",".gif",".svg",".avif":return "Image"
    case ".zip",".gz",".xz",".tar",".7z",".zst":return "Archive"
    case ".json",".yaml",".yml",".toml",".ini":return "Configuration"
    case ".odin",".c",".h",".cpp",".rs",".go",".py",".js",".ts",".tsx",".sh":return "Source file"
    }
    if extension!=""&&len(extension)<=12 {return fmt.tprintf("%s file",strings.to_upper(extension[1:],context.temp_allocator))}
    return "File"
}
explorer_toolbar_render :: proc(a:^App,tab:^Tab,box:Explorer_Layout,hover:Explorer_Control) {
    e:=&tab.explorer;c:=box.controls
    if c[.Close].w>0 {
        ui_icon(a,.Folder,box.margin,HEADER+22,SOFT)
        ui_title(a,"Files",box.margin+26,HEADER+30,16,60)
        device:="Local";if tab.remote {device=tab.device.name}
        ui_rect(a,box.margin+76,HEADER+23,1,14,LINE)
        ui_text_mid(a,device,box.margin+88,HEADER+30,13,c[.Hidden].x-box.margin-104,MUTED)
    }
    explorer_button(a,c[.Close],.Close,"",hover==.Close)
    explorer_button(a,c[.Hidden],.Hidden,"Hidden files",hover==.Hidden,true,e.show_hidden)
    explorer_button(a,c[.Up],.Up,"",hover==.Up,e.loaded&&e.listing.path!="/")
    explorer_button(a,c[.Home],.Home,"",hover==.Home)
    explorer_button(a,c[.Reload],.Reload,"",hover==.Reload)
    path:=c[.Path]
    explorer_field(a,path,e.editing,hover==.Path)
    if path.w>0 {
        text_x:=path.x+12;text_width:=max(0,path.w-48)
        if e.editing {
            start:=explorer_input_start(a,e.input[:e.used],e.cursor,13,text_width-4)
            text_edit_selection_render(a,e.input[:e.used],start,e.cursor,e.input_anchor,e.input_selecting,e.select_all,text_x,path.y+7,13,text_width,22)
            ui_fit_text(a,string(e.input[start:e.used]),text_x,path.y+11,13,text_width,TEXT)
            caret:=renderer_text_width(&a.renderer,string(e.input[start:e.cursor]),13*a.scale)/a.scale
            ui_caret(a,text_x+caret,path.y+9,18)
            ui_text_mid(a,"↵",path.x+path.w-24,path.y+path.h/2,14,16,MUTED)
        } else if e.loaded&&e.listing.path!="" {
            mouse_x,mouse_y:=glfw.GetCursorPos(a.renderer.window)
            for crumb,i in explorer_breadcrumbs(a,e,path) {
                over:=explorer_contains(crumb.rect,f32(mouse_x),f32(mouse_y))
                color:=SOFT;if crumb.current {color=TEXT}
                if over {ui_round(a,crumb.rect.x,crumb.rect.y,crumb.rect.w,crumb.rect.h,RADIUS_ROW,ROW_SELECTED);color=TEXT}
                if i>0 {ui_icon_chevron(a,crumb.rect.x-6,path.y+path.h/2,7,FAINT,0)}
                ui_text_mid(a,crumb.label,crumb.rect.x+6,path.y+path.h/2,13,crumb.rect.w-12,color)
            }
            explorer_icon(a,.Path,path.x+path.w-24,path.y+10,MUTED)
        } else {ui_text_mid(a,"Loading folder…",text_x,path.y+path.h/2,13,text_width,MUTED)}
    }
    search:=c[.Search]
    explorer_field(a,search,e.search_editing,hover==.Search||hover==.Clear_Search)
    if search.w>0 {
        explorer_icon(a,.Search,search.x+12,search.y+10,MUTED)
        x:=search.x+36;width:=max(0,search.w-74)
        start:=0
        if e.search_editing {
            start=explorer_input_start(a,e.search[:],e.search_cursor,13,width-4)
            text_edit_selection_render(a,e.search[:],start,e.search_cursor,e.search_anchor,e.search_selecting,e.search_select_all,x,search.y+7,13,width,22)
        }
        if len(e.search)==0&&!e.search_editing {
            ui_text_mid(a,"Search this folder",x,search.y+search.h/2,13,width,MUTED)
            if search.w>=250 {
                hint_w:=renderer_text_width(&a.renderer,"Ctrl+F",11*a.scale)/a.scale+12
                _=ui_badge(a,"Ctrl+F",search.x+search.w-hint_w-8,search.y+search.h/2-9.5,MUTED)
            }
        } else {ui_text_mid(a,string(e.search[start:]),x,search.y+search.h/2,13,width,TEXT)}
        if e.search_editing {
            caret:=renderer_text_width(&a.renderer,string(e.search[start:e.search_cursor]),13*a.scale)/a.scale
            ui_caret(a,x+caret,search.y+9,18)
        }
        if len(e.search)>0 {explorer_button(a,c[.Clear_Search],.Clear_Search,"",hover==.Clear_Search)}
    }
}

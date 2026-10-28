package main

import "core:c"
import "core:crypto"
import "core:strings"
import "core:time"
import glfw "vendor:glfw"

Tab_Drop_Mode :: enum {Insert,Group,List}
GROUP_ROW_HEIGHT :: 32
Tab_Group_Ref :: struct {id:u64,label:string}
Group_Menu_State :: struct {id:u64,scroll:int}
Group_Popup :: struct {
    x,y,w,h:f32,rows,count,depth:int,group:u64,valid:bool,
    items:[MAX_TABS]int,
    groups:[MAX_TABS]u64,
}

tab_group_depth :: proc(tab:^Tab)->int {if tab.group_id==0 {return 0};return len(tab.group_parents)+1}
tab_group_at :: proc(tab:^Tab,level:int)->Tab_Group_Ref {
    if level<0||level>=tab_group_depth(tab) {return {}}
    if level<len(tab.group_parents) {return tab.group_parents[level]}
    return {id=tab.group_id,label=tab.group_label}
}
tab_group_level :: proc(tab:^Tab,id:u64)->int {
    if id==0 {return -1}
    for level in 0..<tab_group_depth(tab) {if tab_group_at(tab,level).id==id {return level}}
    return -1
}
tab_root_group :: proc(tab:^Tab)->u64 {return tab_group_at(tab,0).id}
tab_group_name :: proc(tab:^Tab,id:u64=0)->string {
    target:=id;if target==0 {target=tab.group_id}
    group:=tab_group_at(tab,tab_group_level(tab,target))
    if group.label!="" {return group.label};return "Group"
}
tab_group_copy_path :: proc(tab:^Tab,start:int=0,end:int=-1)->[]Tab_Group_Ref {
    finish:=end;if finish<0 {finish=tab_group_depth(tab)}
    finish=clamp(finish,start,tab_group_depth(tab))
    result:=make([]Tab_Group_Ref,finish-start,context.temp_allocator)
    for i in start..<finish {group:=tab_group_at(tab,i);result[i-start]={id=group.id,label=strings.clone(group.label,context.temp_allocator)}}
    return result
}
tab_set_path :: proc(tab:^Tab,path:[]Tab_Group_Ref) {
    // Clone before freeing: callers may be using this tab's current path.
    parents:=make([dynamic]Tab_Group_Ref)
    for i in 0..<max(0,len(path)-1) {append(&parents,Tab_Group_Ref{id=path[i].id,label=strings.clone(path[i].label)})}
    leaf:Tab_Group_Ref
    if len(path)>0 {leaf={id=path[len(path)-1].id,label=strings.clone(path[len(path)-1].label)}}
    for parent in tab.group_parents {delete(parent.label)};delete(tab.group_parents);delete(tab.group_label)
    tab.group_parents=parents;tab.group_id=leaf.id;tab.group_label=leaf.label
}
tab_set_group :: proc(tab:^Tab,id:u64,label:string) {
    if id==0 {tab_set_path(tab,nil)} else {path:=[1]Tab_Group_Ref{{id=id,label=label}};tab_set_path(tab,path[:])}
}
tab_group_rename :: proc(a:^App,id:u64,label:string) {
    for tab in a.tabs {
        level:=tab_group_level(tab,id);if level<0 {continue}
        if level<len(tab.group_parents) {delete(tab.group_parents[level].label);tab.group_parents[level].label=strings.clone(label)}
        else {delete(tab.group_label);tab.group_label=strings.clone(label)}
    }
}
tab_group_new_id :: proc()->u64 {
    bytes:[8]u8;crypto.rand_bytes(bytes[:]);id:u64
    for b in bytes {id=(id<<8)|u64(b)}
    return max(1,id)
}
tab_group_first :: proc(a:^App,id:u64)->int {
    if id!=0 {for tab,i in a.tabs {if tab_group_level(tab,id)>=0 {return i}}}
    return -1
}
tab_group_count :: proc(a:^App,id:u64)->int {
    count:=0;for tab in a.tabs {if tab_group_level(tab,id)>=0 {count+=1}};return count
}
// Return the direct children of a group. A child group is represented by its
// first live tab, while its ID distinguishes it from that individual tab.
tab_group_children :: proc(a:^App,id:u64)->Group_Popup {
    result:=Group_Popup{group=id}
    for tab,index in a.tabs {
        level:= -1
        if id!=0 {level=tab_group_level(tab,id);if level<0 {continue}}
        child:=tab_group_at(tab,level+1).id
        if child!=0 {
            seen:=false
            for row in 0..<result.count {if result.groups[row]==child {seen=true;break}}
            if seen {continue}
        }
        result.items[result.count]=index;result.groups[result.count]=child;result.count+=1
    }
    return result
}
tab_group_end :: proc(a:^App,index:int,id:u64=0)->int {
    if index<0||index>=len(a.tabs) {return len(a.tabs)}
    if id==0 {return index+1}
    end:=index+1
    for end<len(a.tabs)&&tab_group_level(a.tabs[end],id)>=0 {end+=1}
    return end
}
tab_group_close :: proc(a:^App) {
    if a.group_hover!=0||len(a.group_menus)>0 {a.group_hover=0;clear(&a.group_menus);a.dirty=true}
}
tab_group_open_to :: proc(a:^App,id:u64) {
    first:=tab_group_first(a,id)
    if first<0 {tab_group_close(a);return}
    tab:=a.tabs[first];level:=tab_group_level(tab,id)
    previous:=make([]Group_Menu_State,len(a.group_menus),context.temp_allocator);copy(previous,a.group_menus[:])
    clear(&a.group_menus)
    for i in 0..=level {
        state:=Group_Menu_State{id=tab_group_at(tab,i).id}
        if i<len(previous)&&previous[i].id==state.id {state.scroll=previous[i].scroll}
        append(&a.group_menus,state)
    }
    height:=f32(a.renderer.height)/a.scale
    for i in 0..<level {
        children:=tab_group_children(a,a.group_menus[i].id)
        rows:=max(1,min(children.count,int((height-HEADER-12)/GROUP_ROW_HEIGHT)))
        for row in 0..<children.count {
            if children.groups[row]!=a.group_menus[i+1].id {continue}
            if row<a.group_menus[i].scroll {a.group_menus[i].scroll=row}
            else if row>=a.group_menus[i].scroll+rows {a.group_menus[i].scroll=row-rows+1}
            break
        }
    }
    a.group_hover=tab_root_group(tab);a.dirty=true
}

// Depth-first packing keeps all descendants contiguous without changing any
// terminal, history, or file-browser ownership.
tab_groups_pack :: proc(a:^App) {
    if len(a.tabs)==0 {tab_group_close(a);return}
    active:=active_tab(a);packed:[MAX_TABS]^Tab;used:=0
    visit :: proc(a:^App,id:u64,packed:^[MAX_TABS]^Tab,used:^int) {
        children:=tab_group_children(a,id)
        for row in 0..<children.count {
            child:=children.groups[row]
            if child!=0 {visit(a,child,packed,used)}
            else {packed[used^]=a.tabs[children.items[row]];used^+=1}
        }
    }
    visit(a,0,&packed,&used)
    copy(a.tabs[:],packed[:used])
    for tab,i in a.tabs {if tab==active {a.active=i;break}}
    if tab_group_first(a,a.group_hover)<0 {tab_group_close(a)}
    else if len(a.group_menus)>0 {
        valid:=len(a.group_menus)
        for menu,i in a.group_menus {
            first:=tab_group_first(a,menu.id)
            if first<0||tab_group_at(a.tabs[first],i).id!=menu.id {valid=i;break}
        }
        resize(&a.group_menus,valid)
        if valid==0 {tab_group_close(a)}
    }
}
tab_bar_slot :: proc(a:^App,bar:Tab_Bar_Layout,tab:^Tab)->int {
    for slot in 0..<bar.count {
        representative:=a.tabs[bar.items[slot]]
        if representative==tab||(bar.groups[slot]!=0&&bar.groups[slot]==tab_root_group(tab)) {return slot}
    }
    return -1
}

tab_group_popup :: proc(a:^App,depth:int=0)->Group_Popup {
    if a.group_hover==0||a.menu.open||a.picker.open||depth<0||depth>=len(a.group_menus) {return {}}
    width,height:=f32(a.renderer.width)/a.scale,f32(a.renderer.height)/a.scale
    bar:=tab_bar_layout(a);previous:Group_Popup
    for level in 0..=depth {
        state:=&a.group_menus[level];box:=tab_group_children(a,state.id)
        if box.count==0 {return {}}
        box.depth=level;box.rows=max(1,min(box.count,int((height-HEADER-12)/GROUP_ROW_HEIGHT)))
        box.w=min(300,width-16);box.h=f32(box.rows)*GROUP_ROW_HEIGHT+12;box.y=HEADER-1
        state.scroll=clamp(state.scroll,0,max(0,box.count-box.rows))
        if level==0 {
            first:=tab_group_first(a,state.id);if first<0 {return {}}
            slot:=tab_bar_slot(a,bar,a.tabs[first]);if slot<bar.first||slot>=bar.first+bar.visible {return {}}
            box.x=clamp(bar.start+f32(slot-bar.first)*bar.tab_width,8,max(8,width-box.w-8))
        } else {
            row:= -1
            for i in 0..<previous.count {if previous.groups[i]==state.id {row=i;break}}
            scroll:=a.group_menus[level-1].scroll
            if row<scroll||row>=scroll+previous.rows {return {}}
            box.x=previous.x+previous.w-1
            if box.x+box.w>width-8 {box.x=previous.x-box.w+1}
            box.x=clamp(box.x,8,max(8,width-box.w-8))
            box.y=clamp(previous.y+f32(row-scroll)*GROUP_ROW_HEIGHT,HEADER-1,max(HEADER-1,height-box.h-8))
        }
        box.valid=true;previous=box
    }
    return previous
}
tab_group_popup_contains :: proc(box:Group_Popup,x,y:f32)->bool {
    return box.valid&&x>=box.x&&x<box.x+box.w&&y>=box.y&&y<box.y+box.h
}
tab_group_hit :: proc(a:^App,x,y:f32)->(box:Group_Popup,row,index:int,group:u64) {
    for depth:=len(a.group_menus)-1;depth>=0;depth-=1 {
        next:=tab_group_popup(a,depth)
        if !tab_group_popup_contains(next,x,y) {continue}
        if y<next.y+6||y>=next.y+next.h-6 {return next,-1,-1,0}
        row=a.group_menus[depth].scroll+int((y-next.y-6)/GROUP_ROW_HEIGHT)
        if row>=next.count {return next,-1,-1,0}
        return next,row,next.items[row],next.groups[row]
    }
    return {},-1,-1,0
}
tab_group_popup_hit :: proc(a:^App,x,y:f32)->int {_,_,index,_:=tab_group_hit(a,x,y);return index}

// Open the next submenu in the cursor event itself, without a hover timer.
tab_group_hover :: proc(a:^App,x,y:f32) {
    if a.menu.open||a.picker.open {tab_group_close(a);return}
    if a.tab_rename.tab!=nil {return}
    if y>=0&&y<HEADER {
        index:=tab_bar_hit(tab_bar_layout(a),x)
        if index>=0 {
            id:=tab_root_group(a.tabs[index])
            if id!=0 {if a.group_hover!=id {tab_group_open_to(a,id)};return}
        }
    }
    box,row,_,child:=tab_group_hit(a,x,y)
    if box.valid {
        if row<0 {return}
        wanted:=box.depth+1
        if child!=0 {wanted+=1}
        same:=len(a.group_menus)==wanted
        if same&&child!=0 {same=a.group_menus[wanted-1].id==child}
        if !same {
            resize(&a.group_menus,box.depth+1)
            if child!=0 {append(&a.group_menus,Group_Menu_State{id=child})}
            a.dirty=true
        }
        return
    }
    tab_group_close(a)
}
tab_click :: proc(a:^App,index:int,x,y:f64,group_header:bool,group_id:u64=0) {
    tab:=a.tabs[index];now:=time.tick_now();id:=group_id
    if group_header&&id==0 {id=tab_root_group(tab)}
    dx,dy:=x-a.last_tab_click_x,y-a.last_tab_click_y
    double:=a.last_tab_click==tab&&a.last_tab_click_group==id&&time.duration_seconds(time.tick_diff(a.last_tab_click_time,now))<0.4&&dx*dx+dy*dy<36
    app_select_device(a,index)
    if double {
        if group_header {tab_rename_begin_group(a,tab,id)} else {tab_rename_begin(a,tab)}
    } else {
        a.last_tab_click=tab;a.last_tab_click_group=id;a.last_tab_click_time=now;a.last_tab_click_x=x;a.last_tab_click_y=y
        tab_drag_press(a,tab,x,y,id)
    }
}
tab_group_mouse :: proc(a:^App,button,action:c.int,x,y:f32)->bool {
    box,_,index,group:=tab_group_hit(a,x,y)
    if !box.valid||y<HEADER {return false}
    if action!=glfw.PRESS||index<0 {return true}
    if group==0&&(button==glfw.MOUSE_BUTTON_MIDDLE||(button==glfw.MOUSE_BUTTON_LEFT&&x>=box.x+box.w-30)) {app_close_tab(a,index);return true}
    if button==glfw.MOUSE_BUTTON_LEFT {tab_click(a,index,f64(x),f64(y),group!=0,group)}
    return true
}
tab_group_scroll :: proc(a:^App,delta:int)->bool {
    x,y:=glfw.GetCursorPos(a.renderer.window);box,_,_,_:=tab_group_hit(a,f32(x),f32(y))
    if !box.valid {return false}
    state:=&a.group_menus[box.depth];state.scroll=clamp(state.scroll-delta,0,max(0,box.count-box.rows))
    resize(&a.group_menus,box.depth+1);a.dirty=true;return true
}
tab_group_render :: proc(a:^App) {
    mx,my:=glfw.GetCursorPos(a.renderer.window)
    for depth in 0..<len(a.group_menus) {
        box:=tab_group_popup(a,depth);if !box.valid {break}
        scroll:=a.group_menus[depth].scroll
        ui_rect(a,box.x+3,box.y+4,box.w,box.h,Color{0,0,0,0.6})
        ui_rect(a,box.x-1,box.y,box.w+2,box.h+1,LINE);ui_rect(a,box.x,box.y,box.w,box.h,PANEL)
        for row in 0..<box.rows {
            item:=row+scroll;index:=box.items[item];tab:=a.tabs[index];group:=box.groups[item]
            y:=box.y+6+f32(row)*GROUP_ROW_HEIGHT
            hover:=f32(mx)>=box.x&&f32(mx)<box.x+box.w&&f32(my)>=y&&f32(my)<y+GROUP_ROW_HEIGHT
            selected:=index==a.active||(group!=0&&tab_group_level(active_tab(a),group)>=0)
            if selected {ui_rect(a,box.x+3,y,box.w-6,GROUP_ROW_HEIGHT,SELECTION)}
            else if hover {ui_rect(a,box.x+3,y,box.w-6,GROUP_ROW_HEIGHT,HOVER)}
            title:=tab_title(tab);if group!=0 {title=tab_group_name(tab,group)}
            if !tab_rename_render_box(a,tab,box.x,y,box.w,GROUP_ROW_HEIGHT,group) {ui_fit_text(a,title,box.x+12,y+10,14,box.w-44,TEXT)}
            if group!=0 {ui_text(a,"›",box.x+box.w-24,y+8,18,MUTED)} else {ui_text(a,"×",box.x+box.w-23,y+10,14,MUTED)}
        }
        if box.count>box.rows {
            track:=f32(box.rows)*GROUP_ROW_HEIGHT;thumb:=max(16,track*f32(box.rows)/f32(box.count))
            ui_rect(a,box.x+box.w-3,box.y+6+(track-thumb)*f32(scroll)/f32(box.count-box.rows),2,thumb,MUTED)
        }
        if tab_drag.dragging&&tab_drag.target==a&&tab_drag.list_depth==depth&&tab_drag.drop_mode==.List {
            row:=box.count
            for i in 0..<box.count {if box.items[i]>=tab_drag.insertion {row=i;break}}
            y:=clamp(box.y+6+f32(row-scroll)*GROUP_ROW_HEIGHT,box.y+6,box.y+box.h-6)
            ui_rect(a,box.x+5,y-1,box.w-10,2,ACCENT)
        }
        if tab_drag.dragging&&tab_drag.target==a&&tab_drag.list_depth==depth&&tab_drag.drop_mode==.Group&&tab_drag.target_y>=f64(HEADER) {
            for row in 0..<box.rows {
                item:=row+scroll
                if a.tabs[box.items[item]]!=tab_drag.onto||box.groups[item]!=tab_drag.onto_group {continue}
                x:=box.x+box.w/2-12;y:=box.y+6+f32(row)*GROUP_ROW_HEIGHT+4
                ui_rect(a,x,y,24,24,ACCENT);ui_rect(a,x+1,y+1,22,22,BG);ui_text(a,"+",x+7,y+4,18,ACCENT)
            }
        }
    }
}

workspace_request_drop :: proc(source:^App,tab:^Tab,target:^App,index:int,mode:Tab_Drop_Mode,onto:^Tab,group_id,to_group:u64,onto_group:u64=0) {
    append(&workspace_actions,Workspace_Action{kind=.Drop,source=source,target=target,tab=tab,index=index,drop_mode=mode,onto=onto,group_id=group_id,to_group=to_group,onto_group=onto_group})
    glfw.PostEmptyEvent()
}
workspace_drop_tabs :: proc(action:Workspace_Action)->bool {
    source,target:=action.source,action.target;members:[MAX_TABS]^Tab;relative:[MAX_TABS][]Tab_Group_Ref;count:=0
    for tab in source.tabs {
        level:=tab_group_level(tab,action.group_id)
        if (action.group_id==0&&tab==action.tab)||(action.group_id!=0&&level>=0) {
            members[count]=tab
            if action.group_id!=0 {relative[count]=tab_group_copy_path(tab,level)}
            count+=1
        }
    }
    if count==0||(source!=target&&len(target.tabs)+count>MAX_TABS) {return false}
    container:=action.to_group
    if action.drop_mode==.Group&&action.onto_group!=0 {container=action.onto_group}
    if action.drop_mode==.Insert {container=0}
    if action.group_id!=0&&container!=0 {
        first:=tab_group_first(target,container)
        if first<0||tab_group_level(target.tabs[first],action.group_id)>=0 {return false}
    }
    prefix:[]Tab_Group_Ref
    if container!=0 {
        first:=tab_group_first(target,container);if first<0 {return false}
        sample:=target.tabs[first];prefix=tab_group_copy_path(sample,0,tab_group_level(sample,container)+1)
    }
    anchor:^Tab
    if action.index<len(target.tabs) {anchor=target.tabs[max(0,action.index)]}
    if action.drop_mode==.Group {
        if action.onto==nil||tab_drag_index(target,action.onto)<0 {return false}
        if action.onto_group==0 {
            for tab in members[:count] {if tab==action.onto {return true}}
            // Center-dropping onto a tab creates a subgroup at that tab's
            // current level. Existing groups retain their full subtree.
            next:=make([]Tab_Group_Ref,len(prefix)+1,context.temp_allocator);copy(next,prefix)
            next[len(prefix)]={id=tab_group_new_id()};prefix=next
            tab_set_path(action.onto,prefix)
        }
        id:=prefix[len(prefix)-1].id
        end:=tab_group_end(target,tab_group_first(target,id),id);anchor=nil
        if end<len(target.tabs) {anchor=target.tabs[end]}
    }
    for member in members[:count] {
        if anchor==member {
            start:=tab_drag_index(target,anchor)
            anchor=nil
            for i:=max(0,start);i<len(target.tabs);i+=1 {
                candidate:=target.tabs[i];moving:=false
                for m in members[:count] {if m==candidate {moving=true;break}}
                if !moving {anchor=candidate;break}
            }
            break
        }
    }
    tab_rename_finish(source,true);if source!=target {tab_rename_finish(target,true)}
    for tab in members[:count] {tab_set_path(tab,nil)}
    for tab,i in members[:count] {
        at:=len(target.tabs);if anchor!=nil {next:=tab_drag_index(target,anchor);if next>=0 {at=next}}
        if !workspace_move_tab(source,tab,target,at,false) {return false}
        path:=make([]Tab_Group_Ref,len(prefix)+len(relative[i]),context.temp_allocator)
        copy(path,prefix);copy(path[len(prefix):],relative[i]);tab_set_path(tab,path)
    }
    tab_groups_pack(source);if source!=target {tab_groups_pack(target)}
    selected:=tab_drag_index(target,action.tab);if selected>=0 {app_select_device(target,selected)}
    if len(prefix)>0 {tab_group_open_to(target,prefix[len(prefix)-1].id)}
    else if action.group_id!=0 {tab_group_open_to(target,action.group_id)}
    session_touch(source);session_touch(target);source.dirty=true;target.dirty=true
    return true
}

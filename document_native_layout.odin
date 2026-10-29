package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"
import glfw "vendor:glfw"

Native_Flow :: struct {a:^App,view:^Document_View,doc:^Native_Document,plain:^[dynamic]u8,left,right,x,y,line,height,collapsible_margin:f32,owner,line_start,align:int}
native_flow_break :: proc(flow:^Native_Flow,minimum:f32=0,justify_line:bool=false) {
    if flow.x>flow.left||flow.line>0 {
        remaining:=max(0,flow.right-flow.x);shift:f32
        if flow.align==1 {shift=remaining/2} else if flow.align==2 {shift=remaining}
        spaces:=0;if flow.align==3&&justify_line {for fragment in flow.doc.fragments[flow.line_start:] {if fragment.text==" " {spaces+=1}}}
        for &fragment in flow.doc.fragments[flow.line_start:] {fragment.x+=shift;if spaces>0&&fragment.text==" " {extra:=remaining/f32(spaces);fragment.w+=extra;shift+=extra}}
        flow.y+=max(flow.line,minimum);flow.x=flow.left;flow.line=0
        if len(flow.plain^)>0&&flow.plain^[len(flow.plain^)-1]!='\n' {append(flow.plain,'\n')}
    } else if minimum>0 {flow.y+=minimum}
    flow.line_start=len(flow.doc.fragments)
}
native_text_width :: proc(a:^App,text:string,style:Native_Style,zoom:f32)->f32 {
    font:=renderer_font_size(&a.renderer,style.size*zoom*a.scale,native_font_kind(style))
    width:f32;for ch in text {width+=renderer_glyph(&a.renderer,font,ch).advance};return width/a.scale
}
native_font_kind :: proc(style:Native_Style)->Font_Kind {
    if !style.mono&&!style.bold&&!style.italic {return .UI}
    if style.bold&&style.italic {return .Terminal_Bold_Italic}
    if style.bold {return .Terminal_Bold}
    if style.italic {return .Terminal_Italic}
    return .Terminal
}
native_flow_word :: proc(flow:^Native_Flow,node:int,text:string,style:Native_Style) {
    if text=="" {return}
    flow.collapsible_margin=0
    zoom:=f32(flow.view.zoom)
    height:=style.size*zoom*max(1,style.line_height)
    width:=native_text_width(flow.a,text,style,zoom)
    if !style.nowrap&&flow.x>flow.left&&flow.x+width>flow.right {native_flow_break(flow,justify_line=true)}
    // Long URLs and unbroken words wrap at Unicode character boundaries.
    if !style.nowrap&&width>flow.right-flow.left&&len(text)>1 {
        cursor:=0
        for cursor<len(text) {
            end:=cursor;part_width:f32
            for end<len(text) {ch,size:=utf8.decode_rune_in_string(text[end:]);next:=native_text_width(flow.a,string_from_rune(ch),style,zoom);if end>cursor&&part_width+next>flow.right-flow.x {break};part_width+=next;end+=max(1,size)}
            if end==cursor {native_flow_break(flow);continue}
            fragment:=text[cursor:end];start:=len(flow.plain^);append(flow.plain,fragment)
            append(&flow.doc.fragments,Native_Fragment{node=node,start=start,end=len(flow.plain^),text=fragment,x=flow.x,y=flow.y,w=part_width,h=height,style=style,image=-1})
            flow.x+=part_width;flow.line=max(flow.line,height);cursor=end
            if cursor<len(text) {native_flow_break(flow,justify_line=true)}
        }
        return
    }
    start:=len(flow.plain^);append(flow.plain,text)
    append(&flow.doc.fragments,Native_Fragment{node=node,start=start,end=len(flow.plain^),text=text,x=flow.x,y=flow.y,w=width,h=height,style=style,image=-1})
    flow.x+=width;flow.line=max(flow.line,height)
}
native_flow_text :: proc(flow:^Native_Flow,node:int,text:string,style:Native_Style) {
    if style.pre {
        expanded,_:=strings.replace_all(text,"\t","    ",context.temp_allocator)
        remaining:=expanded
        for {
            end:=strings.index_byte(remaining,'\n')
            if end<0 {native_flow_word(flow,node,remaining,style);break}
            native_flow_word(flow,node,remaining[:end],style);native_flow_break(flow,style.size*f32(flow.view.zoom)*style.line_height);remaining=remaining[end+1:]
        }
        return
    }
    for i:=0;i<len(text); {
        if text[i]==' '||text[i]=='\n'||text[i]=='\t'||text[i]=='\r' {
            for i<len(text)&&(text[i]==' '||text[i]=='\n'||text[i]=='\t'||text[i]=='\r') {i+=1}
            if flow.x>flow.left {native_flow_word(flow,node," ",style)}
        } else {end:=i;for end<len(text)&&text[end]!=' '&&text[end]!='\n'&&text[end]!='\t'&&text[end]!='\r' {end+=1};native_flow_word(flow,node,text[i:end],style);i=end}
    }
}
native_node_text :: proc(doc:^Native_Document,node:int,depth:int=0)->string {
    if node<0||node>=len(doc.nodes)||depth>256 {return ""}
    if doc.nodes[node].tag=="#text" {return doc.nodes[node].text}
    out:=make([dynamic]u8,context.temp_allocator)
    child:=doc.nodes[node].first
    for child>=0 {append(&out,native_node_text(doc,child,depth+1));child=doc.nodes[child].next}
    return string(out[:])
}
native_flow_length :: proc(flow:^Native_Flow,value:string,basis:f32,fallback:f32=0)->f32 {
    zoom:=f32(flow.view.zoom)
    return native_css_resolve(value,flow.doc.nodes[flow.owner].style.size,basis/zoom,flow.doc.width/zoom,flow.view.viewport_height/zoom,fallback/zoom)*zoom
}
native_flow_edges :: proc(flow:^Native_Flow,style:Native_Style,padding:bool)->[4]f32 {
    result:=style.margin;rules:=style.margin_rule;if padding {result=style.padding;rules=style.padding_rule}
    for i in 0..<4 {result[i]*=f32(flow.view.zoom);if rules[i]!="" {result[i]=native_css_resolve(rules[i],style.size,(flow.right-flow.left)/f32(flow.view.zoom),flow.doc.width/f32(flow.view.zoom),flow.view.viewport_height/f32(flow.view.zoom))*f32(flow.view.zoom)};if padding {result[i]=max(0,result[i])} else if rules[i]=="auto" {result[i]=0}}
    return result
}
native_style_border :: proc(style:Native_Style,zoom:f32)->[4]f32 {
    result:=style.border_edges;for i in 0..<4 {if result[i]<0 {result[i]=style.border_width};result[i]=max(0,result[i])*zoom};return result
}
native_flow_width :: proc(flow:^Native_Flow,style:Native_Style,available:f32,fallback:f32=-1)->f32 {
    width:=fallback
    if style.width>=0 {width=style.width*f32(flow.view.zoom)}
    if style.width_rule!="" {width=native_css_resolve(style.width_rule,style.size,available/f32(flow.view.zoom),flow.doc.width/f32(flow.view.zoom),flow.view.viewport_height/f32(flow.view.zoom),-1)*f32(flow.view.zoom)}
    if style.width_rule==""&&style.width_percent>0 {width=available*style.width_percent}
    return width
}
native_flow_height :: proc(flow:^Native_Flow,style:Native_Style,fallback:f32=-1)->f32 {
    height:=fallback;if style.height>=0 {height=style.height*f32(flow.view.zoom)}
    if style.height_rule!="" {height=native_css_resolve(style.height_rule,style.size,flow.height/f32(flow.view.zoom),flow.doc.width/f32(flow.view.zoom),flow.view.viewport_height/f32(flow.view.zoom),-1)*f32(flow.view.zoom)};return height
}
native_flow_constrain :: proc(flow:^Native_Flow,style:Native_Style,raw_value,basis:f32,horizontal:bool)->f32 {
    value:=raw_value
    min_rule,max_rule:=style.min_width_rule,style.max_width_rule
    if !horizontal {min_rule=style.min_height_rule;max_rule=style.max_height_rule}
    extra:=f32(0)
    if !style.border_box {padding:=native_flow_edges(flow,style,true);border:=native_style_border(style,f32(flow.view.zoom));if horizontal {extra=padding[1]+padding[3]+border[1]+border[3]} else {extra=padding[0]+padding[2]+border[0]+border[2]}}
    if horizontal&&style.max_width>=0&&style.max_width_rule=="" {value=min(value,style.max_width*f32(flow.view.zoom)+extra)}
    if max_rule!="" {bound:=native_flow_length(flow,max_rule,basis,-1);if bound>=0 {value=min(value,bound+extra)}}
    if min_rule!="" {bound:=native_flow_length(flow,min_rule,basis);if bound>=0 {value=max(value,bound+extra)}}
    return max(0,value)
}
native_layout_shift :: proc(doc:^Native_Document,node:int,dx,dy:f32,depth:int=0) {
    if node<0||node>=len(doc.nodes)||depth>256 {return}
    doc.nodes[node].x+=dx;doc.nodes[node].y+=dy
    child:=doc.nodes[node].first;for child>=0 {if doc.nodes[child].style.position!=.Fixed {native_layout_shift(doc,child,dx,dy,depth+1)};child=doc.nodes[child].next}
}
native_layout_shift_range :: proc(doc:^Native_Document,node,first,last:int,dx,dy:f32) {
    if dx==0&&dy==0 {return};native_layout_shift(doc,node,dx,dy)
    for &fragment in doc.fragments[clamp(first,0,len(doc.fragments)):clamp(last,0,len(doc.fragments))] {
        fixed:=false;current:=fragment.node;depth:=0
        for current>=0&&current!=node&&depth<256 {if doc.nodes[current].style.position==.Fixed {fixed=true;break};current=doc.nodes[current].parent;depth+=1}
        if !fixed {fragment.x+=dx;fragment.y+=dy}
    }
}
native_intrinsic_width :: proc(flow:^Native_Flow,node:int,depth:int=0)->f32 {
    if depth>64 {return 0};doc:=flow.doc;n:=doc.nodes[node];style:=n.style
    if style.display==.None {return 0}
    if n.tag=="#text" {return native_text_width(flow.a,n.text,style,f32(flow.view.zoom))}
    explicit:=native_flow_width(flow,style,flow.right-flow.left)
    if explicit>=0 {return explicit}
    if n.image>=0&&n.image<len(doc.images) {return f32(doc.images[n.image].width)*f32(flow.view.zoom)}
    if n.tag=="canvas" {width:=f32(300);if value,ok:=strconv.parse_f32(native_attr(doc,node,"width"));ok {width=max(1,value)};return width*f32(flow.view.zoom)}
    if n.tag=="input"||n.tag=="textarea"||n.tag=="select" {return 200*f32(flow.view.zoom)}
    width,line:f32;child:=n.first
    for child>=0 {next:=native_intrinsic_width(flow,child,depth+1);if doc.nodes[child].style.display==.Inline||doc.nodes[child].tag=="#text" {line+=next} else {width=max(width,line);line=0;width=max(width,next)};child=doc.nodes[child].next}
    width=max(width,line);padding:=native_flow_edges(flow,style,true);border:=native_style_border(style,f32(flow.view.zoom));return width+padding[1]+padding[3]+border[1]+border[3]
}
Native_Flex_Line :: struct {start,end:int,y,cross:f32}
Native_Layout_Item :: struct {node,first,last:int,basis,main,cross,grow,shrink,x,y,w,h:f32,column,row,column_span,row_span:int}
native_layout_children :: proc(flow:^Native_Flow,parent:int)->[dynamic]Native_Layout_Item {
    result:=make([dynamic]Native_Layout_Item,context.temp_allocator);child:=flow.doc.nodes[parent].first
    for child>=0 {n:=flow.doc.nodes[child];if n.style.display!=.None&&!n.style.hidden&&(n.tag!="#text"||strings.trim_space(n.text)!="")&&n.style.position!=.Absolute&&n.style.position!=.Fixed {append(&result,Native_Layout_Item{node=child});j:=len(result)-1;for j>0&&flow.doc.nodes[result[j-1].node].style.order>n.style.order {result[j]=result[j-1];j-=1};result[j]={node=child}};child=n.next}
    return result
}
native_layout_item :: proc(flow:^Native_Flow,item:^Native_Layout_Item,x,y,width:f32,depth:int,height:f32=-1) {
    doc:=flow.doc;style:=doc.nodes[item.node].style
    sub:=flow^;sub.left=x;sub.right=x+max(1,width);sub.x=x;sub.y=y;sub.line=0;sub.line_start=len(doc.fragments);sub.collapsible_margin=0
    if height>=0 {sub.height=height}
    margin:=native_flow_edges(&sub,style,false)
    doc.nodes[item.node].style.display=.Block
    doc.nodes[item.node].style.width_rule="";doc.nodes[item.node].style.width_percent=0;doc.nodes[item.node].style.width=max(0,width-margin[1]-margin[3])/f32(flow.view.zoom);doc.nodes[item.node].style.border_box=true
    if height>=0 {doc.nodes[item.node].style.height_rule="";doc.nodes[item.node].style.height=max(0,height-margin[0]-margin[2])/f32(flow.view.zoom)}
    item.first=len(doc.fragments)
    native_layout_node(&sub,item.node,depth+1);native_flow_break(&sub)
    item.last=len(doc.fragments);item.x=x;item.y=y;item.w=width;item.h=max(0,sub.y-y)
    if doc.nodes[item.node].tag=="#text" {item.h=max(item.h,style.size*f32(flow.view.zoom)*style.line_height)}
    doc.nodes[item.node].style=style
}
native_alignment_spacing :: proc(alignment:Native_Alignment,raw_remaining:f32,count:int)->(offset,gap:f32) {
    remaining:=max(0,raw_remaining)
    #partial switch alignment {case .End:offset=remaining;case .Center:offset=remaining/2;case .Between:if count>1 {gap=remaining/f32(count-1)};case .Around:if count>0 {gap=remaining/f32(count);offset=gap/2};case .Evenly:gap=remaining/f32(count+1);offset=gap;case:}
    return
}
native_layout_flex :: proc(flow:^Native_Flow,parent:int,depth:int) {
    doc:=flow.doc;style:=doc.nodes[parent].style;items:=native_layout_children(flow,parent);if len(items)==0 {return}
    row:=style.flex_direction%2==0;reverse:=style.flex_direction>=2
    main:=flow.right-flow.left;if !row {main=flow.height;if style.height<0&&style.height_rule=="" {main=0}}
    gap_main:=native_flow_length(flow,style.gap[1],flow.right-flow.left);gap_cross:=native_flow_length(flow,style.gap[0],flow.right-flow.left)
    if !row {gap_main,gap_cross=gap_cross,gap_main}
    for &item in items {
        child_style:=doc.nodes[item.node].style
        if row {item.basis=native_flow_width(flow,child_style,main);if item.basis<0 {item.basis=native_intrinsic_width(flow,item.node)}} else {item.basis=native_flow_height(flow,child_style);if item.basis<0 {item.basis=child_style.size*f32(flow.view.zoom)*child_style.line_height}}
        if child_style.flex_basis!=""&&child_style.flex_basis!="auto"&&child_style.flex_basis!="content" {item.basis=native_flow_length(flow,child_style.flex_basis,main)}
        explicit_width:=native_flow_width(flow,child_style,main)>=0||child_style.flex_basis!=""&&child_style.flex_basis!="auto"&&child_style.flex_basis!="content"
        if row&&explicit_width&&!child_style.border_box {padding:=native_flow_edges(flow,child_style,true);border:=native_style_border(child_style,f32(flow.view.zoom));item.basis+=padding[1]+padding[3]+border[1]+border[3]}
        margin:=native_flow_edges(flow,child_style,false);if row {item.basis+=margin[1]+margin[3]} else {item.basis+=margin[0]+margin[2]}
        item.basis=max(0,item.basis);item.grow=child_style.flex_grow;item.shrink=child_style.flex_shrink
    }
    if !row {
        for &item in items {
            child_style:=doc.nodes[item.node].style
            if child_style.height<0&&child_style.height_rule==""&&(child_style.flex_basis==""||child_style.flex_basis=="auto"||child_style.flex_basis=="content") {
                first,plain:=len(doc.fragments),len(flow.plain^)
                native_layout_item(flow,&item,flow.left,flow.y,flow.right-flow.left,depth)
                item.basis=item.h;resize(&doc.fragments,first);resize(flow.plain,plain)
            }
        }
    }
    if !row&&main<=0 {for item in items {main+=item.basis};main+=gap_main*f32(max(0,len(items)-1))}
    start_y:=flow.y;lines:=make([dynamic]Native_Flex_Line,context.temp_allocator)
    cross_cursor:=flow.y;start:=0
    if !row {cross_cursor=flow.left}
    for start<len(items) {
        end:=start;used:f32
        for end<len(items) {next:=items[end].basis;if end>start {next+=gap_main};if style.flex_wrap!=0&&end>start&&used+next>main {break};used+=next;end+=1}
        grow,shrink:f32;for item in items[start:end] {grow+=item.grow;shrink+=item.shrink*item.basis}
        remaining:=main-used
        for &item in items[start:end] {item.main=item.basis;if remaining>0&&grow>0 {item.main+=remaining*item.grow/grow} else if remaining<0&&shrink>0 {item.main=max(0,item.main+remaining*item.shrink*item.basis/shrink)}}
        occupied:=gap_main*f32(max(0,end-start-1));for item in items[start:end] {occupied+=item.main}
        justify:=style.justify;if reverse {if justify==.Start {justify=.End} else if justify==.End {justify=.Start}}
        offset,extra_gap:=native_alignment_spacing(justify,main-occupied,end-start)
        cursor:=offset;line_cross:f32
        for i:=start;i<end;i+=1 {
            index:=i;if reverse {index=end-1-(i-start)};item:=&items[index]
            if row {native_layout_item(flow,item,flow.left+cursor,cross_cursor,item.main,depth);item.cross=item.h}
            else {
                child_style:=doc.nodes[item.node].style;alignment:=style.align_items;if child_style.self_explicit {alignment=child_style.align_self}
                available:=flow.right-flow.left;item_width:=native_flow_width(flow,child_style,available);if item_width<0 {item_width=available;if alignment!=.Stretch {item_width=min(available,native_intrinsic_width(flow,item.node))}}
                delta:f32;if alignment==.Center {delta=(available-item_width)/2} else if alignment==.End {delta=available-item_width}
                native_layout_item(flow,item,cross_cursor+delta,flow.y+cursor,item_width,depth,item.main);item.cross=item.w
            }
            line_cross=max(line_cross,item.cross);cursor+=item.main+gap_main+extra_gap
        }
        if row {
            available_height:=flow.height;if style.height<0&&style.height_rule=="" {available_height=-1};if style.flex_wrap==0&&available_height>=0 {line_cross=max(line_cross,available_height)}
            for &item in items[start:end] {
                child_style:=doc.nodes[item.node].style;alignment:=style.align_items;if child_style.self_explicit {alignment=child_style.align_self}
                delta:f32;if alignment==.End {delta=line_cross-item.h} else if alignment==.Center {delta=(line_cross-item.h)/2}
                if delta!=0 {native_layout_shift_range(doc,item.node,item.first,item.last,0,delta)}
                if alignment==.Stretch&&native_flow_height(flow,child_style)<0 {margin:=native_flow_edges(flow,child_style,false);doc.nodes[item.node].h=max(doc.nodes[item.node].h,line_cross-margin[0]-margin[2])}
            }
            append(&lines,Native_Flex_Line{start,end,cross_cursor,line_cross})
            cross_cursor+=line_cross+gap_cross
        } else {cross_cursor+=line_cross+gap_cross}
        start=end
    }
    if row {
        natural:=max(0,cross_cursor-gap_cross-start_y);target:=natural
        if style.height>=0||style.height_rule!="" {target=max(natural,flow.height)}
        offset,extra_gap:=native_alignment_spacing(style.align_content,target-natural,len(lines));extra_height:=f32(0)
        if style.align_content==.Stretch&&len(lines)>0 {extra_height=max(0,target-natural)/f32(len(lines))}
        cursor:=start_y+offset
        for line in lines {
            y:=cursor;cross:=line.cross+extra_height
            if style.flex_wrap==2 {y=start_y+target-(cursor-start_y)-cross}
            for item in items[line.start:line.end] {
                child_style:=doc.nodes[item.node].style;alignment:=style.align_items;if child_style.self_explicit {alignment=child_style.align_self}
                dy:=y-line.y;if alignment==.End {dy+=extra_height} else if alignment==.Center {dy+=extra_height/2}
                native_layout_shift_range(doc,item.node,item.first,item.last,0,dy)
                if alignment==.Stretch&&native_flow_height(flow,child_style)<0 {doc.nodes[item.node].h+=extra_height}
            }
            cursor+=cross+gap_cross+extra_gap
        }
        flow.y=start_y+target
    } else {flow.y+=main}
    flow.x=flow.left;flow.line=0;flow.line_start=len(doc.fragments)
}
native_grid_track_names :: proc(raw_tracks:string,available:f32,gap:f32=0)->[dynamic]string {
    result:=make([dynamic]string,context.temp_allocator)
    for token in native_css_parts(raw_tracks) {
        if strings.has_prefix(token,"[")||token=="none" {continue}
        if strings.has_prefix(token,"repeat(")&&strings.has_suffix(token,")") {
            args:=native_css_parts(token[7:len(token)-1],',');if len(args)<2 {continue};count,ok:=strconv.parse_int(args[0]);if !ok {minimum:=native_css_length(args[1],16,120);if strings.has_prefix(args[1],"minmax(") {bounds:=native_css_parts(args[1][7:len(args[1])-1],',');if len(bounds)>0 {minimum=native_css_length(bounds[0],16,120)}};count=max(1,int((available+gap)/max(1,minimum+gap)))}
            parts:=native_css_parts(args[1]);for _ in 0..<clamp(count,1,128) {for part in parts {if len(result)<128 {append(&result,part)}}}
        } else if len(result)<128 {append(&result,token)}
    }
    return result
}
native_grid_tracks :: proc(flow:^Native_Flow,names:[dynamic]string,available,gap:f32,count:int,automatic:string)->[dynamic]f32 {
    sizes:=make([dynamic]f32,max(1,count),context.temp_allocator);weights:=make([]f32,len(sizes),context.temp_allocator);minimums:=make([]f32,len(sizes),context.temp_allocator)
    total,weight:f32
    for &size,i in sizes {
        value:=automatic;if i<len(names) {value=names[i]};if value=="" {value="auto"}
        if strings.has_prefix(value,"minmax(")&&strings.has_suffix(value,")") {parts:=native_css_parts(value[7:len(value)-1],',');if len(parts)>=2 {minimums[i]=max(0,native_flow_length(flow,parts[0],available));value=parts[1]}}
        if strings.has_suffix(value,"fr") {n,ok:=strconv.parse_f32(value[:len(value)-2]);if ok {weights[i]=max(0,n)}} else if value=="auto"||value=="min-content"||value=="max-content" {weights[i]=1} else {size=max(0,native_flow_length(flow,value,available))}
        size=max(size,minimums[i]);total+=size;weight+=weights[i]
    }
    remaining:=max(0,available-gap*f32(max(0,len(sizes)-1))-total)
    if weight>0 {for &size,i in sizes {size+=remaining*weights[i]/weight}}
    return sizes
}
native_layout_grid :: proc(flow:^Native_Flow,parent:int,depth:int) {
    doc:=flow.doc;style:=doc.nodes[parent].style;items:=native_layout_children(flow,parent);if len(items)==0 {return}
    column_gap:=native_flow_length(flow,style.gap[1],flow.right-flow.left);row_gap:=native_flow_length(flow,style.gap[0],flow.right-flow.left)
    column_names:=native_grid_track_names(style.grid_columns,flow.right-flow.left,column_gap);row_names:=native_grid_track_names(style.grid_rows,flow.height,row_gap)
    columns:=max(1,len(column_names));rows:=max(1,len(row_names))
    for item in items {rows=max(rows,doc.nodes[item.node].style.grid_row_span)}
    if style.grid_column_flow {columns=max(columns,(len(items)+rows-1)/rows)}
    for item in items {s:=doc.nodes[item.node].style;columns=max(columns,s.grid_column_span);if s.grid_column>0 {columns=max(columns,s.grid_column+max(1,s.grid_column_span)-1)}}
    columns=min(128,columns);occupied:=make([]bool,columns*max(128,len(items)*2),context.temp_allocator);cursor:=0
    for &item in items {
        s:=doc.nodes[item.node].style;item.column_span=clamp(s.grid_column_span,1,columns);item.row_span=clamp(s.grid_row_span,1,128)
        desired_column:=s.grid_column-1;desired_row:=s.grid_row-1
        if s.grid_column<0 {desired_column=max(0,columns+s.grid_column+1)}
        if s.grid_row<0 {desired_row=max(0,rows+s.grid_row+1)}
        if desired_column>=0&&desired_row>=0 {item.column=min(desired_column,columns-item.column_span);item.row=desired_row}
        else {
            search:=cursor;if desired_row>=0 {search=desired_row*columns};if desired_column>=0 {search=desired_column}
            if style.grid_column_flow {search=cursor;if desired_column>=0 {search=desired_column*rows};if desired_row>=0 {search=desired_row}}
            for search<len(occupied)-columns*item.row_span {
                column,row:=search%columns,search/columns
                if style.grid_column_flow {column=search/rows;row=search%rows;if column>=columns {break}}
                if desired_column>=0&&column!=desired_column {search+=1;continue};if desired_row>=0&&row!=desired_row {break};fits:=column+item.column_span<=columns&&row+item.row_span<len(occupied)/columns
                if fits {for y in 0..<item.row_span {for x in 0..<item.column_span {if occupied[(row+y)*columns+column+x] {fits=false}}}}
                if fits {item.column=column;item.row=row;break};search+=1
            }
            cursor=search+item.column_span;if style.grid_column_flow {cursor=search+item.row_span}
        }
        item.row=min(item.row,len(occupied)/columns-item.row_span);for y in 0..<item.row_span {for x in 0..<item.column_span {occupied[(item.row+y)*columns+item.column+x]=true}}
        rows=max(rows,item.row+item.row_span)
    }
    widths:=native_grid_tracks(flow,column_names,flow.right-flow.left,column_gap,columns,style.grid_auto_columns)
    row_height:=flow.height;if style.height<0&&style.height_rule=="" {row_height=0}
    heights:=native_grid_tracks(flow,row_names,row_height,row_gap,rows,style.grid_auto_rows)
    x_positions:=make([]f32,columns+1,context.temp_allocator);x_positions[0]=flow.left
    for width,i in widths {x_positions[i+1]=x_positions[i]+width+column_gap}
    for &item in items {
        width:=x_positions[item.column+item.column_span]-x_positions[item.column]-column_gap
        child_style:=doc.nodes[item.node].style;alignment:=style.justify_items;if child_style.justify_self_explicit {alignment=child_style.justify_self}
        actual_width:=native_flow_width(flow,child_style,width);if actual_width<0 {actual_width=width;if alignment!=.Stretch {actual_width=min(width,native_intrinsic_width(flow,item.node))}}
        offset:f32;if alignment==.Center {offset=(width-actual_width)/2} else if alignment==.End {offset=width-actual_width}
        native_layout_item(flow,&item,x_positions[item.column]+offset,flow.y,actual_width,depth)
        current:=row_gap*f32(max(0,item.row_span-1));for h in heights[item.row:item.row+item.row_span] {current+=h}
        if item.h>current {extra:=(item.h-current)/f32(item.row_span);for &h in heights[item.row:item.row+item.row_span] {h+=extra}}
    }
    y_positions:=make([]f32,rows+1,context.temp_allocator);y_positions[0]=flow.y
    for height,i in heights {y_positions[i+1]=y_positions[i]+height+row_gap}
    for item in items {
        height:=y_positions[item.row+item.row_span]-y_positions[item.row]-row_gap
        alignment:=style.align_items;child_style:=doc.nodes[item.node].style;if child_style.self_explicit {alignment=child_style.align_self}
        dy:=y_positions[item.row]-flow.y;if alignment==.End {dy+=height-item.h} else if alignment==.Center {dy+=(height-item.h)/2}
        native_layout_shift_range(doc,item.node,item.first,item.last,0,dy)
        if alignment==.Stretch&&native_flow_height(flow,child_style)<0 {margin:=native_flow_edges(flow,child_style,false);doc.nodes[item.node].h=max(doc.nodes[item.node].h,height-margin[0]-margin[2])}
    }
    flow.y=y_positions[rows]-row_gap;flow.x=flow.left;flow.line=0;flow.line_start=len(doc.fragments)
}
native_table_columns :: proc(doc:^Native_Document,node:int,depth:int=0)->int {
    if depth>128 {return 1};n:=doc.nodes[node]
    if n.tag=="tr" {columns:=0;child:=n.first;for child>=0 {if doc.nodes[child].tag=="td"||doc.nodes[child].tag=="th" {span,ok:=strconv.parse_int(native_attr(doc,child,"colspan"));if !ok {span=1};columns+=clamp(span,1,128)};child=doc.nodes[child].next};return max(1,columns)}
    columns:=1;child:=n.first;for child>=0 {if doc.nodes[child].tag!="table" {columns=max(columns,native_table_columns(doc,child,depth+1))};child=doc.nodes[child].next};return min(128,columns)
}
native_layout_positioned :: proc(flow:^Native_Flow,node,depth:int) {
    doc:=flow.doc;style:=doc.nodes[node].style;zoom:=f32(flow.view.zoom)
    x,y,w,h:=f32(0),f32(0),doc.width,flow.view.viewport_height
    if style.position!=.Fixed {
        parent:=doc.nodes[node].parent
        for parent>0&&doc.nodes[parent].style.position==.Static {parent=doc.nodes[parent].parent}
        if parent>0 {box:=doc.nodes[parent];x=box.x;y=box.y;w=box.w;h=box.h;if h<=0 {h=native_flow_height(flow,box.style,flow.view.viewport_height)}}
    }
    margin:=native_flow_edges(flow,style,false)
    left:=native_flow_length(flow,style.inset[3],w,-1);right:=native_flow_length(flow,style.inset[1],w,-1);top:=native_flow_length(flow,style.inset[0],h,-1);bottom:=native_flow_length(flow,style.inset[2],h,-1)
    width:=native_flow_width(flow,style,w);if width<0 {if left>=0&&right>=0 {width=max(0,w-left-right-margin[1]-margin[3])} else {width=min(w,native_intrinsic_width(flow,node))}}
    height:=native_flow_height(flow,style);if height<0&&top>=0&&bottom>=0 {height=max(0,h-top-bottom-margin[0]-margin[2])}
    px,py:=x,y;if left>=0 {px+=left} else if right>=0 {px+=w-right-width-margin[1]-margin[3]};if top>=0 {py+=top} else if bottom>=0&&height>=0 {py+=h-bottom-height-margin[0]-margin[2]}
    sub:=flow^;sub.left=px;sub.right=px+width+margin[1]+margin[3];sub.x=px;sub.y=py;sub.line=0;sub.line_start=len(doc.fragments);sub.height=h
    previous:=doc.nodes[node].style;doc.nodes[node].style.width_rule="";doc.nodes[node].style.width_percent=0;doc.nodes[node].style.width=width/zoom;doc.nodes[node].style.border_box=true
    if height>=0 {doc.nodes[node].style.height_rule="";doc.nodes[node].style.height=height/zoom}
    first:=len(doc.fragments)
    native_layout_node(&sub,node,depth+1,true);native_flow_break(&sub)
    if top<0&&bottom>=0&&height<0 {native_layout_shift_range(doc,node,first,len(doc.fragments),0,y+h-bottom-doc.nodes[node].h-doc.nodes[node].y)}
    doc.nodes[node].style=previous
}
native_layout_node :: proc(flow:^Native_Flow,node:int,depth:int=0,positioned:bool=false) {
    if depth>256 {return}
    doc:=flow.doc;n:=&doc.nodes[node];style:=n.style;zoom:=f32(flow.view.zoom)
    if style.display==.None||style.hidden {return}
    if !positioned&&(style.position==.Absolute||style.position==.Fixed) {native_layout_positioned(flow,node,depth);return}
    if n.tag=="#text" {native_flow_text(flow,node,n.text,style);return}
    if n.tag=="br" {native_flow_break(flow,style.size*zoom*style.line_height);return}
    if n.tag=="img"||n.tag=="svg"&&n.image>=0 {
        image:=n.image
        if image<0||doc.atlas_width==0 {native_flow_text(flow,node,native_attr(doc,node,"alt"),style);return}
        asset:=doc.images[image];width,height:=f32(asset.width)*zoom,f32(asset.height)*zoom
        specified_width:=native_flow_width(flow,style,flow.right-flow.left);specified_height:=native_flow_height(flow,style)
        if specified_width>=0 {width=specified_width;height=width*f32(asset.height)/f32(asset.width)}
        if specified_height>=0 {height=specified_height;if specified_width<0 {width=height*f32(asset.width)/f32(asset.height)}}
        constrained:=native_flow_constrain(flow,style,width,flow.right-flow.left,true);if width>0 {height*=constrained/width};width=constrained
        if style.max_width_rule=="100%"&&width>flow.right-flow.left {height*=(flow.right-flow.left)/width;width=flow.right-flow.left}
        if flow.x>flow.left&&flow.x+width>flow.right {native_flow_break(flow)}
        append(&doc.fragments,Native_Fragment{node=node,start=len(flow.plain^),end=len(flow.plain^),x=flow.x,y=flow.y,w=width,h=height,style=style,image=image})
        n.x=flow.x;n.y=flow.y;n.w=width;n.h=height
        flow.x+=width;flow.line=max(flow.line,height);return
    }
    if n.tag=="canvas" {
        width,height:=f32(300)*zoom,f32(150)*zoom
        if value,ok:=strconv.parse_f32(native_attr(doc,node,"width"));ok {width=max(1,value)*zoom};if value,ok:=strconv.parse_f32(native_attr(doc,node,"height"));ok {height=max(1,value)*zoom}
        if specified:=native_flow_width(flow,style,flow.right-flow.left);specified>=0 {width=specified};if specified:=native_flow_height(flow,style);specified>=0 {height=specified}
        width=native_flow_constrain(flow,style,width,flow.right-flow.left,true);height=native_flow_constrain(flow,style,height,flow.height,false)
        if flow.x>flow.left&&flow.x+width>flow.right {native_flow_break(flow)}
        append(&doc.fragments,Native_Fragment{node=node,start=len(flow.plain^),end=len(flow.plain^),x=flow.x,y=flow.y,w=width,h=height,style=style,image=-2})
        n.x=flow.x;n.y=flow.y;n.w=width;n.h=height;flow.x+=width;flow.line=max(flow.line,height);return
    }
    if n.tag=="input"||n.tag=="textarea"||n.tag=="select"||n.tag=="button"||n.tag=="video"||n.tag=="audio" {
        kind:=native_attr(doc,node,"type");text:=n.value
        if n.tag=="video" {text="▶ Play video"}
        if n.tag=="audio" {text="▶ Play audio"}
        if kind=="hidden" {return}
        if n.tag=="button" {text=native_node_text(doc,node)}
        if n.tag=="select"&&text=="" {
            child:=n.first;for child>=0 {if doc.nodes[child].tag=="option" {text=native_node_text(doc,child);break};child=doc.nodes[child].next}
        }
        if kind=="checkbox"||kind=="radio" {text="☐";if n.checked {text="☑"}}
        if kind=="password" {hidden:=make([dynamic]u8,context.temp_allocator);for _ in text {append(&hidden,"•")};text=string(hidden[:])}
        if (kind=="submit"||kind=="button")&&text=="" {text="Submit"}
        if text=="" {text=native_attr(doc,node,"placeholder")}
        width:=max(40,native_text_width(flow.a,text,style,zoom)+16*zoom)
        if n.tag=="textarea"||n.tag=="select"||(n.tag=="input"&&kind!="checkbox"&&kind!="radio"&&kind!="submit"&&kind!="button") {width=max(width,200*zoom)}
        if n.tag=="video" {width=320*zoom}
        if specified:=native_flow_width(flow,style,flow.right-flow.left);specified>=0 {width=specified};width=native_flow_constrain(flow,style,width,flow.right-flow.left,true)
        height:=max(style.size*zoom*1.8,style.height*zoom);if n.tag=="video" {height=max(height,180*zoom)};if n.tag=="textarea" {height=max(height,80*zoom)}
        if flow.x>flow.left&&flow.x+width>flow.right {native_flow_break(flow)}
        n.x=flow.x;n.y=flow.y;n.w=width;n.h=height
        start:=len(flow.plain^);append(flow.plain,text)
        append(&doc.fragments,Native_Fragment{node=node,start=start,end=len(flow.plain^),text=text,x=flow.x,y=flow.y,w=width,h=height,style=style,image=-1})
        flow.x+=width+4*zoom;flow.line=max(flow.line,height);return
    }
    block:=style.display!=.Inline&&style.display!=.Inline_Block
    inline_block:=style.display==.Inline_Block
    margin:=native_flow_edges(flow,style,false);padding:=native_flow_edges(flow,style,true);border:=native_style_border(style,zoom)
    if block {native_flow_break(flow);flow.y+=margin[0]-min(max(0,margin[0]),flow.collapsible_margin);flow.collapsible_margin=0}
    first:=len(doc.fragments);saved_left,saved_right,saved_height,saved_align,saved_owner:=flow.left,flow.right,flow.height,flow.align,flow.owner
    x,y:=flow.x,flow.y
    if block||inline_block {
        if block {x=flow.left+margin[3]} else {x+=margin[3];flow.y+=margin[0];y=flow.y}
        available:=max(1,flow.right-flow.left-margin[1]-margin[3]);width:=native_flow_width(flow,style,available)
        if width<0 {width=available;if inline_block {width=min(available,native_intrinsic_width(flow,node))}} else if !style.border_box {width+=padding[1]+padding[3]+border[1]+border[3]}
        width=native_flow_constrain(flow,style,width,available,true)
        if inline_block&&flow.x>flow.left&&x+width+margin[1]>flow.right {native_flow_break(flow);x=flow.x+margin[3];y=flow.y+margin[0]}
        remaining:=max(0,available-width);auto_left,auto_right:=style.margin_rule[3]=="auto",style.margin_rule[1]=="auto"
        if auto_left {if auto_right {x+=remaining/2} else {x+=remaining}}
        n.x=x;n.y=y;n.w=width;n.h=max(0,native_flow_height(flow,style))
        flow.left=x+padding[3]+border[3];flow.right=max(flow.left+1,x+width-padding[1]-border[1]);flow.x=flow.left
        flow.y=y+padding[0]+border[0];flow.line=0;flow.line_start=len(doc.fragments);flow.align=style.align;flow.owner=node
        height:=native_flow_height(flow,style)
        if height>=0 {flow.height=max(0,height);if style.border_box {flow.height=max(0,flow.height-padding[0]-padding[2]-border[0]-border[2])}} else {flow.height=saved_height}
    }
    if n.tag=="li" {
        marker:="• "
        if n.parent>=0&&doc.nodes[n.parent].tag=="ol" {number:=1;child:=doc.nodes[n.parent].first;for child>=0&&child!=node {if doc.nodes[child].tag=="li" {number+=1};child=doc.nodes[child].next};marker=fmt.tprintf("%d. ",number)}
        native_flow_word(flow,node,marker,style)
    }
    if style.display==.Table {n.style.table_columns=native_table_columns(doc,node)}
    if style.display==.Flex {native_layout_flex(flow,node,depth)}
    else if style.display==.Grid {native_layout_grid(flow,node,depth)}
    else if style.display==.Row {
        items:=native_layout_children(flow,node);columns:=max(1,len(items));parent:=n.parent
        for parent>=0 {if doc.nodes[parent].style.display==.Table {columns=max(columns,doc.nodes[parent].style.table_columns);break};parent=doc.nodes[parent].parent}
        width:=(flow.right-flow.left)/f32(columns);bottom:=flow.y;column:=0
        for &item in items {span,ok:=strconv.parse_int(native_attr(doc,item.node,"colspan"));if !ok {span=1};span=clamp(span,1,columns);native_layout_item(flow,&item,flow.left+f32(column)*width,flow.y,f32(span)*width,depth);bottom=max(bottom,flow.y+item.h);column+=span}
        for item in items {doc.nodes[item.node].h=max(doc.nodes[item.node].h,bottom-doc.nodes[item.node].y)}
        flow.y=bottom;flow.x=flow.left;flow.line=0;flow.line_start=len(doc.fragments)
    } else {
        child:=n.first
        for child>=0 {
            if n.tag=="details"&&!n.expanded&&doc.nodes[child].tag!="summary" {child=doc.nodes[child].next;continue}
            if doc.nodes[child].style.position!=.Absolute&&doc.nodes[child].style.position!=.Fixed {native_layout_node(flow,child,depth+1)};child=doc.nodes[child].next
        }
    }
    if block||inline_block {
        native_flow_break(flow)
        content_height:=max(0,flow.y-y-padding[0]-border[0]);height:=native_flow_height(flow,style)
        if height>=0 {if style.border_box {height=max(0,height-padding[0]-padding[2]-border[0]-border[2])};content_height=height}
        total_height:=content_height+padding[0]+padding[2]+border[0]+border[2];total_height=native_flow_constrain(flow,style,total_height,saved_height,false)
        n.h=total_height
        flow.left=saved_left;flow.right=saved_right;flow.height=saved_height;flow.align=saved_align;flow.owner=saved_owner
        if block {flow.y=y+total_height+margin[2];flow.collapsible_margin=max(0,margin[2]);flow.x=saved_left;flow.line=0;flow.line_start=len(doc.fragments)}
        else {flow.y=y-margin[0];flow.x=x+n.w+margin[1];flow.line=max(flow.line,n.h+margin[0]+margin[2])}
    } else {n.x=x;n.y=y;n.w=max(0,flow.x-x);n.h=max(flow.line,style.size*zoom)}
    child:=n.first
    for child>=0 {if doc.nodes[child].style.position==.Absolute||doc.nodes[child].style.position==.Fixed {native_layout_node(flow,child,depth+1)};child=doc.nodes[child].next}
    if style.position==.Relative {
        dx,dy:f32
        if style.inset[3]!=""&&style.inset[3]!="auto" {dx=native_flow_length(flow,style.inset[3],saved_right-saved_left)} else if style.inset[1]!=""&&style.inset[1]!="auto" {dx=-native_flow_length(flow,style.inset[1],saved_right-saved_left)}
        if style.inset[0]!=""&&style.inset[0]!="auto" {dy=native_flow_length(flow,style.inset[0],saved_height)} else if style.inset[2]!=""&&style.inset[2]!="auto" {dy=-native_flow_length(flow,style.inset[2],saved_height)}
        native_layout_shift_range(doc,node,first,len(doc.fragments),dx,dy)
    }
}
native_style_tree :: proc(doc:^Native_Document,node:int,markdown,dark:bool,depth:int=0) {
    if depth>256||node<0||node>=len(doc.nodes) {return}
    doc.nodes[node].x=0;doc.nodes[node].y=0;doc.nodes[node].w=0;doc.nodes[node].h=0
    doc.nodes[node].style=native_style_default(doc,node,markdown,dark)
    child:=doc.nodes[node].first;for child>=0 {native_style_tree(doc,child,markdown,dark,depth+1);child=doc.nodes[child].next}
}
native_document_layout :: proc(a:^App,view:^Document_View,width:f32) {
    doc:=&view.native
    clear(&doc.fragments)
    plain:=make([dynamic]u8)
    doc.width=width;doc.height=view.viewport_height
    native_style_tree(doc,0,view.kind==.Markdown,view.dark_mode)
    padding:=f32(0);if view.kind==.Markdown {padding=24*f32(view.zoom)}
    available:=max(40,width-2*padding)
    if view.kind==.Markdown {available=min(920*f32(view.zoom),available)}
    flow:=Native_Flow{a=a,view=view,doc=doc,plain=&plain,left=(width-available)/2,right=(width+available)/2,x=(width-available)/2,y=padding,height=view.viewport_height,owner=0}
    native_layout_node(&flow,0);native_flow_break(&flow)
    delete(doc.text);doc.text=string(plain[:])
    // Cached fragments outlive the current temporary allocator (form labels,
    // whitespace expansion and generated list markers all need stable text).
    for &fragment in doc.fragments {if fragment.end>fragment.start {fragment.text=doc.text[fragment.start:fragment.end]}}
    doc.width=width;doc.height=flow.y+padding
    view.layout_revision=doc.revision;view.layout_zoom=view.zoom
    view.scroll=clamp(view.scroll,0,max(0,doc.height-view.viewport_height))
}
native_node_scroll_adjust :: proc(view:^Document_View,node:int)->f32 {
    doc:=&view.native;current:=node
    for current>=0&&current<len(doc.nodes) {
        n:=doc.nodes[current]
        if n.style.position==.Fixed {return view.scroll}
        if n.style.position==.Sticky {
            if n.style.inset[0]==""||n.style.inset[0]=="auto" {return 0}
            top:=native_css_resolve(n.style.inset[0],n.style.size,view.viewport_height/f32(view.zoom),doc.width/f32(view.zoom),view.viewport_height/f32(view.zoom))*f32(view.zoom)
            maximum:=f32(1e30);if n.parent>=0 {maximum=max(0,doc.nodes[n.parent].y+doc.nodes[n.parent].h-n.y-n.h)}
            return min(maximum,max(0,view.scroll+top-n.y))
        }
        current=n.parent
    }
    return 0
}
native_node_clip :: proc(view:^Document_View,node:int,viewport:Explorer_Rect)->Explorer_Rect {
    clip:=viewport;doc:=&view.native;if doc.nodes[node].style.position==.Fixed {return clip};parent:=doc.nodes[node].parent;depth:=0
    for parent>=0&&depth<256 {
        n:=doc.nodes[parent];adjust:=native_node_scroll_adjust(view,parent)
        if n.style.clip_x {x0:=max(clip.x,viewport.x+n.x);x1:=min(clip.x+clip.w,viewport.x+n.x+n.w);clip.x=x0;clip.w=max(0,x1-x0)}
        if n.style.clip_y {y0:=max(clip.y,viewport.y+n.y-view.scroll+adjust);y1:=min(clip.y+clip.h,viewport.y+n.y+n.h-view.scroll+adjust);clip.y=y0;clip.h=max(0,y1-y0)}
        if n.style.position==.Fixed {break};parent=n.parent;depth+=1
    }
    return clip
}
native_node_layer :: proc(doc:^Native_Document,node:int)->int {
    layer:=0;depth:=0
    for node_index:=node;node_index>=0&&node_index<len(doc.nodes)&&depth<256;node_index=doc.nodes[node_index].parent {layer+=doc.nodes[node_index].style.z_index;depth+=1}
    return layer
}
native_render_text :: proc(a:^App,text:string,x,y:f32,style:Native_Style,zoom:f32,clip_left,clip_top,clip_right,clip_bottom:f32) {
    font:=renderer_font_size(&a.renderer,style.size*zoom*a.scale,native_font_kind(style))
    cursor:=math.round(x*a.scale);baseline:=math.round(y*a.scale+style.size*zoom*a.scale*0.8)
    for ch in text {
        glyph:=renderer_glyph(&a.renderer,font,ch)
        gx:=math.round(cursor)+f32(glyph.left);gy:=baseline-f32(glyph.top)
        x0:=max(gx,clip_left*a.scale);x1:=min(gx+f32(glyph.width),clip_right*a.scale)
        y0:=max(gy,clip_top*a.scale);y1:=min(gy+f32(glyph.height),clip_bottom*a.scale)
        if x1>x0&&y1>y0 {renderer_quad(&a.vertices,x0,y0,x1,y1,(f32(glyph.x)+x0-gx)/ATLAS_SIZE,(f32(glyph.y)+y0-gy)/4096,(f32(glyph.x)+x1-gx)/ATLAS_SIZE,(f32(glyph.y)+y1-gy)/4096,style.color)}
        cursor+=glyph.advance
    }
}
native_clipped_rect :: proc(a:^App,x,y,w,h:f32,color:Color,box:Explorer_Rect) {
    x0,y0:=max(x,box.x),max(y,box.y);x1,y1:=min(x+w,box.x+box.w),min(y+h,box.y+box.h)
    if x1>x0&&y1>y0&&color[3]>0 {ui_rect(a,x0,y0,x1-x0,y1-y0,color)}
}
native_document_render :: proc(a:^App,view:^Document_View,box:Preview_Layout) {
    doc:=&view.native
    viewport:=Explorer_Rect{box.x,box.y+68,box.w,max(1,box.h-98)}
    view.viewport_height=viewport.h
    if abs(doc.width-viewport.w)>0.5||view.layout_revision!=doc.revision||view.layout_zoom!=view.zoom {native_document_layout(a,view,viewport.w)}
    background:=Color{1,1,1,1};if view.dark_mode||view.kind==.Markdown {background=BG}
    for n in doc.nodes {if (n.tag=="html"||n.tag=="body")&&n.style.background[3]>0 {background=n.style.background}}
    ui_rect(a,viewport.x,viewport.y,viewport.w,viewport.h,background)
    if doc.atlas_width>0 {a.renderer.page_source=&view.frame;if !renderer_page_prepare(&a.renderer) {glfw.SetWindowShouldClose(a.renderer.window,true);return}}
    layers:=make([dynamic]int,context.temp_allocator);append(&layers,0)
    for _,i in doc.nodes {layer:=native_node_layer(doc,i);exists:=false;for old in layers {if old==layer {exists=true;break}};if !exists {append(&layers,layer);j:=len(layers)-1;for j>0&&layers[j-1]>layer {layers[j]=layers[j-1];j-=1};layers[j]=layer}}
    for layer in layers {
    for n,index in doc.nodes {
        if native_node_layer(doc,index)!=layer {continue}
        clip:=native_node_clip(view,index,viewport)
        if n.style.display==.None||n.style.hidden||n.h==0||n.tag=="#text" {continue}
        y:=viewport.y+n.y-view.scroll+native_node_scroll_adjust(view,index)
        native_clipped_rect(a,viewport.x+n.x,y,n.w,n.h,n.style.background,clip)
        border:=native_style_border(n.style,f32(view.zoom))
        native_clipped_rect(a,viewport.x+n.x,y,n.w,border[0],n.style.border,clip);native_clipped_rect(a,viewport.x+n.x,y+n.h-border[2],n.w,border[2],n.style.border,clip);native_clipped_rect(a,viewport.x+n.x,y,border[3],n.h,n.style.border,clip);native_clipped_rect(a,viewport.x+n.x+n.w-border[1],y,border[1],n.h,n.style.border,clip)
    }
    first,last:=min(view.selection_anchor,view.selection_end),max(view.selection_anchor,view.selection_end)
    for fragment in doc.fragments {
        if native_node_layer(doc,fragment.node)!=layer {continue}
        clip:=native_node_clip(view,fragment.node,viewport)
        x:=viewport.x+fragment.x;y:=viewport.y+fragment.y-view.scroll+native_node_scroll_adjust(view,fragment.node)
        if y+fragment.h<clip.y||y>=clip.y+clip.h {continue}
        if fragment.image== -2&&doc.nodes[fragment.node].tag=="canvas" {native_canvas_render(a,view,fragment.node,x,y,fragment.w,fragment.h,clip);continue}
        if fragment.image>=0 {
            image:=doc.images[fragment.image]
            x0,y0:=max(x,clip.x),max(y,clip.y);x1,y1:=min(x+fragment.w,clip.x+clip.w),min(y+fragment.h,clip.y+clip.h)
            if x1>x0&&y1>y0 {
                start:=len(a.vertices)
                renderer_quad(&a.vertices,x0*a.scale,y0*a.scale,x1*a.scale,y1*a.scale,(f32(image.x)+(x0-x)/fragment.w*f32(image.width))/f32(doc.atlas_width),(f32(image.y)+(y0-y)/fragment.h*f32(image.height))/f32(doc.atlas_height),(f32(image.x)+(x1-x)/fragment.w*f32(image.width))/f32(doc.atlas_width),(f32(image.y)+(y1-y)/fragment.h*f32(image.height))/f32(doc.atlas_height),Color{1,1,1,1})
                for &vertex in a.vertices[start:] {vertex.texture=1}
            }
            continue
        }
        style:=fragment.style
        if style.background[3]>0 {native_clipped_rect(a,x,y,fragment.w,fragment.h,style.background,clip)}
        selected_start:=max(first,fragment.start);selected_end:=min(last,fragment.end)
        if selected_end>selected_start&&len(fragment.text)>0 {
            before:=native_text_width(a,fragment.text[:selected_start-fragment.start],style,f32(view.zoom));selected_width:=native_text_width(a,fragment.text[selected_start-fragment.start:selected_end-fragment.start],style,f32(view.zoom))
            native_clipped_rect(a,x+before,y,selected_width,fragment.h,Color{0.22,0.35,0.55,0.8},clip)
        }
        input:=doc.nodes[fragment.node].tag=="input"||doc.nodes[fragment.node].tag=="textarea"||doc.nodes[fragment.node].tag=="button"||doc.nodes[fragment.node].tag=="select"
        if input {x+=6*f32(view.zoom);y+=4*f32(view.zoom)}
        native_render_text(a,fragment.text,x,y,style,f32(view.zoom),clip.x,clip.y,clip.x+clip.w,clip.y+clip.h)
        if style.underline {native_clipped_rect(a,x,y+style.size*f32(view.zoom)+2,fragment.w,1,style.color,clip)}
        if input&&fragment.node==view.focused_node {
            caret:=native_text_width(a,doc.nodes[fragment.node].value[:clamp(view.caret,0,len(doc.nodes[fragment.node].value))],style,f32(view.zoom))
            native_clipped_rect(a,x+caret,y,1,style.size*f32(view.zoom)+2,ACCENT,clip)
        }
    }
    }
    if doc.height>viewport.h {
        thumb:=max(24,viewport.h*viewport.h/doc.height);position:=(viewport.h-thumb)*view.scroll/max(1,doc.height-viewport.h)
        ui_rect(a,viewport.x+viewport.w-5,viewport.y+position,3,thumb,MUTED)
    }
}

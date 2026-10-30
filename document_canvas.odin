package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:slice"
import "core:strings"

// Canvas commands remain native geometry. Paths are tessellated on the CPU;
// Vulkan draws their triangles, glyphs and images in the application's batch.
Canvas_Point :: [2]f64
Canvas_Matrix :: [6]f64
Canvas_Vertex :: struct {point:Canvas_Point,uv:[2]f32}
Canvas_Polygon :: struct {vertices:[32]Canvas_Vertex,count:int}
Canvas_Command_Kind :: enum {Geometry,Text,Clear}
Canvas_Command :: struct {
    kind:Canvas_Command_Kind,
    vertices:[]Canvas_Vertex,
    color:Color,
    texture:f32,
    text:string,
    x,y,max_width:f64,
    state:Native_Canvas_State,
}
Native_Canvas_State :: struct {
    transform:Canvas_Matrix,
    fill,stroke:Color,
    alpha,line_width,miter_limit:f64,
    fill_text,stroke_text,font_text:[128]u8,
    fill_length,stroke_length,font_length:int,
    font_size:f32,
    font_kind:Font_Kind,
    align,baseline,cap,join:int,
    dash:[32]f64,
    dash_count:int,
    dash_offset:f64,
    clip_ids:[8]int,
    clip_count:int,
    copy:bool,
}
Native_Canvas :: struct {
    state:Native_Canvas_State,
    states:[dynamic]Native_Canvas_State,
    path:[dynamic]Canvas_Point,
    starts:[dynamic]int,
    closed:[dynamic]bool,
    commands:[dynamic]Canvas_Command,
    clips:[dynamic][]Canvas_Vertex,
    width,height:int,
    vertices:int,
    library:rawptr,
    faces:[Font_Kind]^FT_Face,
}
CANVAS_IDENTITY :: Canvas_Matrix{1,0,0,1,0,0}
canvas_transform :: proc(transform_matrix:Canvas_Matrix,point:Canvas_Point)->Canvas_Point {return {transform_matrix[0]*point[0]+transform_matrix[2]*point[1]+transform_matrix[4],transform_matrix[1]*point[0]+transform_matrix[3]*point[1]+transform_matrix[5]}}
canvas_multiply :: proc(a,b:Canvas_Matrix)->Canvas_Matrix {return {a[0]*b[0]+a[2]*b[1],a[1]*b[0]+a[3]*b[1],a[0]*b[2]+a[2]*b[3],a[1]*b[2]+a[3]*b[3],a[0]*b[4]+a[2]*b[5]+a[4],a[1]*b[4]+a[3]*b[5]+a[5]}}
canvas_inverse_point :: proc(transform_matrix:Canvas_Matrix,point:Canvas_Point)->Canvas_Point {det:=transform_matrix[0]*transform_matrix[3]-transform_matrix[1]*transform_matrix[2];if abs(det)<1e-12 {return point};x,y:=point[0]-transform_matrix[4],point[1]-transform_matrix[5];return {(transform_matrix[3]*x-transform_matrix[2]*y)/det,(-transform_matrix[1]*x+transform_matrix[0]*y)/det}}
canvas_cross :: proc(a,b,c:Canvas_Point)->f64 {return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])}
canvas_length :: proc(point:Canvas_Point)->f64 {return math.sqrt(point[0]*point[0]+point[1]*point[1])}
canvas_default_state :: proc()->Native_Canvas_State {
    state:=Native_Canvas_State{transform=CANVAS_IDENTITY,fill={0,0,0,1},stroke={0,0,0,1},alpha=1,line_width=1,miter_limit=10,font_size=10}
    state.fill_length=copy(state.fill_text[:],"#000000");state.stroke_length=copy(state.stroke_text[:],"#000000");state.font_length=copy(state.font_text[:],"10px sans-serif")
    return state
}
canvas_commands_clear :: proc(canvas:^Native_Canvas) {
    for command in canvas.commands {delete(command.vertices);delete(command.text)}
    clear(&canvas.commands);canvas.vertices=0
}
canvas_release_clips :: proc(canvas:^Native_Canvas) {
    for clip,i in canvas.clips {
        used:=false
        for id in canvas.state.clip_ids[:canvas.state.clip_count] {if id==i {used=true}}
        for state in canvas.states {for k in 0..<state.clip_count {if state.clip_ids[k]==i {used=true}}}
        if !used {delete(clip);canvas.clips[i]=nil}
    }
}
native_canvas_context :: proc(view:^Document_View,node:int)->^Native_Canvas {
    context.allocator=runtime.heap_allocator()
    if node<0||node>=len(view.native.nodes) {return nil}
    if view.native.canvases==nil {view.native.canvases=make(map[int]^Native_Canvas)}
    width,height:=300,150
    if value,ok:=strconv.parse_int(native_attr(&view.native,node,"width"));ok {width=clamp(value,0,32768)}
    if value,ok:=strconv.parse_int(native_attr(&view.native,node,"height"));ok {height=clamp(value,0,32768)}
    if canvas,okay:=view.native.canvases[node];okay {
        if canvas.width!=width||canvas.height!=height {canvas_commands_clear(canvas);canvas.state=canvas_default_state();clear(&canvas.states);clear(&canvas.path);clear(&canvas.starts);clear(&canvas.closed);canvas_release_clips(canvas);canvas.width=width;canvas.height=height}
        return canvas
    }
    canvas:=new(Native_Canvas);canvas.state=canvas_default_state();canvas.width=width;canvas.height=height
    view.native.canvases[node]=canvas;return canvas
}
native_canvas_reset :: proc(view:^Document_View,node:int) {
    context.allocator=runtime.heap_allocator()
    canvas:=native_canvas_context(view,node);if canvas==nil {return}
    canvas_commands_clear(canvas);canvas.state=canvas_default_state();clear(&canvas.states);clear(&canvas.path);clear(&canvas.starts);clear(&canvas.closed);canvas_release_clips(canvas);view.native.revision+=1
}
native_canvas_destroy :: proc(doc:^Native_Document) {
    context.allocator=runtime.heap_allocator()
    for _,canvas in doc.canvases {
        canvas_commands_clear(canvas)
        for clip in canvas.clips {delete(clip)}
        delete(canvas.clips);delete(canvas.commands);delete(canvas.path);delete(canvas.starts);delete(canvas.closed);delete(canvas.states)
        for face in canvas.faces {if face!=nil {FT_Done_Face(face)}}
        if canvas.library!=nil {FT_Done_FreeType(canvas.library)}
        free(canvas)
    }
    delete(doc.canvases)
}
canvas_number :: proc(args:[]Native_JS_Value,index:int,fallback:f64=0)->f64 {if index>=len(args) {return fallback};n:=native_js_numeric(args[index]);if math.is_nan(n)||math.is_inf(n) {return fallback};return n}
canvas_style_color :: proc(view:^Document_View,text:string)->(Color,bool) {sentinel:=Color{-1,-1,-1,-1};color:=native_css_color(&view.native,text,sentinel);return color,color[0]>=0}
canvas_set_font :: proc(state:^Native_Canvas_State,text:string) {
    size:f32;bold,italic,mono:=false,false,false
    for part in strings.fields(text,context.temp_allocator) {
        if strings.has_suffix(part,"px")||strings.has_suffix(part,"pt") {number,ok:=strconv.parse_f32(part[:len(part)-2]);if ok {size=number;if strings.has_suffix(part,"pt") {size*=4.0/3}}}
        if part=="bold"||part=="600"||part=="700"||part=="800"||part=="900" {bold=true};if part=="italic"||part=="oblique" {italic=true}
        if strings.contains(part,"mono")||strings.contains(part,"Courier")||strings.contains(part,"courier") {mono=true}
    }
    if size<=0||size>4096 {return}
    state.font_size=size;state.font_kind=.UI
    if mono {state.font_kind=.Terminal};if bold {state.font_kind=.UI_Bold if !mono else .Terminal_Bold};if italic {state.font_kind=.Terminal_Italic};if bold&&italic {state.font_kind=.Terminal_Bold_Italic}
    state.font_length=copy(state.font_text[:],transmute([]u8)text)
}
native_canvas_get :: proc(view:^Document_View,node:int,name:string)->Native_JS_Value {
    canvas:=native_canvas_context(view,node);if canvas==nil {return {}}
    state:=&canvas.state
    switch name {
    case "canvas":return native_dom_object(node)
    case "fillStyle":return native_js_string(&view.native.script,string(state.fill_text[:state.fill_length]))
    case "strokeStyle":return native_js_string(&view.native.script,string(state.stroke_text[:state.stroke_length]))
    case "font":return native_js_string(&view.native.script,string(state.font_text[:state.font_length]))
    case "globalAlpha":return native_js_number(state.alpha)
    case "lineWidth":return native_js_number(state.line_width)
    case "miterLimit":return native_js_number(state.miter_limit)
    case "lineDashOffset":return native_js_number(state.dash_offset)
    case "lineCap":names:=[3]string{"butt","round","square"};return native_js_string(&view.native.script,names[state.cap])
    case "lineJoin":names:=[3]string{"miter","round","bevel"};return native_js_string(&view.native.script,names[state.join])
    case "textAlign":names:=[5]string{"start","end","left","right","center"};return native_js_string(&view.native.script,names[state.align])
    case "textBaseline":names:=[6]string{"alphabetic","top","hanging","middle","bottom","ideographic"};return native_js_string(&view.native.script,names[state.baseline])
    case "globalCompositeOperation":return native_js_string(&view.native.script,"copy" if state.copy else "source-over")
    case "imageSmoothingEnabled":return native_js_bool(true)
    case "filter":return native_js_string(&view.native.script,"none")
    }
    return {}
}
native_canvas_set :: proc(view:^Document_View,node:int,name:string,value:Native_JS_Value)->bool {
    canvas:=native_canvas_context(view,node);if canvas==nil {return false}
    state:=&canvas.state;text:=native_js_value_text(value);number:=native_js_numeric(value)
    switch name {
    case "fillStyle","strokeStyle":
        if value.kind!=.String {document_set_script_error(view,"Canvas gradients/patterns are not implemented.");return true}
        color,valid:=canvas_style_color(view,text);if valid {if name=="fillStyle" {state.fill=color;state.fill_length=copy(state.fill_text[:],transmute([]u8)text)} else {state.stroke=color;state.stroke_length=copy(state.stroke_text[:],transmute([]u8)text)}}
    case "globalAlpha":if !math.is_nan(number)&&number>=0&&number<=1 {state.alpha=number}
    case "lineWidth":if !math.is_nan(number)&&!math.is_inf(number)&&number>0 {state.line_width=number}
    case "miterLimit":if !math.is_nan(number)&&!math.is_inf(number)&&number>0 {state.miter_limit=number}
    case "lineDashOffset":if !math.is_nan(number)&&!math.is_inf(number) {state.dash_offset=number}
    case "font":canvas_set_font(state,text)
    case "lineCap":switch text {case "butt":state.cap=0;case "round":state.cap=1;case "square":state.cap=2}
    case "lineJoin":switch text {case "miter":state.join=0;case "round":state.join=1;case "bevel":state.join=2}
    case "textAlign":switch text {case "start":state.align=0;case "end":state.align=1;case "left":state.align=2;case "right":state.align=3;case "center":state.align=4}
    case "textBaseline":switch text {case "alphabetic":state.baseline=0;case "top":state.baseline=1;case "hanging":state.baseline=2;case "middle":state.baseline=3;case "bottom":state.baseline=4;case "ideographic":state.baseline=5}
    case "globalCompositeOperation":if text=="source-over"||text=="copy" {state.copy=text=="copy"} else {document_set_script_error(view,"This Canvas compositing operation is not implemented.")}
    case "imageSmoothingEnabled":if !native_js_truth(value) {document_set_script_error(view,"Canvas nearest-neighbor image sampling is not implemented.")}
    case "imageSmoothingQuality":
    case "filter":if text!="none" {document_set_script_error(view,"Canvas image filters are not implemented.")}
    case "shadowColor","shadowBlur","shadowOffsetX","shadowOffsetY":if text!="transparent"&&text!="rgba(0, 0, 0, 0)"&&number!=0 {document_set_script_error(view,"Canvas shadows are not implemented.")}
    case:return false
    }
    return true
}
canvas_path_move :: proc(canvas:^Native_Canvas,point:Canvas_Point) {
    if len(canvas.path)>=8192 {return};append(&canvas.starts,len(canvas.path));append(&canvas.closed,false);append(&canvas.path,point)
}
canvas_path_line :: proc(canvas:^Native_Canvas,point:Canvas_Point) {
    if len(canvas.starts)==0 {canvas_path_move(canvas,point);return}
    last:=len(canvas.starts)-1
    if canvas.closed[last] {start:=canvas.path[canvas.starts[last]];canvas_path_move(canvas,start)}
    if len(canvas.path)<8192 {append(&canvas.path,point)}
}
canvas_polygon_triangle :: proc(a,b,c:Canvas_Vertex)->Canvas_Polygon {polygon:=Canvas_Polygon{count=3};polygon.vertices[0]=a;polygon.vertices[1]=b;polygon.vertices[2]=c;return polygon}
canvas_vertex_mix :: proc(a,b:Canvas_Vertex,t:f64)->Canvas_Vertex {return {point={a.point[0]+(b.point[0]-a.point[0])*t,a.point[1]+(b.point[1]-a.point[1])*t},uv={a.uv[0]+(b.uv[0]-a.uv[0])*f32(t),a.uv[1]+(b.uv[1]-a.uv[1])*f32(t)}}}
canvas_half_plane :: proc(polygon:Canvas_Polygon,a,b:Canvas_Point,sign:f64,inside:bool=true)->Canvas_Polygon {
    result:Canvas_Polygon;if polygon.count==0 {return result}
    previous:=polygon.vertices[polygon.count-1];previous_d:=canvas_cross(a,b,previous.point)*sign;if !inside {previous_d= -previous_d}
    for index in 0..<polygon.count {
        current:=polygon.vertices[index]
        distance:=canvas_cross(a,b,current.point)*sign;if !inside {distance= -distance}
        if (distance>= -1e-9)!=(previous_d>= -1e-9)&&result.count<32 {result.vertices[result.count]=canvas_vertex_mix(previous,current,previous_d/(previous_d-distance));result.count+=1}
        if distance>= -1e-9&&result.count<32 {result.vertices[result.count]=current;result.count+=1}
        previous=current;previous_d=distance
    }
    return result
}
canvas_triangle_intersection :: proc(polygon:Canvas_Polygon,a,b,c:Canvas_Point)->Canvas_Polygon {
    sign:f64=1;if canvas_cross(a,b,c)<0 {sign= -1}
    result:=canvas_half_plane(polygon,a,b,sign);result=canvas_half_plane(result,b,c,sign);return canvas_half_plane(result,c,a,sign)
}
canvas_append_polygon :: proc(vertices:^[dynamic]Canvas_Vertex,polygon:Canvas_Polygon) {for i:=1;i<polygon.count-1;i+=1 {if abs(canvas_cross(polygon.vertices[0].point,polygon.vertices[i].point,polygon.vertices[i+1].point))>1e-9 {append(vertices,polygon.vertices[0],polygon.vertices[i],polygon.vertices[i+1])}}}
canvas_clip_geometry :: proc(canvas:^Native_Canvas,input:[]Canvas_Vertex,state:Native_Canvas_State)->[]Canvas_Vertex {
    context.allocator=runtime.heap_allocator()
    vertices:=make([dynamic]Canvas_Vertex,0,len(input))
    for i:=0;i+2<len(input);i+=3 {if abs(canvas_cross(input[i].point,input[i+1].point,input[i+2].point))>1e-9 {append(&vertices,input[i],input[i+1],input[i+2])}}
    for index in 0..<state.clip_count {
        clip_id:=state.clip_ids[index]
        output:=make([dynamic]Canvas_Vertex)
        if clip_id<0||clip_id>=len(canvas.clips) {delete(vertices);return nil}
        clip:=canvas.clips[clip_id]
        for i:=0;i+2<len(vertices);i+=3 {for c:=0;c+2<len(clip);c+=3 {polygon:=canvas_triangle_intersection(canvas_polygon_triangle(vertices[i],vertices[i+1],vertices[i+2]),clip[c].point,clip[c+1].point,clip[c+2].point);canvas_append_polygon(&output,polygon);if len(output)>2000000 {delete(vertices);delete(output);return nil}}}
        delete(vertices);vertices=output
    }
    return vertices[:]
}
Canvas_Edge :: struct {a,b:Canvas_Point,winding:int}
Canvas_Crossing :: struct {x:f64,edge:int}
canvas_edge_x :: proc(edge:Canvas_Edge,y:f64)->f64 {return edge.a[0]+(y-edge.a[1])*(edge.b[0]-edge.a[0])/(edge.b[1]-edge.a[1])}
canvas_fill_geometry :: proc(points:[]Canvas_Point,starts:[]int,evenodd:bool)->[]Canvas_Vertex {
    context.allocator=runtime.heap_allocator()
    edges:=make([dynamic]Canvas_Edge);defer delete(edges)
    levels:=make([dynamic]f64);defer delete(levels)
    for start,sub in starts {end:=len(points);if sub+1<len(starts) {end=starts[sub+1]};if end-start<3 {continue};for i:=start;i<end;i+=1 {a,b:=points[i],points[start+(i-start+1)%(end-start)];append(&levels,a[1]);if abs(a[1]-b[1])>1e-9 {winding:=1;if a[1]>b[1] {winding= -1};append(&edges,Canvas_Edge{a,b,winding})}}}
    // Crossing levels preserve winding correctly for ordinary self-intersecting
    // paths. Bound pair work for very large paths, which remain renderable.
    if len(edges)<=512 {for a,i in edges {for b in edges[i+1:] {denominator:=(a.b[0]-a.a[0])*(b.b[1]-b.a[1])-(a.b[1]-a.a[1])*(b.b[0]-b.a[0]);if abs(denominator)<1e-12 {continue};t:=((b.a[0]-a.a[0])*(b.b[1]-b.a[1])-(b.a[1]-a.a[1])*(b.b[0]-b.a[0]))/denominator;u:=((b.a[0]-a.a[0])*(a.b[1]-a.a[1])-(b.a[1]-a.a[1])*(a.b[0]-a.a[0]))/denominator;if t>1e-9&&t<1-1e-9&&u>1e-9&&u<1-1e-9&&len(levels)<16384 {append(&levels,a.a[1]+t*(a.b[1]-a.a[1]))}}}}
    slice.sort(levels[:])
    vertices:=make([dynamic]Canvas_Vertex)
    crossings:=make([dynamic]Canvas_Crossing);defer delete(crossings)
    for level:=0;level+1<len(levels);level+=1 {
        top,bottom:=levels[level],levels[level+1];if bottom-top<1e-9 {continue};middle:=(top+bottom)/2;clear(&crossings)
        for edge,i in edges {if middle>min(edge.a[1],edge.b[1])&&middle<max(edge.a[1],edge.b[1]) {append(&crossings,Canvas_Crossing{canvas_edge_x(edge,middle),i})}}
        slice.sort_by(crossings[:],proc(a,b:Canvas_Crossing)->bool {return a.x<b.x})
        winding:=0;left:=-1
        for crossing in crossings {before:=winding;if evenodd {winding=1-winding} else {winding+=edges[crossing.edge].winding};if before==0&&winding!=0 {left=crossing.edge};if before!=0&&winding==0&&left>=0 {a,b:=edges[left],edges[crossing.edge];p0:=Canvas_Vertex{point={canvas_edge_x(a,top),top}};p1:=Canvas_Vertex{point={canvas_edge_x(b,top),top}};p2:=Canvas_Vertex{point={canvas_edge_x(b,bottom),bottom}};p3:=Canvas_Vertex{point={canvas_edge_x(a,bottom),bottom}};append(&vertices,p0,p1,p2,p0,p2,p3);left= -1}}
        if len(vertices)>1000000 {break}
    }
    return vertices[:]
}
canvas_command_add :: proc(view:^Document_View,canvas:^Native_Canvas,vertices:[]Canvas_Vertex,color:Color,kind:Canvas_Command_Kind=.Geometry,texture:f32=0) {
    context.allocator=runtime.heap_allocator()
    clipped:=canvas_clip_geometry(canvas,vertices,canvas.state)
    if len(clipped)==0 {delete(clipped);return}
    if canvas.vertices+len(clipped)>2000000||len(canvas.commands)>=16384 {delete(clipped);document_set_script_error(view,"Canvas geometry exceeds the native renderer's resource limit.");return}
    if canvas.state.copy&&kind!=.Clear {clear_vertices:=[6]Canvas_Vertex{{point={0,0}},{point={f64(canvas.width),0}},{point={f64(canvas.width),f64(canvas.height)}},{point={0,0}},{point={f64(canvas.width),f64(canvas.height)}},{point={0,f64(canvas.height)}}};cleared:=canvas_clip_geometry(canvas,clear_vertices[:],canvas.state);append(&canvas.commands,Canvas_Command{kind=.Clear,vertices=cleared});canvas.vertices+=len(cleared)}
    final_color:=color;final_color[3]*=f32(canvas.state.alpha)
    append(&canvas.commands,Canvas_Command{kind=kind,vertices=clipped,color=final_color,texture=texture});canvas.vertices+=len(clipped);view.native.revision+=1
}
canvas_rect_points :: proc(transform_matrix:Canvas_Matrix,x,y,w,h:f64)->[4]Canvas_Point {return {canvas_transform(transform_matrix,{x,y}),canvas_transform(transform_matrix,{x+w,y}),canvas_transform(transform_matrix,{x+w,y+h}),canvas_transform(transform_matrix,{x,y+h})}}
canvas_rect_geometry :: proc(points:[4]Canvas_Point)->[6]Canvas_Vertex {return {{point=points[0]},{point=points[1]},{point=points[2]},{point=points[0]},{point=points[2]},{point=points[3]}}}
canvas_circle :: proc(vertices:^[dynamic]Canvas_Vertex,center:Canvas_Point,radius:f64,transform_matrix:Canvas_Matrix) {for i in 0..<20 {a,b:=f64(i)*2*math.PI/20,f64(i+1)*2*math.PI/20;dx0,dy0:=math.cos(a)*radius,math.sin(a)*radius;dx1,dy1:=math.cos(b)*radius,math.sin(b)*radius;append(vertices,Canvas_Vertex{point=center},Canvas_Vertex{point={center[0]+transform_matrix[0]*dx0+transform_matrix[2]*dy0,center[1]+transform_matrix[1]*dx0+transform_matrix[3]*dy0}},Canvas_Vertex{point={center[0]+transform_matrix[0]*dx1+transform_matrix[2]*dy1,center[1]+transform_matrix[1]*dx1+transform_matrix[3]*dy1}})}}
canvas_stroke_segment :: proc(vertices:^[dynamic]Canvas_Vertex,a,b:Canvas_Point,state:Native_Canvas_State,cap_start:bool=true,cap_end:bool=true) {
    local_a:=canvas_inverse_point(state.transform,a);local_b:=canvas_inverse_point(state.transform,b);d:=Canvas_Point{local_b[0]-local_a[0],local_b[1]-local_a[1]};length:=canvas_length(d);if length<1e-9 {return}
    half:=state.line_width/2;nx,ny:= -d[1]/length*half,d[0]/length*half
    offset:=Canvas_Point{state.transform[0]*nx+state.transform[2]*ny,state.transform[1]*nx+state.transform[3]*ny}
    p0,p1,p2,p3:=Canvas_Point{a[0]+offset[0],a[1]+offset[1]},Canvas_Point{b[0]+offset[0],b[1]+offset[1]},Canvas_Point{b[0]-offset[0],b[1]-offset[1]},Canvas_Point{a[0]-offset[0],a[1]-offset[1]}
    if state.cap==2 {dx,dy:=d[0]/length*half,d[1]/length*half;extension:=Canvas_Point{state.transform[0]*dx+state.transform[2]*dy,state.transform[1]*dx+state.transform[3]*dy};if cap_start {for point in ([2]^Canvas_Point{&p0,&p3}) {point[0]-=extension[0];point[1]-=extension[1]}};if cap_end {for point in ([2]^Canvas_Point{&p1,&p2}) {point[0]+=extension[0];point[1]+=extension[1]}}}
    rectangle:=canvas_rect_geometry({p0,p1,p2,p3});append(vertices,..rectangle[:])
    if state.cap==1 {if cap_start {canvas_circle(vertices,a,half,state.transform)};if cap_end {canvas_circle(vertices,b,half,state.transform)}}
}
canvas_stroke_join :: proc(vertices:^[dynamic]Canvas_Vertex,a,b,c:Canvas_Point,state:Native_Canvas_State) {
    if state.join==1 {canvas_circle(vertices,b,state.line_width/2,state.transform);return}
    local_a,local_b,local_c:=canvas_inverse_point(state.transform,a),canvas_inverse_point(state.transform,b),canvas_inverse_point(state.transform,c)
    first,second:=Canvas_Point{local_b[0]-local_a[0],local_b[1]-local_a[1]},Canvas_Point{local_c[0]-local_b[0],local_c[1]-local_b[1]}
    first_length,second_length:=canvas_length(first),canvas_length(second);cross:=first[0]*second[1]-first[1]*second[0]
    if first_length<1e-9||second_length<1e-9||abs(cross)<1e-9 {return}
    side:f64=1;if cross>0 {side= -1};half:=state.line_width/2
    p:=Canvas_Point{local_b[0]-side*first[1]/first_length*half,local_b[1]+side*first[0]/first_length*half}
    q:=Canvas_Point{local_b[0]-side*second[1]/second_length*half,local_b[1]+side*second[0]/second_length*half}
    world_p,world_q:=canvas_transform(state.transform,p),canvas_transform(state.transform,q)
    append(vertices,Canvas_Vertex{point=b},Canvas_Vertex{point=world_p},Canvas_Vertex{point=world_q})
    if state.join==0 {t:=((q[0]-p[0])*second[1]-(q[1]-p[1])*second[0])/cross;miter:=Canvas_Point{p[0]+t*first[0],p[1]+t*first[1]};if canvas_length({miter[0]-local_b[0],miter[1]-local_b[1]})<=state.miter_limit*half {append(vertices,Canvas_Vertex{point=world_p},Canvas_Vertex{point=canvas_transform(state.transform,miter)},Canvas_Vertex{point=world_q})}}
}
canvas_stroke_geometry :: proc(canvas:^Native_Canvas,points:[]Canvas_Point,starts:[]int,closed:[]bool)->[]Canvas_Vertex {
    context.allocator=runtime.heap_allocator();vertices:=make([dynamic]Canvas_Vertex);state:=canvas.state
    for start,sub in starts {
        end:=len(points);if sub+1<len(starts) {end=starts[sub+1]};count:=end-start;if count<2 {continue};segments:=count-1;if sub<len(closed)&&closed[sub] {segments=count}
        dash_index:=0;dash_position:=state.dash_offset;dash_total:f64;for value in state.dash[:state.dash_count] {dash_total+=value}
        if dash_total>0 {dash_position=math.mod(dash_position,dash_total);if dash_position<0 {dash_position+=dash_total};for dash_position>=state.dash[dash_index]&&state.dash_count>0 {dash_position-=state.dash[dash_index];dash_index=(dash_index+1)%state.dash_count}}
        for i in 0..<segments {
            a,b:=points[start+i],points[start+(i+1)%count]
            if state.dash_count==0||dash_total<=0 {closed_path:=sub<len(closed)&&closed[sub];canvas_stroke_segment(&vertices,a,b,state,i==0&&!closed_path,i==segments-1&&!closed_path)}
            else {length:=canvas_length({b[0]-a[0],b[1]-a[1]});position:f64;for step:=0;position<length&&step<8192;step+=1 {remaining:=state.dash[dash_index]-dash_position;if remaining<=1e-9 {dash_index=(dash_index+1)%state.dash_count;dash_position=0;continue};used:=min(remaining,length-position);if dash_index%2==0 {p0:=Canvas_Point{a[0]+(b[0]-a[0])*position/length,a[1]+(b[1]-a[1])*position/length};p1:=Canvas_Point{a[0]+(b[0]-a[0])*(position+used)/length,a[1]+(b[1]-a[1])*(position+used)/length};canvas_stroke_segment(&vertices,p0,p1,state)};position+=used;dash_position+=used}}
            if state.dash_count==0&&(i+1<segments||sub<len(closed)&&closed[sub]) {next:=points[start+(i+2)%count];canvas_stroke_join(&vertices,a,b,next,state)}
        }
    }
    return vertices[:]
}
canvas_path_arc :: proc(canvas:^Native_Canvas,x,y,rx,ry,rotation,start,end:f64,ccw:bool) {
    if rx<0||ry<0 {return};delta:=end-start
    if !ccw {if delta>=2*math.PI {delta=2*math.PI} else {delta=math.mod(delta,2*math.PI);if delta<0 {delta+=2*math.PI}}} else {if delta<= -2*math.PI {delta= -2*math.PI} else {delta=math.mod(delta,2*math.PI);if delta>0 {delta-=2*math.PI}}}
    steps:=clamp(int(math.ceil(abs(delta)*math.sqrt(max(rx,ry)+1))),1,512)
    for i in 0..=steps {angle:=start+delta*f64(i)/f64(steps);dx,dy:=rx*math.cos(angle),ry*math.sin(angle);point:=canvas_transform(canvas.state.transform,{x+math.cos(rotation)*dx-math.sin(rotation)*dy,y+math.sin(rotation)*dx+math.cos(rotation)*dy});if i==0&&len(canvas.path)==0 {canvas_path_move(canvas,point)} else {canvas_path_line(canvas,point)}}
}
canvas_measure :: proc(canvas:^Native_Canvas,text:string,state:Native_Canvas_State)->(width,ascent,descent:f64) {
    if canvas.library==nil&&FT_Init_FreeType(&canvas.library)!=0 {return}
    face:=canvas.faces[state.font_kind]
    if face==nil {data:=FONT_DATA[state.font_kind];if FT_New_Memory_Face(canvas.library,raw_data(data),c.long(len(data)),0,&face)!=0 {return};canvas.faces[state.font_kind]=face}
    if FT_Set_Pixel_Sizes(face,0,c.uint(max(1,math.round(state.font_size))))!=0 {return}
    ascent=f64(face.ascender)/f64(face.units_per_em)*f64(state.font_size);descent= -f64(face.descender)/f64(face.units_per_em)*f64(state.font_size)
    for ch in text {if FT_Load_Char(face,c.ulong(ch),0)==0 {width+=f64(face.glyph.advance[0])/64}}
    return
}
canvas_text_metrics :: proc(view:^Document_View,canvas:^Native_Canvas,text:string)->Native_JS_Value {
    width,ascent,descent:=canvas_measure(canvas,text,canvas.state)
    result:=native_js_object(&view.native.script)
    for item in ([7]struct {name:string,value:f64}{{"width",width},{"actualBoundingBoxLeft",0},{"actualBoundingBoxRight",width},{"actualBoundingBoxAscent",ascent},{"actualBoundingBoxDescent",descent},{"fontBoundingBoxAscent",ascent},{"fontBoundingBoxDescent",descent}}) {result.reference.properties[item.name]=native_js_number(item.value)}
    return result
}
canvas_is_point :: proc(canvas:^Native_Canvas,x,y:f64,evenodd:bool)->bool {
    winding:=0
    for start,sub in canvas.starts {end:=len(canvas.path);if sub+1<len(canvas.starts) {end=canvas.starts[sub+1]};if end-start<3 {continue};for i:=start;i<end;i+=1 {a,b:=canvas.path[i],canvas.path[start+(i-start+1)%(end-start)];if (a[1]<=y&&b[1]>y)||(b[1]<=y&&a[1]>y) {cross:=canvas_cross(a,b,{x,y});if b[1]>a[1]&&cross>0 {winding+=1} else if b[1]<a[1]&&cross<0 {winding-=1}}}}
    if evenodd {return abs(winding)%2!=0};return winding!=0
}
native_canvas_call :: proc(view:^Document_View,node:int,name:string,args:[]Native_JS_Value)->Native_JS_Value {
    context.allocator=runtime.heap_allocator()
    canvas:=native_canvas_context(view,node);if canvas==nil {return {}}
    state:=&canvas.state
    x,y,w,h:=canvas_number(args,0),canvas_number(args,1),canvas_number(args,2),canvas_number(args,3)
    switch name {
    case "save":if len(canvas.states)<256 {append(&canvas.states,canvas.state)}
    case "restore":if len(canvas.states)>0 {canvas.state=pop(&canvas.states)}
    case "reset":native_canvas_reset(view,node)
    case "resetTransform":state.transform=CANVAS_IDENTITY
    case "translate":state.transform=canvas_multiply(state.transform,{1,0,0,1,x,y})
    case "scale":state.transform=canvas_multiply(state.transform,{x,0,0,y,0,0})
    case "rotate":state.transform=canvas_multiply(state.transform,{math.cos(x),math.sin(x),-math.sin(x),math.cos(x),0,0})
    case "transform","setTransform":
        transform_matrix:=CANVAS_IDENTITY
        if len(args)>=6 {for i in 0..<6 {transform_matrix[i]=canvas_number(args,i)}}
        else if len(args)==1&&args[0].reference!=nil {for field,i in ([6]string{"a","b","c","d","e","f"}) {transform_matrix[i]=native_js_numeric(native_js_property(&view.native.script,args[0],field))}}
        if name=="transform" {state.transform=canvas_multiply(state.transform,transform_matrix)} else {state.transform=transform_matrix}
    case "getTransform":result:=native_js_object(&view.native.script);for field,i in ([6]string{"a","b","c","d","e","f"}) {result.reference.properties[field]=native_js_number(state.transform[i])};result.reference.properties["is2D"]=native_js_bool(true);return result
    case "beginPath":clear(&canvas.path);clear(&canvas.starts);clear(&canvas.closed)
    case "closePath":if len(canvas.closed)>0 {canvas.closed[len(canvas.closed)-1]=true}
    case "moveTo":canvas_path_move(canvas,canvas_transform(state.transform,{x,y}))
    case "lineTo":canvas_path_line(canvas,canvas_transform(state.transform,{x,y}))
    case "rect":points:=canvas_rect_points(state.transform,x,y,w,h);canvas_path_move(canvas,points[0]);for point in points[1:] {canvas_path_line(canvas,point)};canvas.closed[len(canvas.closed)-1]=true
    case "roundRect":
        radii:=[4]f64{}
        if len(args)>4 {
            if args[4].kind==.Array&&args[4].reference!=nil {
                items:=args[4].reference.items;if len(items)<1||len(items)>4 {document_set_script_error(view,"Canvas roundRect requires one to four radii.");return {}}
                for i in 0..<4 {index:=i;if len(items)==1 {index=0} else if len(items)==2 {index=i%2} else if len(items)==3&&i==3 {index=1};radii[i]=native_js_numeric(items[index])}
            } else {for i in 0..<4 {radii[i]=canvas_number(args,4)}}
        }
        for radius in radii {if radius<0||math.is_nan(radius)||math.is_inf(radius) {document_set_script_error(view,"Canvas roundRect radii must be nonnegative numbers.");return {}}}
        if w<0 {x+=w;w= -w;radii[0],radii[1]=radii[1],radii[0];radii[3],radii[2]=radii[2],radii[3]}
        if h<0 {y+=h;h= -h;radii[0],radii[3]=radii[3],radii[0];radii[1],radii[2]=radii[2],radii[1]}
        factor:f64=1
        if radii[0]+radii[1]>w {factor=min(factor,w/(radii[0]+radii[1]))};if radii[3]+radii[2]>w {factor=min(factor,w/(radii[3]+radii[2]))};if radii[0]+radii[3]>h {factor=min(factor,h/(radii[0]+radii[3]))};if radii[1]+radii[2]>h {factor=min(factor,h/(radii[1]+radii[2]))}
        for &radius in radii {radius*=factor}
        canvas_path_move(canvas,canvas_transform(state.transform,{x+radii[0],y}))
        canvas_path_line(canvas,canvas_transform(state.transform,{x+w-radii[1],y}));canvas_path_arc(canvas,x+w-radii[1],y+radii[1],radii[1],radii[1],0,-math.PI/2,0,false)
        canvas_path_line(canvas,canvas_transform(state.transform,{x+w,y+h-radii[2]}));canvas_path_arc(canvas,x+w-radii[2],y+h-radii[2],radii[2],radii[2],0,0,math.PI/2,false)
        canvas_path_line(canvas,canvas_transform(state.transform,{x+radii[3],y+h}));canvas_path_arc(canvas,x+radii[3],y+h-radii[3],radii[3],radii[3],0,math.PI/2,math.PI,false)
        canvas_path_line(canvas,canvas_transform(state.transform,{x,y+radii[0]}));canvas_path_arc(canvas,x+radii[0],y+radii[0],radii[0],radii[0],0,math.PI,math.PI*1.5,false)
        if len(canvas.closed)>0 {canvas.closed[len(canvas.closed)-1]=true}
    case "arc":if w<0 {document_set_script_error(view,"Canvas arc radius cannot be negative.");return {}};canvas_path_arc(canvas,x,y,w,w,0,h,canvas_number(args,4),len(args)>5&&native_js_truth(args[5]))
    case "ellipse":if w<0||h<0 {document_set_script_error(view,"Canvas ellipse radii cannot be negative.");return {}};canvas_path_arc(canvas,x,y,w,h,canvas_number(args,4),canvas_number(args,5),canvas_number(args,6),len(args)>7&&native_js_truth(args[7]))
    case "quadraticCurveTo","bezierCurveTo":
        if len(canvas.path)==0 {canvas_path_move(canvas,canvas_transform(state.transform,{x,y}))}
        start:=canvas_inverse_point(state.transform,canvas.path[len(canvas.path)-1]);control:=Canvas_Point{x,y};last:=Canvas_Point{w,h};other:=last
        if name=="bezierCurveTo" {last={canvas_number(args,4),canvas_number(args,5)}}
        steps:=clamp(int(math.ceil(math.sqrt(canvas_length({last[0]-start[0],last[1]-start[1]})+canvas_length({control[0]-start[0],control[1]-start[1]}))*2)),8,256)
        for i in 1..=steps {t:=f64(i)/f64(steps);u:=1-t;point:Canvas_Point;if name=="quadraticCurveTo" {point={u*u*start[0]+2*u*t*control[0]+t*t*last[0],u*u*start[1]+2*u*t*control[1]+t*t*last[1]}} else {point={u*u*u*start[0]+3*u*u*t*control[0]+3*u*t*t*other[0]+t*t*t*last[0],u*u*u*start[1]+3*u*u*t*control[1]+3*u*t*t*other[1]+t*t*t*last[1]}};canvas_path_line(canvas,canvas_transform(state.transform,point))}
    case "arcTo":
        if len(canvas.path)==0 {canvas_path_move(canvas,canvas_transform(state.transform,{x,y}));return {}}
        radius:=canvas_number(args,4);p0:=canvas_inverse_point(state.transform,canvas.path[len(canvas.path)-1]);p1,p2:=Canvas_Point{x,y},Canvas_Point{w,h};a,b:=Canvas_Point{p0[0]-p1[0],p0[1]-p1[1]},Canvas_Point{p2[0]-p1[0],p2[1]-p1[1]};al,bl:=canvas_length(a),canvas_length(b)
        if radius<=0||al<1e-9||bl<1e-9 {canvas_path_line(canvas,canvas_transform(state.transform,p1));return {}}
        a={a[0]/al,a[1]/al};b={b[0]/bl,b[1]/bl};angle:=math.acos(clamp(a[0]*b[0]+a[1]*b[1],-1,1));if angle<1e-9||abs(angle-math.PI)<1e-9 {canvas_path_line(canvas,canvas_transform(state.transform,p1));return {}}
        distance:=radius/math.tan(angle/2);t0,t1:=Canvas_Point{p1[0]+a[0]*distance,p1[1]+a[1]*distance},Canvas_Point{p1[0]+b[0]*distance,p1[1]+b[1]*distance};bisector:=Canvas_Point{a[0]+b[0],a[1]+b[1]};length:=canvas_length(bisector);center:=Canvas_Point{p1[0]+bisector[0]/length*radius/math.sin(angle/2),p1[1]+bisector[1]/length*radius/math.sin(angle/2)};canvas_path_line(canvas,canvas_transform(state.transform,t0));canvas_path_arc(canvas,center[0],center[1],radius,radius,0,math.atan2(t0[1]-center[1],t0[0]-center[0]),math.atan2(t1[1]-center[1],t1[0]-center[0]),a[0]*b[1]-a[1]*b[0]>0)
    case "fill","stroke","clip":
        evenodd:=len(args)>0&&native_js_value_text(args[len(args)-1])=="evenodd"
        vertices:[]Canvas_Vertex
        if name=="stroke" {vertices=canvas_stroke_geometry(canvas,canvas.path[:],canvas.starts[:],canvas.closed[:])} else {vertices=canvas_fill_geometry(canvas.path[:],canvas.starts[:],evenodd)}
        defer delete(vertices)
        if len(vertices)>=1000000 {document_set_script_error(view,"Canvas path exceeds the native geometry limit.");return {}}
        if name=="clip" {
            if state.clip_count>=8 {document_set_script_error(view,"Canvas clipping stack exceeds eight intersections.");return {}}
            slot:=-1;for clip,i in canvas.clips {if clip==nil {slot=i;break}}
            owned:=make([]Canvas_Vertex,len(vertices));copy(owned,vertices)
            if slot<0 {slot=len(canvas.clips);append(&canvas.clips,owned)} else {canvas.clips[slot]=owned};state.clip_ids[state.clip_count]=slot;state.clip_count+=1
        } else {color:=state.fill;if name=="stroke" {color=state.stroke};canvas_command_add(view,canvas,vertices,color)}
    case "fillRect","strokeRect","clearRect":
        if w==0||h==0 {return {}}
        points:=canvas_rect_points(state.transform,x,y,w,h)
        if name=="clearRect"&&abs(canvas_cross(points[0],points[1],points[2]))<1e-9 {return {}}
        if name=="clearRect"&&state.clip_count==0 {covers:=true;for corner in ([4]Canvas_Point{{0,0},{f64(canvas.width),0},{f64(canvas.width),f64(canvas.height)},{0,f64(canvas.height)}}) {sign:=canvas_cross(points[0],points[1],points[2]);for edge in 0..<4 {if canvas_cross(points[edge],points[(edge+1)%4],corner)*sign< -1e-9 {covers=false}}};if covers {canvas_commands_clear(canvas);canvas_release_clips(canvas);view.native.revision+=1;return {}}}
        if name=="strokeRect" {starts:=[1]int{0};closed:=[1]bool{true};vertices:=canvas_stroke_geometry(canvas,points[:],starts[:],closed[:]);canvas_command_add(view,canvas,vertices,state.stroke);delete(vertices)} else {vertices:=canvas_rect_geometry(points);kind:=Canvas_Command_Kind.Geometry;if name=="clearRect" {kind=.Clear};canvas_command_add(view,canvas,vertices[:],state.fill,kind)}
    case "setLineDash":
        if len(args)>0&&args[0].kind==.Array&&args[0].reference!=nil {items:=args[0].reference.items;count:=len(items);if count>16 {document_set_script_error(view,"Canvas dash pattern is limited to sixteen values.");return {}};for item in items {n:=native_js_numeric(item);if n<0||math.is_nan(n)||math.is_inf(n) {return {}}};state.dash_count=count;if count%2==1 {state.dash_count*=2};for i in 0..<state.dash_count {state.dash[i]=native_js_numeric(items[i%count])}}
    case "getLineDash":values:=make([dynamic]Native_JS_Value,context.temp_allocator);for number in state.dash[:state.dash_count] {append(&values,native_js_number(number))};return native_js_array(&view.native.script,values[:])
    case "measureText":text:="";if len(args)>0 {text=native_js_value_text(args[0])};return canvas_text_metrics(view,canvas,text)
    case "fillText":
        if len(args)<3 {return {}}
        if state.copy {vertices:=canvas_rect_geometry({{0,0},{f64(canvas.width),0},{f64(canvas.width),f64(canvas.height)},{0,f64(canvas.height)}});canvas_command_add(view,canvas,vertices[:],Color{},.Clear)}
        text:=strings.clone(native_js_value_text(args[0]));color:=state.fill;color[3]*=f32(state.alpha)
        if len(canvas.commands)>=16384 {delete(text);document_set_script_error(view,"Canvas command limit reached.");return {}}
        append(&canvas.commands,Canvas_Command{kind=.Text,text=text,x=canvas_number(args,1),y=canvas_number(args,2),max_width=canvas_number(args,3),color=color,state=state^});view.native.revision+=1
    case "drawImage":
        if len(args)<3||args[0].reference!=nil||args[0].object<0||args[0].object>=len(view.native.nodes) {document_set_script_error(view,"Canvas drawImage needs a loaded document image.");return {}}
        image_id:=view.native.nodes[args[0].object].image;if image_id<0||image_id>=len(view.native.images) {document_set_script_error(view,"Canvas image has not loaded.");return {}}
        image:=view.native.images[image_id];sx,sy,sw,sh:=f64(0),f64(0),f64(image.width),f64(image.height);dx,dy:=canvas_number(args,1),canvas_number(args,2);dw,dh:=sw,sh
        if len(args)>=9 {sx=canvas_number(args,1);sy=canvas_number(args,2);sw=canvas_number(args,3);sh=canvas_number(args,4);dx=canvas_number(args,5);dy=canvas_number(args,6);dw=canvas_number(args,7);dh=canvas_number(args,8)} else if len(args)>=5 {dw=canvas_number(args,3);dh=canvas_number(args,4)}
        if sw<0 {sx+=sw;sw= -sw};if sh<0 {sy+=sh;sh= -sh}
        if sw==0||sh==0||dw==0||dh==0||view.native.atlas_width==0 {return {}}
        if dw<0 {dx+=dw;dw= -dw};if dh<0 {dy+=dh;dh= -dh}
        left,top:=max(0,sx),max(0,sy);right,bottom:=min(f64(image.width),sx+sw),min(f64(image.height),sy+sh)
        if right<=left||bottom<=top {return {}}
        dx+=(left-sx)*dw/sw;dy+=(top-sy)*dh/sh;dw*=(right-left)/sw;dh*=(bottom-top)/sh;sx=left;sy=top;sw=right-left;sh=bottom-top
        points:=canvas_rect_points(state.transform,dx,dy,dw,dh);u0,v0:=f32(f64(image.x)+sx)/f32(view.native.atlas_width),f32(f64(image.y)+sy)/f32(view.native.atlas_height);u1,v1:=f32(f64(image.x)+sx+sw)/f32(view.native.atlas_width),f32(f64(image.y)+sy+sh)/f32(view.native.atlas_height)
        vertices:=[6]Canvas_Vertex{{points[0],{u0,v0}},{points[1],{u1,v0}},{points[2],{u1,v1}},{points[0],{u0,v0}},{points[2],{u1,v1}},{points[3],{u0,v1}}};canvas_command_add(view,canvas,vertices[:],Color{1,1,1,1},.Geometry,1)
    case "isPointInStroke":
        vertices:=canvas_stroke_geometry(canvas,canvas.path[:],canvas.starts[:],canvas.closed[:]);defer delete(vertices)
        for i:=0;i+2<len(vertices);i+=3 {a,b,c:=vertices[i].point,vertices[i+1].point,vertices[i+2].point;sign:f64=1;if canvas_cross(a,b,c)<0 {sign= -1};if canvas_cross(a,b,{x,y})*sign>=0&&canvas_cross(b,c,{x,y})*sign>=0&&canvas_cross(c,a,{x,y})*sign>=0 {return native_js_bool(true)}};return native_js_bool(false)
    case "isPointInPath":evenodd:=len(args)>2&&native_js_value_text(args[2])=="evenodd";return native_js_bool(canvas_is_point(canvas,x,y,evenodd))
    case "getContextAttributes":result:=native_js_object(&view.native.script);result.reference.properties["alpha"]=native_js_bool(true);result.reference.properties["desynchronized"]=native_js_bool(false);return result
    case:document_set_script_error(view,fmt.tprintf("Canvas 2D operation '%s' is not implemented.",name))
    }
    return {}
}
canvas_subtract_triangle :: proc(vertices:[]Canvas_Vertex,a,b,c:Canvas_Point)->[]Canvas_Vertex {
    context.allocator=runtime.heap_allocator();output:=make([dynamic]Canvas_Vertex)
    sign:f64=1;if canvas_cross(a,b,c)<0 {sign= -1};edges:=[3][2]Canvas_Point{{a,b},{b,c},{c,a}}
    if abs(canvas_cross(a,b,c))<1e-9 {output:=make([]Canvas_Vertex,len(vertices));copy(output,vertices);return output}
    for i:=0;i+2<len(vertices);i+=3 {inside:=canvas_polygon_triangle(vertices[i],vertices[i+1],vertices[i+2]);for edge in edges {outside:=canvas_half_plane(inside,edge[0],edge[1],sign,false);canvas_append_polygon(&output,outside);inside=canvas_half_plane(inside,edge[0],edge[1],sign);if inside.count==0 {break}}}
    return output[:]
}
canvas_render_geometry :: proc(a:^App,canvas:^Native_Canvas,vertices:[]Canvas_Vertex,color:Color,texture:f32,command_index:int,x,y,w,h:f32,clip:Explorer_Rect) {
    context.allocator=runtime.heap_allocator()
    visible:=make([]Canvas_Vertex,len(vertices));copy(visible,vertices)
    for command in canvas.commands[command_index+1:] {if command.kind!=.Clear {continue};for i:=0;i+2<len(command.vertices);i+=3 {next:=canvas_subtract_triangle(visible,command.vertices[i].point,command.vertices[i+1].point,command.vertices[i+2].point);delete(visible);visible=next;if len(visible)==0 {break}};if len(visible)==0 {break}}
    defer delete(visible)
    left,top:=max(0,f64((clip.x-x)/w)*f64(canvas.width)),max(0,f64((clip.y-y)/h)*f64(canvas.height));right,bottom:=min(f64(canvas.width),f64((clip.x+clip.w-x)/w)*f64(canvas.width)),min(f64(canvas.height),f64((clip.y+clip.h-y)/h)*f64(canvas.height))
    for i:=0;i+2<len(visible);i+=3 {
        polygon:=canvas_polygon_triangle(visible[i],visible[i+1],visible[i+2]);polygon=canvas_half_plane(polygon,{left,top},{right,top},1);polygon=canvas_half_plane(polygon,{right,top},{right,bottom},1);polygon=canvas_half_plane(polygon,{right,bottom},{left,bottom},1);polygon=canvas_half_plane(polygon,{left,bottom},{left,top},1)
        for k:=1;k<polygon.count-1;k+=1 {for vertex in ([3]Canvas_Vertex{polygon.vertices[0],polygon.vertices[k],polygon.vertices[k+1]}) {append(&a.vertices,Vertex{pos={(x+f32(vertex.point[0]/f64(canvas.width))*w)*a.scale,(y+f32(vertex.point[1]/f64(canvas.height))*h)*a.scale},uv=vertex.uv,color=color,texture=texture})}}
    }
}
canvas_render_text :: proc(a:^App,view:^Document_View,canvas:^Native_Canvas,command:Canvas_Command,index:int,x,y,w,h:f32,clip:Explorer_Rect) {
    state:=command.state;measure,ascent,descent:=canvas_measure(canvas,command.text,state);origin:=command.x;baseline:=command.y
    squeeze:f64=1;if command.max_width>0&&measure>command.max_width {squeeze=command.max_width/measure}
    if state.align==1||state.align==3 {origin-=measure*squeeze} else if state.align==4 {origin-=measure*squeeze/2}
    switch state.baseline {case 1:baseline+=ascent;case 2:baseline+=ascent*0.8;case 3:baseline+=(ascent-descent)/2;case 4:baseline-=descent;case 5:baseline-=descent*0.5}
    transform_scale:=math.sqrt(abs(state.transform[0]*state.transform[3]-state.transform[1]*state.transform[2]));requested:=state.font_size*a.scale*h/f32(canvas.height)*f32(max(0.01,transform_scale))
    font:=renderer_font_size(&a.renderer,requested,state.font_kind);ratio:=f64(state.font_size/font.pixels)
    cursor:=origin
    vertices:=make([dynamic]Canvas_Vertex,context.temp_allocator)
    for ch in command.text {
        glyph:=renderer_glyph(&a.renderer,font,ch)
        if glyph.width>0&&glyph.height>0 {
            gx,gy:=cursor+f64(glyph.left)*ratio,baseline-f64(glyph.top)*ratio;gw,gh:=f64(glyph.width)*ratio,f64(glyph.height)*ratio
            points:=canvas_rect_points(state.transform,origin+(gx-origin)*squeeze,gy,gw*squeeze,gh)
            u0,v0:=f32(glyph.x)/ATLAS_SIZE,f32(glyph.y)/4096;u1,v1:=f32(glyph.x+glyph.width)/ATLAS_SIZE,f32(glyph.y+glyph.height)/4096
            append(&vertices,Canvas_Vertex{points[0],{u0,v0}},Canvas_Vertex{points[1],{u1,v0}},Canvas_Vertex{points[2],{u1,v1}},Canvas_Vertex{points[0],{u0,v0}},Canvas_Vertex{points[2],{u1,v1}},Canvas_Vertex{points[3],{u0,v1}})
        }
        cursor+=f64(glyph.advance)*ratio
    }
    clipped:=canvas_clip_geometry(canvas,vertices[:],state);defer delete(clipped)
    canvas_render_geometry(a,canvas,clipped,command.color,0,index,x,y,w,h,clip)
}
native_canvas_render :: proc(a:^App,view:^Document_View,node:int,x,y,w,h:f32,clip:Explorer_Rect) {
    canvas:=native_canvas_context(view,node);if canvas==nil||canvas.width<=0||canvas.height<=0||w<=0||h<=0 {return}
    for command,index in canvas.commands {
        switch command.kind {
        case .Geometry:canvas_render_geometry(a,canvas,command.vertices,command.color,command.texture,index,x,y,w,h,clip)
        case .Text:canvas_render_text(a,view,canvas,command,index,x,y,w,h,clip)
        case .Clear:
        }
    }
}

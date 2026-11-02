package main

import "core:math"

// Interface surfaces follow T3 Code's neutral layering and task_master's
// hairlines. Floating surfaces (menus, dialogs, media controls) use a glass
// treatment: translucent gradient fill, a specular top rim and a soft shadow.
RADIUS_CONTROL :: f32(8)
RADIUS_ROW :: f32(6)
RADIUS_POPUP :: f32(12)
POPUP_INSET :: f32(4)

GLASS_TOP :: Color{0.125,0.125,0.13,0.95}
GLASS_BOTTOM :: Color{0.085,0.085,0.09,0.97}
GLASS_RIM_TOP :: Color{1,1,1,0.17}
GLASS_RIM_BOTTOM :: Color{1,1,1,0.05}
SCRIM :: Color{0,0,0,0.55}

// Physical edges snap to whole framebuffer pixels so hairlines stay sharp at
// fractional monitor scales.
ui_snap :: proc(a:^App,x,y,w,h:f32)->(x0,y0,pw,ph:f32) {
    x0,y0=math.round(x*a.scale),math.round(y*a.scale)
    x1,y1:=math.round((x+w)*a.scale),math.round((y+h)*a.scale)
    return x0,y0,max(x1-x0,1),max(y1-y0,1)
}
ui_hairline :: proc(a:^App)->f32 {return max(1,math.floor(a.scale+0.25))}
ui_round_gradient :: proc(a:^App,x,y,w,h,radius:f32,top,bottom:Color) {
    if w<=0||h<=0 {return}
    px,py,pw,ph:=ui_snap(a,x,y,w,h)
    renderer_round(&a.vertices,px,py,pw,ph,radius*a.scale,top,bottom)
}
ui_round :: proc(a:^App,x,y,w,h,radius:f32,color:Color) {ui_round_gradient(a,x,y,w,h,radius,color,color)}
ui_round_border :: proc(a:^App,x,y,w,h,radius:f32,top:Color,bottom:Color={}) {
    if w<=0||h<=0 {return}
    px,py,pw,ph:=ui_snap(a,x,y,w,h)
    renderer_round(&a.vertices,px,py,pw,ph,radius*a.scale,top,bottom if bottom[3]>0 else top,border=ui_hairline(a))
}
ui_shadow :: proc(a:^App,x,y,w,h,radius,blur,offset:f32,color:Color) {
    if w<=0||h<=0 {return}
    // Inset the casting shape so the blur straddles the surface edge.
    spread:=blur*0.5
    renderer_round(&a.vertices,(x+spread)*a.scale,(y+spread+offset)*a.scale,(w-2*spread)*a.scale,(h-2*spread)*a.scale,radius*a.scale,color,color,blur=blur*a.scale)
}
ui_glass :: proc(a:^App,x,y,w,h:f32,radius:f32=RADIUS_POPUP) {
    ui_shadow(a,x,y,w,h,radius,28,14,Color{0,0,0,0.55})
    ui_shadow(a,x,y,w,h,radius,3,1,Color{0,0,0,0.45})
    ui_round_gradient(a,x,y,w,h,radius,GLASS_TOP,GLASS_BOTTOM)
    ui_round_border(a,x,y,w,h,radius,GLASS_RIM_TOP,GLASS_RIM_BOTTOM)
}
// Highlighted rows inside glass popups and lists.
ui_row :: proc(a:^App,x,y,w,h:f32,selected,hover:bool) {
    if selected {ui_round(a,x,y,w,h,RADIUS_ROW,ROW_SELECTED)}
    else if hover {ui_round(a,x,y,w,h,RADIUS_ROW,ROW_HOVER)}
}
Control_Style :: enum {Ghost,Outline,Primary}
ui_control :: proc(a:^App,x,y,w,h:f32,style:Control_Style,hover:bool,enabled:bool=true,active:bool=false,radius:f32=RADIUS_CONTROL) {
    switch style {
    case .Ghost:
        if active {ui_round(a,x,y,w,h,radius,ROW_SELECTED)}
        else if hover&&enabled {ui_round(a,x,y,w,h,radius,ROW_HOVER)}
    case .Outline:
        fill:=Color{1,1,1,0.035}
        if (hover&&enabled)||active {fill=Color{1,1,1,0.07}}
        ui_round(a,x,y,w,h,radius,fill)
        ui_round_border(a,x,y,w,h,radius,Color{1,1,1,0.12},Color{1,1,1,0.07})
    case .Primary:
        top,bottom:=PRIMARY,PRIMARY*Color{0.88,0.88,0.88,1}
        if !enabled {top,bottom=Color{1,1,1,0.05},Color{1,1,1,0.05}}
        else if hover {top,bottom=top*Color{1.08,1.08,1.08,1},bottom*Color{1.08,1.08,1.08,1}}
        ui_round_gradient(a,x,y,w,h,radius,top,bottom)
        if enabled {ui_round_border(a,x,y,w,h,radius,Color{1,1,1,0.22},Color{1,1,1,0.04})}
    }
}
// Label centred inside a control, with an optional left inset for icons.
ui_control_label :: proc(a:^App,label:string,x,y,w,h,size:f32,color:Color,inset:f32=0) {
    width:=renderer_text_width(&a.renderer,label,size*a.scale)/a.scale
    tx:=x+inset+max(0,(w-inset-width)/2)
    ui_text_mid(a,label,tx,y+h/2,size,w-inset-8,color)
}
ui_button :: proc(a:^App,label:string,x,y,w,h:f32,style:Control_Style,hover:bool,enabled:bool=true)  {
    ui_control(a,x,y,w,h,style,hover,enabled)
    color:=TEXT if enabled else FAINT
    if style==.Primary&&enabled {color=Color{1,1,1,1}}
    ui_control_label(a,label,x,y,w,h,13,color)
}
ui_stroke :: proc(a:^App,x0,y0,x1,y1:f32,color:Color,thickness:f32=1.4) {
    renderer_stroke(&a.vertices,x0*a.scale,y0*a.scale,x1*a.scale,y1*a.scale,max(1,thickness*a.scale),color)
}
// Small line icons share one stroke weight and are centred on (cx,cy).
ui_icon_close :: proc(a:^App,cx,cy,size:f32,color:Color) {
    r:=size/2
    ui_stroke(a,cx-r,cy-r,cx+r,cy+r,color,1.25);ui_stroke(a,cx+r,cy-r,cx-r,cy+r,color,1.25)
}
ui_icon_plus :: proc(a:^App,cx,cy,size:f32,color:Color) {
    r:=size/2
    ui_stroke(a,cx-r,cy,cx+r,cy,color,1.5);ui_stroke(a,cx,cy-r,cx,cy+r,color,1.5)
}
ui_icon_chevron :: proc(a:^App,cx,cy,size:f32,color:Color,direction:int) {
    // direction: 0 right, 1 left, 2 down, 3 up
    r:=size/2;h:=r/2
    switch direction {
    case 0:ui_stroke(a,cx-h,cy-r,cx+h,cy,color);ui_stroke(a,cx+h,cy,cx-h,cy+r,color)
    case 1:ui_stroke(a,cx+h,cy-r,cx-h,cy,color);ui_stroke(a,cx-h,cy,cx+h,cy+r,color)
    case 2:ui_stroke(a,cx-r,cy-h,cx,cy+h,color);ui_stroke(a,cx,cy+h,cx+r,cy-h,color)
    case 3:ui_stroke(a,cx-r,cy+h,cx,cy-h,color);ui_stroke(a,cx,cy-h,cx+r,cy+h,color)
    }
}
ui_dot :: proc(a:^App,cx,cy,size:f32,color:Color) {ui_round(a,cx-size/2,cy-size/2,size,size,size/2,color)}
// Thin rounded scrollbar thumb, matching T3's translucent overlay bars.
ui_scrollbar :: proc(a:^App,x,y,h:f32,hover:bool=false) {
    ui_round(a,x,y,4,h,2,Color{1,1,1,0.16 if hover else 0.10})
}
// Pill-shaped keyboard hint or count badge; returns its width.
ui_badge :: proc(a:^App,label:string,x,y:f32,color:Color=MUTED,size:f32=11)->f32 {
    w:=renderer_text_width(&a.renderer,label,size*a.scale)/a.scale+12
    h:=size+8
    if len(label)<=2 {w=max(w,h)}
    ui_round(a,x,y,w,h,h/2 if len(label)<=2 else 5,Color{1,1,1,0.07})
    ui_text_mid(a,label,x+(w-(renderer_text_width(&a.renderer,label,size*a.scale)/a.scale))/2,y+h/2,size,w,color)
    return w
}
// Text-entry surface shared by every input.
ui_field :: proc(a:^App,x,y,w,h:f32,focused,hover:bool) {
    if w<=0 {return}
    fill:=Color{1,1,1,0.03}
    if focused {fill=Color{1,1,1,0.05}} else if hover {fill=Color{1,1,1,0.045}}
    ui_round(a,x,y,w,h,RADIUS_CONTROL,fill)
    if focused {
        ui_round_border(a,x-2,y-2,w+4,h+4,RADIUS_CONTROL+2,FOCUS_RING)
        ui_round_border(a,x,y,w,h,RADIUS_CONTROL,Color{1,1,1,0.22})
    } else {
        ui_round_border(a,x,y,w,h,RADIUS_CONTROL,Color{1,1,1,0.12 if hover else 0.08})
    }
}
// Text caret: a thin rounded bar.
ui_caret :: proc(a:^App,x,y,h:f32) {ui_round(a,x,y,1.5,h,0.75,CARET)}
// Inline error/notice with a tinted glass surface.
ui_notice :: proc(a:^App,message:string,x,y,w:f32,color:Color=DANGER) {
    h:=f32(30)
    ui_shadow(a,x,y,w,h,RADIUS_CONTROL,12,6,Color{0,0,0,0.45})
    ui_round(a,x,y,w,h,RADIUS_CONTROL,Color{0.11,0.075,0.075,0.95})
    ui_round_border(a,x,y,w,h,RADIUS_CONTROL,color*Color{1,1,1,0.35})
    ui_dot(a,x+14,y+h/2,6,color)
    ui_fit_text(a,message,x+26,y+8,12,w-36,color)
}
// Text vertically centred on cy: Inter's mixed-case optical centre sits about
// 0.34em above the baseline, and ui_text places the baseline at 0.8em.
ui_text_mid :: proc(a:^App,text:string,x,cy,size,width:f32,color:Color,kind:Font_Kind=.UI) {
    ui_fit_text(a,text,x,cy-0.46*size,size,width,color,kind)
}
// Semibold titles for dialogs and panels.
ui_title :: proc(a:^App,text:string,x,cy,size,width:f32,color:Color=TEXT) {ui_text_mid(a,text,x,cy,size,width,color,.UI_Bold)}
ui_round_outline :: proc(a:^App,x,y,w,h,radius:f32,color:Color,thickness:f32=1.4) {
    if w<=0||h<=0 {return}
    renderer_round(&a.vertices,x*a.scale,y*a.scale,w*a.scale,h*a.scale,radius*a.scale,color,color,border=max(1,thickness*a.scale))
}
// 16×16 line icons drawn from the top-left corner (x,y).
UI_Icon :: enum {None,Terminal,Folder,Window,Server,Link,Check}
ui_icon :: proc(a:^App,icon:UI_Icon,x,y:f32,color:Color) {
    switch icon {
    case .None:
    case .Terminal:
        ui_round_outline(a,x+0.5,y+2,15,12,3,color)
        ui_stroke(a,x+4,y+6,x+6.5,y+8,color);ui_stroke(a,x+6.5,y+8,x+4,y+10,color)
        ui_stroke(a,x+8.5,y+10.5,x+11.5,y+10.5,color)
    case .Folder:
        ui_stroke(a,x+1,y+4,x+1,y+13,color);ui_stroke(a,x+1,y+13,x+15,y+13,color)
        ui_stroke(a,x+15,y+13,x+15,y+5.5,color);ui_stroke(a,x+15,y+5.5,x+8,y+5.5,color)
        ui_stroke(a,x+8,y+5.5,x+6.5,y+3,color);ui_stroke(a,x+6.5,y+3,x+1,y+3,color);ui_stroke(a,x+1,y+3,x+1,y+4,color)
    case .Window:
        ui_round_outline(a,x+0.5,y+2,15,12,3,color)
        ui_stroke(a,x+1,y+5.5,x+15,y+5.5,color)
    case .Server:
        ui_round_outline(a,x+1,y+2,14,5.5,2,color);ui_round_outline(a,x+1,y+8.5,14,5.5,2,color)
        ui_dot(a,x+4.5,y+4.75,1.8,color);ui_dot(a,x+4.5,y+11.25,1.8,color)
    case .Link:
        ui_round_outline(a,x+1,y+1,14,14,7,color)
        ui_stroke(a,x+8,y+5,x+8,y+11,color);ui_stroke(a,x+5,y+8,x+11,y+8,color)
    case .Check:
        ui_stroke(a,x+3,y+8.5,x+6.5,y+12,color,1.6);ui_stroke(a,x+6.5,y+12,x+13,y+4.5,color,1.6)
    }
}

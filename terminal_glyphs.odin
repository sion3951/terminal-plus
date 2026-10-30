package main

import "core:math"

// Box drawing and block elements are drawn as geometry rather than taken from
// a font, so borders join seamlessly across cells in any terminal face.
// Each entry packs arms (2 bits each: up, right, down, left; 1 light, 2 heavy,
// 3 double), dash count (bits 8-9), arc (bit 10), diagonal (bits 11-12) and
// diagonal weight (bits 13-14). Generated from the Unicode character names.
TERMINAL_BOX_TABLE :: [128]u16{
    0x0044,0x0088,0x0011,0x0022,0x0244,0x0288,0x0211,0x0222,
    0x0344,0x0388,0x0311,0x0322,0x0014,0x0018,0x0024,0x0028,
    0x0050,0x0090,0x0060,0x00a0,0x0005,0x0009,0x0006,0x000a,
    0x0041,0x0081,0x0042,0x0082,0x0015,0x0019,0x0016,0x0025,
    0x0026,0x001a,0x0029,0x002a,0x0051,0x0091,0x0052,0x0061,
    0x0062,0x0092,0x00a1,0x00a2,0x0054,0x0094,0x0058,0x0098,
    0x0064,0x00a4,0x0068,0x00a8,0x0045,0x0085,0x0049,0x0089,
    0x0046,0x0086,0x004a,0x008a,0x0055,0x0095,0x0059,0x0099,
    0x0056,0x0065,0x0066,0x0096,0x005a,0x00a5,0x0069,0x009a,
    0x00a9,0x00a6,0x006a,0x00aa,0x0144,0x0188,0x0111,0x0122,
    0x00cc,0x0033,0x001c,0x0034,0x003c,0x00d0,0x0070,0x00f0,
    0x000d,0x0007,0x000f,0x00c1,0x0043,0x00c3,0x001d,0x0037,
    0x003f,0x00d1,0x0073,0x00f3,0x00dc,0x0074,0x00fc,0x00cd,
    0x0047,0x00cf,0x00dd,0x0077,0x00ff,0x0414,0x0450,0x0441,
    0x0405,0x2800,0x3000,0x3800,0x0040,0x0001,0x0004,0x0010,
    0x0080,0x0002,0x0008,0x0020,0x0048,0x0021,0x0084,0x0012,
}

terminal_special_glyph :: proc(ch:rune)->bool {
    return (ch>=0x2500&&ch<=0x259f)||(ch>=0xe0b0&&ch<=0xe0b3)
}
terminal_draw_special :: proc(a:^App,ch:rune,x,y,w,h:f32,color:Color) {
    v:=&a.vertices
    light:=max(1,math.round(a.font_size*0.07))
    switch {
    case ch>=0xe0b0:
        terminal_draw_powerline(a,ch,x,y,w,h,color,light)
        return
    case ch>=0x2580:
        terminal_draw_block(a,ch,x,y,w,h,color)
        return
    }
    table:=TERMINAL_BOX_TABLE
    entry:=table[ch-0x2500]
    // Snap the centre lines so neighbouring cells share identical pixels.
    cx:=x+math.floor(w/2);cy:=y+math.floor(h/2)
    if diagonal:=(entry>>11)&3;diagonal!=0 {
        t:=light*f32((entry>>13)&3)
        if diagonal&1!=0 {renderer_stroke(v,x+w,y,x,y+h,t,color)}
        if diagonal&2!=0 {renderer_stroke(v,x,y,x+w,y+h,t,color)}
        return
    }
    up,right,down,left:=entry&3,(entry>>2)&3,(entry>>4)&3,(entry>>6)&3
    weight :: proc(arm:u16,light:f32)->f32 {return light*2 if arm==2 else light}
    if (entry>>10)&1!=0 {
        // Rounded corner: a quarter circle joined to straight half-arms.
        r:=min(w,h)/2;t:=light
        ox:=cx+t/2;oy:=cy+t/2
        sx:=f32(1) if right!=0 else -1;sy:=f32(1) if down!=0 else -1
        center_x,center_y:=ox+sx*r,oy+sy*r
        steps:=8;previous:=[2]f32{ox,center_y}
        for i in 1..=steps {
            angle:=f32(i)*math.PI/2/f32(steps)
            point:=[2]f32{center_x-sx*r*math.cos(angle),center_y-sy*r*math.sin(angle)}
            renderer_stroke(v,previous[0],previous[1],point[0],point[1],t,color)
            previous=point
        }
        edge_x:=x+w if right!=0 else x
        edge_y:=y+h if down!=0 else y
        if abs(edge_x-center_x)>0.5 {renderer_rect(v,min(center_x,edge_x),oy-t/2,abs(edge_x-center_x),t,color)}
        if abs(edge_y-center_y)>0.5 {renderer_rect(v,ox-t/2,min(center_y,edge_y),t,abs(edge_y-center_y),color)}
        return
    }
    if dash:=(entry>>8)&3;dash!=0 {
        count:=int(dash)+1
        horizontal:=left!=0
        t:=weight(max(left,up),light)
        span:=w if horizontal else h
        step:=span/f32(count)
        for i in 0..<count {
            start:=math.round(f32(i)*step+step*0.15);end:=math.round(f32(i+1)*step-step*0.15)
            if horizontal {renderer_rect(v,x+start,cy-math.floor(t/2),end-start,t,color)}
            else {renderer_rect(v,cx-math.floor(t/2),y+start,t,end-start,color)}
        }
        return
    }
    double:=up==3||right==3||down==3||left==3
    gap:=light
    // Single and heavy arms meet the crossing stroke flush: each arm runs from
    // its cell edge through the perpendicular stroke, or to the nearer line
    // of a perpendicular double pair.
    t:=light;o:=gap+math.floor(t/2)
    weight_of :: proc(a,b:u16,light:f32)->f32 {
        m:=f32(0)
        for arm in ([2]u16{a,b}) {if arm==1 {m=max(m,light)} else if arm==2 {m=max(m,light*2)}}
        return m
    }
    vertical_double:=up==3||down==3;horizontal_double:=left==3||right==3
    tv:=weight_of(up,down,light);th:=weight_of(left,right,light)
    vx:=cx-math.floor(tv/2);hy:=cy-math.floor(th/2)
    left_end,right_start:=cx,cx
    if vertical_double {left_end,right_start=cx-o-math.floor(t/2)+t,cx+o-math.floor(t/2)}
    else if tv>0 {left_end,right_start=vx+tv,vx}
    else if left!=0&&right!=0 {right_start=cx-math.floor(th/2);left_end=right_start+th}
    top_end,bottom_start:=cy,cy
    if horizontal_double {top_end,bottom_start=cy-o-math.floor(t/2)+t,cy+o-math.floor(t/2)}
    else if th>0 {top_end,bottom_start=hy+th,hy}
    else if up!=0&&down!=0 {bottom_start=cy-math.floor(tv/2);top_end=bottom_start+tv}
    if left!=0&&left!=3 {s:=weight(left,light);renderer_rect(v,x,cy-math.floor(s/2),left_end-x,s,color)}
    if right!=0&&right!=3 {s:=weight(right,light);renderer_rect(v,right_start,cy-math.floor(s/2),x+w-right_start,s,color)}
    if up!=0&&up!=3 {s:=weight(up,light);renderer_rect(v,cx-math.floor(s/2),y,s,top_end-y,color)}
    if down!=0&&down!=3 {s:=weight(down,light);renderer_rect(v,cx-math.floor(s/2),bottom_start,s,y+h-bottom_start,color)}
    if !double {return}
    // Double arms are parallel pairs; each line stops where a perpendicular
    // arm would cross it, producing the standard corner and junction shapes.
    any_up,any_down,any_left,any_right:=up!=0,down!=0,left!=0,right!=0
    if left==3 {
        renderer_rect(v,x,cy-o-math.floor(t/2),(cx-o if any_up else cx+o)-x+t,t,color)
        renderer_rect(v,x,cy+o-math.floor(t/2),(cx-o if any_down else cx+o)-x+t,t,color)
    }
    if right==3 {
        top:=cx+o if any_up else cx-o;bottom:=cx+o if any_down else cx-o
        renderer_rect(v,top-math.floor(t/2),cy-o-math.floor(t/2),x+w-top+math.floor(t/2),t,color)
        renderer_rect(v,bottom-math.floor(t/2),cy+o-math.floor(t/2),x+w-bottom+math.floor(t/2),t,color)
    }
    if up==3 {
        renderer_rect(v,cx-o-math.floor(t/2),y,t,(cy-o if any_left else cy+o)-y+t,color)
        renderer_rect(v,cx+o-math.floor(t/2),y,t,(cy-o if any_right else cy+o)-y+t,color)
    }
    if down==3 {
        l:=cy+o if any_left else cy-o;r:=cy+o if any_right else cy-o
        renderer_rect(v,cx-o-math.floor(t/2),l-math.floor(t/2),t,y+h-l+math.floor(t/2),color)
        renderer_rect(v,cx+o-math.floor(t/2),r-math.floor(t/2),t,y+h-r+math.floor(t/2),color)
    }
}
terminal_draw_block :: proc(a:^App,ch:rune,x,y,w,h:f32,color:Color) {
    v:=&a.vertices
    eighth_h:=proc(h:f32,n:int)->f32 {return math.round(h*f32(n)/8)}
    switch ch {
    case 0x2580:renderer_rect(v,x,y,w,math.round(h/2),color)
    case 0x2581..=0x2588:
        n:=int(ch-0x2580);top:=h-eighth_h(h,n)
        renderer_rect(v,x,y+top,w,h-top,color)
    case 0x2589..=0x258f:
        n:=8-int(ch-0x2588)
        renderer_rect(v,x,y,math.round(w*f32(n)/8),h,color)
    case 0x2590:half:=math.round(w/2);renderer_rect(v,x+half,y,w-half,h,color)
    case 0x2591,0x2592,0x2593:
        shade:=color;shade[3]*=f32(ch-0x2590)*0.25
        renderer_rect(v,x,y,w,h,shade)
    case 0x2594:renderer_rect(v,x,y,w,eighth_h(h,1),color)
    case 0x2595:e:=math.round(w/8);renderer_rect(v,x+w-e,y,e,h,color)
    case 0x2596..=0x259f:
        // Quadrant bits: upper-left, upper-right, lower-left, lower-right.
        quads:=[10]u8{0b0100,0b1000,0b0001,0b1101,0b1001,0b0111,0b1011,0b0010,0b0110,0b1110}
        bits:=quads[ch-0x2596]
        hw,hh:=math.round(w/2),math.round(h/2)
        if bits&1!=0 {renderer_rect(v,x,y,hw,hh,color)}
        if bits&2!=0 {renderer_rect(v,x+hw,y,w-hw,hh,color)}
        if bits&4!=0 {renderer_rect(v,x,y+hh,hw,h-hh,color)}
        if bits&8!=0 {renderer_rect(v,x+hw,y+hh,w-hw,h-hh,color)}
    }
}
terminal_draw_powerline :: proc(a:^App,ch:rune,x,y,w,h:f32,color:Color,light:f32) {
    v:=&a.vertices
    switch ch {
    case 0xe0b0:append(v,Vertex{pos={x,y},color=color},Vertex{pos={x+w,y+h/2},color=color},Vertex{pos={x,y+h},color=color})
    case 0xe0b2:append(v,Vertex{pos={x+w,y},color=color},Vertex{pos={x,y+h/2},color=color},Vertex{pos={x+w,y+h},color=color})
    case 0xe0b1:renderer_stroke(v,x,y,x+w,y+h/2,light,color);renderer_stroke(v,x+w,y+h/2,x,y+h,light,color)
    case 0xe0b3:renderer_stroke(v,x+w,y,x,y+h/2,light,color);renderer_stroke(v,x,y+h/2,x+w,y+h,light,color)
    }
}

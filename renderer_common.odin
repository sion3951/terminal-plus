package main

import "core:math"
import "core:mem"

Font_Glyph :: struct {
    x, y, width, height: int,
    left, top: int,
    advance: f32,
}
Font_Size :: struct {
    index: int,
    kind: Font_Kind,
    pixels: f32,
    cell_width, ascent, descent: f32,
    glyphs: [95]Font_Glyph,
    prewarmed: bool,
}
Font_Kind :: enum {UI,Terminal,Terminal_Bold,Terminal_Italic,Terminal_Bold_Italic,UI_Bold}
FONT_SIZES :: [10]f32{12,13,14,15,16,18,20,22,24,28}
// Documents need headings and zoomed text beyond the terminal's size settings.
// Large faces cache only the glyphs used by the current document.
RENDER_FONT_SIZES :: [19]f32{12,13,14,15,16,18,20,22,24,28,32,36,40,48,56,64,80,96,160}
INTER_FONT_DATA :: #load("assets/Inter-Regular.ttf")
FONT_DATA := [Font_Kind][]u8{
    .UI=INTER_FONT_DATA,
    .UI_Bold=#load("assets/Inter-SemiBold.ttf"),
    // Atkinson Hyperlegible Mono keeps commonly confused letters distinct
    // (b/d/p/q, I/l/1, O/0) for dyslexic and low-vision readers.
    .Terminal=#load("assets/AtkinsonHyperlegibleMono-Regular.ttf"),
    .Terminal_Bold=#load("assets/AtkinsonHyperlegibleMono-Bold.ttf"),
    .Terminal_Italic=#load("assets/AtkinsonHyperlegibleMono-Italic.ttf"),
    .Terminal_Bold_Italic=#load("assets/AtkinsonHyperlegibleMono-BoldItalic.ttf"),
}
// Adwaita Mono covers arrows, braille, geometric shapes and symbols missing
// from the primary faces before any system font is consulted.
FALLBACK_FONT_DATA :: #load("assets/AdwaitaMono-Regular.ttf")
FONT_COUNT :: len(RENDER_FONT_SIZES)*len(Font_Kind)

FONT_UNICODE_CACHE_LIMIT :: 2048
ATLAS_HEIGHT :: 4096
Font_Source :: struct {
    path: string,
    data: []u8,
    face: rawptr,
    attempted: bool,
}

// CPU-owned raster data is prepared while the main thread creates the GPU device.
Font_Atlas :: struct {
    pixels: [dynamic]u8,
    fonts: [FONT_COUNT]Font_Size,
    height: int,
    scale: f32,
    ready, dirty, reset_pending: bool,
    x, y, row_height, unicode_y: int,
    unicode: map[u64]Font_Glyph,
    library: rawptr,
    faces: [Font_Kind]rawptr,
    sources: [dynamic]Font_Source,
    sources_scanned: bool,
    fallback: rawptr,
    fallback_attempted: bool,
}

// Texture selects the fragment path: 0 glyph atlas, 1 document page,
// 2 rounded rectangle, 3 soft shadow, 4 antialiased capsule stroke.
Vertex :: struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    texture: f32,
    shape: [4]f32,
}
SHAPE_ROUND :: f32(2)
SHAPE_SHADOW :: f32(3)
SHAPE_STROKE :: f32(4)
VERTEX_INITIAL_CAPACITY :: 256*1024
ATLAS_SIZE :: 2048

renderer_quad :: proc(vertices: ^[dynamic]Vertex, x0,y0,x1,y1,u0,v0,u1,v1: f32, color: [4]f32) {
    a := Vertex{pos={x0,y0},uv={u0,v0},color=color}; b := Vertex{pos={x1,y0},uv={u1,v0},color=color}
    c := Vertex{pos={x1,y1},uv={u1,v1},color=color}; d := Vertex{pos={x0,y1},uv={u0,v1},color=color}
    append(vertices,a,b,c,a,c,d)
}
renderer_rect :: proc(vertices: ^[dynamic]Vertex, x,y,w,h: f32, color: [4]f32) {
    renderer_quad(vertices,x,y,x+w,y+h,0,0,0,0,color)
}
// Physical-pixel rounded rectangle with a vertical gradient. A positive
// border draws only the outline; shadows spread by blur beyond the bounds.
renderer_round :: proc(vertices: ^[dynamic]Vertex, x,y,w,h,radius: f32, top,bottom: [4]f32, border: f32=0, blur: f32=0) {
    if w<=0||h<=0 {return}
    hw,hh:=w/2,h/2
    cx,cy:=x+hw,y+hh
    pad:=blur+1
    kind:=SHAPE_SHADOW if blur>0 else SHAPE_ROUND
    shape:=[4]f32{hw,hh,min(radius,min(hw,hh)),blur if blur>0 else border}
    x0,y0,x1,y1:=x-pad,y-pad,x+w+pad,y+h+pad
    // Interpolate the gradient across the visible bounds, not the padding.
    t0,t1:=(y0-y)/h,(y1-y)/h
    c0,c1:=top+(bottom-top)*t0,top+(bottom-top)*t1
    p0:=Vertex{pos={x0,y0},uv={x0-cx,y0-cy},color=c0,texture=kind,shape=shape}
    p1:=Vertex{pos={x1,y0},uv={x1-cx,y0-cy},color=c0,texture=kind,shape=shape}
    p2:=Vertex{pos={x1,y1},uv={x1-cx,y1-cy},color=c1,texture=kind,shape=shape}
    p3:=Vertex{pos={x0,y1},uv={x0-cx,y1-cy},color=c1,texture=kind,shape=shape}
    append(vertices,p0,p1,p2,p0,p2,p3)
}
renderer_stroke :: proc(vertices: ^[dynamic]Vertex, x0,y0,x1,y1,thickness: f32, color: [4]f32) {
    dx,dy:=x1-x0,y1-y0
    length:=math.sqrt(dx*dx+dy*dy);if length<=0.001 {return}
    ux,uy:=dx/length,dy/length
    half:=thickness/2;pad:=half+1
    shape:=[4]f32{length,half,0,0}
    corner :: proc(x0,y0,ux,uy,along,across:f32,color:[4]f32,shape:[4]f32)->Vertex {
        return {pos={x0+ux*along-uy*across,y0+uy*along+ux*across},uv={along,across},color=color,texture=SHAPE_STROKE,shape=shape}
    }
    p0:=corner(x0,y0,ux,uy,-pad,-pad,color,shape);p1:=corner(x0,y0,ux,uy,length+pad,-pad,color,shape)
    p2:=corner(x0,y0,ux,uy,length+pad,pad,color,shape);p3:=corner(x0,y0,ux,uy,-pad,pad,color,shape)
    append(vertices,p0,p1,p2,p0,p2,p3)
}
renderer_font_size :: proc(r: ^Renderer, size: f32,kind:Font_Kind=.UI) -> ^Font_Size {
    start:=int(kind)*len(RENDER_FONT_SIZES)
    nearest := start
    distance := abs(r.fonts[start].pixels-size)
    for i in start..<start+len(RENDER_FONT_SIZES) {
        font:=r.fonts[i]
        next_distance := abs(font.pixels-size)
        if next_distance < distance { nearest=i; distance=next_distance }
    }
    return &r.fonts[nearest]
}
renderer_text :: proc(r: ^Renderer, vertices: ^[dynamic]Vertex, text: string, x,y,size: f32, color: [4]f32,clip_top:f32=-1e30,clip_bottom:f32=1e30,kind:Font_Kind=.UI) {
    font := renderer_font_size(r,size,kind)
    cursor := math.round(x)
    // Public y denotes the top of the text line rather than its baseline.
    baseline := math.round(y+size*0.80)
    for ch in text {
        glyph := renderer_glyph(r,font,ch)
        if glyph.width > 0 && glyph.height > 0 {
            gx := math.round(cursor)+f32(glyph.left)
            gy := baseline-f32(glyph.top)
            // Integer physical pixels and one atlas texel per framebuffer
            // pixel keep stems crisp even at fractional monitor scales.
            top,bottom:=max(gy,clip_top),min(gy+f32(glyph.height),clip_bottom)
            if bottom>top {
                renderer_quad(vertices,gx,top,gx+f32(glyph.width),bottom,
                    f32(glyph.x)/ATLAS_SIZE,(f32(glyph.y)+top-gy)/f32(r.atlas_height),
                    f32(glyph.x+glyph.width)/ATLAS_SIZE,(f32(glyph.y)+bottom-gy)/f32(r.atlas_height),color)
            }
        }
        cursor+=glyph.advance
    }
}
renderer_text_width :: proc(r: ^Renderer, text: string, size: f32,kind:Font_Kind=.UI) -> f32 {
    font := renderer_font_size(r,size,kind)
    width: f32
    for ch in text { width+=renderer_glyph(r,font,ch).advance }
    return width
}

// Measuring and drawing share the same glyph, including fallback advances.
// Atlas dimensions never change while vertices are being generated.
renderer_glyph :: proc(r:^Renderer,font:^Font_Size,ch:rune)->Font_Glyph {
    if ch>=32 && ch<=126 && font.prewarmed {return font.glyphs[ch-32]}
    // Formatting controls and variation selectors have no standalone ink.
    // Do not insert visible replacement marks into emoji or joined names.
    if ch==0x00ad || ch==0x061c || ch==0xfeff || (ch>=0x200b && ch<=0x200f) || (ch>=0x202a && ch<=0x202e) || (ch>=0x2060 && ch<=0x206f) || (ch>=0xfe00 && ch<=0xfe0f) || (ch>=0xe0000 && ch<=0xe007f) || (ch>=0xe0100 && ch<=0xe01ef) {return {}}
    if ch<32 || (ch>=127 && ch<160) {return font.glyphs['?'-32]}
    index:=font.index
    key:=(u64(index)<<32)|u64(ch)
    if glyph,ok:=r.atlas.unicode[key];ok {return glyph}
    if len(r.atlas.unicode)>=FONT_UNICODE_CACHE_LIMIT {
        r.atlas.reset_pending=true
        return font.glyphs['?'-32]
    }
    glyph,ok:=renderer_font_unicode(&r.atlas,index,ch)
    if !ok {glyph=font.glyphs['?'-32]}
    r.atlas.unicode[key]=glyph
    return glyph
}
renderer_font_pack :: proc(atlas:^Font_Atlas,width,height:int)->(x,y:int,ok:bool) {
    if width+2>=ATLAS_SIZE {return 0,0,false}
    if atlas.x+width+1>=ATLAS_SIZE {atlas.x=1;atlas.y+=atlas.row_height+2;atlas.row_height=0}
    if atlas.y+height+2>ATLAS_HEIGHT {atlas.reset_pending=true;return 0,0,false}
    when ODIN_OS==.Linux {
        // Coordinates retain the maximum-height basis throughout a frame.
        // Only the occupied rows need CPU storage or a GPU texture backing.
        rows:=max(128,len(atlas.pixels)/ATLAS_SIZE)
        for rows<atlas.y+height+2 {rows=min(rows*2,ATLAS_HEIGHT)}
        if rows*ATLAS_SIZE>len(atlas.pixels) {
            if resize(&atlas.pixels,rows*ATLAS_SIZE)!=nil {return 0,0,false}
        }
    }
    x,y=atlas.x,atlas.y
    atlas.x+=width+2;atlas.row_height=max(atlas.row_height,height)
    return x,y,true
}
renderer_font_prepare :: proc(atlas:^Font_Atlas) {
    atlas.unicode_y=atlas.y+atlas.row_height+2
    atlas.x=1;atlas.y=atlas.unicode_y;atlas.row_height=0
    atlas.height=ATLAS_HEIGHT
    when ODIN_OS!=.Linux {resize(&atlas.pixels,ATLAS_SIZE*ATLAS_HEIGHT)}
    atlas.unicode=make(map[u64]Font_Glyph)
}
// Eviction happens only before a new frame, never underneath its vertices.
renderer_font_begin :: proc(r:^Renderer) {
    if !r.atlas.reset_pending {return}
    clear(&r.atlas.unicode)
    start:=r.atlas.unicode_y*ATLAS_SIZE
    when ODIN_OS==.Linux {
        rows:=128
        // A completely packed ASCII section can leave unicode_y at the last
        // atlas row. Cap the target as well as growth to avoid looping forever.
        for rows<min(r.atlas.unicode_y+2,ATLAS_HEIGHT) {rows=min(rows*2,ATLAS_HEIGHT)}
        if rows*ATLAS_SIZE<len(r.atlas.pixels) {
            compact:=make([dynamic]u8,rows*ATLAS_SIZE)
            copy(compact[:start],r.atlas.pixels[:start])
            delete(r.atlas.pixels);r.atlas.pixels=compact
        } else if start<len(r.atlas.pixels) {mem.zero(&r.atlas.pixels[start],len(r.atlas.pixels)-start)}
    } else {
        if start<len(r.atlas.pixels) {mem.zero(&r.atlas.pixels[start],len(r.atlas.pixels)-start)}
    }
    r.atlas.x=1;r.atlas.y=r.atlas.unicode_y;r.atlas.row_height=0
    r.atlas.reset_pending=false;r.atlas.dirty=true
}
renderer_font_accept :: proc(r:^Renderer,atlas:^Font_Atlas) {
    renderer_font_dispose(&r.atlas)
    r.atlas=atlas^
    atlas^={}
}

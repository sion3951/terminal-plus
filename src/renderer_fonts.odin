package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"

// FreeType's public C structure prefixes. Only fields through the rendered
// bitmap are needed; the library owns the complete structures and their tails.
FT_Generic :: struct { data, finalizer: rawptr }
FT_Bitmap :: struct {
    rows, width: c.uint,
    pitch: c.int,
    buffer: [^]u8,
    num_grays: c.ushort,
    pixel_mode, palette_mode: u8,
    palette: rawptr,
}
FT_Glyph_Slot :: struct {
    library, face, next: rawptr,
    glyph_index: c.uint,
    generic: FT_Generic,
    metrics: [8]c.long,
    linear_hori_advance, linear_vert_advance: c.long,
    advance: [2]c.long,
    format: c.uint,
    bitmap: FT_Bitmap,
    bitmap_left, bitmap_top: c.int,
}
FT_Face :: struct {
    num_faces, face_index, face_flags, style_flags, num_glyphs: c.long,
    family_name, style_name: cstring,
    num_fixed_sizes: c.int,
    available_sizes: rawptr,
    num_charmaps: c.int,
    charmaps: rawptr,
    generic: FT_Generic,
    bbox: [4]c.long,
    units_per_em: c.ushort,
    ascender, descender, height, max_advance_width, max_advance_height,
        underline_position, underline_thickness: c.short,
    glyph: ^FT_Glyph_Slot,
}
when ODIN_OS == .Windows {
    FREETYPE_LIBRARY :: #config(FREETYPE_LIBRARY,"system:freetype.lib")
    foreign import freetype {FREETYPE_LIBRARY}
} else {
    FREETYPE_LIBRARY :: #config(FREETYPE_LIBRARY,"system:freetype")
    foreign import freetype {FREETYPE_LIBRARY}
}
foreign freetype {
    FT_Init_FreeType :: proc(library: ^rawptr) -> c.int ---
    FT_Done_FreeType :: proc(library: rawptr) -> c.int ---
    FT_New_Memory_Face :: proc(library: rawptr, data: [^]u8, length, index: c.long, face: ^^FT_Face) -> c.int ---
    FT_New_Face :: proc(library:rawptr,path:cstring,index:c.long,face:^^FT_Face)->c.int ---
    FT_Get_Char_Index :: proc(face:^FT_Face,codepoint:c.ulong)->c.uint ---
    FT_Done_Face :: proc(face: ^FT_Face) -> c.int ---
    FT_Set_Pixel_Sizes :: proc(face: ^FT_Face, width, height: c.uint) -> c.int ---
    FT_Load_Char :: proc(face: ^FT_Face, codepoint: c.ulong, flags: c.int) -> c.int ---
}
// CPU glyph rasterization shared by the Vulkan and Metal backends.
renderer_font_rasterize :: proc(atlas: ^Font_Atlas) -> bool {
    if FT_Init_FreeType(&atlas.library)!=0 {fmt.eprintln("Cannot initialize FreeType");return false}
    when ODIN_OS==.Linux||ODIN_OS==.Darwin {atlas.pixels=make([dynamic]u8,ATLAS_SIZE*128)}
    else {atlas.pixels=make([dynamic]u8,ATLAS_SIZE*ATLAS_HEIGHT)}
    atlas.x=3;atlas.y=1
    for kind in Font_Kind {
        data:=FONT_DATA[kind]
        face:^FT_Face
        if FT_New_Memory_Face(atlas.library,raw_data(data),c.long(len(data)),0,&face)!=0 {return false}
        atlas.faces[kind]=face
        for logical_size,i in RENDER_FONT_SIZES {
            index:=int(kind)*len(RENDER_FONT_SIZES)+i
            pixels:=f32(max(1,int(math.round(logical_size*atlas.scale))))
            font:=&atlas.fonts[index]
            font.index=index;font.kind=kind;font.pixels=pixels
            font.ascent=math.ceil(pixels*f32(face.ascender)/f32(face.units_per_em))
            font.descent=math.ceil(-pixels*f32(face.descender)/f32(face.units_per_em))
            // Prewarm both regular faces. Styled glyphs are cached on demand
            // so high-DPI atlases retain room for Unicode and fallback fonts.
            font.prewarmed=(kind==.UI||kind==.Terminal)&&i<len(FONT_SIZES)
            if font.prewarmed {
                for codepoint in 32..<127 {
                    glyph,ok:=renderer_font_freetype_glyph(atlas,face,index,rune(codepoint))
                    if !ok {return false}
                    font.glyphs[codepoint-32]=glyph
                }
            } else if i<len(FONT_SIZES) {
                // A '?' is always available even when the cache is full.
                glyph,ok:=renderer_font_freetype_glyph(atlas,face,index,'?')
                if !ok {return false}
                font.glyphs['?'-32]=glyph
            }
            if kind==.Terminal {font.cell_width=max(1,font.glyphs['0'-32].advance)}
        }
    }
    atlas.pixels[0]=255;atlas.pixels[1]=255
    atlas.pixels[ATLAS_SIZE]=255;atlas.pixels[ATLAS_SIZE+1]=255
    renderer_font_prepare(atlas)
    atlas.dirty=false
    return true
}
renderer_font_freetype_glyph :: proc(atlas:^Font_Atlas,face:^FT_Face,index:int,ch:rune)->(glyph:Font_Glyph,ok:bool) {
    if FT_Set_Pixel_Sizes(face,0,c.uint(atlas.fonts[index].pixels))!=0 {return {},false}
    // Match task_master: native-size hinted grayscale outlines, without
    // overriding the font's own hinting or rescaling its rendered bitmap.
    if FT_Load_Char(face,c.ulong(ch),(1<<2)|(1<<3))!=0 {return {},false}
    slot:=face.glyph
    bitmap:=slot.bitmap
    w,h:=int(bitmap.width),int(bitmap.rows)
    if w>0 && h>0 && bitmap.pixel_mode!=2 {return {},false}
    x,y,packed:=renderer_font_pack(atlas,w,h)
    if !packed {return {},false}
    if w>0 && h>0 {
        for row in 0..<h {
            source_row:=row
            if bitmap.pitch<0 {source_row=h-1-row}
            mem.copy(&atlas.pixels[(y+row)*ATLAS_SIZE+x],&bitmap.buffer[source_row*abs(int(bitmap.pitch))],w)
        }
    }
    atlas.dirty=true
    return {x=x,y=y,width=w,height=h,left=int(slot.bitmap_left),top=int(slot.bitmap_top),advance=f32(slot.advance[0])/64},true
}
renderer_font_scan_directory :: proc(atlas:^Font_Atlas,path:string) {
    if path=="" {return}
    walker:=os.walker_create(path)
    defer os.walker_destroy(&walker)
    for info in os.walker_walk(&walker) {
        if len(atlas.sources)>=512 {break}
        if info.type==.Directory {continue}
        extension:=strings.to_lower(info.name,context.temp_allocator)
        if !strings.has_suffix(extension,".ttf") && !strings.has_suffix(extension,".otf") && !strings.has_suffix(extension,".ttc") {continue}
        append(&atlas.sources,Font_Source{path=strings.clone(info.fullpath)})
    }
}
renderer_font_scan :: proc(atlas:^Font_Atlas) {
    atlas.sources_scanned=true
    when ODIN_OS==.Windows {
        system_root:=os.get_env("SystemRoot",context.temp_allocator)
        if system_root!="" {renderer_font_scan_directory(atlas,fmt.tprintf("%s/Fonts",system_root))}
        local:=os.get_env("LOCALAPPDATA",context.temp_allocator)
        if local!="" {renderer_font_scan_directory(atlas,fmt.tprintf("%s/Microsoft/Windows/Fonts",local))}
    } else when ODIN_OS==.Darwin {
        renderer_font_scan_directory(atlas,"/System/Library/Fonts")
        renderer_font_scan_directory(atlas,"/Library/Fonts")
        home:=os.get_env("HOME",context.temp_allocator)
        if home!="" {renderer_font_scan_directory(atlas,fmt.tprintf("%s/Library/Fonts",home))}
    } else {
        renderer_font_scan_directory(atlas,"/usr/share/fonts")
        renderer_font_scan_directory(atlas,"/usr/local/share/fonts")
        home:=os.get_env("HOME",context.temp_allocator)
        data:=os.get_env("XDG_DATA_HOME",context.temp_allocator)
        if data!="" {renderer_font_scan_directory(atlas,fmt.tprintf("%s/fonts",data))}
        else if home!="" {renderer_font_scan_directory(atlas,fmt.tprintf("%s/.local/share/fonts",home))}
        if home!="" {renderer_font_scan_directory(atlas,fmt.tprintf("%s/.fonts",home))}
    }
}
renderer_font_unicode :: proc(atlas:^Font_Atlas,index:int,ch:rune)->(Font_Glyph,bool) {
    face:=cast(^FT_Face)atlas.faces[atlas.fonts[index].kind]
    if FT_Get_Char_Index(face,c.ulong(ch))!=0 {return renderer_font_freetype_glyph(atlas,face,index,ch)}
    if !atlas.fallback_attempted {
        atlas.fallback_attempted=true
        fallback:^FT_Face
        data:=FALLBACK_FONT_DATA
        if FT_New_Memory_Face(atlas.library,raw_data(data),c.long(len(data)),0,&fallback)==0 {atlas.fallback=fallback}
    }
    if fallback:=cast(^FT_Face)atlas.fallback;fallback!=nil&&FT_Get_Char_Index(fallback,c.ulong(ch))!=0 {
        if glyph,ok:=renderer_font_freetype_glyph(atlas,fallback,index,ch);ok {return glyph,true}
    }
    if !atlas.sources_scanned {renderer_font_scan(atlas)}
    for &source in atlas.sources {
        if !source.attempted {
            source.attempted=true
            fallback:^FT_Face
            if FT_New_Face(atlas.library,strings.clone_to_cstring(source.path,context.temp_allocator),0,&fallback)==0 {source.face=fallback}
            when ODIN_OS==.Windows {
                // FreeType's narrow path API cannot open every Unicode user
                // profile. Odin opens it through the native wide-path API.
                if source.face==nil {
                    data,error:=os.read_entire_file(source.path,context.allocator)
                    if error==nil {
                        if FT_New_Memory_Face(atlas.library,raw_data(data),c.long(len(data)),0,&fallback)==0 {source.face=fallback;source.data=data}
                        else {delete(data)}
                    }
                }
            }
        }
        fallback:=cast(^FT_Face)source.face
        if fallback==nil || FT_Get_Char_Index(fallback,c.ulong(ch))==0 {continue}
        if glyph,ok:=renderer_font_freetype_glyph(atlas,fallback,index,ch);ok {return glyph,true}
    }
    return {},false
}
renderer_font_dispose :: proc(atlas:^Font_Atlas) {
    for source in atlas.sources {
        if source.face!=nil {FT_Done_Face(cast(^FT_Face)source.face)}
        delete(source.path);delete(source.data)
    }
    delete(atlas.sources)
    if atlas.fallback!=nil {FT_Done_Face(cast(^FT_Face)atlas.fallback)}
    for face in atlas.faces {if face!=nil {FT_Done_Face(cast(^FT_Face)face)}}
    if atlas.library!=nil {FT_Done_FreeType(atlas.library)}
    delete(atlas.pixels);delete(atlas.unicode)
    atlas^={}
}
renderer_font :: proc(r: ^Renderer, scale: f32) -> bool {
    atlas:=new(Font_Atlas);atlas.scale=scale
    defer {renderer_font_dispose(atlas);free(atlas)}
    if !renderer_font_rasterize(atlas)||!renderer_font_upload(r,atlas) {return false}
    renderer_font_accept(r,atlas)
    return true
}

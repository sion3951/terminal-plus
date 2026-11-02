package main

import "base:runtime"
import "core:sync"

// Decoders publish complete frames; the Vulkan thread owns texture uploads.
Renderer_Pixels :: struct {
    mutex:sync.Mutex,
    pixels:rawptr,
    storage:[dynamic]u8,
    pixel_width,pixel_height:int,
    identity,generation:u64,
}
renderer_pixels_identity:u64

renderer_pixels_init :: proc(frame:^Renderer_Pixels) {
    renderer_pixels_identity+=1;frame.identity=renderer_pixels_identity
    frame.storage=make([dynamic]u8,allocator=runtime.heap_allocator())
}
renderer_pixels_publish :: proc(frame:^Renderer_Pixels,pixels:[]u8,width,height:int) {
    if width<=0||height<=0||width>16384||height>16384||len(pixels)!=width*height*4 {return}
    sync.mutex_lock(&frame.mutex);defer sync.mutex_unlock(&frame.mutex)
    if resize(&frame.storage,len(pixels))!=nil {return}
    copy(frame.storage[:],pixels)
    frame.pixels=raw_data(frame.storage);frame.pixel_width=width;frame.pixel_height=height;frame.generation+=1
}
// Hand a decoded buffer to the renderer and recycle its previous allocation.
// No frame-sized copy or allocation occurs on the presentation thread.
renderer_pixels_exchange :: proc(frame:^Renderer_Pixels,pixels:^[dynamic]u8,width,height:int) {
    if pixels==nil||width<=0||height<=0||width>16384||height>16384||len(pixels^)!=width*height*4 {return}
    sync.mutex_lock(&frame.mutex);defer sync.mutex_unlock(&frame.mutex)
    frame.storage,pixels^=pixels^,frame.storage
    frame.pixels=raw_data(frame.storage);frame.pixel_width=width;frame.pixel_height=height;frame.generation+=1
}
renderer_pixels_destroy :: proc(frame:^Renderer_Pixels) {
    delete(frame.storage)
    frame^={}
}

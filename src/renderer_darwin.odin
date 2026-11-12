package main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"

// Metal backend for macOS. It draws the same physical-pixel vertex stream as
// the Vulkan backend into a CAMetalLayer attached to the GLFW Cocoa view, with
// one frame in flight so vertex and texture storage can be reused safely.
Renderer :: struct {
    lifecycle_counted, frame_pending, occluded: bool,
    window: glfw.WindowHandle,
    width, height: int,
    device_name: string,
    capture_path: string,
    capture_supported, capture_success: bool,
    device: ^MTL.Device,
    queue: ^MTL.CommandQueue,
    layer: ^CA.MetalLayer,
    pipeline: ^MTL.RenderPipelineState,
    sampler: ^MTL.SamplerState,
    // The last committed frame; acquiring the next one waits for it.
    in_flight: ^MTL.CommandBuffer,
    drawable: ^CA.MetalDrawable,
    layer_scale: f64,
    vertex_buffer: ^MTL.Buffer,
    vertex_capacity: int,
    vertex_small_frames: int,
    font_texture: ^MTL.Texture,
    font_texture_height: int,
    fonts: [FONT_COUNT]Font_Size,
    font_scale: f32,
    atlas_height: int,
    atlas: Font_Atlas,
    page: Renderer_Page,
    page_source: ^Renderer_Pixels,
}
Renderer_Page :: struct {
    texture: ^MTL.Texture,
    width, height: int,
    identity, generation: u64,
}

RENDERER_METAL_SHADER :: `
#include <metal_stdlib>
using namespace metal;

struct UI_Vertex {
    packed_float2 position;
    packed_float2 uv;
    packed_float4 color;
    float texture_kind;
    packed_float4 shape;
};
struct UI_Varyings {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float texture_kind [[flat]];
    float4 shape [[flat]];
};

vertex UI_Varyings ui_vertex(uint id [[vertex_id]], const device UI_Vertex *vertices [[buffer(0)]], constant float2 &extent [[buffer(1)]]) {
    UI_Vertex v = vertices[id];
    float2 ndc = float2(v.position) / extent * 2.0 - 1.0;
    UI_Varyings out;
    // Vertices use a top-left origin; Metal clip space points y upwards.
    out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    out.uv = float2(v.uv);
    out.color = float4(v.color);
    out.texture_kind = v.texture_kind;
    out.shape = float4(v.shape);
    return out;
}

fragment float4 ui_fragment(UI_Varyings in [[stage_in]], texture2d<float> atlas [[texture(0)]], texture2d<float> page [[texture(1)]], sampler pixel [[sampler(0)]]) {
    if (in.texture_kind > 3.5) {
        // Capsule stroke: UV runs along/across the segment in framebuffer pixels.
        float2 nearest = float2(clamp(in.uv.x, 0.0, in.shape.x), 0.0);
        float distance = length(in.uv - nearest) - in.shape.y;
        return float4(in.color.rgb, in.color.a * clamp(0.5 - distance, 0.0, 1.0));
    }
    if (in.texture_kind > 1.5) {
        // Rounded rectangle: UV is the offset from the centre; shape holds half
        // extents, corner radius and either a border or blur width.
        float2 q = abs(in.uv) - in.shape.xy + in.shape.z;
        float distance = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - in.shape.z;
        float coverage;
        if (in.texture_kind > 2.5) {
            coverage = 1.0 - smoothstep(-in.shape.w, in.shape.w, distance);
        } else {
            if (in.shape.w > 0.0) {distance = abs(distance + in.shape.w * 0.5) - in.shape.w * 0.5;}
            coverage = clamp(0.5 - distance, 0.0, 1.0);
        }
        return float4(in.color.rgb, in.color.a * coverage);
    }
    if (in.texture_kind > 0.5) {
        return page.sample(pixel, in.uv) * in.color;
    }
    // Glyph coordinates retain a 4096-row basis as the atlas grows.
    float2 uv = in.uv * float2(1.0, 4096.0 / float(atlas.get_height()));
    return float4(in.color.rgb, in.color.a * atlas.sample(pixel, uv).r);
}
`

foreign import core_graphics "system:CoreGraphics.framework"
@(default_calling_convention="c")
foreign core_graphics {
    @(link_name="kCGColorSpaceSRGB") renderer_cg_srgb_name: ^NS.String
    @(link_name="CGColorSpaceCreateWithName") renderer_cg_colorspace_create :: proc(name:^NS.String)->rawptr ---
    @(link_name="CGColorSpaceRelease") renderer_cg_colorspace_release :: proc(space:rawptr) ---
}

renderer_glfw_count:int

renderer_metal_error :: proc(action:string,error:^NS.Error) {
    if error!=nil {fmt.eprintf("Metal %s: %s\n",action,NS.String_odinString(NS.Error_localizedDescription(error)))}
    else {fmt.eprintf("Metal %s failed\n",action)}
}
renderer_release :: proc(object:^$T) {
    if object!=nil {NS.release(cast(^NS.Object)object)}
}

// Wait for the frame in flight. Storage it reads may then be rewritten.
renderer_wait_idle :: proc(r:^Renderer) {
    if r.in_flight==nil {return}
    MTL.CommandBuffer_waitUntilCompleted(r.in_flight)
    renderer_release(r.in_flight);r.in_flight=nil
}
renderer_frame_busy :: proc(r:^Renderer)->bool {
    if r.in_flight==nil {return false}
    status:=MTL.CommandBuffer_status(r.in_flight)
    if status!=.Completed&&status!=.Error {return true}
    renderer_release(r.in_flight);r.in_flight=nil
    return false
}

renderer_reserve_vertices :: proc(r:^Renderer,size:int)->bool {
    capacity:=VERTEX_INITIAL_CAPACITY
    if r.vertex_buffer!=nil&&size<=r.vertex_capacity {
        if r.vertex_capacity<=VERTEX_INITIAL_CAPACITY||size>r.vertex_capacity/4 {r.vertex_small_frames=0;return true}
        r.vertex_small_frames+=1
        if r.vertex_small_frames<120 {return true}
    } else {
        capacity=max(capacity,r.vertex_capacity)
    }
    r.vertex_small_frames=0
    for capacity<size {capacity*=2}
    shrinking:=capacity<r.vertex_capacity
    buffer:=MTL.Device_newBufferWithLength(r.device,NS.UInteger(capacity),MTL.ResourceStorageModeShared)
    // An optional trim must never interrupt rendering if allocation fails.
    if buffer==nil {return shrinking}
    renderer_release(r.vertex_buffer)
    r.vertex_buffer=buffer;r.vertex_capacity=capacity
    return true
}

renderer_texture :: proc(r:^Renderer,format:MTL.PixelFormat,width,height:int)->^MTL.Texture {
    // Page and scale changes run outside a frame's pool; free the descriptor here.
    pool:=NS.AutoreleasePool_alloc();NS.AutoreleasePool_init(pool)
    defer NS.AutoreleasePool_drain(pool)
    descriptor:=MTL.TextureDescriptor_texture2DDescriptorWithPixelFormat(format,NS.UInteger(width),NS.UInteger(height),false)
    MTL.TextureDescriptor_setUsage(descriptor,{.ShaderRead})
    // Apple GPUs share memory with the CPU; uploads are a direct copy.
    MTL.TextureDescriptor_setStorageMode(descriptor,.Shared)
    return MTL.Device_newTextureWithDescriptor(r.device,descriptor)
}
renderer_texture_write :: proc(texture:^MTL.Texture,pixels:rawptr,width,height,bytes_per_pixel:int) {
    region:=MTL.Region{origin={0,0,0},size={NS.Integer(width),NS.Integer(height),1}}
    MTL.Texture_replaceRegion(texture,region,0,pixels,NS.UInteger(width*bytes_per_pixel))
}

renderer_font_upload :: proc(r:^Renderer,atlas:^Font_Atlas)->bool {
    pixels:=atlas.pixels[:]
    texture_height:=len(pixels)/ATLAS_SIZE
    if texture_height<=0 {return false}
    r.fonts=atlas.fonts
    r.atlas_height=atlas.height
    // The atlas texture may be sampled by the frame in flight.
    renderer_wait_idle(r)
    if r.font_texture==nil||r.font_texture_height!=texture_height {
        texture:=renderer_texture(r,.R8Unorm,ATLAS_SIZE,texture_height)
        if texture==nil {fmt.eprintln("Metal font texture allocation failed");return false}
        renderer_release(r.font_texture)
        r.font_texture=texture;r.font_texture_height=texture_height
    }
    renderer_texture_write(r.font_texture,raw_data(pixels),ATLAS_SIZE,texture_height,1)
    r.font_scale=atlas.scale
    atlas.dirty=false
    return true
}
renderer_set_scale :: proc(r:^Renderer,scale:f32)->bool {
    renderer_font_begin(r)
    target_scale:=clamp(scale,0.5,4.0)
    if abs(r.font_scale-target_scale)<0.001 {return true}
    renderer_wait_idle(r)
    return renderer_font(r,target_scale)
}

renderer_pipeline :: proc(r:^Renderer)->bool {
    source:=NS.String_initWithOdinString(NS.String_alloc(),RENDERER_METAL_SHADER)
    defer NS.release(source)
    library,library_error:=MTL.Device_newLibraryWithSource(r.device,source,nil)
    if library==nil {renderer_metal_error("shader compile",library_error);return false}
    defer NS.release(library)
    vertex_function:=MTL.Library_newFunctionWithName(library,NS.AT("ui_vertex"))
    fragment_function:=MTL.Library_newFunctionWithName(library,NS.AT("ui_fragment"))
    defer {renderer_release(vertex_function);renderer_release(fragment_function)}
    if vertex_function==nil||fragment_function==nil {fmt.eprintln("Metal shader entry points are missing");return false}
    descriptor:=MTL.RenderPipelineDescriptor_init(MTL.RenderPipelineDescriptor_alloc())
    defer NS.release(descriptor)
    MTL.RenderPipelineDescriptor_setVertexFunction(descriptor,vertex_function)
    MTL.RenderPipelineDescriptor_setFragmentFunction(descriptor,fragment_function)
    color:=MTL.RenderPipelineColorAttachmentDescriptorArray_object(MTL.RenderPipelineDescriptor_colorAttachments(descriptor),0)
    MTL.RenderPipelineColorAttachmentDescriptor_setPixelFormat(color,.BGRA8Unorm)
    MTL.RenderPipelineColorAttachmentDescriptor_setBlendingEnabled(color,true)
    MTL.RenderPipelineColorAttachmentDescriptor_setRgbBlendOperation(color,.Add)
    MTL.RenderPipelineColorAttachmentDescriptor_setAlphaBlendOperation(color,.Add)
    MTL.RenderPipelineColorAttachmentDescriptor_setSourceRGBBlendFactor(color,.SourceAlpha)
    MTL.RenderPipelineColorAttachmentDescriptor_setDestinationRGBBlendFactor(color,.OneMinusSourceAlpha)
    MTL.RenderPipelineColorAttachmentDescriptor_setSourceAlphaBlendFactor(color,.One)
    MTL.RenderPipelineColorAttachmentDescriptor_setDestinationAlphaBlendFactor(color,.OneMinusSourceAlpha)
    MTL.RenderPipelineColorAttachmentDescriptor_setWriteMask(color,MTL.ColorWriteMaskAll)
    pipeline,pipeline_error:=MTL.Device_newRenderPipelineStateWithDescriptor(r.device,descriptor)
    if pipeline==nil {renderer_metal_error("render pipeline",pipeline_error);return false}
    r.pipeline=pipeline
    // One glyph texel maps to one physical pixel, as in the Vulkan backend.
    sampler:=MTL.SamplerDescriptor_init(MTL.SamplerDescriptor_alloc())
    defer NS.release(sampler)
    MTL.SamplerDescriptor_setMinFilter(sampler,.Nearest)
    MTL.SamplerDescriptor_setMagFilter(sampler,.Nearest)
    MTL.SamplerDescriptor_setMipFilter(sampler,.NotMipmapped)
    MTL.SamplerDescriptor_setSAddressMode(sampler,.ClampToEdge)
    MTL.SamplerDescriptor_setTAddressMode(sampler,.ClampToEdge)
    r.sampler=MTL.Device_newSamplerState(r.device,sampler)
    if r.sampler==nil {fmt.eprintln("Metal sampler creation failed");return false}
    return true
}

// Keep the layer's backing store at the framebuffer's physical size and the
// current display's scale so glyphs map one texel to one screen pixel.
renderer_layer_resize :: proc(r:^Renderer) {
    w,h:=glfw.GetFramebufferSize(r.window)
    r.width=int(max(w,0));r.height=int(max(h,0))
    window:=glfw.GetCocoaWindow(r.window)
    if window!=nil {
        scale:=f64(NS.Window_backingScaleFactor(window))
        if scale>0&&scale!=r.layer_scale {r.layer_scale=scale;NS.Layer_setContentsScale(r.layer,NS.Float(scale))}
    }
    if r.width>0&&r.height>0 {CA.MetalLayer_setDrawableSize(r.layer,NS.Size{NS.Float(r.width),NS.Float(r.height)})}
}

renderer_init :: proc(r:^Renderer,width,height:int,title:cstring)->bool {
    pool:=NS.AutoreleasePool_alloc();NS.AutoreleasePool_init(pool)
    defer NS.AutoreleasePool_drain(pool)
    stage:=time.tick_now()
    if renderer_glfw_count==0 {
        // A bundled app must keep the user's working directory for shells.
        glfw.InitHint(glfw.COCOA_CHDIR_RESOURCES,0)
        if !glfw.Init() {fmt.eprintln("Cannot initialize the macOS window system.");return false}
    }
    renderer_glfw_count+=1;r.lifecycle_counted=true
    stage=startup_stage(stage,"GLFW initialization")
    r.device=MTL.CreateSystemDefaultDevice()
    if r.device==nil {fmt.eprintln("No Metal graphics device is available");renderer_destroy(r);return false}
    r.device_name=strings.clone(NS.String_odinString(MTL.Device_name(r.device)))
    stage=startup_stage(stage,"Metal device")
    glfw.WindowHint(glfw.CLIENT_API,glfw.NO_API)
    glfw.WindowHint(glfw.SCALE_FRAMEBUFFER,1)
    glfw.WindowHint(glfw.VISIBLE,true)
    r.window=glfw.CreateWindow(i32(width),i32(height),title,nil,nil)
    if r.window==nil {renderer_destroy(r);return false}
    r.width=width;r.height=height
    scale_x,scale_y:=glfw.GetWindowContentScale(r.window)
    atlas:=new(Font_Atlas);atlas.scale=clamp(max(scale_x,scale_y),0.5,4.0)
    font_worker:=thread.create(startup_font_worker)
    if font_worker!=nil {font_worker.data=atlas;thread.start(font_worker)}
    else {atlas.ready=renderer_font_rasterize(atlas)}
    defer {
        // Also wait on early Metal failures before releasing worker-owned data.
        if font_worker!=nil {thread.destroy(font_worker)}
        renderer_font_dispose(atlas);free(atlas)
    }
    stage=startup_stage(stage,"GLFW / window")
    window:=glfw.GetCocoaWindow(r.window)
    view:=glfw.GetCocoaView(r.window)
    if window==nil||view==nil {fmt.eprintln("GLFW did not create a Cocoa window");renderer_destroy(r);return false}
    r.layer=CA.MetalLayer_layer()
    if r.layer==nil {fmt.eprintln("Cannot create a Metal layer");renderer_destroy(r);return false}
    NS.retain(cast(^NS.Object)r.layer)
    CA.MetalLayer_setDevice(r.layer,r.device)
    // UNORM keeps the deliberate UI palette identical to its authored RGB
    // colors; tagging it sRGB matches how Linux compositors present it.
    CA.MetalLayer_setPixelFormat(r.layer,.BGRA8Unorm)
    if space:=renderer_cg_colorspace_create(renderer_cg_srgb_name);space!=nil {
        CA.MetalLayer_setColorSpace(r.layer,cast(NS.id)space)
        renderer_cg_colorspace_release(space)
    }
    // Screenshots read the presented drawable back.
    CA.MetalLayer_setFramebufferOnly(r.layer,false)
    CA.MetalLayer_setMaximumDrawableCount(r.layer,3)
    CA.MetalLayer_setOpaque(r.layer,true)
    NS.View_setLayer(view,r.layer)
    NS.View_setWantsLayer(view,true)
    renderer_layer_resize(r)
    r.capture_supported=true
    stage=startup_stage(stage,"Metal layer")
    r.queue=MTL.Device_newCommandQueue(r.device)
    if r.queue==nil {fmt.eprintln("Cannot create a Metal command queue");renderer_destroy(r);return false}
    if !renderer_pipeline(r) {renderer_destroy(r);return false}
    stage=startup_stage(stage,"pipeline")
    if font_worker!=nil {thread.join(font_worker)}
    if !atlas.ready||!renderer_font_upload(r,atlas) {renderer_destroy(r);return false}
    renderer_font_accept(r,atlas)
    stage=startup_stage(stage,"font join / upload")
    return true
}

renderer_prepare_frame :: proc(r:^Renderer)->bool {
    w,h:=glfw.GetFramebufferSize(r.window)
    window:=glfw.GetCocoaWindow(r.window)
    scale:=r.layer_scale
    if window!=nil {scale=f64(NS.Window_backingScaleFactor(window))}
    if int(w)!=r.width||int(h)!=r.height||scale!=r.layer_scale {renderer_layer_resize(r)}
    return true
}

renderer_acquire_frame :: proc(r:^Renderer)->(index:u32,ready,ok:bool) {
    r.frame_pending=false;r.occluded=false
    if r.width<=0||r.height<=0||glfw.GetWindowAttrib(r.window,glfw.ICONIFIED)!=0||glfw.GetWindowAttrib(r.window,glfw.VISIBLE)==0 {return 0,false,true}
    // A busy or occluded window must not hold up its siblings. Pending GPU
    // work retries from the shared event loop without blocking on this layer.
    if renderer_frame_busy(r) {r.frame_pending=true;return 0,false,true}
    // A covered window or one on another Space is not composited, so
    // nextDrawable would block for up to a second and stall every window.
    // Keep the frame dirty and recheck occasionally until it is visible.
    if window:=glfw.GetCocoaWindow(r.window);window!=nil {
        NS_WINDOW_OCCLUSION_VISIBLE :: NS.UInteger(1<<1)
        if intrinsics.objc_send(NS.UInteger,window,"occlusionState")&NS_WINDOW_OCCLUSION_VISIBLE==0 {r.occluded=true;return 0,false,true}
    }
    if r.drawable==nil {
        pool:=NS.AutoreleasePool_alloc();NS.AutoreleasePool_init(pool)
        defer NS.AutoreleasePool_drain(pool)
        drawable:=CA.MetalLayer_nextDrawable(r.layer)
        if drawable==nil {r.frame_pending=true;return 0,false,true}
        NS.retain(cast(^NS.Object)drawable)
        r.drawable=drawable
    }
    return 0,true,true
}
renderer_frame_wait_delay :: proc(r:^Renderer,precise:bool=false)->f64 {
    if r.frame_pending {return (0.001 if precise else 0.008)}
    if r.occluded {return 0.25}
    return 60
}

renderer_draw :: proc(r:^Renderer,vertices:[]Vertex,image_index:u32)->bool {
    pool:=NS.AutoreleasePool_alloc();NS.AutoreleasePool_init(pool)
    defer NS.AutoreleasePool_drain(pool)
    drawable:=r.drawable
    if drawable==nil {return true}
    defer {renderer_release(r.drawable);r.drawable=nil}
    if r.atlas.dirty&&!renderer_font_upload(r,&r.atlas) {return false}
    bytes:=len(vertices)*size_of(Vertex)
    if !renderer_reserve_vertices(r,max(bytes,1)) {return false}
    if r.page_source==nil {renderer_page_release(r)}
    if bytes>0 {mem.copy(MTL.Buffer_contentsPointer(r.vertex_buffer),raw_data(vertices),bytes)}
    target:=CA.MetalDrawable_texture(drawable)
    target_width,target_height:=int(MTL.Texture_width(target)),int(MTL.Texture_height(target))
    pass:=MTL.RenderPassDescriptor_renderPassDescriptor()
    color:=MTL.RenderPassColorAttachmentDescriptorArray_object(MTL.RenderPassDescriptor_colorAttachments(pass),0)
    MTL.RenderPassAttachmentDescriptor_setTexture(color,target)
    MTL.RenderPassAttachmentDescriptor_setLoadAction(color,.Clear)
    MTL.RenderPassAttachmentDescriptor_setStoreAction(color,.Store)
    MTL.RenderPassColorAttachmentDescriptor_setClearColor(color,MTL.ClearColor{f64(BG[0]),f64(BG[1]),f64(BG[2]),f64(BG[3])})
    command:=MTL.CommandQueue_commandBuffer(r.queue)
    if command==nil {fmt.eprintln("Cannot allocate a Metal command buffer");return false}
    encoder:=MTL.CommandBuffer_renderCommandEncoderWithDescriptor(command,pass)
    MTL.RenderCommandEncoder_setRenderPipelineState(encoder,r.pipeline)
    MTL.RenderCommandEncoder_setViewport(encoder,MTL.Viewport{0,0,f64(target_width),f64(target_height),0,1})
    extent:=[2]f32{f32(target_width),f32(target_height)}
    MTL.RenderCommandEncoder_setVertexBuffer(encoder,r.vertex_buffer,0,0)
    MTL.RenderCommandEncoder_setVertexBytes(encoder,mem.ptr_to_bytes(&extent),1)
    page:=r.page.texture if r.page.texture!=nil else r.font_texture
    MTL.RenderCommandEncoder_setFragmentTexture(encoder,r.font_texture,0)
    MTL.RenderCommandEncoder_setFragmentTexture(encoder,page,1)
    MTL.RenderCommandEncoder_setFragmentSamplerState(encoder,r.sampler,0)
    if len(vertices)>0 {MTL.RenderCommandEncoder_drawPrimitives(encoder,.Triangle,0,NS.UInteger(len(vertices)))}
    MTL.CommandEncoder_endEncoding(encoder)
    capture:^MTL.Buffer
    defer renderer_release(capture)
    capture_bytes:=target_width*target_height*4
    if r.capture_path!="" {
        r.capture_success=false
        capture=MTL.Device_newBufferWithLength(r.device,NS.UInteger(capture_bytes),MTL.ResourceStorageModeShared)
        if capture!=nil {
            blit:=MTL.CommandBuffer_blitCommandEncoder(command)
            MTL.BlitCommandEncoder_copyFromTextureEx(blit,target,0,0,MTL.Origin{0,0,0},MTL.Size{NS.Integer(target_width),NS.Integer(target_height),1},
                capture,0,NS.UInteger(target_width*4),NS.UInteger(capture_bytes))
            MTL.CommandEncoder_endEncoding(blit)
        } else {fmt.eprintln("Metal screenshot buffer allocation failed");r.capture_path=""}
    }
    MTL.CommandBuffer_presentDrawable(command,drawable)
    MTL.CommandBuffer_commit(command)
    NS.retain(cast(^NS.Object)command)
    r.in_flight=command
    if capture!=nil {
        renderer_wait_idle(r)
        // Encoding repeatedly reads neighbouring pixels; work from ordinary RAM.
        pixels:=make([]u8,capture_bytes)
        defer delete(pixels)
        copy(pixels,(cast([^]u8)MTL.Buffer_contentsPointer(capture))[:capture_bytes])
        for i:=0;i<capture_bytes;i+=4 {pixels[i],pixels[i+2]=pixels[i+2],pixels[i]}
        path:=strings.clone_to_cstring(r.capture_path)
        r.capture_success=stbi.write_png(path,i32(target_width),i32(target_height),4,raw_data(pixels),i32(target_width*4))!=0
        delete(path)
        r.capture_path=""
    }
    return true
}

// Decoders publish complete frames; the presentation thread owns the texture.
// Called before vertex generation, after any previous frame may still be in
// flight, so wait for it before rewriting shared texture storage.
renderer_page_prepare :: proc(r:^Renderer)->bool {
    control:=r.page_source;p:=&r.page
    if control==nil {return true}
    sync.mutex_lock(&control.mutex);defer sync.mutex_unlock(&control.mutex)
    if control.pixels==nil {return true}
    if p.identity==control.identity&&p.generation==control.generation {return true}
    width,height:=control.pixel_width,control.pixel_height
    renderer_wait_idle(r)
    if p.texture==nil||p.width!=width||p.height!=height {
        renderer_release(p.texture);p^={}
        p.texture=renderer_texture(r,.RGBA8Unorm,width,height)
        if p.texture==nil {fmt.eprintln("Metal document texture allocation failed");return false}
        p.width=width;p.height=height
    }
    renderer_texture_write(p.texture,control.pixels,width,height,4)
    p.identity=control.identity;p.generation=control.generation
    return true
}
renderer_page_release :: proc(r:^Renderer) {
    if r.page.texture==nil {return}
    renderer_wait_idle(r)
    renderer_release(r.page.texture)
    r.page={}
}

renderer_destroy :: proc(r:^Renderer) {
    renderer_font_dispose(&r.atlas)
    renderer_wait_idle(r)
    renderer_release(r.drawable)
    renderer_release(r.page.texture)
    renderer_release(r.font_texture)
    renderer_release(r.vertex_buffer)
    renderer_release(r.sampler)
    renderer_release(r.pipeline)
    renderer_release(r.queue)
    if r.window!=nil {glfw.DestroyWindow(r.window)}
    renderer_release(r.layer)
    renderer_release(r.device)
    if r.device_name!="" {delete(r.device_name)}
    if r.lifecycle_counted {
        renderer_glfw_count-=1
        if renderer_glfw_count==0 {tab_drag_wayland_destroy();glfw.Terminate()}
    }
    r^={}
}

renderer_backend_name :: proc()->string {return "Metal"}

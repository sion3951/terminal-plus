#+build !darwin
package main

import vk "vendor:vulkan"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import "core:c"
import "core:mem"
import "core:fmt"
import "core:strings"
import "core:math"
import "core:time"
import "core:thread"
import "core:os"

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
Renderer :: struct {
    dispatch: Renderer_Vulkan,
    lifecycle_counted, frame_pending: bool,
    window: glfw.WindowHandle,
    width, height: int,
    device_name: string,
    capture_path: string,
    capture_supported, capture_success: bool,
    instance: vk.Instance,
    physical: vk.PhysicalDevice,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    queue: vk.Queue,
    family: u32,
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    images: []vk.Image,
    views: []vk.ImageView,
    framebuffers: []vk.Framebuffer,
    present_semaphores: []vk.Semaphore,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    pool: vk.CommandPool,
    command: vk.CommandBuffer,
    fence: vk.Fence,
    acquired: vk.Semaphore,
    vertex_buffer: vk.Buffer,
    vertex_memory: vk.DeviceMemory,
    vertex_mapping: rawptr,
    vertex_capacity: int,
    vertex_small_frames: int,
    font_image: vk.Image,
    font_memory: vk.DeviceMemory,
    font_view: vk.ImageView,
    font_texture_height: int,
    font_staging: vk.Buffer,
    font_staging_memory: vk.DeviceMemory,
    font_staging_mapping: rawptr,
    font_staging_capacity: int,
    sampler: vk.Sampler,
    descriptor_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor: vk.DescriptorSet,
    fonts: [FONT_COUNT]Font_Size,
    font_scale: f32,
    atlas_height: int,
    atlas: Font_Atlas,
    page: Renderer_Page,
    page_source: ^Renderer_Pixels,
}
Renderer_Vulkan :: struct {
    AcquireNextImageKHR: vk.ProcAcquireNextImageKHR,
    AllocateCommandBuffers: vk.ProcAllocateCommandBuffers,
    AllocateDescriptorSets: vk.ProcAllocateDescriptorSets,
    AllocateMemory: vk.ProcAllocateMemory,
    BeginCommandBuffer: vk.ProcBeginCommandBuffer,
    BindBufferMemory: vk.ProcBindBufferMemory,
    BindImageMemory: vk.ProcBindImageMemory,
    CmdBeginRenderPass: vk.ProcCmdBeginRenderPass,
    CmdBindDescriptorSets: vk.ProcCmdBindDescriptorSets,
    CmdBindPipeline: vk.ProcCmdBindPipeline,
    CmdBindVertexBuffers: vk.ProcCmdBindVertexBuffers,
    CmdCopyBufferToImage: vk.ProcCmdCopyBufferToImage,
    CmdCopyImageToBuffer: vk.ProcCmdCopyImageToBuffer,
    CmdDraw: vk.ProcCmdDraw,
    CmdEndRenderPass: vk.ProcCmdEndRenderPass,
    CmdPipelineBarrier: vk.ProcCmdPipelineBarrier,
    CmdPushConstants: vk.ProcCmdPushConstants,
    CmdSetScissor: vk.ProcCmdSetScissor,
    CmdSetViewport: vk.ProcCmdSetViewport,
    CreateBuffer: vk.ProcCreateBuffer,
    CreateCommandPool: vk.ProcCreateCommandPool,
    CreateDescriptorPool: vk.ProcCreateDescriptorPool,
    CreateDescriptorSetLayout: vk.ProcCreateDescriptorSetLayout,
    CreateDevice: vk.ProcCreateDevice,
    CreateFence: vk.ProcCreateFence,
    CreateFramebuffer: vk.ProcCreateFramebuffer,
    CreateGraphicsPipelines: vk.ProcCreateGraphicsPipelines,
    CreateImage: vk.ProcCreateImage,
    CreateImageView: vk.ProcCreateImageView,
    CreateInstance: vk.ProcCreateInstance,
    CreatePipelineLayout: vk.ProcCreatePipelineLayout,
    CreateRenderPass: vk.ProcCreateRenderPass,
    CreateSampler: vk.ProcCreateSampler,
    CreateSemaphore: vk.ProcCreateSemaphore,
    CreateShaderModule: vk.ProcCreateShaderModule,
    CreateSwapchainKHR: vk.ProcCreateSwapchainKHR,
    DestroyBuffer: vk.ProcDestroyBuffer,
    DestroyCommandPool: vk.ProcDestroyCommandPool,
    DestroyDescriptorPool: vk.ProcDestroyDescriptorPool,
    DestroyDescriptorSetLayout: vk.ProcDestroyDescriptorSetLayout,
    DestroyDevice: vk.ProcDestroyDevice,
    DestroyFence: vk.ProcDestroyFence,
    DestroyFramebuffer: vk.ProcDestroyFramebuffer,
    DestroyImage: vk.ProcDestroyImage,
    DestroyImageView: vk.ProcDestroyImageView,
    DestroyInstance: vk.ProcDestroyInstance,
    DestroyPipeline: vk.ProcDestroyPipeline,
    DestroyPipelineLayout: vk.ProcDestroyPipelineLayout,
    DestroyRenderPass: vk.ProcDestroyRenderPass,
    DestroySampler: vk.ProcDestroySampler,
    DestroySemaphore: vk.ProcDestroySemaphore,
    DestroyShaderModule: vk.ProcDestroyShaderModule,
    DestroySurfaceKHR: vk.ProcDestroySurfaceKHR,
    DestroySwapchainKHR: vk.ProcDestroySwapchainKHR,
    DeviceWaitIdle: vk.ProcDeviceWaitIdle,
    EndCommandBuffer: vk.ProcEndCommandBuffer,
    EnumerateDeviceExtensionProperties: vk.ProcEnumerateDeviceExtensionProperties,
    EnumerateInstanceExtensionProperties: vk.ProcEnumerateInstanceExtensionProperties,
    EnumerateInstanceVersion: vk.ProcEnumerateInstanceVersion,
    EnumeratePhysicalDevices: vk.ProcEnumeratePhysicalDevices,
    FreeMemory: vk.ProcFreeMemory,
    GetBufferMemoryRequirements: vk.ProcGetBufferMemoryRequirements,
    GetDeviceProcAddr: vk.ProcGetDeviceProcAddr,
    GetDeviceQueue: vk.ProcGetDeviceQueue,
    GetFenceStatus: vk.ProcGetFenceStatus,
    GetImageMemoryRequirements: vk.ProcGetImageMemoryRequirements,
    GetInstanceProcAddr: vk.ProcGetInstanceProcAddr,
    GetPhysicalDeviceMemoryProperties: vk.ProcGetPhysicalDeviceMemoryProperties,
    GetPhysicalDeviceProperties: vk.ProcGetPhysicalDeviceProperties,
    GetPhysicalDeviceQueueFamilyProperties: vk.ProcGetPhysicalDeviceQueueFamilyProperties,
    GetPhysicalDeviceSurfaceCapabilitiesKHR: vk.ProcGetPhysicalDeviceSurfaceCapabilitiesKHR,
    GetPhysicalDeviceSurfaceFormatsKHR: vk.ProcGetPhysicalDeviceSurfaceFormatsKHR,
    GetPhysicalDeviceSurfacePresentModesKHR: vk.ProcGetPhysicalDeviceSurfacePresentModesKHR,
    GetPhysicalDeviceSurfaceSupportKHR: vk.ProcGetPhysicalDeviceSurfaceSupportKHR,
    GetSwapchainImagesKHR: vk.ProcGetSwapchainImagesKHR,
    MapMemory: vk.ProcMapMemory,
    QueuePresentKHR: vk.ProcQueuePresentKHR,
    QueueSubmit: vk.ProcQueueSubmit,
    QueueWaitIdle: vk.ProcQueueWaitIdle,
    ResetCommandBuffer: vk.ProcResetCommandBuffer,
    ResetFences: vk.ProcResetFences,
    UnmapMemory: vk.ProcUnmapMemory,
    UpdateDescriptorSets: vk.ProcUpdateDescriptorSets,
    WaitForFences: vk.ProcWaitForFences,
}

// Proc addresses obtained for one VkDevice are not necessarily valid for
// another. Keep dispatch local instead of replacing Odin vendor globals when
// another terminal window creates its own device.
renderer_vulkan_global :: proc(r:^Renderer) {
    r.dispatch.GetInstanceProcAddr=auto_cast glfw.GetInstanceProcAddress(nil,"vkGetInstanceProcAddr")
    r.dispatch.CreateInstance=auto_cast r.dispatch.GetInstanceProcAddr(nil,"vkCreateInstance")
    r.dispatch.EnumerateInstanceExtensionProperties=auto_cast r.dispatch.GetInstanceProcAddr(nil,"vkEnumerateInstanceExtensionProperties")
    r.dispatch.EnumerateInstanceVersion=auto_cast r.dispatch.GetInstanceProcAddr(nil,"vkEnumerateInstanceVersion")
}
renderer_vulkan_instance :: proc(r:^Renderer) {
    r.dispatch.GetDeviceProcAddr=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkGetDeviceProcAddr")
    r.dispatch.CreateDevice=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkCreateDevice")
    r.dispatch.DestroyInstance=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkDestroyInstance")
    r.dispatch.DestroySurfaceKHR=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkDestroySurfaceKHR")
    r.dispatch.EnumerateDeviceExtensionProperties=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkEnumerateDeviceExtensionProperties")
    r.dispatch.EnumeratePhysicalDevices=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkEnumeratePhysicalDevices")
    r.dispatch.GetPhysicalDeviceMemoryProperties=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkGetPhysicalDeviceMemoryProperties")
    r.dispatch.GetPhysicalDeviceProperties=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkGetPhysicalDeviceProperties")
    r.dispatch.GetPhysicalDeviceQueueFamilyProperties=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkGetPhysicalDeviceQueueFamilyProperties")
    r.dispatch.GetPhysicalDeviceSurfaceCapabilitiesKHR=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
    r.dispatch.GetPhysicalDeviceSurfaceFormatsKHR=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkGetPhysicalDeviceSurfaceFormatsKHR")
    r.dispatch.GetPhysicalDeviceSurfacePresentModesKHR=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkGetPhysicalDeviceSurfacePresentModesKHR")
    r.dispatch.GetPhysicalDeviceSurfaceSupportKHR=auto_cast r.dispatch.GetInstanceProcAddr(r.instance,"vkGetPhysicalDeviceSurfaceSupportKHR")
}
renderer_vulkan_device :: proc(r:^Renderer) {
    r.dispatch.AcquireNextImageKHR=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkAcquireNextImageKHR")
    r.dispatch.AllocateCommandBuffers=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkAllocateCommandBuffers")
    r.dispatch.AllocateDescriptorSets=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkAllocateDescriptorSets")
    r.dispatch.AllocateMemory=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkAllocateMemory")
    r.dispatch.BeginCommandBuffer=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkBeginCommandBuffer")
    r.dispatch.BindBufferMemory=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkBindBufferMemory")
    r.dispatch.BindImageMemory=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkBindImageMemory")
    r.dispatch.CmdBeginRenderPass=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdBeginRenderPass")
    r.dispatch.CmdBindDescriptorSets=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdBindDescriptorSets")
    r.dispatch.CmdBindPipeline=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdBindPipeline")
    r.dispatch.CmdBindVertexBuffers=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdBindVertexBuffers")
    r.dispatch.CmdCopyBufferToImage=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdCopyBufferToImage")
    r.dispatch.CmdCopyImageToBuffer=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdCopyImageToBuffer")
    r.dispatch.CmdDraw=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdDraw")
    r.dispatch.CmdEndRenderPass=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdEndRenderPass")
    r.dispatch.CmdPipelineBarrier=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdPipelineBarrier")
    r.dispatch.CmdPushConstants=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdPushConstants")
    r.dispatch.CmdSetScissor=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdSetScissor")
    r.dispatch.CmdSetViewport=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCmdSetViewport")
    r.dispatch.CreateBuffer=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateBuffer")
    r.dispatch.CreateCommandPool=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateCommandPool")
    r.dispatch.CreateDescriptorPool=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateDescriptorPool")
    r.dispatch.CreateDescriptorSetLayout=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateDescriptorSetLayout")
    r.dispatch.CreateFence=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateFence")
    r.dispatch.CreateFramebuffer=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateFramebuffer")
    r.dispatch.CreateGraphicsPipelines=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateGraphicsPipelines")
    r.dispatch.CreateImage=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateImage")
    r.dispatch.CreateImageView=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateImageView")
    r.dispatch.CreatePipelineLayout=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreatePipelineLayout")
    r.dispatch.CreateRenderPass=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateRenderPass")
    r.dispatch.CreateSampler=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateSampler")
    r.dispatch.CreateSemaphore=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateSemaphore")
    r.dispatch.CreateShaderModule=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateShaderModule")
    r.dispatch.CreateSwapchainKHR=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkCreateSwapchainKHR")
    r.dispatch.DestroyBuffer=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyBuffer")
    r.dispatch.DestroyCommandPool=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyCommandPool")
    r.dispatch.DestroyDescriptorPool=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyDescriptorPool")
    r.dispatch.DestroyDescriptorSetLayout=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyDescriptorSetLayout")
    r.dispatch.DestroyDevice=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyDevice")
    r.dispatch.DestroyFence=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyFence")
    r.dispatch.DestroyFramebuffer=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyFramebuffer")
    r.dispatch.DestroyImage=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyImage")
    r.dispatch.DestroyImageView=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyImageView")
    r.dispatch.DestroyPipeline=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyPipeline")
    r.dispatch.DestroyPipelineLayout=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyPipelineLayout")
    r.dispatch.DestroyRenderPass=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyRenderPass")
    r.dispatch.DestroySampler=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroySampler")
    r.dispatch.DestroySemaphore=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroySemaphore")
    r.dispatch.DestroyShaderModule=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroyShaderModule")
    r.dispatch.DestroySwapchainKHR=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDestroySwapchainKHR")
    r.dispatch.DeviceWaitIdle=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkDeviceWaitIdle")
    r.dispatch.EndCommandBuffer=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkEndCommandBuffer")
    r.dispatch.FreeMemory=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkFreeMemory")
    r.dispatch.GetBufferMemoryRequirements=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkGetBufferMemoryRequirements")
    r.dispatch.GetDeviceQueue=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkGetDeviceQueue")
    r.dispatch.GetFenceStatus=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkGetFenceStatus")
    r.dispatch.GetImageMemoryRequirements=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkGetImageMemoryRequirements")
    r.dispatch.GetSwapchainImagesKHR=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkGetSwapchainImagesKHR")
    r.dispatch.MapMemory=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkMapMemory")
    r.dispatch.QueuePresentKHR=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkQueuePresentKHR")
    r.dispatch.QueueSubmit=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkQueueSubmit")
    r.dispatch.QueueWaitIdle=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkQueueWaitIdle")
    r.dispatch.ResetCommandBuffer=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkResetCommandBuffer")
    r.dispatch.ResetFences=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkResetFences")
    r.dispatch.UnmapMemory=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkUnmapMemory")
    r.dispatch.UpdateDescriptorSets=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkUpdateDescriptorSets")
    r.dispatch.WaitForFences=auto_cast r.dispatch.GetDeviceProcAddr(r.device,"vkWaitForFences")
}

renderer_glfw_count:int
renderer_vulkan_shared_instance:vk.Instance
renderer_vulkan_instance_count:int

// NVIDIA's Wayland dispatch has process-wide state tied to VkInstance teardown.
// Keep one instance alive for the whole workspace; devices, surfaces and GPU
// resources remain owned by their individual renderers.
renderer_instance_acquire :: proc(r:^Renderer,info:^vk.InstanceCreateInfo)->bool {
    if renderer_vulkan_shared_instance==nil {
        instance:vk.Instance
        if !renderer_ok(r.dispatch.CreateInstance(info,nil,&instance),"instance") {return false}
        renderer_vulkan_shared_instance=instance
    }
    r.instance=renderer_vulkan_shared_instance
    renderer_vulkan_instance_count+=1
    renderer_vulkan_instance(r)
    return true
}
renderer_instance_release :: proc(r:^Renderer) {
    if r.instance==nil {return}
    renderer_vulkan_instance_count-=1
    if renderer_vulkan_instance_count==0 {
        r.dispatch.DestroyInstance(renderer_vulkan_shared_instance,nil)
        renderer_vulkan_shared_instance=nil
    }
    r.instance=nil
}

renderer_ok :: proc(result: vk.Result, action: string) -> bool {
    if result != .SUCCESS { fmt.eprintf("Vulkan %s: %v\n", action, result); return false }
    return true
}
renderer_memory_type :: proc(r: ^Renderer, bits: u32, flags: vk.MemoryPropertyFlags) -> (u32, bool) {
    props: vk.PhysicalDeviceMemoryProperties
    r.dispatch.GetPhysicalDeviceMemoryProperties(r.physical, &props)
    for i in 0..<props.memoryTypeCount {
        if bits & (1 << i) != 0 && flags <= props.memoryTypes[i].propertyFlags { return i, true }
    }
    return 0, false
}
renderer_buffer :: proc(r: ^Renderer, size: int, usage: vk.BufferUsageFlags, buffer: ^vk.Buffer, memory: ^vk.DeviceMemory) -> bool {
    info := vk.BufferCreateInfo{sType=.BUFFER_CREATE_INFO, size=vk.DeviceSize(size), usage=usage, sharingMode=.EXCLUSIVE}
    if !renderer_ok(r.dispatch.CreateBuffer(r.device,&info,nil,buffer), "create buffer") { return false }
    req: vk.MemoryRequirements
    r.dispatch.GetBufferMemoryRequirements(r.device,buffer^,&req)
    idx, ok := renderer_memory_type(r,req.memoryTypeBits,{.HOST_VISIBLE,.HOST_COHERENT})
    if !ok { return false }
    alloc := vk.MemoryAllocateInfo{sType=.MEMORY_ALLOCATE_INFO,allocationSize=req.size,memoryTypeIndex=idx}
    if !renderer_ok(r.dispatch.AllocateMemory(r.device,&alloc,nil,memory), "buffer memory") { return false }
    return renderer_ok(r.dispatch.BindBufferMemory(r.device,buffer^,memory^,0), "bind buffer")
}
// The caller waits for the previous frame before replacing its vertex storage.
// Allocate for actual geometry, grow geometrically for dense histories, and
// release a large view's spare storage once a smaller view has settled.
renderer_reserve_vertices :: proc(r: ^Renderer, size: int) -> bool {
    capacity := VERTEX_INITIAL_CAPACITY
    if r.vertex_buffer!=0 && size<=r.vertex_capacity {
        if r.vertex_capacity<=VERTEX_INITIAL_CAPACITY || size>r.vertex_capacity/4 {
            r.vertex_small_frames=0
            return true
        }
        r.vertex_small_frames+=1
        if r.vertex_small_frames<120 { return true }
    } else {
        capacity=max(capacity,r.vertex_capacity)
    }
    r.vertex_small_frames=0
    for capacity<size { capacity*=2 }
    shrinking := capacity<r.vertex_capacity
    buffer: vk.Buffer
    memory: vk.DeviceMemory
    mapping: rawptr
    defer {
        if mapping!=nil { r.dispatch.UnmapMemory(r.device,memory) }
        if buffer!=0 { r.dispatch.DestroyBuffer(r.device,buffer,nil) }
        if memory!=0 { r.dispatch.FreeMemory(r.device,memory,nil) }
    }
    // An optional trim must never interrupt rendering if allocation fails.
    if !renderer_buffer(r,capacity,{.VERTEX_BUFFER},&buffer,&memory) { return shrinking }
    if !renderer_ok(r.dispatch.MapMemory(r.device,memory,0,vk.DeviceSize(capacity),{},&mapping), "map vertices") { return shrinking }
    if r.vertex_mapping!=nil { r.dispatch.UnmapMemory(r.device,r.vertex_memory) }
    if r.vertex_buffer!=0 { r.dispatch.DestroyBuffer(r.device,r.vertex_buffer,nil) }
    if r.vertex_memory!=0 { r.dispatch.FreeMemory(r.device,r.vertex_memory,nil) }
    r.vertex_buffer,r.vertex_memory,r.vertex_mapping,r.vertex_capacity=buffer,memory,mapping,capacity
    buffer=0;memory=0;mapping=nil
    return true
}
renderer_image_view :: proc(r: ^Renderer, image: vk.Image, format: vk.Format, view: ^vk.ImageView) -> bool {
    info := vk.ImageViewCreateInfo{sType=.IMAGE_VIEW_CREATE_INFO,image=image,viewType=.D2,format=format,
        subresourceRange={aspectMask={.COLOR},levelCount=1,layerCount=1}}
    return renderer_ok(r.dispatch.CreateImageView(r.device,&info,nil,view), "image view")
}
renderer_shader :: proc(r: ^Renderer, data: string) -> vk.ShaderModule {
    info := vk.ShaderModuleCreateInfo{sType=.SHADER_MODULE_CREATE_INFO,codeSize=len(data),pCode=cast([^]u32)raw_data(data)}
    shader: vk.ShaderModule
    renderer_ok(r.dispatch.CreateShaderModule(r.device,&info,nil,&shader), "shader")
    return shader
}
renderer_font_rasterize :: proc(atlas: ^Font_Atlas) -> bool {
    if FT_Init_FreeType(&atlas.library)!=0 {fmt.eprintln("Cannot initialize FreeType");return false}
    when ODIN_OS==.Linux {atlas.pixels=make([dynamic]u8,ATLAS_SIZE*128)}
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
renderer_font_upload :: proc(r: ^Renderer, atlas: ^Font_Atlas) -> bool {
    pixels := atlas.pixels[:]
    texture_height:=len(pixels)/ATLAS_SIZE
    // New glyphs usually fit the existing atlas. Keep its device allocation,
    // image view and descriptor instead of rebuilding them on every upload.
    reuse_image:=r.font_image!=0&&r.font_texture_height==texture_height
    old_image,old_memory,old_view:=r.font_image,r.font_memory,r.font_view
    if !reuse_image {r.font_image=0;r.font_memory=0;r.font_view=0}
    uploaded:=false
    defer {
        if !reuse_image {
            if uploaded {
                if old_view!=0 {r.dispatch.DestroyImageView(r.device,old_view,nil)}
                if old_image!=0 {r.dispatch.DestroyImage(r.device,old_image,nil)}
                if old_memory!=0 {r.dispatch.FreeMemory(r.device,old_memory,nil)}
            } else {
                if r.font_view!=0 {r.dispatch.DestroyImageView(r.device,r.font_view,nil)}
                if r.font_image!=0 {r.dispatch.DestroyImage(r.device,r.font_image,nil)}
                if r.font_memory!=0 {r.dispatch.FreeMemory(r.device,r.font_memory,nil)}
                r.font_image,r.font_memory,r.font_view=old_image,old_memory,old_view
            }
        }
    }
    r.fonts=atlas.fonts
    r.atlas_height=atlas.height
    if !reuse_image {
        image_info := vk.ImageCreateInfo{sType=.IMAGE_CREATE_INFO,imageType=.D2,format=.R8_UNORM,
            extent={ATLAS_SIZE,u32(texture_height),1},mipLevels=1,arrayLayers=1,samples={._1},tiling=.OPTIMAL,
            usage={.TRANSFER_DST,.SAMPLED},sharingMode=.EXCLUSIVE,initialLayout=.UNDEFINED}
        if !renderer_ok(r.dispatch.CreateImage(r.device,&image_info,nil,&r.font_image), "font image") { return false }
        req: vk.MemoryRequirements
        r.dispatch.GetImageMemoryRequirements(r.device,r.font_image,&req)
        idx, ok := renderer_memory_type(r,req.memoryTypeBits,{.DEVICE_LOCAL})
        if !ok { return false }
        alloc := vk.MemoryAllocateInfo{sType=.MEMORY_ALLOCATE_INFO,allocationSize=req.size,memoryTypeIndex=idx}
        if !renderer_ok(r.dispatch.AllocateMemory(r.device,&alloc,nil,&r.font_memory), "font memory") { return false }
        if !renderer_ok(r.dispatch.BindImageMemory(r.device,r.font_image,r.font_memory,0), "bind font") { return false }
    }
    // Glyph cache misses can upload on consecutive frames. Keep the host-visible
    // staging allocation mapped instead of allocating and mapping it every time.
    // Each upload below completes before this storage can be written again.
    if r.font_staging_capacity<len(pixels) {
        staging:vk.Buffer;memory:vk.DeviceMemory;mapping:rawptr
        defer {
            if mapping!=nil {r.dispatch.UnmapMemory(r.device,memory)}
            if staging!=0 {r.dispatch.DestroyBuffer(r.device,staging,nil)}
            if memory!=0 {r.dispatch.FreeMemory(r.device,memory,nil)}
        }
        if !renderer_buffer(r,len(pixels),{.TRANSFER_SRC},&staging,&memory) {return false}
        if !renderer_ok(r.dispatch.MapMemory(r.device,memory,0,vk.DeviceSize(len(pixels)),{},&mapping),"map font staging") {return false}
        if r.font_staging_mapping!=nil {r.dispatch.UnmapMemory(r.device,r.font_staging_memory)}
        if r.font_staging!=0 {r.dispatch.DestroyBuffer(r.device,r.font_staging,nil)}
        if r.font_staging_memory!=0 {r.dispatch.FreeMemory(r.device,r.font_staging_memory,nil)}
        r.font_staging,r.font_staging_memory,r.font_staging_mapping=staging,memory,mapping
        r.font_staging_capacity=len(pixels)
        staging=0;memory=0;mapping=nil
    }
    mem.copy(r.font_staging_mapping,raw_data(pixels),len(pixels))
    begin := vk.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO,flags={.ONE_TIME_SUBMIT}}
    if !renderer_ok(r.dispatch.BeginCommandBuffer(r.command,&begin),"begin font upload") {return false}
    barrier := vk.ImageMemoryBarrier{sType=.IMAGE_MEMORY_BARRIER,oldLayout=.UNDEFINED,newLayout=.TRANSFER_DST_OPTIMAL,
        srcQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,dstQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,
        image=r.font_image,subresourceRange={aspectMask={.COLOR},levelCount=1,layerCount=1},dstAccessMask={.TRANSFER_WRITE}}
    source_stage:vk.PipelineStageFlags={.TOP_OF_PIPE}
    if reuse_image {
        barrier.oldLayout=.SHADER_READ_ONLY_OPTIMAL
        barrier.srcAccessMask={.SHADER_READ}
        source_stage={.FRAGMENT_SHADER}
    }
    r.dispatch.CmdPipelineBarrier(r.command,source_stage,{.TRANSFER},{},0,nil,0,nil,1,&barrier)
    region := vk.BufferImageCopy{imageSubresource={aspectMask={.COLOR},layerCount=1},imageExtent={ATLAS_SIZE,u32(texture_height),1}}
    r.dispatch.CmdCopyBufferToImage(r.command,r.font_staging,r.font_image,.TRANSFER_DST_OPTIMAL,1,&region)
    barrier.oldLayout=.TRANSFER_DST_OPTIMAL; barrier.newLayout=.SHADER_READ_ONLY_OPTIMAL
    barrier.srcAccessMask={.TRANSFER_WRITE}; barrier.dstAccessMask={.SHADER_READ}
    r.dispatch.CmdPipelineBarrier(r.command,{.TRANSFER},{.FRAGMENT_SHADER},{},0,nil,0,nil,1,&barrier)
    if !renderer_ok(r.dispatch.EndCommandBuffer(r.command),"end font upload") {return false}
    submit := vk.SubmitInfo{sType=.SUBMIT_INFO,commandBufferCount=1,pCommandBuffers=&r.command}
    if !renderer_ok(r.dispatch.QueueSubmit(r.queue,1,&submit,0),"submit font upload") {return false}
    if !renderer_ok(r.dispatch.QueueWaitIdle(r.queue),"wait font upload") {return false}
    if !renderer_ok(r.dispatch.ResetCommandBuffer(r.command,{}),"reset font upload") {return false}
    if !reuse_image&&!renderer_image_view(r,r.font_image,.R8_UNORM,&r.font_view) { return false }
    if r.sampler == 0 {
        // One glyph texel maps to one physical pixel, as in task_master.
        sampler := vk.SamplerCreateInfo{sType=.SAMPLER_CREATE_INFO,magFilter=.NEAREST,minFilter=.NEAREST,
            mipmapMode=.NEAREST,addressModeU=.CLAMP_TO_EDGE,addressModeV=.CLAMP_TO_EDGE,addressModeW=.CLAMP_TO_EDGE,maxLod=0}
        if !renderer_ok(r.dispatch.CreateSampler(r.device,&sampler,nil,&r.sampler), "font sampler") { return false }
        bindings := [2]vk.DescriptorSetLayoutBinding{
            {binding=0,descriptorType=.COMBINED_IMAGE_SAMPLER,descriptorCount=1,stageFlags={.FRAGMENT}},
            {binding=1,descriptorType=.COMBINED_IMAGE_SAMPLER,descriptorCount=1,stageFlags={.FRAGMENT}}}
        layout := vk.DescriptorSetLayoutCreateInfo{sType=.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,bindingCount=2,pBindings=raw_data(bindings[:])}
        if !renderer_ok(r.dispatch.CreateDescriptorSetLayout(r.device,&layout,nil,&r.descriptor_layout), "descriptor layout") { return false }
        pool_size := vk.DescriptorPoolSize{type=.COMBINED_IMAGE_SAMPLER,descriptorCount=2}
        pool := vk.DescriptorPoolCreateInfo{sType=.DESCRIPTOR_POOL_CREATE_INFO,maxSets=1,poolSizeCount=1,pPoolSizes=&pool_size}
        if !renderer_ok(r.dispatch.CreateDescriptorPool(r.device,&pool,nil,&r.descriptor_pool), "descriptor pool") { return false }
        set := vk.DescriptorSetAllocateInfo{sType=.DESCRIPTOR_SET_ALLOCATE_INFO,descriptorPool=r.descriptor_pool,descriptorSetCount=1,pSetLayouts=&r.descriptor_layout}
        if !renderer_ok(r.dispatch.AllocateDescriptorSets(r.device,&set,&r.descriptor), "descriptor set") { return false }
    }
    if !reuse_image {
        image := vk.DescriptorImageInfo{sampler=r.sampler,imageView=r.font_view,imageLayout=.SHADER_READ_ONLY_OPTIMAL}
        write := vk.WriteDescriptorSet{sType=.WRITE_DESCRIPTOR_SET,dstSet=r.descriptor,descriptorCount=1,descriptorType=.COMBINED_IMAGE_SAMPLER,pImageInfo=&image}
        r.dispatch.UpdateDescriptorSets(r.device,1,&write,0,nil)
        if r.page.view==0 {write.dstBinding=1;r.dispatch.UpdateDescriptorSets(r.device,1,&write,0,nil)}
    }
    r.font_scale=atlas.scale
    r.font_texture_height=texture_height
    uploaded=true;atlas.dirty=false
    return true
}
renderer_font :: proc(r: ^Renderer, scale: f32) -> bool {
    atlas:=new(Font_Atlas);atlas.scale=scale
    defer {renderer_font_dispose(atlas);free(atlas)}
    if !renderer_font_rasterize(atlas)||!renderer_font_upload(r,atlas) {return false}
    renderer_font_accept(r,atlas)
    return true
}
renderer_set_scale :: proc(r: ^Renderer, scale: f32) -> bool {
    renderer_font_begin(r)
    target_scale := clamp(scale,0.5,4.0)
    if abs(r.font_scale-target_scale) < 0.001 { return true }
    // This runs only when the monitor DPI changes, before generating vertices.
    if !renderer_ok(r.dispatch.DeviceWaitIdle(r.device),"wait font resize") { return false }
    return renderer_font(r,target_scale)
}
renderer_pipeline :: proc(r: ^Renderer) -> bool {
    attachment := vk.AttachmentDescription{format=r.format,samples={._1},loadOp=.CLEAR,storeOp=.STORE,
        stencilLoadOp=.DONT_CARE,stencilStoreOp=.DONT_CARE,initialLayout=.UNDEFINED,finalLayout=.PRESENT_SRC_KHR}
    reference := vk.AttachmentReference{attachment=0,layout=.COLOR_ATTACHMENT_OPTIMAL}
    subpass := vk.SubpassDescription{pipelineBindPoint=.GRAPHICS,colorAttachmentCount=1,pColorAttachments=&reference}
    dependency := vk.SubpassDependency{srcSubpass=vk.SUBPASS_EXTERNAL,dstSubpass=0,
        srcStageMask={.COLOR_ATTACHMENT_OUTPUT},dstStageMask={.COLOR_ATTACHMENT_OUTPUT},dstAccessMask={.COLOR_ATTACHMENT_WRITE}}
    pass := vk.RenderPassCreateInfo{sType=.RENDER_PASS_CREATE_INFO,attachmentCount=1,pAttachments=&attachment,subpassCount=1,pSubpasses=&subpass,dependencyCount=1,pDependencies=&dependency}
    if !renderer_ok(r.dispatch.CreateRenderPass(r.device,&pass,nil,&r.render_pass), "render pass") { return false }
    push := vk.PushConstantRange{stageFlags={.VERTEX},size=8}
    layout := vk.PipelineLayoutCreateInfo{sType=.PIPELINE_LAYOUT_CREATE_INFO,setLayoutCount=1,pSetLayouts=&r.descriptor_layout,pushConstantRangeCount=1,pPushConstantRanges=&push}
    if !renderer_ok(r.dispatch.CreatePipelineLayout(r.device,&layout,nil,&r.layout), "pipeline layout") { return false }
    stages := [2]vk.PipelineShaderStageCreateInfo{
        {sType=.PIPELINE_SHADER_STAGE_CREATE_INFO,stage={.VERTEX},pName="main"},
        {sType=.PIPELINE_SHADER_STAGE_CREATE_INFO,stage={.FRAGMENT},pName="main"}}
    binding := vk.VertexInputBindingDescription{binding=0,stride=size_of(Vertex),inputRate=.VERTEX}
    attributes := [5]vk.VertexInputAttributeDescription{
        {location=0,binding=0,format=.R32G32_SFLOAT,offset=u32(offset_of(Vertex,pos))},
        {location=1,binding=0,format=.R32G32_SFLOAT,offset=u32(offset_of(Vertex,uv))},
        {location=2,binding=0,format=.R32G32B32A32_SFLOAT,offset=u32(offset_of(Vertex,color))},
        {location=3,binding=0,format=.R32_SFLOAT,offset=u32(offset_of(Vertex,texture))},
        {location=4,binding=0,format=.R32G32B32A32_SFLOAT,offset=u32(offset_of(Vertex,shape))}}
    vertex := vk.PipelineVertexInputStateCreateInfo{sType=.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,vertexBindingDescriptionCount=1,pVertexBindingDescriptions=&binding,vertexAttributeDescriptionCount=len(attributes),pVertexAttributeDescriptions=raw_data(attributes[:])}
    assembly := vk.PipelineInputAssemblyStateCreateInfo{sType=.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,topology=.TRIANGLE_LIST}
    viewport := vk.PipelineViewportStateCreateInfo{sType=.PIPELINE_VIEWPORT_STATE_CREATE_INFO,viewportCount=1,scissorCount=1}
    raster := vk.PipelineRasterizationStateCreateInfo{sType=.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,polygonMode=.FILL,cullMode={},frontFace=.COUNTER_CLOCKWISE,lineWidth=1}
    multisample := vk.PipelineMultisampleStateCreateInfo{sType=.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,rasterizationSamples={._1}}
    blend_attachment := vk.PipelineColorBlendAttachmentState{blendEnable=true,srcColorBlendFactor=.SRC_ALPHA,dstColorBlendFactor=.ONE_MINUS_SRC_ALPHA,colorBlendOp=.ADD,srcAlphaBlendFactor=.ONE,dstAlphaBlendFactor=.ONE_MINUS_SRC_ALPHA,alphaBlendOp=.ADD,colorWriteMask={.R,.G,.B,.A}}
    blend := vk.PipelineColorBlendStateCreateInfo{sType=.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,attachmentCount=1,pAttachments=&blend_attachment}
    dynamics := [2]vk.DynamicState{.VIEWPORT,.SCISSOR}
    dynamic_state := vk.PipelineDynamicStateCreateInfo{sType=.PIPELINE_DYNAMIC_STATE_CREATE_INFO,dynamicStateCount=2,pDynamicStates=raw_data(dynamics[:])}
    info := vk.GraphicsPipelineCreateInfo{sType=.GRAPHICS_PIPELINE_CREATE_INFO,stageCount=2,pStages=raw_data(stages[:]),pVertexInputState=&vertex,pInputAssemblyState=&assembly,pViewportState=&viewport,pRasterizationState=&raster,pMultisampleState=&multisample,pColorBlendState=&blend,pDynamicState=&dynamic_state,layout=r.layout,renderPass=r.render_pass}
    vert:=renderer_shader(r,#load("shaders/ui.vert.spv"));frag:=renderer_shader(r,#load("shaders/ui.frag.spv"))
    defer if vert!=0 {r.dispatch.DestroyShaderModule(r.device,vert,nil)}
    defer if frag!=0 {r.dispatch.DestroyShaderModule(r.device,frag,nil)}
    if vert==0||frag==0 {return false}
    stages[0].module=vert;stages[1].module=frag
    if !renderer_ok(r.dispatch.CreateGraphicsPipelines(r.device,0,1,&info,nil,&r.pipeline),"graphics pipeline") {return false}
    return true
}
renderer_swapchain_destroy :: proc(r: ^Renderer) {
    for framebuffer in r.framebuffers { r.dispatch.DestroyFramebuffer(r.device,framebuffer,nil) }
    for view in r.views { r.dispatch.DestroyImageView(r.device,view,nil) }
    for sem in r.present_semaphores { r.dispatch.DestroySemaphore(r.device,sem,nil) }
    delete(r.framebuffers); delete(r.views); delete(r.images); delete(r.present_semaphores)
    r.framebuffers=nil; r.views=nil; r.images=nil; r.present_semaphores=nil
    if r.swapchain != 0 { r.dispatch.DestroySwapchainKHR(r.device,r.swapchain,nil); r.swapchain=0 }
}
renderer_swapchain :: proc(r: ^Renderer) -> bool {
    if !renderer_ok(r.dispatch.DeviceWaitIdle(r.device),"wait swapchain") {return false}
    renderer_swapchain_destroy(r)
    w,h := glfw.GetFramebufferSize(r.window)
    if w <= 0 || h <= 0 { r.width=0; r.height=0; return true }
    caps: vk.SurfaceCapabilitiesKHR
    if !renderer_ok(r.dispatch.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.physical,r.surface,&caps), "surface capabilities") { return false }
    count: u32
    if !renderer_ok(r.dispatch.GetPhysicalDeviceSurfaceFormatsKHR(r.physical,r.surface,&count,nil),"surface format count") {return false}
    if count == 0 { fmt.eprintln("Vulkan device has no supported window surface format"); return false }
    formats := make([]vk.SurfaceFormatKHR,int(count)); defer delete(formats)
    if !renderer_ok(r.dispatch.GetPhysicalDeviceSurfaceFormatsKHR(r.physical,r.surface,&count,raw_data(formats)),"surface formats") {return false}
    selected := formats[0]
    // UNORM keeps the deliberate UI palette identical to its authored RGB colors.
    for format in formats { if format.format == .B8G8R8A8_UNORM || format.format == .R8G8B8A8_UNORM { selected=format; break } }
    // A single UNDEFINED format means the surface allows the application to
    // choose its format; UNDEFINED itself cannot back swapchain images.
    if selected.format==.UNDEFINED {selected.format=.B8G8R8A8_UNORM}
    // Moving between displays can change the supported formats. Framebuffers
    // must use a render pass and pipeline built for the new attachment format.
    if r.render_pass!=0&&r.format!=selected.format {
        if r.pipeline!=0 {r.dispatch.DestroyPipeline(r.device,r.pipeline,nil);r.pipeline=0}
        if r.layout!=0 {r.dispatch.DestroyPipelineLayout(r.device,r.layout,nil);r.layout=0}
        r.dispatch.DestroyRenderPass(r.device,r.render_pass,nil);r.render_pass=0
    }
    if r.render_pass == 0 { r.format=selected.format; if !renderer_pipeline(r) { return false } }
    extent := caps.currentExtent
    if extent.width == ~u32(0) { extent={clamp(u32(w),caps.minImageExtent.width,caps.maxImageExtent.width),clamp(u32(h),caps.minImageExtent.height,caps.maxImageExtent.height)} }
    r.width=int(extent.width); r.height=int(extent.height)
    if r.width<=0||r.height<=0 {return true}
    image_count := caps.minImageCount+1
    if caps.maxImageCount > 0 { image_count=min(image_count,caps.maxImageCount) }
    alpha: vk.CompositeAlphaFlagKHR = .OPAQUE
    if !(.OPAQUE in caps.supportedCompositeAlpha) {
        for candidate in vk.CompositeAlphaFlagKHR { if candidate in caps.supportedCompositeAlpha { alpha=candidate; break } }
    }
    // PNG readback below decodes exactly four 8-bit RGBA/BGRA components.
    // Other surface formats can require more storage or different unpacking.
    r.capture_supported=.TRANSFER_SRC in caps.supportedUsageFlags&&
        (r.format==.B8G8R8A8_UNORM||r.format==.B8G8R8A8_SRGB||r.format==.R8G8B8A8_UNORM||r.format==.R8G8B8A8_SRGB)
    usage: vk.ImageUsageFlags={.COLOR_ATTACHMENT}
    if r.capture_supported { usage += {.TRANSFER_SRC} }
    // Mailbox presents the newest hover frame instead of queuing old positions.
    // FIFO remains the supported fallback on surfaces without mailbox mode.
    present_mode:=vk.PresentModeKHR.FIFO
    if !renderer_ok(r.dispatch.GetPhysicalDeviceSurfacePresentModesKHR(r.physical,r.surface,&count,nil),"present mode count") {return false}
    modes:=make([]vk.PresentModeKHR,int(count),context.temp_allocator)
    if !renderer_ok(r.dispatch.GetPhysicalDeviceSurfacePresentModesKHR(r.physical,r.surface,&count,raw_data(modes)),"present modes") {return false}
    for mode in modes {if mode==.MAILBOX {present_mode=.MAILBOX;break}}
    info := vk.SwapchainCreateInfoKHR{sType=.SWAPCHAIN_CREATE_INFO_KHR,surface=r.surface,minImageCount=image_count,
        imageFormat=r.format,imageColorSpace=selected.colorSpace,imageExtent=extent,imageArrayLayers=1,imageUsage=usage,
        imageSharingMode=.EXCLUSIVE,preTransform=caps.currentTransform,compositeAlpha={alpha},presentMode=present_mode,clipped=true}
    if !renderer_ok(r.dispatch.CreateSwapchainKHR(r.device,&info,nil,&r.swapchain), "swapchain") { return false }
    if !renderer_ok(r.dispatch.GetSwapchainImagesKHR(r.device,r.swapchain,&count,nil),"swapchain image count") {return false}
    r.images=make([]vk.Image,int(count)); r.views=make([]vk.ImageView,int(count)); r.framebuffers=make([]vk.Framebuffer,int(count)); r.present_semaphores=make([]vk.Semaphore,int(count))
    if !renderer_ok(r.dispatch.GetSwapchainImagesKHR(r.device,r.swapchain,&count,raw_data(r.images)),"swapchain images") {return false}
    sem_info := vk.SemaphoreCreateInfo{sType=.SEMAPHORE_CREATE_INFO}
    for image,i in r.images {
        if !renderer_image_view(r,image,r.format,&r.views[i]) { return false }
        framebuffer := vk.FramebufferCreateInfo{sType=.FRAMEBUFFER_CREATE_INFO,renderPass=r.render_pass,attachmentCount=1,pAttachments=&r.views[i],width=extent.width,height=extent.height,layers=1}
        if !renderer_ok(r.dispatch.CreateFramebuffer(r.device,&framebuffer,nil,&r.framebuffers[i]), "framebuffer") { return false }
        if !renderer_ok(r.dispatch.CreateSemaphore(r.device,&sem_info,nil,&r.present_semaphores[i]), "presentation semaphore") { return false }
    }
    return true
}
renderer_init :: proc(r: ^Renderer, width,height: int, title: cstring) -> bool {
    stage:=time.tick_now()
    if renderer_glfw_count==0 {
        glfw.InitHint(glfw.PLATFORM,glfw.PLATFORM_WAYLAND)
        if !glfw.Init() {fmt.eprintln("Cannot initialize native Wayland. Terminal+ requires a Wayland compositor.");return false}
    }
    renderer_glfw_count+=1;r.lifecycle_counted=true
    stage=startup_stage(stage,"GLFW initialization")
    if !glfw.VulkanSupported() { fmt.eprintln("Vulkan loader or graphics driver unavailable"); renderer_destroy(r); return false }
    stage=startup_stage(stage,"Vulkan loader")
    glfw.WindowHint(glfw.CLIENT_API,glfw.NO_API)
    glfw.WindowHintString(glfw.WAYLAND_APP_ID,"terminal-plus")
    // Wayland needs an XDG role and its first configure before Vulkan attaches
    // a buffer. A visible Wayland window still maps only at the first present.
    glfw.WindowHint(glfw.VISIBLE,true)
    r.window=glfw.CreateWindow(i32(width),i32(height),title,nil,nil)
    if r.window == nil { renderer_destroy(r); return false }
    r.width=width; r.height=height
    scale_x,scale_y := glfw.GetWindowContentScale(r.window)
    atlas:=new(Font_Atlas);atlas.scale=clamp(max(scale_x,scale_y),0.5,4.0)
    font_worker:=thread.create(startup_font_worker)
    if font_worker!=nil {font_worker.data=atlas;thread.start(font_worker)}
    else {atlas.ready=renderer_font_rasterize(atlas)}
    defer {
        // Also wait on early Vulkan failures before releasing worker-owned data.
        if font_worker!=nil {thread.destroy(font_worker)}
        renderer_font_dispose(atlas);free(atlas)
    }
    stage=startup_stage(stage,"GLFW / window")
    renderer_vulkan_global(r)
    required_extensions := glfw.GetRequiredInstanceExtensions()
    extensions:=make([dynamic]cstring,0,len(required_extensions)+2,context.temp_allocator)
    append(&extensions,..required_extensions)
    if len(extensions) == 0 { fmt.eprintln("GLFW cannot create Vulkan surfaces on this display"); renderer_destroy(r); return false }
    api_version:u32=vk.API_VERSION_1_0
    loader_version:u32
    if r.dispatch.EnumerateInstanceVersion!=nil&&r.dispatch.EnumerateInstanceVersion(&loader_version)==.SUCCESS {
        api_version=min(loader_version,vk.API_VERSION_1_3)
    }
    portability:=false
    available_count:u32
    r.dispatch.EnumerateInstanceExtensionProperties(nil,&available_count,nil)
    available:=make([]vk.ExtensionProperties,int(available_count),context.temp_allocator)
    r.dispatch.EnumerateInstanceExtensionProperties(nil,&available_count,raw_data(available))
    for &extension in available {
        name:=string(cast(cstring)&extension.extensionName[0])
        if name=="VK_KHR_portability_enumeration" {append(&extensions,"VK_KHR_portability_enumeration");portability=true}
        if api_version<vk.API_VERSION_1_1&&name=="VK_KHR_get_physical_device_properties2" {append(&extensions,"VK_KHR_get_physical_device_properties2")}
    }
    app := vk.ApplicationInfo{sType=.APPLICATION_INFO,pApplicationName="terminal-plus",apiVersion=api_version}
    instance := vk.InstanceCreateInfo{sType=.INSTANCE_CREATE_INFO,pApplicationInfo=&app,enabledExtensionCount=u32(len(extensions)),ppEnabledExtensionNames=raw_data(extensions)}
    if portability {instance.flags={.ENUMERATE_PORTABILITY_KHR}}
    if !renderer_instance_acquire(r,&instance) { renderer_destroy(r); return false }
    if !renderer_ok(glfw.CreateWindowSurface(r.instance,r.window,nil,&r.surface), "window surface") { renderer_destroy(r); return false }
    stage=startup_stage(stage,"Vulkan instance / surface")
    count: u32
    r.dispatch.EnumeratePhysicalDevices(r.instance,&count,nil)
    devices := make([]vk.PhysicalDevice,int(count)); defer delete(devices)
    r.dispatch.EnumeratePhysicalDevices(r.instance,&count,raw_data(devices))
    best_score := -1
    for device in devices {
        props: vk.PhysicalDeviceProperties; r.dispatch.GetPhysicalDeviceProperties(device,&props)
        score := 1
        if props.deviceType == .INTEGRATED_GPU { score=2 }
        if props.deviceType == .DISCRETE_GPU { score=3 }
        family_count: u32
        r.dispatch.GetPhysicalDeviceQueueFamilyProperties(device,&family_count,nil)
        families := make([]vk.QueueFamilyProperties,int(family_count))
        r.dispatch.GetPhysicalDeviceQueueFamilyProperties(device,&family_count,raw_data(families))
        for family,i in families {
            supported: b32
            r.dispatch.GetPhysicalDeviceSurfaceSupportKHR(device,u32(i),r.surface,&supported)
            if .GRAPHICS in family.queueFlags && supported && score > best_score {
                r.physical=device; r.family=u32(i); best_score=score
                if r.device_name != "" { delete(r.device_name) }
                r.device_name=strings.clone(string(cast(cstring)&props.deviceName[0]))
            }
        }
        delete(families)
    }
    if best_score < 0 { fmt.eprintln("No graphics device with presentation support"); renderer_destroy(r); return false }
    stage=startup_stage(stage,"GPU discovery")
    priority: f32=1
    queue := vk.DeviceQueueCreateInfo{sType=.DEVICE_QUEUE_CREATE_INFO,queueFamilyIndex=r.family,queueCount=1,pQueuePriorities=&priority}
    device_extensions := [2]cstring{"VK_KHR_swapchain",nil}
    extension_count:u32=1
    device := vk.DeviceCreateInfo{sType=.DEVICE_CREATE_INFO,queueCreateInfoCount=1,pQueueCreateInfos=&queue,enabledExtensionCount=extension_count,ppEnabledExtensionNames=raw_data(device_extensions[:])}
    r.dispatch.EnumerateDeviceExtensionProperties(r.physical,nil,&available_count,nil)
    device_available:=make([]vk.ExtensionProperties,int(available_count),context.temp_allocator)
    r.dispatch.EnumerateDeviceExtensionProperties(r.physical,nil,&available_count,raw_data(device_available))
    for &extension in device_available {
        if string(cast(cstring)&extension.extensionName[0])=="VK_KHR_portability_subset" {
            device_extensions[extension_count]="VK_KHR_portability_subset"
            device.enabledExtensionCount=extension_count+1
            break
        }
    }
    if !renderer_ok(r.dispatch.CreateDevice(r.physical,&device,nil,&r.device), "device") { renderer_destroy(r); return false }
    renderer_vulkan_device(r)
    stage=startup_stage(stage,"Vulkan device")
    r.dispatch.GetDeviceQueue(r.device,r.family,0,&r.queue)
    pool := vk.CommandPoolCreateInfo{sType=.COMMAND_POOL_CREATE_INFO,flags={.RESET_COMMAND_BUFFER},queueFamilyIndex=r.family}
    if !renderer_ok(r.dispatch.CreateCommandPool(r.device,&pool,nil,&r.pool), "command pool") { renderer_destroy(r); return false }
    command := vk.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=r.pool,level=.PRIMARY,commandBufferCount=1}
    if !renderer_ok(r.dispatch.AllocateCommandBuffers(r.device,&command,&r.command), "command buffer") { renderer_destroy(r); return false }
    fence := vk.FenceCreateInfo{sType=.FENCE_CREATE_INFO,flags={.SIGNALED}}
    sem := vk.SemaphoreCreateInfo{sType=.SEMAPHORE_CREATE_INFO}
    if !renderer_ok(r.dispatch.CreateFence(r.device,&fence,nil,&r.fence), "fence") || !renderer_ok(r.dispatch.CreateSemaphore(r.device,&sem,nil,&r.acquired), "acquire semaphore") { renderer_destroy(r); return false }
    stage=startup_stage(stage,"buffers / commands")
    if font_worker!=nil {thread.join(font_worker)}
    if !atlas.ready || !renderer_font_upload(r,atlas) { renderer_destroy(r); return false }
    renderer_font_accept(r,atlas)
    stage=startup_stage(stage,"font join / upload")
    if !renderer_swapchain(r) { renderer_destroy(r); return false }
    stage=startup_stage(stage,"pipeline / swapchain")
    return true
}
renderer_prepare_frame :: proc(r: ^Renderer) -> bool {
    w,h := glfw.GetFramebufferSize(r.window)
    if int(w) != r.width || int(h) != r.height { if !renderer_swapchain(r) { return false } }
    return true
}
renderer_acquire_frame :: proc(r:^Renderer)->(index:u32,ready,ok:bool) {
    r.frame_pending=false
    if r.width<=0||r.height<=0||glfw.GetWindowAttrib(r.window,glfw.ICONIFIED)!=0||glfw.GetWindowAttrib(r.window,glfw.VISIBLE)==0 {return 0,false,true}
    // A minimized/occluded window must not hold up its siblings. Pending GPU
    // work retries from the shared event loop without waiting on this surface.
    fence:=r.dispatch.GetFenceStatus(r.device,r.fence)
    if fence==.NOT_READY {r.frame_pending=true;return 0,false,true}
    if !renderer_ok(fence,"frame fence") {return 0,false,false}
    acquired := r.dispatch.AcquireNextImageKHR(r.device,r.swapchain,0,r.acquired,0,&index)
    if acquired==.NOT_READY||acquired==.TIMEOUT {r.frame_pending=true;return 0,false,true}
    if acquired==.ERROR_OUT_OF_DATE_KHR {
        okay:=renderer_swapchain(r);r.frame_pending=okay&&r.width>0&&r.height>0
        return 0,false,okay
    }
    if acquired != .SUCCESS && acquired != .SUBOPTIMAL_KHR {renderer_ok(acquired,"acquire image");return 0,false,false}
    return index,true,true
}
renderer_frame_wait_delay :: proc(r:^Renderer,precise:bool=false)->f64 {if r.frame_pending {return (0.001 if precise else 0.008)};return 60}
renderer_draw :: proc(r: ^Renderer, vertices: []Vertex,image_index:u32) -> bool {
    index:=image_index
    if r.atlas.dirty {
        if !renderer_ok(r.dispatch.DeviceWaitIdle(r.device),"wait Unicode atlas")||!renderer_font_upload(r,&r.atlas) {return false}
    }
    if !renderer_reserve_vertices(r,len(vertices)*size_of(Vertex)) { return false }
    if r.page_source==nil {renderer_page_release(r)}
    capture_buffer: vk.Buffer
    capture_memory: vk.DeviceMemory
    capture_bytes := r.width*r.height*4
    capturing := r.capture_path != "" && r.capture_supported
    if r.capture_path != "" && !r.capture_supported {
        fmt.eprintln("Surface does not support Vulkan screenshot transfer")
        r.capture_path=""; r.capture_success=false
    }
    defer {
        if capture_buffer != 0 { r.dispatch.DestroyBuffer(r.device,capture_buffer,nil) }
        if capture_memory != 0 { r.dispatch.FreeMemory(r.device,capture_memory,nil) }
    }
    if capturing {
        r.capture_success=false
        if !renderer_buffer(r,capture_bytes,{.TRANSFER_DST},&capture_buffer,&capture_memory) { return false }
    }
    mem.copy(r.vertex_mapping,raw_data(vertices),len(vertices)*size_of(Vertex))
    if !renderer_ok(r.dispatch.ResetCommandBuffer(r.command,{}),"reset frame") {return false}
    begin := vk.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO,flags={.ONE_TIME_SUBMIT}}
    if !renderer_ok(r.dispatch.BeginCommandBuffer(r.command,&begin),"begin frame") {return false}
    renderer_page_copy(r)
    clear := vk.ClearValue{color={float32=BG}}
    pass := vk.RenderPassBeginInfo{sType=.RENDER_PASS_BEGIN_INFO,renderPass=r.render_pass,framebuffer=r.framebuffers[index],renderArea={extent={u32(r.width),u32(r.height)}},clearValueCount=1,pClearValues=&clear}
    r.dispatch.CmdBeginRenderPass(r.command,&pass,.INLINE)
    r.dispatch.CmdBindPipeline(r.command,.GRAPHICS,r.pipeline)
    viewport := vk.Viewport{width=f32(r.width),height=f32(r.height),maxDepth=1}
    scissor := vk.Rect2D{extent={u32(r.width),u32(r.height)}}
    r.dispatch.CmdSetViewport(r.command,0,1,&viewport); r.dispatch.CmdSetScissor(r.command,0,1,&scissor)
    offset: vk.DeviceSize=0
    r.dispatch.CmdBindVertexBuffers(r.command,0,1,&r.vertex_buffer,&offset)
    r.dispatch.CmdBindDescriptorSets(r.command,.GRAPHICS,r.layout,0,1,&r.descriptor,0,nil)
    extent := [2]f32{f32(r.width),f32(r.height)}
    r.dispatch.CmdPushConstants(r.command,r.layout,{.VERTEX},0,8,&extent)
    r.dispatch.CmdDraw(r.command,u32(len(vertices)),1,0,0)
    r.dispatch.CmdEndRenderPass(r.command)
    if capturing {
        barrier := vk.ImageMemoryBarrier{sType=.IMAGE_MEMORY_BARRIER,oldLayout=.PRESENT_SRC_KHR,newLayout=.TRANSFER_SRC_OPTIMAL,
            srcQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,dstQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,image=r.images[index],
            subresourceRange={aspectMask={.COLOR},levelCount=1,layerCount=1},srcAccessMask={.COLOR_ATTACHMENT_WRITE},dstAccessMask={.TRANSFER_READ}}
        r.dispatch.CmdPipelineBarrier(r.command,{.COLOR_ATTACHMENT_OUTPUT},{.TRANSFER},{},0,nil,0,nil,1,&barrier)
        region := vk.BufferImageCopy{imageSubresource={aspectMask={.COLOR},layerCount=1},imageExtent={u32(r.width),u32(r.height),1}}
        r.dispatch.CmdCopyImageToBuffer(r.command,r.images[index],.TRANSFER_SRC_OPTIMAL,capture_buffer,1,&region)
        barrier.oldLayout=.TRANSFER_SRC_OPTIMAL; barrier.newLayout=.PRESENT_SRC_KHR
        barrier.srcAccessMask={.TRANSFER_READ}; barrier.dstAccessMask={}
        r.dispatch.CmdPipelineBarrier(r.command,{.TRANSFER},{.BOTTOM_OF_PIPE},{},0,nil,0,nil,1,&barrier)
    }
    if !renderer_ok(r.dispatch.EndCommandBuffer(r.command),"end frame") {return false}
    wait_stage: vk.PipelineStageFlags={.COLOR_ATTACHMENT_OUTPUT}
    submit := vk.SubmitInfo{sType=.SUBMIT_INFO,waitSemaphoreCount=1,pWaitSemaphores=&r.acquired,pWaitDstStageMask=&wait_stage,commandBufferCount=1,pCommandBuffers=&r.command,signalSemaphoreCount=1,pSignalSemaphores=&r.present_semaphores[index]}
    if !renderer_ok(r.dispatch.ResetFences(r.device,1,&r.fence),"reset frame fence") {return false}
    if !renderer_ok(r.dispatch.QueueSubmit(r.queue,1,&submit,r.fence), "draw submit") { return false }
    if capturing {
        if !renderer_ok(r.dispatch.WaitForFences(r.device,1,&r.fence,true,~u64(0)),"wait screenshot") {return false}
        pixels: rawptr
        if renderer_ok(r.dispatch.MapMemory(r.device,capture_memory,0,vk.DeviceSize(capture_bytes),{},&pixels),"map screenshot") {
            // Encoding repeatedly reads neighbouring pixels. Keep that work
            // in ordinary RAM instead of making byte-sized reads over the GPU
            // mapping for every PNG filter candidate.
            bytes := make([]u8,capture_bytes)
            defer delete(bytes)
            copy(bytes,(cast([^]u8)pixels)[:capture_bytes])
            if r.format == .B8G8R8A8_UNORM || r.format == .B8G8R8A8_SRGB {
                for i := 0; i < capture_bytes; i += 4 { bytes[i],bytes[i+2]=bytes[i+2],bytes[i] }
            }
            path := strings.clone_to_cstring(r.capture_path)
            r.capture_success=stbi.write_png(path,i32(r.width),i32(r.height),4,raw_data(bytes),i32(r.width*4)) != 0
            delete(path)
            r.dispatch.UnmapMemory(r.device,capture_memory)
        }
        r.capture_path=""
    }
    present := vk.PresentInfoKHR{sType=.PRESENT_INFO_KHR,waitSemaphoreCount=1,pWaitSemaphores=&r.present_semaphores[index],swapchainCount=1,pSwapchains=&r.swapchain,pImageIndices=&index}
    result := r.dispatch.QueuePresentKHR(r.queue,&present)
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR { return renderer_swapchain(r) }
    return renderer_ok(result,"present")
}
renderer_destroy :: proc(r: ^Renderer) {
    renderer_font_dispose(&r.atlas)
    if r.device != nil {
        r.dispatch.DeviceWaitIdle(r.device)
        renderer_page_destroy(r)
        renderer_swapchain_destroy(r)
        if r.pipeline != 0 { r.dispatch.DestroyPipeline(r.device,r.pipeline,nil) }
        if r.layout != 0 { r.dispatch.DestroyPipelineLayout(r.device,r.layout,nil) }
        if r.render_pass != 0 { r.dispatch.DestroyRenderPass(r.device,r.render_pass,nil) }
        if r.descriptor_pool != 0 { r.dispatch.DestroyDescriptorPool(r.device,r.descriptor_pool,nil) }
        if r.descriptor_layout != 0 { r.dispatch.DestroyDescriptorSetLayout(r.device,r.descriptor_layout,nil) }
        if r.sampler != 0 { r.dispatch.DestroySampler(r.device,r.sampler,nil) }
        if r.font_view != 0 { r.dispatch.DestroyImageView(r.device,r.font_view,nil) }
        if r.font_image != 0 { r.dispatch.DestroyImage(r.device,r.font_image,nil) }
        if r.font_memory != 0 { r.dispatch.FreeMemory(r.device,r.font_memory,nil) }
        if r.font_staging_mapping != nil { r.dispatch.UnmapMemory(r.device,r.font_staging_memory) }
        if r.font_staging != 0 { r.dispatch.DestroyBuffer(r.device,r.font_staging,nil) }
        if r.font_staging_memory != 0 { r.dispatch.FreeMemory(r.device,r.font_staging_memory,nil) }
        if r.vertex_mapping != nil { r.dispatch.UnmapMemory(r.device,r.vertex_memory) }
        if r.vertex_buffer != 0 { r.dispatch.DestroyBuffer(r.device,r.vertex_buffer,nil) }
        if r.vertex_memory != 0 { r.dispatch.FreeMemory(r.device,r.vertex_memory,nil) }
        if r.fence != 0 { r.dispatch.DestroyFence(r.device,r.fence,nil) }
        if r.acquired != 0 { r.dispatch.DestroySemaphore(r.device,r.acquired,nil) }
        if r.pool != 0 { r.dispatch.DestroyCommandPool(r.device,r.pool,nil) }
        r.dispatch.DestroyDevice(r.device,nil)
    }
    if r.surface != 0 { r.dispatch.DestroySurfaceKHR(r.instance,r.surface,nil) }
    renderer_instance_release(r)
    if r.window != nil { glfw.DestroyWindow(r.window) }
    if r.device_name != "" { delete(r.device_name) }
    if r.lifecycle_counted {
        renderer_glfw_count-=1
        if renderer_glfw_count==0 {tab_drag_wayland_destroy();glfw.Terminate()}
    }
    r^={}
}

renderer_backend_name :: proc()->string {return "Vulkan"}

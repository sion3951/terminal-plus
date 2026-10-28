package main

import "core:mem"
import "core:sync"
import vk "vendor:vulkan"

Renderer_Page :: struct {
    image:vk.Image,
    memory:vk.DeviceMemory,
    view:vk.ImageView,
    staging:vk.Buffer,
    staging_memory:vk.DeviceMemory,
    mapped:rawptr,
    width,height:int,
    identity,generation:u64,
    copying,initial:bool,
}
renderer_page_destroy :: proc(r:^Renderer) {
    p:=&r.page
    if p.view!=0 {r.dispatch.DestroyImageView(r.device,p.view,nil)}
    if p.image!=0 {r.dispatch.DestroyImage(r.device,p.image,nil)}
    if p.memory!=0 {r.dispatch.FreeMemory(r.device,p.memory,nil)}
    if p.mapped!=nil {r.dispatch.UnmapMemory(r.device,p.staging_memory)}
    if p.staging!=0 {r.dispatch.DestroyBuffer(r.device,p.staging,nil)}
    if p.staging_memory!=0 {r.dispatch.FreeMemory(r.device,p.staging_memory,nil)}
    p^={}
}
// Called only after the previous frame's fence signalled. Reuse device-local
// texture and mapped staging storage; upload once in the next Vulkan command.
renderer_page_prepare :: proc(r:^Renderer)->bool {
    control:=r.page_source;p:=&r.page;p.copying=false
    if control==nil {return true}
    sync.mutex_lock(&control.mutex);defer sync.mutex_unlock(&control.mutex)
    if control.pixels==nil {return true}
    if p.identity==control.identity&&p.generation==control.generation {return true}
    width,height:=control.pixel_width,control.pixel_height
    if p.width!=width||p.height!=height {
        renderer_page_destroy(r)
        p.width=width;p.height=height;p.initial=true
        info:=vk.ImageCreateInfo{sType=.IMAGE_CREATE_INFO,imageType=.D2,format=.R8G8B8A8_UNORM,
            extent={u32(width),u32(height),1},mipLevels=1,arrayLayers=1,samples={._1},tiling=.OPTIMAL,
            usage={.TRANSFER_DST,.SAMPLED},sharingMode=.EXCLUSIVE,initialLayout=.UNDEFINED}
        if !renderer_ok(r.dispatch.CreateImage(r.device,&info,nil,&p.image),"document image") {return false}
        requirements:vk.MemoryRequirements;r.dispatch.GetImageMemoryRequirements(r.device,p.image,&requirements)
        kind,okay:=renderer_memory_type(r,requirements.memoryTypeBits,{.DEVICE_LOCAL});if !okay {return false}
        allocation:=vk.MemoryAllocateInfo{sType=.MEMORY_ALLOCATE_INFO,allocationSize=requirements.size,memoryTypeIndex=kind}
        if !renderer_ok(r.dispatch.AllocateMemory(r.device,&allocation,nil,&p.memory),"document memory") {return false}
        if !renderer_ok(r.dispatch.BindImageMemory(r.device,p.image,p.memory,0),"bind document image") {return false}
        if !renderer_image_view(r,p.image,.R8G8B8A8_UNORM,&p.view) {return false}
        if !renderer_buffer(r,width*height*4,{.TRANSFER_SRC},&p.staging,&p.staging_memory) {return false}
        if !renderer_ok(r.dispatch.MapMemory(r.device,p.staging_memory,0,vk.DeviceSize(width*height*4),{},&p.mapped),"map document upload") {return false}
        image:=vk.DescriptorImageInfo{sampler=r.sampler,imageView=p.view,imageLayout=.SHADER_READ_ONLY_OPTIMAL}
        write:=vk.WriteDescriptorSet{sType=.WRITE_DESCRIPTOR_SET,dstSet=r.descriptor,dstBinding=1,descriptorCount=1,descriptorType=.COMBINED_IMAGE_SAMPLER,pImageInfo=&image}
        r.dispatch.UpdateDescriptorSets(r.device,1,&write,0,nil)
    }
    mem.copy(p.mapped,control.pixels,width*height*4)
    p.identity=control.identity;p.generation=control.generation;p.copying=true
    return true
}
renderer_page_copy :: proc(r:^Renderer) {
    p:=&r.page;if !p.copying {return}
    barrier:=vk.ImageMemoryBarrier{sType=.IMAGE_MEMORY_BARRIER,oldLayout=.SHADER_READ_ONLY_OPTIMAL,newLayout=.TRANSFER_DST_OPTIMAL,
        srcQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,dstQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,image=p.image,
        subresourceRange={aspectMask={.COLOR},levelCount=1,layerCount=1},srcAccessMask={.SHADER_READ},dstAccessMask={.TRANSFER_WRITE}}
    stage:vk.PipelineStageFlags={.FRAGMENT_SHADER}
    if p.initial {barrier.oldLayout=.UNDEFINED;barrier.srcAccessMask={};stage={.TOP_OF_PIPE}}
    r.dispatch.CmdPipelineBarrier(r.command,stage,{.TRANSFER},{},0,nil,0,nil,1,&barrier)
    copy:=vk.BufferImageCopy{imageSubresource={aspectMask={.COLOR},layerCount=1},imageExtent={u32(p.width),u32(p.height),1}}
    r.dispatch.CmdCopyBufferToImage(r.command,p.staging,p.image,.TRANSFER_DST_OPTIMAL,1,&copy)
    barrier.oldLayout=.TRANSFER_DST_OPTIMAL;barrier.newLayout=.SHADER_READ_ONLY_OPTIMAL
    barrier.srcAccessMask={.TRANSFER_WRITE};barrier.dstAccessMask={.SHADER_READ}
    r.dispatch.CmdPipelineBarrier(r.command,{.TRANSFER},{.FRAGMENT_SHADER},{},0,nil,0,nil,1,&barrier)
    p.initial=false;p.copying=false
}
renderer_page_release :: proc(r:^Renderer) {
    if r.page.image==0 {return}
    renderer_page_destroy(r)
    image:=vk.DescriptorImageInfo{sampler=r.sampler,imageView=r.font_view,imageLayout=.SHADER_READ_ONLY_OPTIMAL}
    write:=vk.WriteDescriptorSet{sType=.WRITE_DESCRIPTOR_SET,dstSet=r.descriptor,dstBinding=1,descriptorCount=1,descriptorType=.COMBINED_IMAGE_SAMPLER,pImageInfo=&image}
    r.dispatch.UpdateDescriptorSets(r.device,1,&write,0,nil)
}

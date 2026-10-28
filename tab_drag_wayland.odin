#+build linux
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import posix "core:sys/posix"
import glfw "vendor:glfw"

// GLFW exposes Wayland surfaces, but not drag sources or button serials. Own
// separate protocol objects on its display; never replace GLFW's listeners.
Drag_WL_Interface :: struct {
    name:cstring,version:c.int,
    method_count:c.int,methods:rawptr,
    event_count:c.int,events:rawptr,
}
foreign import drag_wayland_lib "system:wayland-client"
foreign drag_wayland_lib {
    wl_proxy_marshal_flags :: proc(proxy:rawptr,opcode:u32,iface:^Drag_WL_Interface,version,flags:u32,#c_vararg args:..any)->rawptr ---
    wl_proxy_add_listener :: proc(proxy,listener,data:rawptr)->c.int ---
    wl_proxy_get_version :: proc(proxy:rawptr)->u32 ---
    wl_proxy_destroy :: proc(proxy:rawptr) ---
    wl_display_roundtrip :: proc(display:rawptr)->c.int ---
    wl_display_flush :: proc(display:rawptr)->c.int ---
    wl_registry_interface,wl_seat_interface,wl_pointer_interface:Drag_WL_Interface
    wl_data_device_manager_interface,wl_data_device_interface,wl_data_source_interface:Drag_WL_Interface
}
DRAG_WL_MIME :: cstring("application/x-terminal-plus-tab")
Drag_WL_Offer :: struct {proxy:rawptr,tab:bool,action:u32}
Drag_Wayland :: struct {
    display,registry,seat,pointer,manager,device,source:rawptr,
    pointer_surface,press_surface,offer:rawptr,
    seat_name:u32,
    serial,enter_serial:u32,
    occupied:^App,
    offers:[dynamic]Drag_WL_Offer,
    active,accepted:bool,
}
drag_wayland:Drag_Wayland

drag_wl_request :: proc(proxy:rawptr,opcode:u32,destroy:bool=false) {
    if proxy==nil {return}
    wl_proxy_marshal_flags(proxy,opcode,nil,wl_proxy_get_version(proxy),u32(destroy))
}
drag_wl_offer_destroy :: proc(proxy:rawptr) {
    if proxy==nil {return}
    for offer,i in drag_wayland.offers {if offer.proxy==proxy {drag_wl_request(proxy,2,true);ordered_remove(&drag_wayland.offers,i);break}}
    if drag_wayland.offer==proxy {drag_wayland.offer=nil;drag_wayland.accepted=false}
}
tab_drag_wayland_cancel :: proc() {
    state:=&drag_wayland
    state.active=false;state.occupied=nil
    drag_wl_offer_destroy(state.offer)
    if state.source!=nil {drag_wl_request(state.source,1,true);state.source=nil}
}
tab_drag_wayland_destroy :: proc() {
    state:=&drag_wayland
    tab_drag_wayland_cancel()
    for len(state.offers)>0 {drag_wl_offer_destroy(state.offers[len(state.offers)-1].proxy)}
    delete(state.offers)
    if state.pointer!=nil {
        if wl_proxy_get_version(state.pointer)>=3 {drag_wl_request(state.pointer,1,true)} else {wl_proxy_destroy(state.pointer)}
    }
    if state.device!=nil {
        if wl_proxy_get_version(state.device)>=2 {drag_wl_request(state.device,2,true)} else {wl_proxy_destroy(state.device)}
    }
    if state.seat!=nil {
        if wl_proxy_get_version(state.seat)>=5 {drag_wl_request(state.seat,3,true)} else {wl_proxy_destroy(state.seat)}
    }
    if state.manager!=nil {wl_proxy_destroy(state.manager)}
    if state.registry!=nil {wl_proxy_destroy(state.registry)}
    state^={}
}

drag_wl_registry_global :: proc "c" (data,registry:rawptr,name:u32,iface:cstring,version:u32) {
    context=runtime.default_context();state:=&drag_wayland
    if string(iface)=="wl_seat"&&state.seat==nil {
        state.seat=wl_proxy_marshal_flags(registry,0,&wl_seat_interface,min(version,5),0,name,wl_seat_interface.name,min(version,5),rawptr(nil))
        state.seat_name=name
        if state.seat!=nil {wl_proxy_add_listener(state.seat,&drag_wl_seat_listener,nil)}
    } else if string(iface)=="wl_data_device_manager"&&state.manager==nil&&version>=3 {
        state.manager=wl_proxy_marshal_flags(registry,0,&wl_data_device_manager_interface,3,0,name,wl_data_device_manager_interface.name,u32(3),rawptr(nil))
    }
}
drag_wl_registry_remove :: proc "c" (data,registry:rawptr,name:u32) {
    context=runtime.default_context()
    if name==drag_wayland.seat_name {tab_drag_cancel();tab_drag_wayland_destroy()}
}
drag_wl_seat_capabilities :: proc "c" (data,seat:rawptr,capabilities:u32) {
    context=runtime.default_context();state:=&drag_wayland
    if capabilities&1!=0&&state.pointer==nil {
        state.pointer=wl_proxy_marshal_flags(seat,0,&wl_pointer_interface,wl_proxy_get_version(seat),0,rawptr(nil))
        if state.pointer!=nil {wl_proxy_add_listener(state.pointer,&drag_wl_pointer_listener,nil)}
    } else if capabilities&1==0&&state.pointer!=nil {
        tab_drag_cancel()
        if wl_proxy_get_version(state.pointer)>=3 {drag_wl_request(state.pointer,1,true)} else {wl_proxy_destroy(state.pointer)}
        state.pointer=nil;state.pointer_surface=nil;state.press_surface=nil;state.serial=0
    }
}
drag_wl_seat_name :: proc "c" (data,seat:rawptr,name:cstring) {}
drag_wl_pointer_enter :: proc "c" (data,pointer:rawptr,serial:u32,surface:rawptr,x,y:i32) {
    context=runtime.default_context();drag_wayland.pointer_surface=surface
}
drag_wl_pointer_leave :: proc "c" (data,pointer:rawptr,serial:u32,surface:rawptr) {
    context=runtime.default_context();drag_wayland.pointer_surface=nil
}
drag_wl_pointer_motion :: proc "c" (data,pointer:rawptr,time:u32,x,y:i32) {}
drag_wl_pointer_button :: proc "c" (data,pointer:rawptr,serial,time,button,state:u32) {
    context=runtime.default_context()
    if button!=0x110 {return} // Linux BTN_LEFT, rather than GLFW's button index.
    if state==1 {drag_wayland.serial=serial;drag_wayland.press_surface=drag_wayland.pointer_surface}
    else {drag_wayland.serial=0;drag_wayland.press_surface=nil}
}
drag_wl_pointer_axis :: proc "c" (data,pointer:rawptr,time,axis:u32,value:i32) {}
drag_wl_pointer_frame :: proc "c" (data,pointer:rawptr) {}
drag_wl_pointer_axis_source :: proc "c" (data,pointer:rawptr,source:u32) {}
drag_wl_pointer_axis_stop :: proc "c" (data,pointer:rawptr,time,axis:u32) {}
drag_wl_pointer_axis_discrete :: proc "c" (data,pointer:rawptr,axis:u32,discrete:i32) {}

drag_wl_offer_mime :: proc "c" (data,proxy:rawptr,mime:cstring) {
    context=runtime.default_context()
    for &offer in drag_wayland.offers {if offer.proxy==proxy {offer.tab=offer.tab||string(mime)==string(DRAG_WL_MIME);break}}
}
drag_wl_offer_source_actions :: proc "c" (data,offer:rawptr,actions:u32) {}
drag_wl_offer_action :: proc "c" (data,proxy:rawptr,action:u32) {
    context=runtime.default_context()
    for &offer in drag_wayland.offers {if offer.proxy==proxy {offer.action=action;break}}
}
drag_wl_device_offer :: proc "c" (data,device,offer:rawptr) {
    context=runtime.default_context()
    append(&drag_wayland.offers,Drag_WL_Offer{proxy=offer})
    wl_proxy_add_listener(offer,&drag_wl_offer_listener,nil)
}
drag_wl_target :: proc(x,y:i32) {
    state:=&drag_wayland
    if !state.active||!tab_drag.armed {return}
    tab_drag.screen_x=f64(x)/256;tab_drag.screen_y=f64(y)/256
    tab_drag_update_target(tab_drag.screen_x,tab_drag.screen_y,state.occupied)
    accepted:=tab_drag.target!=nil
    if state.offer!=nil&&accepted!=state.accepted {
        mime:cstring;if accepted {mime=DRAG_WL_MIME}
        wl_proxy_marshal_flags(state.offer,0,nil,wl_proxy_get_version(state.offer),0,state.enter_serial,mime)
        state.accepted=accepted
    }
}
drag_wl_device_enter :: proc "c" (data,device:rawptr,serial:u32,surface:rawptr,x,y:i32,offer:rawptr) {
    context=runtime.default_context();state:=&drag_wayland
    state.offer=offer;state.enter_serial=serial;state.accepted=false;state.occupied=nil
    if !state.active {return}
    ours:=false
    for item in state.offers {if item.proxy==offer {ours=item.tab;break}}
    if !ours {return}
    for a in workspace_windows {
        if !glfw.WindowShouldClose(a.renderer.window)&&glfw.GetWaylandWindow(a.renderer.window)==surface {state.occupied=a;break}
    }
    wl_proxy_marshal_flags(offer,4,nil,wl_proxy_get_version(offer),0,u32(2),u32(2)) // MOVE only.
    drag_wl_target(x,y)
}
drag_wl_device_leave :: proc "c" (data,device:rawptr) {
    context=runtime.default_context();state:=&drag_wayland
    drag_wl_offer_destroy(state.offer);state.occupied=nil
    if state.active {tab_drag_update_target(tab_drag.screen_x,tab_drag.screen_y,nil)}
}
drag_wl_device_motion :: proc "c" (data,device:rawptr,time:u32,x,y:i32) {
    context=runtime.default_context();drag_wl_target(x,y)
}
drag_wl_device_drop :: proc "c" (data,device:rawptr) {
    context=runtime.default_context();state:=&drag_wayland
    if !state.active {return}
    move:=false
    for offer in state.offers {if offer.proxy==state.offer {move=offer.action==2;break}}
    if state.accepted&&move&&tab_drag.target!=nil {
        drag:=tab_drag
        workspace_request_drop(drag.source,drag.tab,drag.target,drag.insertion,drag.drop_mode,drag.onto,drag.group_id,drag.to_group,drag.onto_group)
        drag_wl_request(state.offer,3) // finish only an accepted, negotiated drop.
    }
    tab_drag_cancel()
}
drag_wl_device_selection :: proc "c" (data,device,offer:rawptr) {
    context=runtime.default_context()
    // Clipboard remains GLFW's responsibility; release our separate offer.
    drag_wl_offer_destroy(offer)
}
drag_wl_source_target :: proc "c" (data,source:rawptr,mime:cstring) {}
drag_wl_source_send :: proc "c" (data,source:rawptr,mime:cstring,fd:c.int) {
    context=runtime.default_context()
    // Transfers use the live tab pointer within this process, never shell data.
    posix.close(posix.FD(fd))
}
drag_wl_source_done :: proc "c" (data,source:rawptr) {
    context=runtime.default_context();tab_drag_cancel()
}
drag_wl_source_drop :: proc "c" (data,source:rawptr) {}
drag_wl_source_action :: proc "c" (data,source:rawptr,action:u32) {}

// Keep callbacks as procedures through global initialization. Casting them to
// rawptr in global initializers produces null entries in optimized Odin builds.
Drag_WL_Registry_Listener :: struct {
    global:type_of(drag_wl_registry_global),
    remove:type_of(drag_wl_registry_remove),
}
Drag_WL_Seat_Listener :: struct {
    capabilities:type_of(drag_wl_seat_capabilities),
    name:type_of(drag_wl_seat_name),
}
Drag_WL_Pointer_Listener :: struct {
    enter:type_of(drag_wl_pointer_enter),
    leave:type_of(drag_wl_pointer_leave),
    motion:type_of(drag_wl_pointer_motion),
    button:type_of(drag_wl_pointer_button),
    axis:type_of(drag_wl_pointer_axis),
    frame:type_of(drag_wl_pointer_frame),
    axis_source:type_of(drag_wl_pointer_axis_source),
    axis_stop:type_of(drag_wl_pointer_axis_stop),
    axis_discrete:type_of(drag_wl_pointer_axis_discrete),
}
Drag_WL_Offer_Listener :: struct {
    mime:type_of(drag_wl_offer_mime),
    source_actions:type_of(drag_wl_offer_source_actions),
    action:type_of(drag_wl_offer_action),
}
Drag_WL_Device_Listener :: struct {
    offer:type_of(drag_wl_device_offer),
    enter:type_of(drag_wl_device_enter),
    leave:type_of(drag_wl_device_leave),
    motion:type_of(drag_wl_device_motion),
    drop:type_of(drag_wl_device_drop),
    selection:type_of(drag_wl_device_selection),
}
Drag_WL_Source_Listener :: struct {
    target:type_of(drag_wl_source_target),
    send:type_of(drag_wl_source_send),
    cancelled:type_of(drag_wl_source_done),
    drop:type_of(drag_wl_source_drop),
    finished:type_of(drag_wl_source_done),
    action:type_of(drag_wl_source_action),
}
drag_wl_registry_listener := Drag_WL_Registry_Listener{drag_wl_registry_global,drag_wl_registry_remove}
drag_wl_seat_listener := Drag_WL_Seat_Listener{drag_wl_seat_capabilities,drag_wl_seat_name}
drag_wl_pointer_listener := Drag_WL_Pointer_Listener{drag_wl_pointer_enter,drag_wl_pointer_leave,drag_wl_pointer_motion,drag_wl_pointer_button,drag_wl_pointer_axis,drag_wl_pointer_frame,drag_wl_pointer_axis_source,drag_wl_pointer_axis_stop,drag_wl_pointer_axis_discrete}
drag_wl_offer_listener := Drag_WL_Offer_Listener{drag_wl_offer_mime,drag_wl_offer_source_actions,drag_wl_offer_action}
drag_wl_device_listener := Drag_WL_Device_Listener{drag_wl_device_offer,drag_wl_device_enter,drag_wl_device_leave,drag_wl_device_motion,drag_wl_device_drop,drag_wl_device_selection}
drag_wl_source_listener := Drag_WL_Source_Listener{drag_wl_source_target,drag_wl_source_send,drag_wl_source_done,drag_wl_source_drop,drag_wl_source_done,drag_wl_source_action}

tab_drag_wayland_init :: proc() {
    if glfw.GetPlatform()!=glfw.PLATFORM_WAYLAND||drag_wayland.registry!=nil {return}
    if !tab_drag_wayland_connect(glfw.GetWaylandDisplay()) {fmt.eprintln("Native Wayland tab dragging could not initialize.")}
}
tab_drag_wayland_connect :: proc(display:rawptr)->bool {
    state:=&drag_wayland
    state.display=display
    if state.display==nil {return false}
    state.registry=wl_proxy_marshal_flags(state.display,1,&wl_registry_interface,1,0,rawptr(nil))
    if state.registry!=nil {
        wl_proxy_add_listener(state.registry,&drag_wl_registry_listener,nil)
        if wl_display_roundtrip(state.display)>=0&&state.seat!=nil&&state.manager!=nil {
            state.device=wl_proxy_marshal_flags(state.manager,1,&wl_data_device_interface,3,0,rawptr(nil),state.seat)
            if state.device!=nil {wl_proxy_add_listener(state.device,&drag_wl_device_listener,nil)}
            if wl_display_roundtrip(state.display)>=0&&state.device!=nil&&state.pointer!=nil {return true}
        }
    }
    tab_drag_wayland_destroy()
    return false
}
tab_drag_wayland_start :: proc()->bool {
    state:=&drag_wayland
    if state.active {return true}
    if state.device==nil||state.serial==0||state.press_surface!=glfw.GetWaylandWindow(tab_drag.source.renderer.window) {return false}
    state.source=wl_proxy_marshal_flags(state.manager,0,&wl_data_source_interface,3,0,rawptr(nil))
    if state.source==nil {return false}
    wl_proxy_add_listener(state.source,&drag_wl_source_listener,nil)
    wl_proxy_marshal_flags(state.source,0,nil,3,0,DRAG_WL_MIME)
    wl_proxy_marshal_flags(state.source,2,nil,3,0,u32(2))
    wl_proxy_marshal_flags(state.device,0,nil,3,0,state.source,state.press_surface,rawptr(nil),state.serial)
    state.active=true
    wl_display_flush(state.display)
    return true
}

#+build linux
package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import posix "core:sys/posix"

Media_Audio_Device :: struct {name,label:string}

media_audio_devices_destroy :: proc(devices:^[dynamic]Media_Audio_Device) {
    for device in devices^ {delete(device.name);delete(device.label)}
    delete(devices^);devices^=nil
}

// Ask the same FFmpeg installation used for playback for its output devices.
// This also handles PipeWire's Pulse compatibility service and ALSA plugins,
// without requiring a second audio runtime or command-line audio utilities.
// Run on a worker: an unavailable audio server must never block the UI.
media_audio_devices :: proc(view:^Media_View,backend:string)->(devices:[dynamic]Media_Audio_Device,error:string) {
    append(&devices,Media_Audio_Device{strings.clone("default"),strings.clone("System default")})
    executable:=media_ffmpeg()
    if executable=="" {return devices,"FFmpeg is unavailable."}
    process:Media_Process
    if !media_spawn(&process,[]string{executable,"-hide_banner","-sinks",backend}) {return devices,"Could not list audio outputs."}
    defer {media_process_finish(view,&process);delete(process.diagnostic)}
    output:[dynamic]u8;defer delete(output)
    buffer:[4096]u8
    started:=time.tick_now()
    for {
        if media_stopping(view) {return devices,""}
        if time.tick_diff(started,time.tick_now())>2*time.Second {return devices,"Audio output discovery timed out."}
        media_errors(&process)
        count:=posix.read(process.output,raw_data(buffer[:]),len(buffer))
        if count>0 {
            if len(output)+int(count)>256*1024 {return devices,"Audio output list is too large."}
            append(&output,..buffer[:int(count)])
            continue
        }
        if count==0 {break}
        if posix.errno()==.EINTR {continue}
        if posix.errno()!=.EAGAIN {return devices,"Could not read audio outputs."}
        descriptors:=[2]posix.pollfd{{fd=process.output,events={.IN}},{fd=process.errors,events={.IN}}}
        _=posix.poll(raw_data(descriptors[:]),2,50)
    }
    text:=string(output[:])
    if strings.contains(text,"Cannot list sinks")||strings.contains(string(process.diagnostic[:]),"Cannot list sinks") {
        return devices,"Audio outputs unavailable. System default is still available."
    }
    found:[dynamic]Media_Audio_Device;defer delete(found)
    for source_line in strings.split_lines_iterator(&text) {
        line:=strings.trim_space(source_line)
        if strings.has_prefix(line,"*") {line=strings.trim_space(line[1:])}
        separator:=strings.index(line," [")
        if separator<=0 {continue}
        name:=strings.trim_space(line[:separator])
        description:=line[separator+2:]
        end:=strings.last_index(description,"]")
        if end<0||name=="default" {continue}
        label:=strings.trim_space(description[:end]);if label=="" {label=name}
        append(&found,Media_Audio_Device{name,label})
    }
    if backend=="alsa" {media_alsa_outputs(&devices,found[:])}
    else {for device in found {media_audio_device_add(&devices,device.name,device.label)}}
    if len(devices)==1 {error="No additional audio outputs found."}
    return
}
// Clones both strings; skips repeated names and numbers repeated labels.
media_audio_device_add :: proc(devices:^[dynamic]Media_Audio_Device,name,label:string) {
    repeats:=0
    for device in devices^ {
        if device.name==name {return}
        if device.label==label||strings.has_prefix(device.label,label)&&strings.has_prefix(device.label[len(label):]," (") {repeats+=1}
    }
    shown:=strings.clone(label) if repeats==0 else fmt.aprintf("%s (%d)",label,repeats+1)
    append(devices,Media_Audio_Device{strings.clone(name),shown})
}

Media_Alsa_Card :: struct {id,name:string,index,monitors:int,eld:bool}

// Without a sound server FFmpeg reports every ALSA hint: resamplers, routing
// plugins and each surround/HDMI PCM of every card. Present one entry per
// physical output instead, named after the card rather than the PCM type.
media_alsa_outputs :: proc(devices:^[dynamic]Media_Audio_Device,found:[]Media_Audio_Device) {
    cards_text:=media_proc_text("/proc/asound/cards");defer delete(cards_text)
    cards:[dynamic]Media_Alsa_Card;defer delete(cards)
    remaining:=cards_text
    for line in strings.split_lines_iterator(&remaining) {
        // " 0 [Duo            ]: USB-Audio - RØDECaster Duo"
        open:=strings.index_byte(line,'[');close:=strings.index(line,"]:")
        if open<0||close<open {continue}
        index,ok:=strconv.parse_int(strings.trim_space(line[:open]));if !ok {continue}
        card:=Media_Alsa_Card{id=strings.trim_space(line[open+1:close]),index=index}
        rest:=line[close+2:]
        if dash:=strings.index(rest," - ");dash>=0 {card.name=strings.trim_space(rest[dash+3:])}
        if card.name=="" {card.name=card.id}
        card.monitors,card.eld=media_alsa_monitors(index)
        append(&cards,card)
    }
    find_card :: proc(cards:[]Media_Alsa_Card,id:string)->(Media_Alsa_Card,bool) {
        for card in cards {if card.id==id {return card,true}}
        return {},false
    }
    // An HDMI-only controller has no analog PCM even if a default hint exists.
    has_hint :: proc(found:[]Media_Audio_Device,interface,card:string)->bool {
        for device in found {if media_alsa_interface(device.name)==interface&&media_alsa_field(device.name,"CARD")==card {return true}}
        return false
    }
    for device in found {
        card_id:=media_alsa_field(device.name,"CARD");if card_id=="" {continue}
        interface:=media_alsa_interface(device.name)
        card,known:=find_card(cards[:],card_id);if !known {card=Media_Alsa_Card{id=card_id,name=card_id}}
        switch interface {
        case "sysdefault","front":
            // sysdefault converts formats for the card, so prefer it over front.
            if interface=="front"&&has_hint(found,"sysdefault",card_id) {continue}
            if has_hint(found,"hdmi",card_id)&&!has_hint(found,"front",card_id) {continue}
            label:=card.name
            if interface=="front" {
                if dev:=media_alsa_field(device.name,"DEV");dev!=""&&dev!="0" {label=fmt.tprintf("%s · Output %s",card.name,dev)}
            }
            media_audio_device_add(devices,device.name,label)
        case "hdmi":
            if card.eld&&card.monitors==0 {continue}
            port:=1
            if dev,ok:=strconv.parse_int(media_alsa_field(device.name,"DEV"));ok {port=dev+1}
            label:=fmt.tprintf("%s · HDMI %d",card.name,port)
            if strings.contains(strings.to_lower(card.name,context.temp_allocator),"hdmi") {label=fmt.tprintf("%s %d",card.name,port)}
            media_audio_device_add(devices,device.name,label)
        }
    }
}
media_alsa_interface :: proc(name:string)->string {
    colon:=strings.index_byte(name,':');if colon<0 {return name}
    return name[:colon]
}
media_alsa_field :: proc(name,key:string)->string {
    colon:=strings.index_byte(name,':');if colon<0 {return ""}
    params:=name[colon+1:]
    for part in strings.split_iterator(&params,",") {
        if len(part)>len(key)&&strings.has_prefix(part,key)&&part[len(key)]=='=' {return part[len(key)+1:]}
    }
    return ""
}
// HDMI controllers expose a PCM per port whether or not a display is attached.
// The ELD files report which ports currently have an audio-capable sink.
media_alsa_monitors :: proc(card:int)->(monitors:int,eld:bool) {
    directory:=fmt.tprintf("/proc/asound/card%d",card)
    handle:=posix.opendir(strings.clone_to_cstring(directory,context.temp_allocator));if handle==nil {return}
    defer posix.closedir(handle)
    for entry:=posix.readdir(handle);entry!=nil;entry=posix.readdir(handle) {
        file:=string(cstring(raw_data(entry.d_name[:])))
        if !strings.has_prefix(file,"eld#") {continue}
        eld=true
        text:=media_proc_text(fmt.tprintf("%s/%s",directory,file));defer delete(text)
        remaining:=text
        for line in strings.split_lines_iterator(&remaining) {
            fields:=strings.fields(line,context.temp_allocator)
            if len(fields)==2&&fields[0]=="monitor_present"&&fields[1]=="1" {monitors+=1;break}
        }
    }
    return
}
// procfs reports a zero size, so read until end of file.
media_proc_text :: proc(path:string)->string {
    fd:=posix.open(strings.clone_to_cstring(path,context.temp_allocator),{.CLOEXEC});if fd<0 {return ""}
    defer posix.close(fd)
    data:[dynamic]u8
    buffer:[4096]u8
    for len(data)<64*1024 {
        count:=posix.read(fd,raw_data(buffer[:]),len(buffer))
        if count>0 {append(&data,..buffer[:int(count)]);continue}
        if count<0&&posix.errno()==.EINTR {continue}
        break
    }
    return string(data[:])
}

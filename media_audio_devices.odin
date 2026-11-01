#+build linux
package main

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
        duplicate:=false
        for device in devices {if device.name==name {duplicate=true;break}}
        if duplicate {continue}
        append(&devices,Media_Audio_Device{strings.clone(name),strings.clone(label)})
    }
    if len(devices)==1 {error="No additional audio outputs found."}
    return
}

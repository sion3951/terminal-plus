#+build linux
package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import glfw "vendor:glfw"

// Audio-only playback gets a native analyser: a log-frequency spectrum with
// peak hold, a spectrogram flowing beneath it on the same frequency axis,
// and stereo level meters. The controls' timeline remains the only playhead.
// The playback FFmpeg process tees its decoded audio to a pipe for analysis.
MEDIA_VISUAL_RATE :: 48000
MEDIA_VISUAL_RING :: 1<<18 // frames per channel, about 5.4 s
MEDIA_FFT :: 4096
MEDIA_FFT_HALF :: MEDIA_FFT/2
MEDIA_HOP :: 800 // 60 spectrogram rows per second
MEDIA_BANDS :: 512
MEDIA_HISTORY :: 2048
MEDIA_LEVEL_WINDOW :: 2048
MEDIA_DB_FLOOR :: f32(-90)
MEDIA_METER_FLOOR :: f32(-60)
MEDIA_FREQ_LOW :: f32(20)
MEDIA_FREQ_HIGH :: f32(20000)
// FFmpeg reads ahead of the device (its initial read burst), so the analysis
// clock follows wall time from the first decoded audio instead of FFmpeg's
// progress. The server starts without prebuffering; while the decoder is
// stopped it keeps playing up to its 120 ms target before it underruns.
MEDIA_DEVICE_LATENCY :: 0.04
MEDIA_DEVICE_BUFFER :: 0.12

Media_Visual :: struct {
    // Decoder thread → render thread. Frame 0 of each decoder run is `origin`.
    pcm_mutex:sync.Mutex,
    left,right:[]f32,
    written:i64,
    origin:f64,
    epoch,generation:u64,
    started:bool,
    start_tick:time.Tick,
    // Probe details; immutable after creation.
    title,detail:string,
    // Everything below belongs to the render thread.
    seen_generation:u64,
    seen_hop:i64,
    rows:i64,
    history:[MEDIA_HISTORY][MEDIA_BANDS]u8,
    marker:[MEDIA_HISTORY]bool,
    image_width,image_height:int,
    image_rows:i64,
    column_band:[dynamic]f32,
    raw,spectrum,peak,peak_time:[MEDIA_BANDS]f32,
    level,level_peak,level_hold,hold_time,clip:[2]f32,
    correlation:f32,
    readout_rms,readout_peak,readout_correlation:f32,
    tick,readout_tick:time.Tick,
    ticked:bool,
    re,im,window:[MEDIA_FFT]f32,
    power:[MEDIA_FFT_HALF+1]f32,
    cosine,sine:[MEDIA_FFT_HALF]f32,
    reverse:[MEDIA_FFT]u16,
    band_first,band_last:[MEDIA_BANDS]i32,
    band_center:[MEDIA_BANDS]f32,
    lut:[256][4]u8,
}
Media_Visual_Layout :: struct {info,spectrum,meters,axis,waterfall:Explorer_Rect}

media_visual_new :: proc()->^Media_Visual {
    visual:=new(Media_Visual)
    visual.left=make([]f32,MEDIA_VISUAL_RING);visual.right=make([]f32,MEDIA_VISUAL_RING)
    bits:uint=0;for (1<<bits)<MEDIA_FFT {bits+=1}
    for i in 0..<MEDIA_FFT {
        reversed:=0
        for bit in 0..<bits {if i&(1<<bit)!=0 {reversed|=1<<(bits-1-bit)}}
        visual.reverse[i]=u16(reversed)
        visual.window[i]=f32(0.5-0.5*math.cos(2*math.PI*f64(i)/MEDIA_FFT))
    }
    for k in 0..<MEDIA_FFT_HALF {
        angle:=2*math.PI*f64(k)/MEDIA_FFT
        visual.cosine[k]=f32(math.cos(angle));visual.sine[k]=f32(math.sin(angle))
    }
    // Narrow bass bands interpolate between bins; wider bands take their peak.
    span:=f64(MEDIA_FREQ_HIGH/MEDIA_FREQ_LOW);bin:=f64(MEDIA_FFT)/MEDIA_VISUAL_RATE
    for b in 0..<MEDIA_BANDS {
        low:=f64(MEDIA_FREQ_LOW)*math.pow(span,f64(b)/MEDIA_BANDS)*bin
        high:=f64(MEDIA_FREQ_LOW)*math.pow(span,f64(b+1)/MEDIA_BANDS)*bin
        visual.band_first[b]=i32(math.ceil(low));visual.band_last[b]=i32(min(math.floor(high),f64(MEDIA_FFT_HALF)))
        visual.band_center[b]=f32(min(math.sqrt(low*high),f64(MEDIA_FFT_HALF-1)))
    }
    // Inferno-like perceptual ramp: dark violet through orange to pale yellow.
    stops:=[9][3]f32{{0,0,4},{31,12,72},{85,15,109},{136,34,106},{186,54,85},{227,89,51},{249,140,10},{249,201,50},{252,255,164}}
    for i in 0..<256 {
        t:=f32(i)/255*8;k:=min(int(t),7);f:=t-f32(k)
        for ch in 0..<3 {visual.lut[i][ch]=u8(stops[k][ch]+(stops[k+1][ch]-stops[k][ch])*f+0.5)}
        visual.lut[i][3]=255
    }
    for b in 0..<MEDIA_BANDS {visual.spectrum[b]=MEDIA_DB_FLOOR-10;visual.peak[b]=MEDIA_DB_FLOOR-10}
    for ch in 0..<2 {visual.level[ch]=-100;visual.level_peak[ch]=-100;visual.level_hold[ch]=-100}
    visual.readout_rms=-100;visual.readout_peak=-100
    return visual
}
media_visual_create :: proc(diagnostic,path:string)->^Media_Visual {
    visual:=media_visual_new()
    visual.title,visual.detail=media_visual_info(diagnostic,path)
    return visual
}
media_visual_destroy :: proc(visual:^Media_Visual) {
    if visual==nil {return}
    delete(visual.left);delete(visual.right);delete(visual.column_band)
    delete(visual.title);delete(visual.detail);free(visual)
}
// Audio files often carry cover art as a one-frame video stream; that is not video.
media_has_video :: proc(diagnostic:string)->bool {
    text:=diagnostic
    for line in strings.split_lines_iterator(&text) {
        if strings.contains(line,"Video:")&&!strings.contains(line,"(attached pic)") {return true}
    }
    return false
}
// Arguments that tee the playback decoder's audio to the analysis pipe.
media_visual_output :: proc(arguments:^[dynamic]string) {
    append(arguments,"-map","0:a:0","-vn","-sn","-dn","-c:a","pcm_f32le","-ac","2","-ar","48000","-f","f32le","pipe:1")
}
// Called on the decoder thread for each playback process.
media_visual_drain :: proc(view:^Media_View,visual:^Media_Visual,process:^Media_Process,position:f64,command:u64) {
    sync.mutex_lock(&visual.pcm_mutex)
    visual.written=0;visual.origin=position;visual.epoch=command;visual.started=false;visual.generation+=1
    sync.mutex_unlock(&visual.pcm_mutex)
    chunk:[1024]f32
    for media_read(view,process,mem.slice_to_bytes(chunk[:])) {
        sync.mutex_lock(&visual.pcm_mutex)
        if !visual.started {visual.started=true;visual.start_tick=time.tick_now()}
        for i in 0..<len(chunk)/2 {
            slot:=(visual.written+i64(i))&(MEDIA_VISUAL_RING-1)
            visual.left[slot]=chunk[2*i];visual.right[slot]=chunk[2*i+1]
        }
        visual.written+=i64(len(chunk)/2)
        sync.mutex_unlock(&visual.pcm_mutex)
    }
}
// Called with view.mutex held when playback resumes after a pause.
media_visual_resume_locked :: proc(visual:^Media_Visual,paused_at,now:time.Tick) {
    sync.mutex_lock(&visual.pcm_mutex);defer sync.mutex_unlock(&visual.pcm_mutex)
    if !visual.started {return}
    if time.tick_diff(visual.start_tick,paused_at)<=0 {visual.start_tick=now;return}
    stopped:=time.tick_diff(paused_at,now)
    drained:=min(stopped,time.Duration(MEDIA_DEVICE_BUFFER*f64(time.Second)))
    visual.start_tick=time.tick_add(visual.start_tick,stopped-drained)
}


// In-place radix-2 FFT of visual.re/visual.im.
media_visual_fft :: proc(visual:^Media_Visual) {
    for i in 0..<MEDIA_FFT {
        j:=int(visual.reverse[i])
        if j>i {visual.re[i],visual.re[j]=visual.re[j],visual.re[i];visual.im[i],visual.im[j]=visual.im[j],visual.im[i]}
    }
    for size:=2;size<=MEDIA_FFT;size*=2 {
        half:=size/2;step:=MEDIA_FFT/size
        for start:=0;start<MEDIA_FFT;start+=size {
            for k in 0..<half {
                wr,wi:=visual.cosine[k*step],-visual.sine[k*step]
                p,q:=start+k,start+k+half
                tr:=wr*visual.re[q]-wi*visual.im[q];ti:=wr*visual.im[q]+wi*visual.re[q]
                visual.re[q]=visual.re[p]-tr;visual.im[q]=visual.im[p]-ti
                visual.re[p]+=tr;visual.im[p]+=ti
            }
        }
    }
}
// Spectrum (dBFS per band) of the FFT window ending at frame `end`. Left and
// right share one complex transform: left is real input, right imaginary.
media_visual_analyse :: proc(visual:^Media_Visual,end:i64) {
    sync.mutex_lock(&visual.pcm_mutex)
    oldest:=visual.written-MEDIA_VISUAL_RING
    for i in 0..<MEDIA_FFT {
        index:=end-MEDIA_FFT+i64(i)
        l,r:f32
        if index>=0&&index>=oldest&&index<visual.written {slot:=index&(MEDIA_VISUAL_RING-1);l=visual.left[slot];r=visual.right[slot]}
        visual.re[i]=l*visual.window[i];visual.im[i]=r*visual.window[i]
    }
    sync.mutex_unlock(&visual.pcm_mutex)
    media_visual_fft(visual)
    // Mean channel power is (|Z[k]|²+|Z[N-k]|²)/4. A full-scale sine reads
    // 0 dBFS: a Hann window's coherent gain leaves N/4 at the peak bin.
    scale:=f32(4.0/(f64(MEDIA_FFT)*f64(MEDIA_FFT)))
    for k in 0..=MEDIA_FFT_HALF {
        m:=(MEDIA_FFT-k)&(MEDIA_FFT-1)
        visual.power[k]=(visual.re[k]*visual.re[k]+visual.im[k]*visual.im[k]+visual.re[m]*visual.re[m]+visual.im[m]*visual.im[m])*scale
    }
    for b in 0..<MEDIA_BANDS {
        value:f32=0
        if visual.band_last[b]>=visual.band_first[b] {
            for k in visual.band_first[b]..=visual.band_last[b] {value=max(value,visual.power[k])}
        } else {
            center:=visual.band_center[b];k:=int(center);t:=center-f32(k)
            value=visual.power[k]*(1-t)+visual.power[k+1]*t
        }
        visual.raw[b]=10*math.log10(max(value,1e-12))
    }
}
media_visual_row :: proc(visual:^Media_Visual,marker:bool) {
    slot:=visual.rows%%MEDIA_HISTORY
    visual.marker[slot]=marker
    if !marker {
        for b in 0..<MEDIA_BANDS {visual.history[slot][b]=u8(clamp((visual.raw[b]-MEDIA_DB_FLOOR)/(-MEDIA_DB_FLOOR),0,1)*255+0.5)}
    }
    visual.rows+=1
}
// Advance analysis to the audible position. Returns that position in media time.
media_visual_step :: proc(visual:^Media_Visual,paused,finished:bool,paused_at:time.Tick,command:u64)->(position:f64,valid:bool) {
    now:=time.tick_now()
    dt:f32=0
    if visual.ticked {dt=f32(clamp(time.duration_seconds(time.tick_diff(visual.tick,now)),0,0.25))}
    visual.tick=now;visual.ticked=true
    if paused {dt=0}
    sync.mutex_lock(&visual.pcm_mutex)
    epoch,generation,origin,written,started,start:=visual.epoch,visual.generation,visual.origin,visual.written,visual.started,visual.start_tick
    sync.mutex_unlock(&visual.pcm_mutex)
    target:i64=0
    if started {
        clock:=paused_at if paused else now
        elapsed:=time.duration_seconds(time.tick_diff(start,clock))-MEDIA_DEVICE_LATENCY
        target=i64(max(0,elapsed)*MEDIA_VISUAL_RATE)
    }
    if finished {target=written}
    target=clamp(target,0,written)
    // Each new decoder run (seek, replay or output change) leaves a divider.
    if generation!=visual.seen_generation {
        if visual.rows>0 {media_visual_row(visual,true)}
        visual.seen_generation=generation;visual.seen_hop=0
    }
    hop:=target/MEDIA_HOP
    if hop>visual.seen_hop {
        for h:=max(visual.seen_hop+1,hop-255);h<=hop;h+=1 {media_visual_analyse(visual,h*MEDIA_HOP);media_visual_row(visual,false)}
        visual.seen_hop=hop
    }
    media_visual_analyse(visual,target)
    for b in 0..<MEDIA_BANDS {
        raw:=visual.raw[b]
        if raw>=visual.spectrum[b] {visual.spectrum[b]=raw} else {visual.spectrum[b]=max(raw,visual.spectrum[b]-60*dt)}
        if visual.spectrum[b]>=visual.peak[b] {visual.peak[b]=visual.spectrum[b];visual.peak_time[b]=0.9}
        else {
            visual.peak_time[b]-=dt
            if visual.peak_time[b]<=0 {visual.peak[b]=max(visual.spectrum[b],visual.peak[b]-24*dt)}
        }
    }
    peak:[2]f32;energy:[2]f64;cross:f64
    sync.mutex_lock(&visual.pcm_mutex)
    oldest:=visual.written-MEDIA_VISUAL_RING
    for i in 0..<MEDIA_LEVEL_WINDOW {
        index:=target-MEDIA_LEVEL_WINDOW+i64(i)
        if index<0||index<oldest {continue}
        slot:=index&(MEDIA_VISUAL_RING-1)
        l,r:=visual.left[slot],visual.right[slot]
        peak[0]=max(peak[0],abs(l));peak[1]=max(peak[1],abs(r))
        energy[0]+=f64(l*l);energy[1]+=f64(r*r);cross+=f64(l*r)
    }
    sync.mutex_unlock(&visual.pcm_mutex)
    for ch in 0..<2 {
        rms:=f32(10*math.log10(max(energy[ch]/MEDIA_LEVEL_WINDOW,1e-10)))
        instant:=f32(20*math.log10(max(f64(peak[ch]),1e-5)))
        if rms>visual.level[ch] {visual.level[ch]+=(rms-visual.level[ch])*min(1,dt/0.06)}
        else {visual.level[ch]=max(rms,visual.level[ch]-20*dt)}
        if instant>visual.level_peak[ch] {visual.level_peak[ch]=instant}
        else {visual.level_peak[ch]=max(instant,visual.level_peak[ch]-30*dt)}
        if visual.level_peak[ch]>=visual.level_hold[ch] {visual.level_hold[ch]=visual.level_peak[ch];visual.hold_time[ch]=1.5}
        else {
            visual.hold_time[ch]-=dt
            if visual.hold_time[ch]<=0 {visual.level_hold[ch]=max(visual.level_peak[ch],visual.level_hold[ch]-20*dt)}
        }
        if peak[ch]>=0.999 {visual.clip[ch]=2} else {visual.clip[ch]=max(0,visual.clip[ch]-dt)}
    }
    if energy[0]>1e-9&&energy[1]>1e-9 {
        raw:=f32(cross/math.sqrt(energy[0]*energy[1]))
        visual.correlation+=(raw-visual.correlation)*min(1,dt/0.25)
    }
    // Numeric readouts update a few times a second so they stay legible.
    if time.tick_diff(visual.readout_tick,now)>=250*time.Millisecond {
        visual.readout_tick=now
        visual.readout_rms=max(visual.level[0],visual.level[1])
        visual.readout_peak=max(visual.level_hold[0],visual.level_hold[1])
        visual.readout_correlation=visual.correlation
    }
    return origin+f64(target)/MEDIA_VISUAL_RATE,started&&epoch==command
}
// Spectrogram texture at physical resolution, kept as a ring of rows: newest
// history row n lives at texture row (-n) mod height, drawn as two quads.
media_visual_image :: proc(visual:^Media_Visual,frame:^Renderer_Pixels,width,height:int)->bool {
    if width<=0||height<=0||width>16384||height>16384 {return false}
    sync.mutex_lock(&frame.mutex);defer sync.mutex_unlock(&frame.mutex)
    first:=visual.image_rows
    if width!=visual.image_width||height!=visual.image_height||frame.pixels==nil {
        if resize(&frame.storage,width*height*4)!=nil {return false}
        resize(&visual.column_band,width)
        for x in 0..<width {visual.column_band[x]=(f32(x)+0.5)/f32(width)*MEDIA_BANDS-0.5}
        background:=transmute(u32)visual.lut[0]
        for &pixel in mem.slice_data_cast([]u32,frame.storage[:]) {pixel=background}
        visual.image_width=width;visual.image_height=height;first=0
    }
    first=max(first,visual.rows-i64(min(height,MEDIA_HISTORY)))
    if first>=visual.rows&&frame.pixels!=nil {return true}
    pixels:=mem.slice_data_cast([]u32,frame.storage[:])
    divider:=transmute(u32)[4]u8{86,86,96,255}
    for n:=first;n<visual.rows;n+=1 {
        row:=int((-n)%%i64(height))
        line:=pixels[row*width:(row+1)*width]
        slot:=n%%MEDIA_HISTORY
        if visual.marker[slot] {for &pixel in line {pixel=divider};continue}
        history:=&visual.history[slot]
        for x in 0..<width {
            f:=max(visual.column_band[x],0);b0:=min(int(f),MEDIA_BANDS-1);b1:=min(b0+1,MEDIA_BANDS-1);t:=f-f32(b0)
            value:=f32(history[b0])*(1-t)+f32(history[b1])*t
            line[x]=transmute(u32)visual.lut[min(int(value+0.5),255)]
        }
    }
    visual.image_rows=visual.rows
    frame.pixels=raw_data(frame.storage);frame.pixel_width=width;frame.pixel_height=height;frame.generation+=1
    return true
}

media_visual_layout :: proc(a:^App,controls:Media_Controls)->Media_Visual_Layout {
    l:Media_Visual_Layout
    width:=f32(a.renderer.width)/a.scale
    total:=min(width-48,f32(1240))
    if total<280 {return l}
    x:=math.round((width-total)/2)
    // Leave a line above the controls for playback status messages.
    top,bottom:=f32(HEADER+18),controls.bar.y-34
    gutter,meters:=f32(40),f32(80)
    px,pw:=x+gutter,total-gutter-meters
    height:=bottom-top
    info_h,axis_h:=f32(42),f32(20)
    rest:=height-info_h-16-axis_h
    if rest<90 {info_h=0;rest=height-axis_h}
    if rest<50 {return l}
    if info_h>0 {l.info={x,top,total,info_h}}
    y:=top+(info_h+16 if info_h>0 else 0)
    spectrum_h:=rest if rest<220 else math.round(rest*0.42)
    l.spectrum={px,y,pw,spectrum_h}
    // Meters run the full height of the spectrum and spectrogram.
    l.meters={px+pw+16,y,meters-16,rest+axis_h if rest>=220 else spectrum_h}
    y+=spectrum_h;l.axis={px,y,pw,axis_h};y+=axis_h
    if rest>=220 {l.waterfall={px,y,pw,rest-spectrum_h}}
    return l
}
media_visual_x :: proc(rect:Explorer_Rect,frequency:f32)->f32 {
    return rect.x+rect.w*math.ln(frequency/MEDIA_FREQ_LOW)/math.ln(MEDIA_FREQ_HIGH/MEDIA_FREQ_LOW)
}
media_visual_color :: proc(visual:^Media_Visual,fraction:f32,alpha:f32=1)->Color {
    c:=visual.lut[clamp(int(fraction*255+0.5),0,255)]
    return {f32(c[0])/255,f32(c[1])/255,f32(c[2])/255,alpha}
}
media_db_text :: proc(value:f32)->string {
    if value<=-89.5 {return "−∞"}
    text:=fmt.tprintf("%.1f",value)
    if strings.has_prefix(text,"-") {return fmt.tprintf("−%s",text[1:])}
    return text
}
media_frequency_text :: proc(frequency:f32)->string {
    if frequency<1000 {return fmt.tprintf("%.0f Hz",frequency)}
    if frequency<10000 {return fmt.tprintf("%.2f kHz",frequency/1000)}
    return fmt.tprintf("%.1f kHz",frequency/1000)
}
media_text_right :: proc(a:^App,text:string,right,cy,size:f32,color:Color) {
    w:=renderer_text_width(&a.renderer,text,size*a.scale)/a.scale
    ui_text_mid(a,text,right-w,cy,size,w+2,color)
}
media_meter_fraction :: proc(db:f32)->f32 {return clamp((db-MEDIA_METER_FLOOR)/(-MEDIA_METER_FLOOR),0,1)}
// Hover label in a small glass pill, kept inside [left, right].
media_visual_tag :: proc(a:^App,label:string,x,cy,left,right:f32) {
    w:=renderer_text_width(&a.renderer,label,11*a.scale)/a.scale+16
    lx:=x+8;if lx+w>right {lx=x-8-w}
    lx=max(lx,left)
    ui_round(a,lx,cy-10,w,20,6,Color{0.1,0.1,0.11,0.94})
    ui_round_border(a,lx,cy-10,w,20,6,GLASS_RIM_TOP,GLASS_RIM_BOTTOM)
    ui_text_mid(a,label,lx+8,cy,11,w-12,TEXT)
}

// Draws the analyser in place of a video frame. Returns false when the view
// has no audio analysis; `position` becomes the audible playback position.
media_visual_render :: proc(a:^App,view:^Media_View,controls:Media_Controls,position:^f64)->bool {
    sync.mutex_lock(&view.mutex)
    visual:=view.visual
    paused,finished,paused_at,command,duration:=view.paused,view.finished,view.pause_tick,view.command_revision,view.duration
    dragging:=view.drag!=.None
    sync.mutex_unlock(&view.mutex)
    if visual==nil {return false}
    audible,valid:=media_visual_step(visual,paused,finished,paused_at,command)
    if valid&&!finished&&!dragging {position^=audible;if duration>0 {position^=min(position^,duration)}}
    l:=media_visual_layout(a,controls)
    r:=&a.renderer;s:=a.scale
    mx,my:=glfw.GetCursorPos(r.window);mouse_x,mouse_y:=f32(mx),f32(my)
    hairline:=1/s
    if l.info.w>0 {
        readout:=fmt.tprintf("RMS %s · Peak %s dBFS · Correlation %+.2f",media_db_text(visual.readout_rms),media_db_text(visual.readout_peak),visual.readout_correlation)
        readout_w:=renderer_text_width(r,readout,12*s)/s
        title_w:=renderer_text_width(r,visual.title,16*s,.UI_Bold)/s
        // The live readout shares the title row when it fits beside it.
        beside:=title_w+readout_w+32<=l.info.w
        below:=!beside&&l.info.w-readout_w-24>=160
        ui_title(a,visual.title,l.info.x,l.info.y+11,16,l.info.w)
        ui_text_mid(a,visual.detail,l.info.x,l.info.y+33,12,l.info.w-readout_w-24 if below else l.info.w,MUTED)
        if beside {media_text_right(a,readout,l.info.x+l.info.w,l.info.y+11,12,SOFT)}
        if below {media_text_right(a,readout,l.info.x+l.info.w,l.info.y+33,12,SOFT)}
    }
    sp:=l.spectrum
    if sp.w<=0 {return true}
    decades:=[3]f32{100,1000,10000}
    // Spectrum: dBFS grid, log-frequency bars coloured by level, peak holds.
    ui_round(a,sp.x,sp.y,sp.w,sp.h,6,Color{1,1,1,0.025})
    for db:=f32(0);db>MEDIA_DB_FLOOR;db-=15 {
        y:=sp.y+sp.h*(db/MEDIA_DB_FLOOR)
        if db<0 {ui_rect(a,sp.x,y,sp.w,hairline,Color{1,1,1,0.06})}
        media_text_right(a,"0 dB" if db==0 else fmt.tprintf("−%d",int(-db)),sp.x-6,y+(5 if db==0 else 0),10,FAINT)
    }
    for f in decades {ui_rect(a,media_visual_x(sp,f),sp.y,hairline,sp.h,Color{1,1,1,0.05})}
    count:=clamp(int(sp.w/5),16,MEDIA_BANDS)
    pitch:=sp.w/f32(count);gap:=max(hairline,pitch*0.22)
    for i in 0..<count {
        b0:=i*MEDIA_BANDS/count;b1:=max(b0+1,(i+1)*MEDIA_BANDS/count)
        level,held:=f32(-200),f32(-200)
        for b in b0..<b1 {level=max(level,visual.spectrum[b]);held=max(held,visual.peak[b])}
        x0:=(sp.x+f32(i)*pitch)*s;bw:=(pitch-gap)*s
        fraction:=clamp((level-MEDIA_DB_FLOOR)/(-MEDIA_DB_FLOOR),0,1)
        if fraction>0.002 {
            h:=fraction*sp.h*s
            renderer_round(&a.vertices,x0,(sp.y+sp.h)*s-h,bw,h,min(1.5*s,bw/2),media_visual_color(visual,fraction),media_visual_color(visual,fraction*0.35))
        }
        hold:=clamp((held-MEDIA_DB_FLOOR)/(-MEDIA_DB_FLOOR),0,1)
        if hold>0.002 {renderer_rect(&a.vertices,x0,math.round((sp.y+sp.h*(1-hold))*s),bw,max(1,math.round(1.5*s)),Color{1,1,1,0.55})}
    }
    // Frequency axis shared by the spectrum and the spectrogram.
    ax:=l.axis
    frequencies:=[10]f32{20,50,100,200,500,1000,2000,5000,10000,20000}
    labels:=[10]string{"20","50","100","200","500","1k","2k","5k","10k","20k"}
    last:=f32(-1e9)
    for frequency,i in frequencies {
        x:=media_visual_x(sp,frequency)
        w:=renderer_text_width(r,labels[i],10*s)/s
        left:=clamp(x-w/2,ax.x,ax.x+ax.w-w)
        if left<last+8 {continue}
        ui_rect(a,x,ax.y,hairline,3,Color{1,1,1,0.2})
        ui_text_mid(a,labels[i],left,ax.y+ax.h/2+1,10,w+2,MUTED)
        last=left+w
    }
    media_text_right(a,"Hz",sp.x-6,ax.y+ax.h/2+1,10,FAINT)
    // Stereo meters: RMS fill, instantaneous peak, held peak and a clip lamp
    // capping each bar, with a dBFS scale beside them.
    me:=l.meters
    bar_w,bar_gap:=f32(12),f32(4)
    names:=[2]string{"L","R"}
    for ch in 0..<2 {
        x:=me.x+f32(ch)*(bar_w+bar_gap)
        ui_round(a,x,me.y,bar_w,me.h,3,Color{1,1,1,0.05})
        rms,instant,held:=media_meter_fraction(visual.level[ch]),media_meter_fraction(visual.level_peak[ch]),media_meter_fraction(visual.level_hold[ch])
        if instant>0 {ui_round(a,x,me.y+me.h*(1-instant),bar_w,me.h*instant,3,Color{1,1,1,0.12})}
        if rms>0 {ui_round_gradient(a,x,me.y+me.h*(1-rms),bar_w,me.h*rms,3,media_visual_color(visual,0.45+0.55*rms),media_visual_color(visual,0.3))}
        if held>0 {ui_rect(a,x,me.y+me.h*(1-held)-0.75,bar_w,1.5,Color{1,1,1,0.8})}
        if visual.clip[ch]>0 {ui_round(a,x,me.y,bar_w,5,2.5,DANGER)}
        w:=renderer_text_width(r,names[ch],10*s)/s
        ui_text_mid(a,names[ch],x+(bar_w-w)/2,me.y-9,10,w+2,MUTED)
    }
    scale_x:=me.x+2*bar_w+bar_gap+6
    for db in ([7]f32{0,-6,-12,-18,-24,-36,-48}) {
        y:=me.y+me.h*(1-media_meter_fraction(db))
        if db<0 {ui_rect(a,me.x,y,2*bar_w+bar_gap,hairline,Color{0,0,0,0.6})}
        ui_text_mid(a,"0" if db==0 else fmt.tprintf("−%d",int(-db)),scale_x,y+(5 if db==0 else 0),10,40,FAINT)
    }
    // Spectrogram: newest audio at the top, one physical row per hop.
    wf:=l.waterfall
    plot_bottom:=sp.y+sp.h
    if wf.w>0&&wf.h>0 {
        plot_bottom=wf.y+wf.h
        x0,y0:=math.round(wf.x*s),math.round(wf.y*s)
        pw,ph:=int(math.round((wf.x+wf.w)*s)-x0),int(math.round((wf.y+wf.h)*s)-y0)
        if media_visual_image(visual,&view.frame,pw,ph) {
            r.page_source=&view.frame
            if !renderer_page_prepare(r) {glfw.SetWindowShouldClose(r.window,true);return true}
            top:=int((-(visual.rows-1))%%i64(ph));split:=f32(ph-top);v:=f32(top)/f32(ph)
            start:=len(a.vertices)
            renderer_quad(&a.vertices,x0,y0,x0+f32(pw),y0+split,0,v,1,1,Color{1,1,1,1})
            if top>0 {renderer_quad(&a.vertices,x0,y0+split,x0+f32(pw),y0+f32(ph),0,0,1,v,Color{1,1,1,1})}
            for &vertex in a.vertices[start:] {vertex.texture=1}
        }
        for f in decades {ui_rect(a,media_visual_x(wf,f),wf.y,hairline,wf.h,Color{1,1,1,0.07})}
        // Seconds-ago ticks; rows are physical pixels at 60 rows per second.
        rows_per_second:=f32(MEDIA_VISUAL_RATE)/MEDIA_HOP/s
        step:=1
        for candidate in ([5]int{1,2,5,10,30}) {step=candidate;if rows_per_second*f32(candidate)>=36 {break}}
        for k:=step;wf.y+rows_per_second*f32(k)<wf.y+wf.h-6;k+=step {
            y:=wf.y+rows_per_second*f32(k)
            ui_rect(a,wf.x,y,5,hairline,Color{1,1,1,0.4})
            media_text_right(a,fmt.tprintf("−%ds",k),wf.x-6,y,10,FAINT)
        }
    }
    if mouse_x>=sp.x&&mouse_x<sp.x+sp.w&&mouse_y>=sp.y&&mouse_y<plot_bottom {
        fraction:=(mouse_x-sp.x)/sp.w
        frequency:=MEDIA_FREQ_LOW*math.pow(MEDIA_FREQ_HIGH/MEDIA_FREQ_LOW,fraction)
        band:=clamp(int(fraction*MEDIA_BANDS),0,MEDIA_BANDS-1)
        ui_rect(a,mouse_x,sp.y,hairline,plot_bottom-sp.y,Color{1,1,1,0.4})
        media_visual_tag(a,fmt.tprintf("%s · %s dB",media_frequency_text(frequency),media_db_text(visual.spectrum[band])),mouse_x,sp.y+16,sp.x,sp.x+sp.w)
    }
    return true
}

// Title and format line from FFmpeg's stream report.
media_visual_info :: proc(diagnostic,path:string)->(title,detail:string) {
    tags:[5]string // title, artist, album, date, album artist
    codec,rate,layout,depth,bitrate,stream_bitrate:string
    metadata,allowed,audio_seen:=false,true,false
    text:=diagnostic
    for line in strings.split_lines_iterator(&text) {
        trimmed:=strings.trim_space(line)
        if strings.has_prefix(trimmed,"Stream #") {
            metadata=false
            allowed=!audio_seen&&strings.contains(trimmed,"Audio: ")
            if !allowed {continue}
            audio_seen=true
            at:=strings.index(trimmed,"Audio: ")
            parts:=strings.split(trimmed[at+len("Audio: "):],", ",context.temp_allocator)
            for part,i in parts {
                item:=strings.trim_space(part)
                if i==0 {
                    name:=item;if space:=strings.index_byte(item,' ');space>=0 {name=item[:space]}
                    codec=media_codec_name(name);continue
                }
                if strings.has_suffix(item," Hz") {
                    if hz,okay:=strconv.parse_f64(item[:len(item)-3]);okay {
                        number:=strings.trim_right(strings.trim_right(fmt.tprintf("%.2f",hz/1000),"0"),".")
                        rate=fmt.tprintf("%s kHz",number)
                    }
                    continue
                }
                if strings.contains(item,"kb/s") {
                    stream_bitrate=item;if paren:=strings.index_byte(item,'(');paren>0 {stream_bitrate=strings.trim_space(item[:paren])}
                    continue
                }
                if i==2 {
                    layout=item;if paren:=strings.index_byte(item,'(');paren>0 {layout=item[:paren]}
                    if layout!="" {layout=fmt.tprintf("%s%s",strings.to_upper(layout[:1],context.temp_allocator),layout[1:])}
                }
                if i==3 {depth=media_sample_depth(item)}
            }
            continue
        }
        if strings.has_prefix(trimmed,"Duration:") {
            metadata=false;allowed=false
            if at:=strings.index(trimmed,"bitrate: ");at>=0 {bitrate=strings.trim_space(trimmed[at+len("bitrate: "):])}
            continue
        }
        if trimmed=="Metadata:" {metadata=allowed;continue}
        if !metadata {continue}
        colon:=strings.index_byte(trimmed,':');if colon<=0 {continue}
        value:=strings.trim_space(trimmed[colon+1:]);if value=="" {continue}
        slot:= -1
        switch strings.to_lower(strings.trim_space(trimmed[:colon]),context.temp_allocator) {
        case "title":slot=0
        case "artist":slot=1
        case "album":slot=2
        case "date","year":slot=3
        case "album_artist":slot=4
        }
        if slot>=0&&tags[slot]=="" {tags[slot]=value}
    }
    artist:=tags[1] if tags[1]!="" else tags[4]
    name:=tags[0];if name=="" {name=filepath.stem(filepath.base(path))}
    title=fmt.aprintf("%s — %s",artist,name) if artist!="" else strings.clone(name)
    parts:=make([dynamic]string,context.temp_allocator)
    if tags[2]!="" {
        year:=tags[3];if len(year)>4 {year=year[:4]}
        append(&parts,fmt.tprintf("%s (%s)",tags[2],year) if year!="" else tags[2])
    }
    if stream_bitrate=="" {stream_bitrate=bitrate}
    for item in ([]string{codec,rate,layout,depth,stream_bitrate}) {if item!=""&&item!="N/A" {append(&parts,item)}}
    detail=strings.join(parts[:]," · ")
    return
}
media_codec_name :: proc(name:string)->string {
    switch name {
    case "mp3","mp3float":return "MP3"
    case "aac":return "AAC"
    case "flac":return "FLAC"
    case "alac":return "ALAC"
    case "opus":return "Opus"
    case "vorbis":return "Vorbis"
    case "wmav1","wmav2","wmapro":return "WMA"
    case "ac3":return "AC-3"
    case "eac3":return "E-AC-3"
    case "wavpack":return "WavPack"
    }
    if strings.has_prefix(name,"pcm_") {return "PCM"}
    return strings.to_upper(name,context.temp_allocator)
}
media_sample_depth :: proc(format:string)->string {
    if open:=strings.index_byte(format,'(');open>=0 {
        inner:=format[open+1:]
        if end:=strings.index(inner," bit");end>0 {return fmt.tprintf("%s-bit",inner[:end])}
    }
    switch strings.trim_right(format,"p") {
    case "u8":return "8-bit"
    case "s16":return "16-bit"
    case "s32":return "32-bit"
    case "s64":return "64-bit"
    }
    return ""
}

// Headless checks for --media-check: the tee delivers PCM and the analyser
// places a known tone in the right band at the right level.
media_visual_check :: proc(view:^Media_View)->bool {
    began:=time.tick_now()
    for time.tick_diff(began,time.tick_now())<2*time.Second {
        sync.mutex_lock(&view.mutex);visual:=view.visual;sync.mutex_unlock(&view.mutex)
        if visual!=nil {
            sync.mutex_lock(&visual.pcm_mutex);written:=visual.written;sync.mutex_unlock(&visual.pcm_mutex)
            if written>=MEDIA_FFT {
                fmt.printf("FFmpeg audio analysis stream: OK (%d frames) — %s · %s\n",written,visual.title,visual.detail)
                return media_visual_self_test()
            }
        }
        time.sleep(10*time.Millisecond)
    }
    fmt.eprintln("Audio analysis stream delivered no PCM.")
    return false
}
media_visual_self_test :: proc()->bool {
    visual:=media_visual_new();defer media_visual_destroy(visual)
    for i in 0..<MEDIA_FFT*2 {
        value:=f32(0.5*math.sin(2*math.PI*1000*f64(i)/MEDIA_VISUAL_RATE))
        visual.left[i]=value;visual.right[i]=value
    }
    visual.written=MEDIA_FFT*2
    media_visual_analyse(visual,visual.written)
    best:=0
    for b in 1..<MEDIA_BANDS {if visual.raw[b]>visual.raw[best] {best=b}}
    frequency:=MEDIA_FREQ_LOW*math.pow(MEDIA_FREQ_HIGH/MEDIA_FREQ_LOW,(f32(best)+0.5)/MEDIA_BANDS)
    okay:=abs(frequency-1000)<30&&abs(visual.raw[best]+6.02)<1.6
    if okay {fmt.printf("Spectrum analyser: OK (1 kHz −6 dBFS tone read as %.0f Hz, %.1f dB)\n",frequency,visual.raw[best])}
    else {fmt.eprintf("Spectrum analyser failed: peak %.0f Hz at %.1f dB\n",frequency,visual.raw[best])}
    return okay
}

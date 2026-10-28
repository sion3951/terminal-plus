package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

Device_Profile :: struct {
    name, target: string,
    // Runtime only, borrowed from the owning tab's stable session ID. Distinct
    // tabs need independent masters so closing one never disconnects another.
    control_id: string,
    // Zero means let OpenSSH choose the port from its normal configuration.
    port: u16,
    configured, saved: bool,
}
Device_Saved_Record :: struct {name,target:string,port:u16}
DEVICE_PROFILE_LIMIT :: 256
DEVICE_PROFILE_FILE_LIMIT :: 1024*1024

// Parse destinations, not shell command lines. OpenSSH is always executed with
// argv and '--'; aliases retain all their usual ssh_config settings.
device_target_parse :: proc(input:string)->(target:string,port:u16,error:string) {
    text:=strings.trim_space(input)
    if len(text)==0 {return "",0,"Enter an SSH host or user@host."}
    if len(text)>512 {return "",0,"SSH destination is too long."}
    for ch in text {
        if ch<=32||ch>=127 {return "",0,"Use an SSH alias, host, or user@host without spaces."}
    }
    user,host:="",text
    at:=strings.last_index(text,"@")
    if at>=0 {
        user=text[:at];host=text[at+1:]
        if len(user)==0||len(user)>128||user[0]=='-' {return "",0,"Enter a valid SSH username."}
        for ch in user {if !((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='_'||ch=='-'||ch=='.'||ch=='+') {return "",0,"Enter a valid SSH username."}}
    }
    if len(host)==0||host[0]=='-' {return "",0,"Enter a valid SSH hostname."}
    port_text:string
    if host[0]=='[' {
        end:=strings.index(host,"]")
        if end<2 {return "",0,"Use [IPv6 address]:port for an IPv6 port."}
        suffix:=host[end+1:]
        if len(suffix)>0 {
            if suffix[0]!=':'||len(suffix)==1 {return "",0,"Use [IPv6 address]:port for an IPv6 port."}
            port_text=suffix[1:]
        }
        host=host[1:end]
    } else {
        colons:=0
        for ch in host {if ch==':' {colons+=1}}
        if colons==1 {
            split:=strings.index(host,":")
            port_text=host[split+1:];host=host[:split]
            if port_text=="" {return "",0,"Port must be between 1 and 65535."}
        }
    }
    if len(host)==0||len(host)>255||host[0]=='-' {return "",0,"Enter a valid SSH hostname."}
    for ch in host {
        if !((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='_'||ch=='-'||ch=='.'||ch==':'||ch=='%') {return "",0,"Use a hostname, IP address, or SSH config alias."}
    }
    if port_text!="" {
        if len(port_text)>5 {return "",0,"Port must be between 1 and 65535."}
        for ch in port_text {if ch<'0'||ch>'9' {return "",0,"Port must be between 1 and 65535."}}
        value,ok:=strconv.parse_u64(port_text)
        if !ok||value==0||value>65535 {return "",0,"Port must be between 1 and 65535."}
        port=u16(value)
    }
    if user!="" {target=fmt.tprintf("%s@%s",user,host)} else {target=strings.clone(host,context.temp_allocator)}
    return
}

device_profile_equal :: proc(a,b:Device_Profile)->bool {
    if a.port!=b.port {return false}
    a_user,a_host:="",a.target
    b_user,b_host:="",b.target
    if at:=strings.last_index(a.target,"@");at>=0 {a_user=a.target[:at];a_host=a.target[at+1:]}
    if at:=strings.last_index(b.target,"@");at>=0 {b_user=b.target[:at];b_host=b.target[at+1:]}
    return a_user==b_user&&strings.equal_fold(a_host,b_host)
}

device_profiles_path :: proc()->string {
    root,err:=os.user_config_dir(context.temp_allocator)
    if err!=nil||root=="" {return ""}
    path,_:=filepath.join([]string{root,"minor-terminal","devices.json"},context.temp_allocator)
    return path
}

device_saved_records :: proc(path:string)->[]Device_Saved_Record {
    if path=="" {return nil}
    info,stat_error:=os.stat(path,context.temp_allocator)
    if stat_error!=nil||info.type!=.Regular||info.size<0||info.size>DEVICE_PROFILE_FILE_LIMIT {return nil}
    bytes,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil {return nil}
    records:[]Device_Saved_Record
    if json.unmarshal(bytes,&records,allocator=context.temp_allocator)!=nil {return nil}
    if len(records)>DEVICE_PROFILE_LIMIT {return records[:DEVICE_PROFILE_LIMIT]}
    return records
}

device_profile_add :: proc(profiles:^[dynamic]Device_Profile,profile:Device_Profile) {
    for &old in profiles^ {
        if device_profile_equal(old,profile) {
            old.configured=old.configured||profile.configured
            old.saved=old.saved||profile.saved
            return
        }
    }
    if len(profiles^)>=4096 {return}
    name:=profile.name
    if name=="" {name=profile.target}
    next:=profile
    next.name=strings.clone(name);next.target=strings.clone(profile.target)
    append(profiles,next)
}

device_profiles_load :: proc()->[dynamic]Device_Profile {
    profiles:=make([dynamic]Device_Profile)
    for record in device_saved_records(device_profiles_path()) {
        target,port,error:=device_target_parse(record.target)
        if error!=""||port!=0 {continue}
        name:=record.name
        if len(name)>128||strings.contains_any(name,"\r\n\x00") {name=target}
        device_profile_add(&profiles,Device_Profile{name=name,target=target,port=record.port,saved=true})
    }
    home:=os.get_env("HOME",context.temp_allocator)
    for host in ssh_discover_hosts(home) {
        target,port,error:=device_target_parse(host.host)
        if error!=""||port!=0 {continue}
        device_profile_add(&profiles,Device_Profile{name=host.name,target=target,port=host.port,configured=host.configured})
    }
    return profiles
}

// Only destinations and display names are persisted. Authentication remains
// entirely with OpenSSH and the user's existing keys/agent/configuration.
device_profile_save :: proc(profile:Device_Profile)->bool {
    target,parsed_port,error:=device_target_parse(profile.target)
    if error!=""||parsed_port!=0||len(profile.name)>128||strings.contains_any(profile.name,"\r\n\x00") {return false}
    path:=device_profiles_path()
    if path=="" {return false}
    records:=make([dynamic]Device_Saved_Record,context.temp_allocator)
    found:=false
    for record in device_saved_records(path) {
        old_target,old_port,old_error:=device_target_parse(record.target)
        if old_error!=""||old_port!=0 {continue}
        old:=Device_Profile{target=old_target,port=record.port}
        if device_profile_equal(old,profile) {
            if !found {append(&records,Device_Saved_Record{name=profile.name,target=target,port=profile.port});found=true}
        } else {append(&records,record)}
    }
    if !found {
        if len(records)>=DEVICE_PROFILE_LIMIT {return false}
        append(&records,Device_Saved_Record{name=profile.name,target=target,port=profile.port})
    }
    bytes,marshal_error:=json.marshal(records[:],{pretty=true},context.temp_allocator)
    if marshal_error!=nil {return false}
    directory:=filepath.dir(path)
    directory_error:=os.mkdir_all(directory,{.Read_User,.Write_User,.Execute_User})
    if directory_error!=nil&&directory_error!=.Exist {return false}
    temporary:=fmt.tprintf("%s.tmp-%d-%d",path,os.get_pid(),time.tick_now()._nsec)
    file,open_error:=os.open(temporary,{.Write,.Create,.Excl},{.Read_User,.Write_User})
    if open_error!=nil {return false}
    committed:=false
    defer {if !committed {os.remove(temporary)}}
    offset:=0
    for offset<len(bytes) {
        n,write_error:=os.write(file,bytes[offset:])
        if write_error!=nil||n<=0 {os.close(file);return false}
        offset+=n
    }
    sync_error:=os.sync(file)
    close_error:=os.close(file)
    if sync_error!=nil||close_error!=nil {return false}
    if os.rename(temporary,path)!=nil {return false}
    committed=true
    return true
}

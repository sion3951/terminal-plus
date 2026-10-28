#+build linux
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import posix "core:sys/posix"

// The row cache and pending spool stay bounded. The full index lives on disk,
// so retaining millions of rows does not require millions of heap allocations.
HISTORY_RECENT_BYTES :: 32*1024*1024
HISTORY_QUEUE_BYTES :: 32*1024*1024
HISTORY_VIEW_CELLS :: 512*1024
HISTORY_CELL_MAX_BYTES :: 32
TERMINAL_MAX_COLS :: 65535
TERMINAL_MAX_CELLS :: 4*1024*1024
HISTORY_FILE_HEADER :: 16
HISTORY_RECORD_HEADER :: 16

History_Page :: struct {start,cols:int,rows:[dynamic][]Cell,epoch,serial:u64}
Terminal_History :: struct {
    mutex:sync.Mutex,
    cond:sync.Cond,
    worker:^thread.Thread,
    notify:proc(),
    stopping,closing,clear_pending,read_pending,page_ready,restoring,restore_ready:bool,
    persistent_id:string,
    restored_rows:int,
    epoch,request_serial:u64,
    queue:[dynamic]u8,
    pending_bytes,queue_limit,written_rows:int,
    data_bytes:i64,
    request_start,request_count,request_cols:int,
    request_cache_cells:int,
    page:History_Page,
    error:[256]u8,
    error_len:int,
}

history_page_destroy :: proc(page:^History_Page) {
    for row in page.rows {delete(row)}
    delete(page.rows);page^={}
}
history_notify :: proc(h:^Terminal_History) {
    sync.mutex_lock(&h.mutex);notify:=h.notify;sync.mutex_unlock(&h.mutex)
    if notify!=nil {notify()}
}
history_error_set :: proc(h:^Terminal_History,epoch:u64,message:string) {
    sync.mutex_lock(&h.mutex)
    if h.epoch==epoch {h.error_len=copy(h.error[:],transmute([]u8)message)}
    sync.mutex_unlock(&h.mutex)
    history_notify(h)
}
terminal_set_notify :: proc(t:^Terminal,notify:proc()) {
    t.history_notify=notify
    if h:=t.archive;h!=nil {sync.mutex_lock(&h.mutex);h.notify=notify;sync.mutex_unlock(&h.mutex)}
}
terminal_history_error :: proc(t:^Terminal)->string {
    if t.persistent!=nil {return local_session_error(t)}
    h:=t.archive;if h==nil {return ""}
    sync.mutex_lock(&h.mutex);defer sync.mutex_unlock(&h.mutex)
    return strings.clone(string(h.error[:h.error_len]),context.temp_allocator)
}
terminal_history_stats :: proc(t:^Terminal)->(rows,pending_bytes:int,disk_bytes:i64) {
    h:=t.archive;if h==nil {return}
    sync.mutex_lock(&h.mutex);defer sync.mutex_unlock(&h.mutex)
    return h.written_rows,h.pending_bytes,max(0,h.data_bytes-HISTORY_FILE_HEADER)+i64(h.written_rows)*16
}
terminal_history_loading :: proc(t:^Terminal)->bool {
    if t.persistent!=nil {return local_session_loading(t)}
    h:=t.archive;if h==nil {return false}
    sync.mutex_lock(&h.mutex);defer sync.mutex_unlock(&h.mutex)
    return h.restoring||(h.read_pending&&!h.page_ready)
}
history_row_reserve :: proc(cols:int)->int {return cols*HISTORY_CELL_MAX_BYTES+64}
history_ensure :: proc(t:^Terminal)->^Terminal_History {
    if t.archive!=nil {return t.archive}
    h:=new(Terminal_History)
    h.epoch=t.history_epoch;h.notify=t.history_notify
    h.queue_limit=max(HISTORY_QUEUE_BYTES,history_row_reserve(t.cols)*t.rows*2)
    h.worker=thread.create(history_worker)
    if h.worker==nil {h.error_len=copy(h.error[:],transmute([]u8)string("Cannot start scrollback storage worker."))}
    else {h.worker.data=h;thread.start(h.worker)}
    t.archive=h
    return h
}
terminal_history_restore :: proc(t:^Terminal,id:string)->bool {
    if t.archive!=nil||t.history_count!=0||len(id)==0||len(id)>64 {return false}
    for ch in id {if !((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='-'||ch=='_') {return false}}
    h:=history_ensure(t)
    sync.mutex_lock(&h.mutex)
    h.persistent_id=strings.clone(id);h.restoring=true
    sync.mutex_unlock(&h.mutex);sync.cond_signal(&h.cond)
    return h.worker!=nil
}
terminal_history_is_restoring :: proc(t:^Terminal)->bool {
    h:=t.archive;if h==nil {return false}
    sync.mutex_lock(&h.mutex);defer sync.mutex_unlock(&h.mutex)
    return h.restoring
}
terminal_history_allow :: proc(t:^Terminal,rows:int)->bool {
    if rows<=0||t.alternate {return true}
    needed:=history_row_reserve(t.cols)*rows
    h:=t.archive
    if h==nil {t.history_feed_budget=max(HISTORY_QUEUE_BYTES,history_row_reserve(t.cols)*t.rows*2);return true}
    if t.history_feed_budget>=needed {return true}
    sync.mutex_lock(&h.mutex)
    room:=h.queue_limit-h.pending_bytes
    if h.error_len>0 {room=0}
    sync.mutex_unlock(&h.mutex)
    t.history_feed_budget=room
    return room>=needed
}
terminal_history_update_limit :: proc(t:^Terminal) {
    h:=t.archive;if h==nil {return}
    sync.mutex_lock(&h.mutex)
    h.queue_limit=max(HISTORY_QUEUE_BYTES,history_row_reserve(t.cols)*t.rows*2,h.pending_bytes)
    sync.mutex_unlock(&h.mutex)
}
terminal_history_feed_begin :: proc(t:^Terminal) {
    t.history_feed_budget=0
    h:=t.archive
    if h!=nil {
        sync.mutex_lock(&h.mutex)
        if h.error_len==0 {t.history_feed_budget=h.queue_limit-h.pending_bytes}
        sync.mutex_unlock(&h.mutex)
    }
}
terminal_history_destroy :: proc(t:^Terminal) {
    h:=t.archive
    if h!=nil {
        sync.mutex_lock(&h.mutex)
        if h.persistent_id!="" {h.closing=true} else {h.stopping=true}
        sync.mutex_unlock(&h.mutex);sync.cond_signal(&h.cond)
        if h.worker!=nil {thread.join(h.worker);thread.destroy(h.worker)}
        if h.persistent_id!=""&&h.error_len>0 {fmt.eprintf("Scrollback could not be fully saved: %s\n",string(h.error[:h.error_len]))}
        delete(h.queue);delete(h.persistent_id);history_page_destroy(&h.page);free(h);t.archive=nil
    }
    history_page_destroy(&t.history_view);delete(t.history_encoded)
}
terminal_clear_history :: proc(t:^Terminal) {
    if t.persistent!=nil {local_session_clear(t);return}
    for &line in t.history {delete(line);line=nil}
    t.history_start=0;t.history_recent_count=0;t.history_count=0;t.history_recent_bytes=0
    t.history_epoch+=1;t.history_feed_budget=0;t.history_checkpointed=false
    history_page_destroy(&t.history_view)
    h:=t.archive
    if h!=nil {
        sync.mutex_lock(&h.mutex)
        h.epoch=t.history_epoch;h.clear_pending=true;h.read_pending=false;h.page_ready=false;h.restore_ready=false
        h.pending_bytes=0;h.error_len=0;clear(&h.queue)
        old:=h.page;h.page={}
        sync.mutex_unlock(&h.mutex)
        history_page_destroy(&old)
        if h.worker==nil {
            h.worker=thread.create(history_worker)
            if h.worker!=nil {h.worker.data=h;thread.start(h.worker)}
            else {history_error_set(h,t.history_epoch,"Cannot start scrollback storage worker.")}
        }
        sync.cond_signal(&h.cond)
    }
    t.dirty=true
}
terminal_history_poll :: proc(t:^Terminal)->bool {
    h:=t.archive;if h==nil {return false}
    changed:=false
    sync.mutex_lock(&h.mutex)
    if h.restore_ready {
        t.history_count=h.restored_rows
        h.restore_ready=false;h.restoring=false;changed=true
    }
    page:=History_Page{}
    ready:=h.page_ready
    if ready {page=h.page;h.page={};h.page_ready=false}
    sync.mutex_unlock(&h.mutex)
    if changed {sync.cond_signal(&h.cond)}
    if ready {
        if page.epoch==t.history_epoch {history_page_destroy(&t.history_view);t.history_view=page;changed=true}
        else {history_page_destroy(&page)}
    }
    if changed {t.dirty=true}
    return changed
}
terminal_history_prepare :: proc(t:^Terminal,scroll_offset:int) {
    if t.persistent!=nil {local_session_history_prepare(t,scroll_offset);return}
    if t.alternate||scroll_offset<=0||t.history_count==0 {return}
    start:=max(0,t.history_count-clamp(scroll_offset,0,t.history_count))
    end:=min(t.history_count-t.history_recent_count,start+t.rows)
    if end<=start {return}
    view:=&t.history_view
    if view.epoch==t.history_epoch&&view.start<=start&&view.start+len(view.rows)>=end {
        if view.cols>=t.cols {return}
    }
    h:=t.archive;if h==nil {return}
    cache_cells:=max(HISTORY_VIEW_CELLS,t.cols*t.rows)
    maximum_rows:=max(1,cache_cells/t.cols)
    count:=min(maximum_rows,max(t.rows*3,128))
    // Center prefetch around the viewport, within the archived portion.
    first:=max(0,start-max(0,(count-t.rows)/2))
    count=min(count,t.history_count-t.history_recent_count-first)
    sync.mutex_lock(&h.mutex)
    if h.error_len>0||h.restoring {sync.mutex_unlock(&h.mutex);return}
    if h.read_pending&&h.request_start<=start&&h.request_start+h.request_count>=end&&h.request_cols==t.cols {
        sync.mutex_unlock(&h.mutex);return
    }
    h.request_start=first;h.request_count=count;h.request_cols=t.cols;h.request_cache_cells=cache_cells
    h.request_serial+=1;h.read_pending=true
    sync.mutex_unlock(&h.mutex);sync.cond_signal(&h.cond)
}

history_u32 :: proc(bytes:[]u8,offset:int)->u32 {return u32(bytes[offset])|u32(bytes[offset+1])<<8|u32(bytes[offset+2])<<16|u32(bytes[offset+3])<<24}
history_u64 :: proc(bytes:[]u8,offset:int)->u64 {return u64(history_u32(bytes,offset))|u64(history_u32(bytes,offset+4))<<32}
history_put_u32 :: proc(bytes:^[dynamic]u8,value:u32) {append(bytes,u8(value),u8(value>>8),u8(value>>16),u8(value>>24))}
history_put_u64 :: proc(bytes:^[dynamic]u8,value:u64) {history_put_u32(bytes,u32(value));history_put_u32(bytes,u32(value>>32))}
history_style_equal :: proc(a,b:Cell)->bool {return a.fg==b.fg&&a.bg==b.bg&&a.bold==b.bold&&a.italic==b.italic&&a.underline==b.underline&&a.inverse==b.inverse}
history_put_style :: proc(bytes:^[dynamic]u8,cell:Cell) {
    history_put_u32(bytes,cell.fg);history_put_u32(bytes,cell.bg)
    flags:u8
    if cell.bold {flags|=1};if cell.italic {flags|=2};if cell.underline {flags|=4};if cell.inverse {flags|=8}
    append(bytes,flags)
}
history_put_cell :: proc(bytes:^[dynamic]u8,cell:Cell) {
    marks:=0
    for mark in cell.combining {if mark!=0 {marks+=1}}
    append(bytes,(cell.width&3)|(u8(marks)<<2))
    encoded,n:=utf8.encode_rune(cell.ch);append(bytes,..encoded[:n])
    for mark in cell.combining {if mark!=0 {encoded,n=utf8.encode_rune(mark);append(bytes,..encoded[:n])}}
}
history_encode_row :: proc(t:^Terminal,row:[]Cell) {
    bytes:=&t.history_encoded;clear(bytes)
    cursor:=0
    for cursor<len(row) {
        repeated:=1
        for cursor+repeated<len(row)&&row[cursor+repeated]==row[cursor] {repeated+=1}
        if repeated>=4 {
            append(bytes,1);history_put_u32(bytes,u32(repeated));history_put_style(bytes,row[cursor]);history_put_cell(bytes,row[cursor]);cursor+=repeated
        } else {
            start:=cursor;cursor+=repeated
            for cursor<len(row)&&history_style_equal(row[start],row[cursor]) {
                run:=1
                for cursor+run<len(row)&&row[cursor+run]==row[cursor] {run+=1}
                if run>=4 {break}
                cursor+=run
            }
            append(bytes,0);history_put_u32(bytes,u32(cursor-start));history_put_style(bytes,row[start])
            for cell in row[start:cursor] {history_put_cell(bytes,cell)}
        }
    }
}
history_enqueue :: proc(t:^Terminal,row:[]Cell) {
    h:=history_ensure(t)
    history_encode_row(t,row)
    bytes:=len(t.history_encoded)+HISTORY_RECORD_HEADER
    sync.mutex_lock(&h.mutex)
    // Admission is checked before a scrolling instruction; the only other
    // producer is this same terminal thread, while the worker frees capacity.
    assert(bytes<=h.queue_limit-h.pending_bytes)
    history_put_u32(&h.queue,u32(len(t.history_encoded)));history_put_u32(&h.queue,u32(len(row)))
    history_put_u64(&h.queue,history_checksum(t.history_encoded[:]))
    append(&h.queue,..t.history_encoded[:]);h.pending_bytes+=bytes
    sync.mutex_unlock(&h.mutex)
    t.history_feed_budget=max(0,t.history_feed_budget-bytes)
    sync.cond_signal(&h.cond)
}

History_Decoder :: struct {bytes:[]u8,offset:int,valid:bool}
history_take :: proc(d:^History_Decoder,n:int)->[]u8 {
    if !d.valid||n<0||d.offset>len(d.bytes)-n {d.valid=false;return nil}
    value:=d.bytes[d.offset:d.offset+n];d.offset+=n;return value
}
history_read_rune :: proc(d:^History_Decoder)->rune {
    if !d.valid||d.offset>=len(d.bytes) {d.valid=false;return 0}
    ch,n:=utf8.decode_rune(d.bytes[d.offset:]);if n<=0 {d.valid=false;return 0}
    d.offset+=n;return ch
}
history_decode_row :: proc(bytes:[]u8,cols,max_cols:int)->(row:[]Cell,ok:bool) {
    if cols<1||cols>TERMINAL_MAX_COLS||max_cols<1 {return nil,false}
    row=make([]Cell,min(cols,max_cols))
    d:=History_Decoder{bytes=bytes,valid=true}
    position:=0
    for position<cols&&d.valid {
        head:=history_take(&d,14)
        if !d.valid {break}
        repeated:=head[0]==1
        if head[0]>1 {d.valid=false;break}
        count:=int(history_u32(head,1))
        if count<1||count>cols-position {d.valid=false;break}
        flags:=head[13]
        style:=Cell{fg=history_u32(head,5),bg=history_u32(head,9),bold=flags&1!=0,italic=flags&2!=0,underline=flags&4!=0,inverse=flags&8!=0}
        for i in 0..<count {
            cell:=style
            if !repeated||i==0 {
                cell.combining={}
                metadata:=history_take(&d,1);if !d.valid {break}
                cell.width=metadata[0]&3
                if cell.width>2 {d.valid=false;break}
                cell.ch=history_read_rune(&d)
                marks:=int((metadata[0]>>2)&3)
                for j in 0..<marks {cell.combining[j]=history_read_rune(&d)}
                style=cell
            }
            if position<len(row) {row[position]=cell}
            position+=1
        }
    }
    ok=d.valid&&position==cols&&d.offset==len(bytes)
    if !ok {delete(row);row=nil}
    return
}

history_open_file :: proc()->(fd:posix.FD,error:string) {
    fd= -1
    cache,cache_error:=os.user_cache_dir(context.temp_allocator)
    if cache_error!=nil||cache=="" {return -1,"Cannot locate disk cache for scrollback."}
    directory_error:=os.mkdir_all(cache,{.Read_User,.Write_User,.Execute_User})
    if directory_error!=nil&&directory_error!=.Exist {return -1,"Cannot create disk cache for scrollback."}
    path:=strings.clone_to_cstring(fmt.tprintf("%s/minor-terminal-history-XXXXXX",cache))
    defer delete(path)
    fd=history_mkostemp(path,c.int(posix.O_CLOEXEC))
    if fd<0 {return -1,fmt.tprintf("Cannot create scrollback file: %v",posix.errno())}
    if posix.unlink(path)!=.OK {posix.close(fd);return -1,"Cannot unlink private scrollback file."}
    if posix.fcntl(fd,.SETFD,c.int(posix.FD_CLOEXEC))<0 {posix.close(fd);return -1,"Cannot protect private scrollback file."}
    return
}
history_write :: proc(fd:posix.FD,bytes:[]u8,offset:i64)->bool {
    used:=0
    for used<len(bytes) {
        remaining:=len(bytes)-used
        n:=posix.pwrite(fd,&bytes[used],c.size_t(remaining),posix.off_t(offset+i64(used)))
        if n<0&&posix.errno()==.EINTR {continue}
        if n<=0 {return false};used+=int(n)
    }
    return true
}
history_read :: proc(fd:posix.FD,bytes:[]u8,offset:i64)->bool {
    used:=0
    for used<len(bytes) {
        remaining:=len(bytes)-used
        n:=posix.pread(fd,&bytes[used],c.size_t(remaining),posix.off_t(offset+i64(used)))
        if n<0&&posix.errno()==.EINTR {continue}
        if n<=0 {return false};used+=int(n)
    }
    return true
}
history_read_page :: proc(data_fd,index_fd:posix.FD,start,count,max_cols,cache_cells:int,epoch,serial:u64)->(page:History_Page,error:string) {
    page={start=start,cols=max_cols,epoch=epoch,serial=serial}
    if count<=0 {return}
    index:=make([]u8,count*16);defer delete(index)
    if !history_read(index_fd,index,HISTORY_FILE_HEADER+i64(start)*16) {return page,"Cannot read scrollback index."}
    buffer:=make([dynamic]u8);defer delete(buffer)
    cells:=0
    for row in 0..<count {
        offset:=history_u64(index,row*16);size:=int(history_u32(index,row*16+8));cols:=int(history_u32(index,row*16+12))
        if cols<1||cols>TERMINAL_MAX_COLS||size<1||size>history_row_reserve(cols)||offset>u64(max(i64)) {return page,"Invalid scrollback record."}
        if cells+min(cols,max_cols)>cache_cells {break}
        if offset<HISTORY_FILE_HEADER+HISTORY_RECORD_HEADER {return page,"Invalid scrollback offset."}
        resize(&buffer,size+HISTORY_RECORD_HEADER)
        if !history_read(data_fd,buffer[:],i64(offset)-HISTORY_RECORD_HEADER) {return page,"Cannot read scrollback data."}
        payload:=buffer[HISTORY_RECORD_HEADER:]
        if int(history_u32(buffer[:],0))!=size||int(history_u32(buffer[:],4))!=cols||history_checksum(payload)!=history_u64(buffer[:],8) {return page,"Scrollback record checksum failed."}
        decoded,ok:=history_decode_row(payload,cols,max_cols)
        if !ok {return page,"Invalid scrollback row."}
        append(&page.rows,decoded);cells+=len(decoded)
    }
    return
}

foreign import history_lib "system:c"
foreign history_lib {
    @(link_name="mkostemp") history_mkostemp :: proc(template:cstring,flags:c.int)->posix.FD ---
    @(link_name="flock") history_flock :: proc(fd:posix.FD,operation:c.int)->c.int ---
}
history_checksum :: proc(bytes:[]u8)->u64 {
    value:u64=14695981039346656037
    for b in bytes {value=(value~u64(b))*1099511628211}
    return value
}
history_file_header :: proc(data:bool)->[HISTORY_FILE_HEADER]u8 {
    bytes:[HISTORY_FILE_HEADER]u8
    if data {copy(bytes[:],"MTHDATA2")} else {copy(bytes[:],"MTHIDX02")}
    bytes[8]=2
    return bytes
}
history_reset_files :: proc(data_fd,index_fd:posix.FD)->bool {
    if data_fd<0||index_fd<0 {return true}
    data_header,index_header:=history_file_header(true),history_file_header(false)
    return posix.ftruncate(data_fd,0)==.OK&&posix.ftruncate(index_fd,0)==.OK&&history_write(data_fd,data_header[:],0)&&history_write(index_fd,index_header[:],0)
}
history_open_persistent :: proc(id,extension:string)->(fd:posix.FD,error:string) {
    fd= -1
    state,state_error:=os.user_state_dir(context.temp_allocator)
    if state_error!=nil||state=="" {return -1,"Cannot locate persistent scrollback storage."}
    directory:=fmt.tprintf("%s/minor-terminal/history",state)
    directory_error:=os.mkdir_all(directory,{.Read_User,.Write_User,.Execute_User})
    if directory_error!=nil&&directory_error!=.Exist {return -1,"Cannot create persistent scrollback directory."}
    path:=strings.clone_to_cstring(fmt.tprintf("%s/%s.%s",directory,id,extension),context.temp_allocator)
    fd=posix.open(path,{.RDWR,.CREAT,.CLOEXEC,.NOFOLLOW},posix.mode_t{.IRUSR,.IWUSR})
    if fd<0 {return -1,fmt.tprintf("Cannot open persistent scrollback: %v",posix.errno())}
    info:posix.stat_t
    if posix.fstat(fd,&info)!=.OK||!posix.S_ISREG(info.st_mode)||info.st_uid!=posix.getuid() {posix.close(fd);return -1,"Persistent scrollback must be a regular user-owned file."}
    if posix.fchmod(fd,{.IRUSR,.IWUSR})!=.OK {posix.close(fd);return -1,"Cannot protect persistent scrollback file."}
    if extension=="index"&&history_flock(fd,6)!=0 {posix.close(fd);return -1,"This scrollback is already open in another app instance."}
    return
}
history_valid_record :: proc(data_fd:posix.FD,position,data_end:i64,buffer:^[dynamic]u8)->(bytes,cols:int,valid:bool) {
    if position<HISTORY_FILE_HEADER||data_end-position<HISTORY_RECORD_HEADER {return}
    header:[HISTORY_RECORD_HEADER]u8
    if !history_read(data_fd,header[:],position) {return}
    bytes=int(history_u32(header[:],0));cols=int(history_u32(header[:],4))
    if cols<1||cols>TERMINAL_MAX_COLS||bytes<1||bytes>history_row_reserve(cols)||i64(bytes)>data_end-position-HISTORY_RECORD_HEADER {return}
    resize(buffer,bytes)
    if !history_read(data_fd,buffer[:],position+HISTORY_RECORD_HEADER)||history_checksum(buffer[:])!=history_u64(header[:],8) {return}
    decoded,ok:=history_decode_row(buffer[:],cols,1);delete(decoded)
    valid=ok
    return
}
history_recover :: proc(h:^Terminal_History,epoch:u64,data_fd,index_fd:posix.FD)->(rows:int,data_end:i64,error:string) {
    data_size:=i64(posix.lseek(data_fd,0,.END));index_size:=i64(posix.lseek(index_fd,0,.END))
    if data_size<0||index_size<0 {return 0,0,"Cannot inspect persistent scrollback files."}
    if data_size==0&&index_size==0 {
        if !history_reset_files(data_fd,index_fd) {return 0,0,"Cannot initialize scrollback files."}
        return 0,HISTORY_FILE_HEADER,""
    }
    data_header,index_header:[HISTORY_FILE_HEADER]u8
    expected_data,expected_index:=history_file_header(true),history_file_header(false)
    if data_size<HISTORY_FILE_HEADER||!history_read(data_fd,data_header[:],0)||data_header!=expected_data {return 0,0,"Unsupported or corrupt scrollback header; clear history to reset it."}
    if index_size<HISTORY_FILE_HEADER||!history_read(index_fd,index_header[:],0)||index_header!=expected_index {
        if posix.ftruncate(index_fd,0)!=.OK||!history_write(index_fd,expected_index[:],0) {return 0,0,"Cannot recover scrollback index header."}
        index_size=HISTORY_FILE_HEADER
    }
    rows=int((index_size-HISTORY_FILE_HEADER)/16)
    index:[16]u8
    buffer:=make([dynamic]u8);defer delete(buffer)
    data_end=HISTORY_FILE_HEADER
    // A partial/corrupt tail index is discarded; the checksummed data records
    // can recover a fully written row that had not reached the index yet.
    for rows>0 {
        sync.mutex_lock(&h.mutex);cancelled:=h.stopping||h.closing||h.epoch!=epoch;sync.mutex_unlock(&h.mutex)
        if cancelled {return 0,-1,""}
        if history_read(index_fd,index[:],HISTORY_FILE_HEADER+i64(rows-1)*16) {
            offset:=history_u64(index[:],0);size:=int(history_u32(index[:],8));cols:=int(history_u32(index[:],12))
            if offset>=HISTORY_FILE_HEADER+HISTORY_RECORD_HEADER&&offset<=u64(max(i64)) {
                actual_size,actual_cols,valid:=history_valid_record(data_fd,i64(offset)-HISTORY_RECORD_HEADER,data_size,&buffer)
                if valid&&actual_size==size&&actual_cols==cols {data_end=i64(offset)+i64(size);break}
            }
        }
        rows-=1
    }
    recovered:=make([dynamic]u8);defer delete(recovered)
    base_rows:=rows
    for data_end<data_size {
        sync.mutex_lock(&h.mutex);cancelled:=h.stopping||h.closing||h.epoch!=epoch;sync.mutex_unlock(&h.mutex)
        if cancelled {return 0,-1,""}
        size,cols,valid:=history_valid_record(data_fd,data_end,data_size,&buffer)
        if !valid {break}
        if rows>=max(int)/16 {return rows,data_end,"Scrollback index capacity exceeded."}
        history_put_u64(&recovered,u64(data_end)+HISTORY_RECORD_HEADER);history_put_u32(&recovered,u32(size));history_put_u32(&recovered,u32(cols))
        rows+=1;data_end+=HISTORY_RECORD_HEADER+i64(size)
        if len(recovered)>=64*1024 {
            if !history_write(index_fd,recovered[:],HISTORY_FILE_HEADER+i64(base_rows)*16) {return 0,0,"Cannot recover scrollback index."}
            base_rows=rows;clear(&recovered)
        }
    }
    if len(recovered)>0&&!history_write(index_fd,recovered[:],HISTORY_FILE_HEADER+i64(base_rows)*16) {return 0,0,"Cannot recover scrollback index."}
    if posix.ftruncate(data_fd,posix.off_t(data_end))!=.OK||posix.ftruncate(index_fd,posix.off_t(HISTORY_FILE_HEADER+i64(rows)*16))!=.OK {return 0,0,"Cannot repair scrollback tail."}
    return
}
terminal_history_checkpoint :: proc(t:^Terminal)->bool {
    h:=t.archive
    if h==nil||h.persistent_id==""||t.history_checkpointed {return true}
    // No input is accepted before restore completes, so an early close has
    // no new screen contents to checkpoint and can cancel a long repair scan.
    terminal_history_poll(t)
    if terminal_history_is_restoring(t) {return true}
    last:= -1
    for y in 0..<t.rows {
        for cell in t.normal_screen[y*t.cols:(y+1)*t.cols] {
            if (cell.ch!=0&&cell.ch!=' ')||cell.bg!=TERMINAL_BG||cell.inverse||cell.underline {last=y;break}
        }
    }
    cursor:=Terminal_Cursor{x=t.cursor_x,y=t.cursor_y}
    if t.alternate {cursor=t.normal_cursor}
    if cursor.y>0||cursor.x>0 {last=max(last,cursor.y)}
    alternate:=t.alternate;t.alternate=false
    defer {t.alternate=alternate}
    for y in 0..=last {
        terminal_history_feed_begin(t)
        for !terminal_history_allow(t,1) {
            if terminal_history_error(t)!="" {return false}
            time.sleep(time.Millisecond);terminal_history_feed_begin(t)
        }
        terminal_history_push(t,t.normal_screen[y*t.cols:(y+1)*t.cols])
    }
    t.history_checkpointed=true
    return true
}
history_worker :: proc(worker:^thread.Thread) {
    h:=cast(^Terminal_History)worker.data
    data_fd,index_fd:posix.FD= -1,-1
    defer {if data_fd>=0 {posix.close(data_fd)};if index_fd>=0 {posix.close(index_fd)}}
    batch:=make([dynamic]u8);defer delete(batch)
    index:=make([dynamic]u8);defer delete(index)
    epoch:u64
    written:=0
    data_size:i64=HISTORY_FILE_HEADER
    last_sync:=time.tick_now()
    for {
        sync.mutex_lock(&h.mutex)
        read_ready:=h.read_pending&&h.request_start+h.request_count<=written
        need_open:=(data_fd<0||index_fd<0)&&(h.restoring||len(h.queue)>0||h.clear_pending)
        for !h.stopping&&!h.closing&&!h.clear_pending&&(h.error_len>0||h.restoring||len(h.queue)==0)&&!read_ready&&!(need_open&&h.error_len==0) {
            sync.cond_wait(&h.cond,&h.mutex)
            read_ready=h.read_pending&&h.request_start+h.request_count<=written
            need_open=(data_fd<0||index_fd<0)&&(h.restoring||len(h.queue)>0||h.clear_pending)
        }
        if h.stopping {sync.mutex_unlock(&h.mutex);break}
        epoch=h.epoch
        if h.closing&&h.error_len>0 {sync.mutex_unlock(&h.mutex);break}
        if need_open&&h.error_len==0 {
            id:=h.persistent_id;clearing:=h.clear_pending
            sync.mutex_unlock(&h.mutex)
            error:string
            if id!="" {
                if data_fd<0 {data_fd,error=history_open_persistent(id,"data")}
                if error==""&&index_fd<0 {index_fd,error=history_open_persistent(id,"index")}
            } else {
                if data_fd<0 {data_fd,error=history_open_file()}
                if error==""&&index_fd<0 {index_fd,error=history_open_file()}
            }
            if error==""&&!clearing {
                if id!="" {written,data_size,error=history_recover(h,epoch,data_fd,index_fd)}
                else if !history_reset_files(data_fd,index_fd) {error="Cannot initialize scrollback files."}
            }
            if data_size<0 {continue}
            if error!="" {history_error_set(h,epoch,error)}
            else {
                sync.mutex_lock(&h.mutex)
                if h.epoch==epoch&&!h.clear_pending {
                    h.written_rows=written;h.data_bytes=data_size
                    if h.restoring {h.restored_rows=written;h.restore_ready=true}
                }
                sync.mutex_unlock(&h.mutex);history_notify(h)
            }
            continue
        }
        if h.clear_pending&&data_fd>=0&&index_fd>=0 {
            sync.mutex_unlock(&h.mutex)
            good:=history_reset_files(data_fd,index_fd)
            clear(&batch);written=0;data_size=HISTORY_FILE_HEADER
            sync.mutex_lock(&h.mutex)
            if h.epoch==epoch {
                h.clear_pending=false;h.written_rows=0;h.data_bytes=data_size
                if h.restoring {h.restored_rows=0;h.restore_ready=true}
            }
            sync.mutex_unlock(&h.mutex)
            if !good {history_error_set(h,epoch,"Cannot clear scrollback files.")}
            history_notify(h);continue
        }
        if h.closing&&len(h.queue)==0&&len(batch)==0 {
            sync.mutex_unlock(&h.mutex)
            if data_fd>=0&&index_fd>=0&&(posix.fsync(data_fd)!=.OK||posix.fsync(index_fd)!=.OK) {history_error_set(h,epoch,"Could not sync persistent scrollback to disk.")}
            break
        }
        if read_ready&&data_fd>=0&&index_fd>=0&&!h.closing {
            start,count,cols,cells,serial:=h.request_start,h.request_count,h.request_cols,h.request_cache_cells,h.request_serial
            sync.mutex_unlock(&h.mutex)
            page,error:=history_read_page(data_fd,index_fd,start,count,cols,cells,epoch,serial)
            sync.mutex_lock(&h.mutex)
            valid:=h.epoch==epoch&&h.request_serial==serial&&!h.stopping&&!h.closing
            old:=History_Page{}
            if valid {old=h.page;h.page=page;h.page_ready=true;h.read_pending=false}
            sync.mutex_unlock(&h.mutex)
            history_page_destroy(&old)
            if !valid {history_page_destroy(&page)}
            if error!="" {history_error_set(h,epoch,error)}
            history_notify(h);continue
        }
        if h.error_len>0||h.restoring {sync.mutex_unlock(&h.mutex);continue}
        batch,h.queue=h.queue,batch
        sync.mutex_unlock(&h.mutex)
        clear(&index)
        position:=0;rows:=0;valid:=true
        for position<len(batch) {
            if position>len(batch)-HISTORY_RECORD_HEADER {valid=false;break}
            size:=int(history_u32(batch[:],position));cols:=int(history_u32(batch[:],position+4))
            if cols<1||cols>TERMINAL_MAX_COLS||size<1||size>history_row_reserve(cols)||size>len(batch)-position-HISTORY_RECORD_HEADER {valid=false;break}
            history_put_u64(&index,u64(data_size)+u64(position)+HISTORY_RECORD_HEADER);history_put_u32(&index,u32(size));history_put_u32(&index,u32(cols))
            position+=size+HISTORY_RECORD_HEADER;rows+=1
        }
        if rows>max(int)-written||data_size>max(i64)-i64(len(batch))||written>(max(int)-HISTORY_FILE_HEADER)/16-rows {valid=false}
        good:=valid&&history_write(data_fd,batch[:],data_size)&&history_write(index_fd,index[:],HISTORY_FILE_HEADER+i64(written)*16)
        if good {
            written+=rows;data_size+=i64(len(batch))
            sync.mutex_lock(&h.mutex)
            if h.epoch==epoch {h.pending_bytes-=len(batch);h.written_rows=written;h.data_bytes=data_size}
            sync.mutex_unlock(&h.mutex)
            clear(&batch)
            if h.persistent_id!=""&&time.duration_seconds(time.tick_diff(last_sync,time.tick_now()))>=2 {
                if posix.fsync(data_fd)!=.OK||posix.fsync(index_fd)!=.OK {history_error_set(h,epoch,"Could not sync persistent scrollback to disk.")}
                last_sync=time.tick_now()
            }
            history_notify(h)
        } else {
            message:="Scrollback disk write failed; output is paused. Clear history to retry."
            if !valid {message="Scrollback index capacity exceeded; output is paused."}
            history_error_set(h,epoch,message)
            // Retain the failed batch until clear or close, so no accepted row
            // disappears merely because the disk became full/unavailable.
        }
        free_all(context.temp_allocator)
    }
}

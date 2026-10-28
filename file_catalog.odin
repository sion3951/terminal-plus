#+build linux
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import glfw "vendor:glfw"

foreign import file_sqlite "system:sqlite3"
foreign file_sqlite {
    @(link_name="sqlite3_open_v2") catalog_sql_open :: proc(path:cstring,db:^rawptr,flags:c.int,vfs:cstring)->c.int ---
    @(link_name="sqlite3_close") catalog_sql_close :: proc(db:rawptr)->c.int ---
    @(link_name="sqlite3_exec") catalog_sql_exec :: proc(db:rawptr,sql:cstring,callback:rawptr,user:rawptr,error:^cstring)->c.int ---
    @(link_name="sqlite3_errmsg") catalog_sql_error :: proc(db:rawptr)->cstring ---
    @(link_name="sqlite3_prepare_v2") catalog_sql_prepare :: proc(db:rawptr,sql:cstring,n:c.int,stmt:^rawptr,tail:^cstring)->c.int ---
    @(link_name="sqlite3_step") catalog_sql_step :: proc(stmt:rawptr)->c.int ---
    @(link_name="sqlite3_finalize") catalog_sql_finalize :: proc(stmt:rawptr)->c.int ---
    @(link_name="sqlite3_reset") catalog_sql_reset :: proc(stmt:rawptr)->c.int ---
    @(link_name="sqlite3_clear_bindings") catalog_sql_clear :: proc(stmt:rawptr)->c.int ---
    @(link_name="sqlite3_bind_text") catalog_sql_text :: proc(stmt:rawptr,index:c.int,value:rawptr,n:c.int,destroy:rawptr)->c.int ---
    @(link_name="sqlite3_bind_int64") catalog_sql_integer :: proc(stmt:rawptr,index:c.int,value:i64)->c.int ---
    @(link_name="sqlite3_column_int64") catalog_sql_value :: proc(stmt:rawptr,index:c.int)->i64 ---
    @(link_name="sqlite3_column_text") catalog_sql_string :: proc(stmt:rawptr,index:c.int)->[^]u8 ---
    @(link_name="sqlite3_column_bytes") catalog_sql_bytes :: proc(stmt:rawptr,index:c.int)->c.int ---
    @(link_name="sqlite3_changes64") catalog_sql_changes :: proc(db:rawptr)->i64 ---
    @(link_name="sqlite3_progress_handler") catalog_sql_progress :: proc(db:rawptr,n:c.int,callback:proc "c" (rawptr)->c.int,user:rawptr) ---
}
CATALOG_SQL_OK :: 0
CATALOG_SQL_ROW :: 100
CATALOG_SQL_DONE :: 101
FILE_PAGE_LIMIT :: 512
File_Catalog :: struct {
    db,insert:rawptr,
    browser:^File_Browser,
    generation:u64,
    directory,path,error:string,
    total,visible:int,
    complete:bool,
    notify_at:time.Tick,
    count_query:string,
    count_hidden,count_valid:bool,
    count_matches:int,
}
file_catalog_progress :: proc "c" (data:rawptr)->c.int {
    context=runtime.default_context()
    cat:=cast(^File_Catalog)data
    if file_request_cancelled(cat.browser,cat.generation) {return 1}
    return 0
}
file_catalog_fail :: proc(cat:^File_Catalog,message:string="")->bool {
    delete(cat.error)
    if message!="" {cat.error=strings.clone(message)}
    else {cat.error=strings.clone(fmt.tprintf("File index: %s",string(catalog_sql_error(cat.db))))}
    return false
}
file_catalog_exec :: proc(cat:^File_Catalog,sql:cstring)->bool {
    if catalog_sql_exec(cat.db,sql,nil,nil,nil)!=CATALOG_SQL_OK {return file_catalog_fail(cat)}
    return true
}
file_catalog_prepare :: proc(cat:^File_Catalog,sql:string,statement:^rawptr)->bool {
    if catalog_sql_prepare(cat.db,strings.clone_to_cstring(sql,context.temp_allocator),c.int(len(sql)),statement,nil)!=CATALOG_SQL_OK {return file_catalog_fail(cat)}
    return true
}
file_catalog_bind_text :: proc(statement:rawptr,index:c.int,value:string)->bool {
    // SQLITE_TRANSIENT copies the bounded name/query into the statement.
    return catalog_sql_text(statement,index,rawptr(raw_data(value)),c.int(len(value)),rawptr(uintptr(~uintptr(0))))==CATALOG_SQL_OK
}
file_catalog_destroy :: proc(cat:^File_Catalog) {
    if cat.insert!=nil {catalog_sql_finalize(cat.insert)}
    if cat.db!=nil {catalog_sql_progress(cat.db,0,nil,nil);catalog_sql_close(cat.db)}
    if cat.directory!="" {
        files,error:=os.read_directory_by_path(cat.directory,0,context.temp_allocator)
        if error==nil {for file in files {os.remove(file.fullpath)}}
        os.remove(cat.directory)
    }
    delete(cat.directory);delete(cat.path);delete(cat.error);delete(cat.count_query)
    cat^={}
}
file_catalog_begin :: proc(cat:^File_Catalog,b:^File_Browser,generation:u64)->bool {
    file_catalog_destroy(cat)
    cat.browser=b;cat.generation=generation;cat.notify_at=time.tick_now()
    root,error:=os.user_cache_dir(context.temp_allocator)
    if error!=nil||root=="" {return file_catalog_fail(cat,"Cannot find the disk cache directory for the file index.")}
    directory_error:=os.mkdir_all(root,{.Read_User,.Write_User,.Execute_User})
    if directory_error!=nil&&directory_error!=.Exist {return file_catalog_fail(cat,"Cannot create the disk cache directory for the file index.")}
    cat.directory,error=os.make_directory_temp(root,"minor-terminal-files-*",context.allocator)
    if error!=nil {return file_catalog_fail(cat,"Cannot create the disk-backed file index.")}
    if os.chmod(cat.directory,{.Read_User,.Write_User,.Execute_User})!=nil {return file_catalog_fail(cat,"Cannot protect the file index directory.")}
    path:=fmt.tprintf("%s/catalog.sqlite",cat.directory)
    file,open_error:=os.open(path,{.Write,.Create,.Excl},{.Read_User,.Write_User})
    if open_error!=nil {return file_catalog_fail(cat,"Cannot create the file index database.")}
    os.close(file)
    if catalog_sql_open(strings.clone_to_cstring(path,context.temp_allocator),&cat.db,0x2|0x4|0x8000,nil)!=CATALOG_SQL_OK {return file_catalog_fail(cat,"Cannot open the file index database.")}
    catalog_sql_progress(cat.db,1000,file_catalog_progress,cat)
    if !file_catalog_exec(cat,"PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-16384; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA threads=8; CREATE TABLE entries(id INTEGER PRIMARY KEY,name TEXT NOT NULL,folded TEXT NOT NULL,directory INTEGER NOT NULL,symlink INTEGER NOT NULL,size INTEGER NOT NULL,hidden INTEGER NOT NULL); BEGIN;") {return false}
    return file_catalog_prepare(cat,"INSERT INTO entries(name,folded,directory,symlink,size,hidden) VALUES(?1,?2,?3,?4,?5,?6)",&cat.insert)
}
file_catalog_report :: proc(cat:^File_Catalog,force:bool=false) {
    if !force&&cat.total%2048!=0 {return}
    now:=time.tick_now()
    if !force&&time.duration_seconds(time.tick_diff(cat.notify_at,now))<0.1 {return}
    cat.notify_at=now
    sync.mutex_lock(&cat.browser.mutex)
    if cat.browser.generation==cat.generation {cat.browser.indexed=cat.total}
    sync.mutex_unlock(&cat.browser.mutex)
    if cat.browser.wake_events {glfw.PostEmptyEvent()}
}
file_catalog_add :: proc(cat:^File_Catalog,entry:File_Entry)->bool {
    if cat.error!="" {return false}
    if file_request_cancelled(cat.browser,cat.generation) {return file_catalog_fail(cat,"Cancelled.")}
    if cat.total==max(int) {return file_catalog_fail(cat,"This directory exceeds the platform's addressable row count.")}
    folded:=strings.to_lower(entry.name,context.temp_allocator)
    hidden:=strings.has_prefix(entry.name,".")
    catalog_sql_reset(cat.insert);catalog_sql_clear(cat.insert)
    if !file_catalog_bind_text(cat.insert,1,entry.name)||!file_catalog_bind_text(cat.insert,2,folded) {return file_catalog_fail(cat)}
    catalog_sql_integer(cat.insert,3,i64(entry.directory));catalog_sql_integer(cat.insert,4,i64(entry.symlink));catalog_sql_integer(cat.insert,5,entry.size);catalog_sql_integer(cat.insert,6,i64(hidden))
    if catalog_sql_step(cat.insert)!=CATALOG_SQL_DONE {return file_catalog_fail(cat)}
    cat.total+=1;if !hidden {cat.visible+=1}
    file_catalog_report(cat)
    return true
}
file_catalog_finish :: proc(cat:^File_Catalog,path:string)->bool {
    if cat.insert!=nil {catalog_sql_finalize(cat.insert);cat.insert=nil}
    if cat.error!="" {return false}
    file_catalog_report(cat,true)
    if !file_catalog_exec(cat,"COMMIT; CREATE INDEX entries_order ON entries(directory DESC,folded,name,id); CREATE INDEX entries_visible ON entries(hidden,directory DESC,folded,name,id); CREATE TABLE order_all(rank INTEGER PRIMARY KEY,entry INTEGER NOT NULL); INSERT INTO order_all(entry) SELECT id FROM entries ORDER BY directory DESC,folded,name,id; CREATE TABLE order_visible(rank INTEGER PRIMARY KEY,entry INTEGER NOT NULL); INSERT INTO order_visible(entry) SELECT id FROM entries WHERE hidden=0 ORDER BY directory DESC,folded,name,id; CREATE TABLE search_rows(rank INTEGER PRIMARY KEY,entry INTEGER NOT NULL); CREATE VIRTUAL TABLE names USING fts5(folded,content='entries',content_rowid='id',tokenize='trigram'); INSERT INTO names(names) VALUES('rebuild');") {return false}
    cat.path=strings.clone(path);cat.complete=true
    return true
}
file_catalog_column_string :: proc(statement:rawptr,index:c.int)->string {
    n:=int(catalog_sql_bytes(statement,index));data:=catalog_sql_string(statement,index)
    if n<=0||data==nil {return ""}
    return strings.clone(string(data[:n]))
}
file_catalog_query :: proc(cat:^File_Catalog,generation:u64,query:string,hidden:bool,offset,limit:int,result:^File_Result) {
    result.query=strings.clone(query);result.show_hidden=hidden
    result.page_offset=max(0,offset);result.total_entries=cat.total
    delete(result.path);result.path=strings.clone(cat.path)
    if !cat.complete {file_set_error(result,"The directory index is not ready.");return}
    cat.generation=generation
    folded:=strings.to_lower(query,context.temp_allocator)
    use_fts:=utf8.rune_count(folded)>=3
    clause:="WHERE (?1 OR e.hidden=0)"
    if folded!="" {
        if use_fts {clause="JOIN names ON names.rowid=e.id WHERE names MATCH ?3 AND (?1 OR e.hidden=0) AND instr(e.folded,?2)>0"}
        else {clause="WHERE (?1 OR e.hidden=0) AND instr(e.folded,?2)>0"}
    }
    escaped,_:=strings.replace_all(folded,"\"","\"\"",context.temp_allocator)
    phrase:=fmt.tprintf("\"%s\"",escaped)
    bind :: proc(statement:rawptr,query,phrase:string,hidden,fts:bool)->bool {
        catalog_sql_integer(statement,1,i64(hidden))
        if query!=""&&!file_catalog_bind_text(statement,2,query) {return false}
        if fts&&!file_catalog_bind_text(statement,3,phrase) {return false}
        return true
    }
    if !cat.count_valid||cat.count_query!=folded||cat.count_hidden!=hidden {
        cat.count_valid=false
        matches:=cat.visible;if hidden {matches=cat.total}
        if folded!="" {
            if !file_catalog_exec(cat,"DELETE FROM search_rows") {file_set_error(result,cat.error);return}
            statement:rawptr
            if !file_catalog_prepare(cat,fmt.tprintf("INSERT INTO search_rows(entry) SELECT e.id FROM entries e %s ORDER BY e.directory DESC,e.folded,e.name,e.id",clause),&statement) {file_set_error(result,cat.error);return}
            bound:=bind(statement,folded,phrase,hidden,use_fts)
            if !bound||catalog_sql_step(statement)!=CATALOG_SQL_DONE {catalog_sql_finalize(statement);file_catalog_fail(cat);file_set_error(result,cat.error);return}
            matches=int(catalog_sql_changes(cat.db));catalog_sql_finalize(statement)
        }
        delete(cat.count_query);cat.count_query=strings.clone(folded);cat.count_hidden=hidden;cat.count_matches=matches;cat.count_valid=true
    }
    result.matched_entries=cat.count_matches
    statement:rawptr
    order:="order_visible";if hidden {order="order_all"};if folded!="" {order="search_rows"}
    // Rank is an INTEGER PRIMARY KEY on disk: deep scrolling never scans all
    // preceding filenames, and search result pages retain the same property.
    sql:=fmt.tprintf("SELECT e.name,e.size,e.directory,e.symlink FROM %s v JOIN entries e ON e.id=v.entry WHERE v.rank>=?1 AND v.rank<?2 ORDER BY v.rank",order)
    if !file_catalog_prepare(cat,sql,&statement) {file_set_error(result,cat.error);return}
    defer catalog_sql_finalize(statement)
    length:=max(1,limit)
    start:=min(result.page_offset,max(int)-length-1)
    catalog_sql_integer(statement,1,i64(start+1));catalog_sql_integer(statement,2,i64(start+length+1))
    for {
        code:=catalog_sql_step(statement)
        if code==CATALOG_SQL_DONE {break}
        if code!=CATALOG_SQL_ROW {file_catalog_fail(cat);file_set_error(result,cat.error);return}
        entry:=File_Entry{name=file_catalog_column_string(statement,0),size=catalog_sql_value(statement,1),directory=catalog_sql_value(statement,2)!=0,symlink=catalog_sql_value(statement,3)!=0}
        if !cat.browser.remote&&entry.size<0 {
            full:=fmt.tprintf("%s/%s",cat.path,entry.name)
            info,error:=os.stat(full,context.temp_allocator)
            if error==nil {entry.size=info.size;entry.directory=info.type==.Directory}
        }
        append(&result.entries,entry)
    }
}

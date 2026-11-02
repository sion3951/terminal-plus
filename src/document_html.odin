package main

import vmem "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

// HTML tokenization and tree construction live here rather than depending on
// XML parsing: omitted end tags, legacy entities and table recovery are HTML.
HTML_Token_Kind :: enum {End,Text,Start_Tag,End_Tag,Comment,Declaration}
HTML_Token :: struct {kind:HTML_Token_Kind,tag,text:string,attributes:[dynamic]Native_Attribute,self_closing,literal:bool}
HTML_Parser :: struct {
    doc:^Native_Document,
    input:string,
    position,parent,html,head,body:int,
    stack,formatting:[dynamic]int,
    document,body_started:bool,
    merged_text:[dynamic]u8,
    merged_text_node:int,
}
html_space :: proc(b:u8)->bool {return b==' '||b=='\t'||b=='\n'||b=='\r'||b==12}
html_alpha :: proc(b:u8)->bool {return b>='a'&&b<='z'||b>='A'&&b<='Z'}
html_alnum :: proc(b:u8)->bool {return html_alpha(b)||b>='0'&&b<='9'}
html_ascii_lower :: proc(text:string)->string {
    out:=make([]u8,len(text));for b,i in transmute([]u8)text {out[i]=b;if b>='A'&&b<='Z' {out[i]=b+32}};return string(out)
}
html_equal_at :: proc(text:string,position:int,word:string)->bool {
    if position<0||position>len(text)-len(word) {return false}
    for expected,i in transmute([]u8)word {actual:=text[position+i];if actual>='A'&&actual<='Z' {actual+=32};if actual!=expected {return false}}
    return true
}
html_normalize_input :: proc(text:string)->string {
    out:=make([dynamic]u8,0,len(text));i:=0
    if strings.has_prefix(text,"\xef\xbb\xbf") {i=3}
    for i<len(text) {
        if text[i]==13 {append(&out,'\n');i+=1;if i<len(text)&&text[i]==10 {i+=1};continue}
        if text[i]==0 {append(&out,"�");i+=1;continue}
        if text[i]<128 {append(&out,text[i]);i+=1;continue}
        ch,size:=utf8.decode_rune_in_string(text[i:]);size=max(1,size)
        if ch==utf8.RUNE_ERROR&&size==1 {append(&out,"�")} else {append(&out,text[i:i+size])}
        i+=size
    }
    return string(out[:])
}
html_named_entity :: proc(name:string)->(string,bool) {
    left,right:=0,len(HTML_NAMED_ENTITIES)
    for left<right {middle:=(left+right)/2;entry:=HTML_NAMED_ENTITIES[middle];if name==entry.name {return entry.value,true};if name<entry.name {right=middle} else {left=middle+1}}
    return "",false
}
html_numeric_entity :: proc(value:u32)->rune {
    if value==0||value>0x10ffff||value>=0xd800&&value<=0xdfff {return 0xfffd}
    // The HTML numeric-reference replacement table is Windows-1252 for C1.
    replacements := [32]rune{0x20ac,0x81,0x201a,0x192,0x201e,0x2026,0x2020,0x2021,0x2c6,0x2030,0x160,0x2039,0x152,0x8d,0x17d,0x8f,0x90,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x2dc,0x2122,0x161,0x203a,0x153,0x9d,0x17e,0x178}
    if value>=0x80&&value<=0x9f {return replacements[value-0x80]}
    return rune(value)
}
native_entity_context :: proc(text:string,attribute:bool)->string {
    out:=make([dynamic]u8,0,len(text));i:=0
    for i<len(text) {
        if text[i]!='&' {append(&out,text[i]);i+=1;continue}
        start:=i+1
        if start<len(text)&&text[start]=='#' {
            index:=start+1;base:u32=10
            if index<len(text)&&(text[index]=='x'||text[index]=='X') {base=16;index+=1}
            digits:=index;value:u32
            for index<len(text) {
                byte:=text[index];digit:u32
                if byte>='0'&&byte<='9' {digit=u32(byte-'0')} else if base==16&&byte>='a'&&byte<='f' {digit=u32(byte-'a')+10} else if base==16&&byte>='A'&&byte<='F' {digit=u32(byte-'A')+10} else {break}
                if value<=0x10ffff {value=value*base+digit};index+=1
            }
            if index>digits {if index<len(text)&&text[index]==';' {index+=1};encoded,n:=utf8.encode_rune(html_numeric_entity(value));append(&out,..encoded[:n]);i=index;continue}
        } else {
            end:=start
            for end<len(text)&&end-start<32&&html_alnum(text[end]) {end+=1}
            if end<len(text)&&text[end]==';' {end+=1}
            matched:=false
            for finish:=end;finish>start;finish-=1 {
                replacement,okay:=html_named_entity(text[start:finish]);if !okay {continue}
                if attribute&&text[finish-1]!=';'&&finish<len(text)&&(html_alnum(text[finish])||text[finish]=='=') {break}
                append(&out,replacement);i=finish;matched=true;break
            }
            if matched {continue}
        }
        append(&out,'&');i+=1
    }
    return string(out[:])
}
native_entity :: proc(text:string)->string {return native_entity_context(text,false)}
html_current :: proc(p:^HTML_Parser)->int {return p.stack[len(p.stack)-1]}
html_foreign :: proc(p:^HTML_Parser)->bool {
    for i:=len(p.stack)-1;i>=0;i-=1 {tag:=p.doc.nodes[p.stack[i]].tag;if tag=="foreignobject"||tag=="annotation-xml" {return false};if tag=="svg"||tag=="math" {return true}}
    return false
}
html_next_token :: proc(p:^HTML_Parser)->HTML_Token {
    text:=p.input
    if p.position>=len(text) {return {kind=.End}}
    start:=p.position
    if text[start]!='<' {for p.position<len(text)&&text[p.position]!='<' {p.position+=1};return {kind=.Text,text=text[start:p.position]}}
    if strings.has_prefix(text[start:],"<!--") {
        p.position+=4;body:=p.position
        if p.position<len(text)&&text[p.position]=='>' {p.position+=1;return {kind=.Comment}}
        if strings.has_prefix(text[p.position:],"->") {p.position+=2;return {kind=.Comment}}
        for p.position<len(text)&&!strings.has_prefix(text[p.position:],"-->")&&!strings.has_prefix(text[p.position:],"--!>") {p.position+=1}
        comment:=text[body:p.position]
        if p.position<len(text) {if strings.has_prefix(text[p.position:],"--!>") {p.position+=4} else {p.position+=3}}
        return {kind=.Comment,text=comment}
    }
    if strings.has_prefix(text[start:],"<![CDATA[")&&html_foreign(p) {
        p.position+=9;body:=p.position;end:=strings.index(text[body:],"]]>")
        if end<0 {p.position=len(text);return {kind=.Text,text=text[body:],literal=true}}
        p.position=body+end+3;return {kind=.Text,text=text[body:body+end],literal=true}
    }
    if start+1>=len(text) {p.position+=1;return {kind=.Text,text="<"}}
    cursor:=start+1;ending:=false
    if text[cursor]=='/' {ending=true;cursor+=1}
    if cursor>=len(text)||!html_alpha(text[cursor]) {
        if text[start+1]=='!'||text[start+1]=='?'||ending {
            p.position=cursor;for p.position<len(text)&&text[p.position]!='>' {p.position+=1};if p.position<len(text) {p.position+=1};return {kind=.Declaration}
        }
        p.position+=1;return {kind=.Text,text="<"}
    }
    name_start:=cursor
    for cursor<len(text)&&!html_space(text[cursor])&&text[cursor]!='/'&&text[cursor]!='>' {cursor+=1}
    token:=HTML_Token{kind=.Start_Tag,tag=html_ascii_lower(text[name_start:cursor])}
    if ending {token.kind=.End_Tag}
    attributes_seen:=make(map[string]bool)
    defer delete(attributes_seen)
    for cursor<len(text) {
        for cursor<len(text)&&html_space(text[cursor]) {cursor+=1}
        if cursor>=len(text) {break}
        if text[cursor]=='>' {cursor+=1;p.position=cursor;return token}
        if text[cursor]=='/' {cursor+=1;if cursor<len(text)&&text[cursor]=='>' {token.self_closing=true;cursor+=1;p.position=cursor;return token};continue}
        attr_start:=cursor
        // An '=' in the first position is part of a malformed attribute name.
        cursor+=1
        for cursor<len(text)&&!html_space(text[cursor])&&text[cursor]!='='&&text[cursor]!='/'&&text[cursor]!='>' {cursor+=1}
        name:=html_ascii_lower(text[attr_start:cursor]);value:=""
        for cursor<len(text)&&html_space(text[cursor]) {cursor+=1}
        if cursor<len(text)&&text[cursor]=='=' {
            cursor+=1;for cursor<len(text)&&html_space(text[cursor]) {cursor+=1}
            if cursor<len(text)&&(text[cursor]=='\''||text[cursor]=='"') {
                quote:=text[cursor];cursor+=1;value_start:=cursor
                for cursor<len(text)&&text[cursor]!=quote {cursor+=1};value=text[value_start:cursor]
                if cursor<len(text) {cursor+=1}
            } else {value_start:=cursor;for cursor<len(text)&&!html_space(text[cursor])&&text[cursor]!='>' {cursor+=1};value=text[value_start:cursor]}
        }
        if !ending&&!attributes_seen[name]&&name!="" {attributes_seen[name]=true;append(&token.attributes,Native_Attribute{name,native_entity_context(value,true)})}
    }
    // EOF in a tag is discarded, matching the HTML tokenizer's EOF recovery.
    p.position=len(text);return {kind=.End}
}
html_void :: proc(tag:string)->bool {
    switch tag {case "area","base","basefont","bgsound","br","col","embed","frame","hr","img","input","keygen","link","meta","param","source","track","wbr":return true};return false
}
html_block :: proc(tag:string)->bool {
    switch tag {case "address","article","aside","blockquote","center","details","dialog","dir","div","dl","fieldset","figcaption","figure","footer","form","h1","h2","h3","h4","h5","h6","header","hgroup","hr","listing","main","menu","nav","ol","p","pre","section","summary","table","ul":return true};return false
}
html_formatting :: proc(tag:string)->bool {
    switch tag {case "a","b","big","code","em","font","i","nobr","s","small","strike","strong","tt","u":return true};return false
}
html_head_tag :: proc(tag:string)->bool {
    switch tag {case "base","basefont","bgsound","link","meta","title","style","script","noscript","template":return true};return false
}
html_stack_index :: proc(p:^HTML_Parser,tag:string)->int {
    for i:=len(p.stack)-1;i>=0;i-=1 {if p.doc.nodes[p.stack[i]].tag==tag {return i}}
    return -1
}
html_pop_tag :: proc(p:^HTML_Parser,tag:string)->bool {
    index:=html_stack_index(p,tag);if index<0 {return false};resize(&p.stack,max(1,index));return true
}
html_close_implied :: proc(p:^HTML_Parser,tag:string,stop:string="") {
    for i:=len(p.stack)-1;i>0;i-=1 {
        current:=p.doc.nodes[p.stack[i]].tag
        if current==tag {resize(&p.stack,i);return}
        if current==stop||current=="table"||current=="html"||stop=="list"&&(current=="ul"||current=="ol")||tag=="p"&&(current=="button"||current=="td"||current=="th") {return}
    }
}
html_merge_attributes :: proc(p:^HTML_Parser,node:int,attributes:[]Native_Attribute) {
    for attr in attributes {if !native_has_attr(p.doc,node,attr.name) {append(&p.doc.nodes[node].attributes,attr)}}
}
html_detach :: proc(doc:^Native_Document,node:int) {
    parent:=doc.nodes[node].parent;if parent<0 {return}
    previous:=-1;current:=doc.nodes[parent].first
    for current>=0&&current!=node {previous=current;current=doc.nodes[current].next}
    if current<0 {return}
    next:=doc.nodes[node].next
    if previous>=0 {doc.nodes[previous].next=next} else {doc.nodes[parent].first=next}
    if doc.nodes[parent].last==node {doc.nodes[parent].last=previous}
    doc.nodes[node].parent=-1;doc.nodes[node].next=-1
}
html_attach_before :: proc(doc:^Native_Document,node,parent,before:int) {
    html_detach(doc,node)
    previous:=-1;current:=doc.nodes[parent].first
    for current>=0&&current!=before {previous=current;current=doc.nodes[current].next}
    doc.nodes[node].parent=parent;doc.nodes[node].next=current
    if previous>=0 {doc.nodes[previous].next=node} else {doc.nodes[parent].first=node}
    if current<0 {doc.nodes[parent].last=node}
}
html_table_context :: proc(p:^HTML_Parser)->int {
    for i:=len(p.stack)-1;i>=0;i-=1 {
        tag:=p.doc.nodes[p.stack[i]].tag
        if tag=="td"||tag=="th"||tag=="caption"||tag=="template" {return -1}
        if tag=="table"||i==0&&!p.document&&(tag=="tbody"||tag=="thead"||tag=="tfoot"||tag=="tr"||tag=="colgroup") {return i}
    }
    return -1
}
html_insert :: proc(p:^HTML_Parser,tag,text:string,attributes:[]Native_Attribute=nil,foster:bool=false)->int {
    parent:=html_current(p);before:=-1
    current_tag:=p.doc.nodes[parent].tag
    if foster&&(current_tag=="table"||current_tag=="tbody"||current_tag=="thead"||current_tag=="tfoot"||current_tag=="tr") {
        table:=html_table_context(p)
        if table>=0&&!(table==0&&!p.document) {before=p.stack[table];if p.doc.nodes[before].parent>=0 {parent=p.doc.nodes[before].parent} else if table>0 {parent=p.stack[table-1];before=-1}}
    }
    if tag=="#text"&&before<0&&p.doc.nodes[parent].last>=0 {
        last:=p.doc.nodes[parent].last
        if p.doc.nodes[last].tag=="#text" {
            // Malformed markup can emit one-byte text tokens repeatedly. Grow
            // a shared buffer geometrically rather than copy the entire text
            // into the document arena for every token.
            if p.merged_text_node!=last {
                p.merged_text=make([dynamic]u8,0,len(p.doc.nodes[last].text)+len(text))
                append(&p.merged_text,p.doc.nodes[last].text);p.merged_text_node=last
            }
            append(&p.merged_text,text);p.doc.nodes[last].text=string(p.merged_text[:]);return last
        }
    }
    node:=native_add_node(p.doc,parent,tag,text)
    if before>=0 {html_attach_before(p.doc,node,parent,before)}
    if attributes!=nil {p.doc.nodes[node].attributes=make([dynamic]Native_Attribute,0,len(attributes));append(&p.doc.nodes[node].attributes,..attributes)}
    p.doc.nodes[node].value=native_attr(p.doc,node,"value");p.doc.nodes[node].checked=native_has_attr(p.doc,node,"checked");p.doc.nodes[node].hidden=native_has_attr(p.doc,node,"hidden")
    if tag=="details" {p.doc.nodes[node].expanded=native_has_attr(p.doc,node,"open")}
    if tag=="noscript" {p.doc.nodes[node].hidden=true}
    return node
}
html_clone_format :: proc(p:^HTML_Parser,node,parent:int)->int {
    clone:=native_add_node(p.doc,parent,p.doc.nodes[node].tag,"")
    append(&p.doc.nodes[clone].attributes,..p.doc.nodes[node].attributes[:]);return clone
}
html_reconstruct_formatting :: proc(p:^HTML_Parser) {
    start:=len(p.formatting)
    for start>0 {
        node:=p.formatting[start-1];if node<0 {break}
        found:=false;for open in p.stack {if open==node {found=true;break}};if found {break};start-=1
    }
    for i in start..<len(p.formatting) {node:=p.formatting[i];if node<0 {continue};clone:=html_clone_format(p,node,html_current(p));p.formatting[i]=clone;if len(p.stack)<256 {append(&p.stack,clone)}}
}
html_formatting_end :: proc(p:^HTML_Parser,tag:string)->bool {
    active:=-1
    for i:=len(p.formatting)-1;i>=0;i-=1 {if p.formatting[i]<0 {break};if p.doc.nodes[p.formatting[i]].tag==tag {active=i;break}}
    if active<0 {return html_pop_tag(p,tag)}
    node:=p.formatting[active];open:=-1
    for candidate,i in p.stack {if candidate==node {open=i;break}}
    if open>=0 {
        // Recover the common adoption-agency case where a formatting element
        // straddles a block. The block remains in scope after the end tag.
        block:=-1
        for i:=open+1;i<len(p.stack);i+=1 {if html_block(p.doc.nodes[p.stack[i]].tag) {block=i;break}}
        if block>=0&&p.doc.nodes[node].parent>=0 {
            block_node:=p.stack[block];parent:=p.doc.nodes[node].parent
            next:=p.doc.nodes[node].next;html_attach_before(p.doc,block_node,parent,next)
            first,last:=p.doc.nodes[block_node].first,p.doc.nodes[block_node].last
            p.doc.nodes[block_node].first=-1;p.doc.nodes[block_node].last=-1
            clone:=html_clone_format(p,node,block_node)
            p.doc.nodes[clone].first=first;p.doc.nodes[clone].last=last
            child:=first;for child>=0 {p.doc.nodes[child].parent=clone;child=p.doc.nodes[child].next}
            copy(p.stack[open:],p.stack[block:]);resize(&p.stack,len(p.stack)-(block-open))
        } else {resize(&p.stack,max(1,open))}
    }
    ordered_remove(&p.formatting,active);return true
}
html_clear_formatting :: proc(p:^HTML_Parser) {for len(p.formatting)>0 {node:=pop(&p.formatting);if node<0 {break}}}
html_close_cell :: proc(p:^HTML_Parser) {
    for i:=len(p.stack)-1;i>0;i-=1 {tag:=p.doc.nodes[p.stack[i]].tag;if tag=="td"||tag=="th" {resize(&p.stack,i);html_clear_formatting(p);return};if tag=="table" {return}}
}
html_begin_body :: proc(p:^HTML_Parser) {
    if !p.document||p.body_started {return}
    p.body_started=true;clear(&p.stack);append(&p.stack,p.html,p.body)
}
html_raw_end :: proc(p:^HTML_Parser,tag:string)->int {
    i:=p.position;escaped,double_escaped:=false,false
    for i<len(p.input) {
        if tag=="script" {
            if !escaped&&strings.has_prefix(p.input[i:],"<!--") {escaped=true;i+=4;continue}
            if escaped&&!double_escaped&&strings.has_prefix(p.input[i:],"-->") {escaped=false;i+=3;continue}
            if escaped&&html_equal_at(p.input,i,"<script") {
                end:=i+7;if end==len(p.input)||html_space(p.input[end])||p.input[end]=='/'||p.input[end]=='>' {double_escaped=true;i=end;continue}
            }
        }
        if html_equal_at(p.input,i,"</")&&html_equal_at(p.input,i+2,tag) {
            end:=i+2+len(tag)
            if end==len(p.input)||html_space(p.input[end])||p.input[end]=='/'||p.input[end]=='>' {
                if tag=="script"&&double_escaped {double_escaped=false;i=end;continue};return i
            }
        }
        i+=1
    }
    return len(p.input)
}
html_script_type :: proc(doc:^Native_Document,node:int)->bool {
    kind:=html_ascii_lower(strings.trim_space(native_attr(doc,node,"type")))
    if kind==""||kind=="module" {return true}
    semicolon:=strings.index_byte(kind,';');if semicolon>=0 {kind=strings.trim_space(kind[:semicolon])}
    switch html_ascii_lower(kind) {case "application/ecmascript","application/javascript","application/x-ecmascript","application/x-javascript","text/ecmascript","text/javascript","text/javascript1.0","text/javascript1.1","text/javascript1.2","text/javascript1.3","text/javascript1.4","text/javascript1.5","text/jscript","text/livescript","text/x-ecmascript","text/x-javascript":return true};return false
}
html_raw_content :: proc(p:^HTML_Parser,node:int,tag:string) {
    end:=len(p.input);if tag!="plaintext" {end=html_raw_end(p,tag)}
    text:=p.input[p.position:end]
    if tag=="textarea"&&strings.has_prefix(text,"\n") {text=text[1:]}
    if tag=="textarea"||tag=="title" {text=native_entity(text)}
    if text!="" {native_add_node(p.doc,node,"#text",text)}
    if tag=="textarea" {p.doc.nodes[node].value=text}
    if tag=="script"&&html_stack_index(p,"template")<0&&native_attr(p.doc,node,"src")==""&&html_script_type(p.doc,node) {append(&p.doc.scripts,strings.clone(text))}
    if tag=="style"&&html_stack_index(p,"template")<0 {native_css_parse(p.doc,text)}
    p.position=end
}
html_raw_tag :: proc(tag:string)->bool {
    switch tag {case "script","style","textarea","title","xmp","iframe","noembed","noframes","noscript","plaintext":return true};return false
}
html_start_tag :: proc(p:^HTML_Parser,token:HTML_Token) {
    tag:=token.tag
    if p.document {
        if tag=="html" {html_merge_attributes(p,p.html,token.attributes[:]);return}
        if tag=="head" {if !p.body_started {html_merge_attributes(p,p.head,token.attributes[:]);clear(&p.stack);append(&p.stack,p.html,p.head)};return}
        if tag=="body" {html_merge_attributes(p,p.body,token.attributes[:]);html_begin_body(p);return}
        if !p.body_started&&!html_head_tag(tag)&&html_stack_index(p,"template")<0 {html_begin_body(p)}
    }
    current:=p.doc.nodes[html_current(p)].tag
    select_index:=html_stack_index(p,"select")
    if select_index>=0 {
        switch tag {
        case "option":if current=="option" {resize(&p.stack,len(p.stack)-1)}
        case "optgroup":if current=="option" {resize(&p.stack,len(p.stack)-1)};if p.doc.nodes[html_current(p)].tag=="optgroup" {resize(&p.stack,len(p.stack)-1)}
        case "select":resize(&p.stack,max(1,select_index));return
        case "input","keygen","textarea":resize(&p.stack,max(1,select_index))
        case "script","template","hr":
        case:return
        }
    }
    table:=html_table_context(p)
    if table>=0 {
        switch tag {
        case "caption","colgroup","tbody","tfoot","thead":
            if table==0&&!p.document&&p.doc.nodes[p.stack[0]].tag!="table" {return}
            resize(&p.stack,table+1);node:=html_insert(p,tag,"",token.attributes[:]);append(&p.stack,node);if tag=="caption" {append(&p.formatting,-1)};return
        case "col":
            if p.doc.nodes[html_current(p)].tag!="colgroup" {resize(&p.stack,table+1);group:=html_insert(p,"colgroup","");append(&p.stack,group)}
            html_insert(p,tag,"",token.attributes[:]);return
        case "tr":
            group:=-1
            context_tag:=p.doc.nodes[p.stack[table]].tag
            if context_tag=="tbody"||context_tag=="thead"||context_tag=="tfoot" {group=p.stack[table]}
            for i:=table+1;i<len(p.stack);i+=1 {name:=p.doc.nodes[p.stack[i]].tag;if name=="tbody"||name=="thead"||name=="tfoot" {group=p.stack[i];break}}
            resize(&p.stack,table+1)
            if group<0 {group=html_insert(p,"tbody","")};if group!=html_current(p) {append(&p.stack,group)}
            row:=html_insert(p,"tr","",token.attributes[:]);append(&p.stack,row);return
        case "td","th":
            row_index:=html_stack_index(p,"tr")
            if row_index<0 {html_start_tag(p,HTML_Token{kind=.Start_Tag,tag="tr"});row_index=html_stack_index(p,"tr")}
            if row_index>=0 {resize(&p.stack,row_index+1)}
            cell:=html_insert(p,tag,"",token.attributes[:]);append(&p.stack,cell);append(&p.formatting,-1);return
        case "table":if table==0 {return};resize(&p.stack,table);html_start_tag(p,token);return
        }
    } else if tag=="td"||tag=="th"||tag=="tr"||tag=="tbody"||tag=="thead"||tag=="tfoot" {
        // Cell/row/group tokens imply the previous cell's end before entering
        // the table insertion mode again.
        cell:=max(html_stack_index(p,"td"),html_stack_index(p,"th"))
        if cell>=0 {html_close_cell(p);html_start_tag(p,token);return}
        if html_stack_index(p,"table")<0 {return}
    }
    if tag=="li" {html_close_implied(p,"li","list");html_close_implied(p,"p")}
    if tag=="dd"||tag=="dt" {html_close_implied(p,"dd","dl");html_close_implied(p,"dt","dl");html_close_implied(p,"p")}
    if html_block(tag) {html_close_implied(p,"p")}
    if len(tag)==2&&tag[0]=='h'&&tag[1]>='1'&&tag[1]<='6' {
        top_tag:=p.doc.nodes[html_current(p)].tag;if len(top_tag)==2&&top_tag[0]=='h'&&top_tag[1]>='1'&&top_tag[1]<='6' {resize(&p.stack,max(1,len(p.stack)-1))}
    }
    if tag=="button"&&html_stack_index(p,"button")>=0 {html_pop_tag(p,"button");html_clear_formatting(p)}
    if tag=="form"&&html_stack_index(p,"form")>=0 {return}
    if tag=="option"&&p.doc.nodes[html_current(p)].tag=="option" {resize(&p.stack,max(1,len(p.stack)-1))}
    if tag=="rb"||tag=="rt"||tag=="rtc"||tag=="rp" {
        for len(p.stack)>1 {top:=p.doc.nodes[html_current(p)].tag;if top!="rb"&&top!="rt"&&top!="rp"&&(tag=="rt"||top!="rtc") {break};resize(&p.stack,len(p.stack)-1)}
    }
    if tag=="a" {html_formatting_end(p,"a")}
    if !html_block(tag)&&tag!="script"&&tag!="style"&&tag!="title"&&tag!="meta"&&tag!="link" {html_reconstruct_formatting(p)}
    node:=html_insert(p,tag,"",token.attributes[:],table>=0)
    if html_raw_tag(tag) {html_raw_content(p,node,tag);return}
    if tag=="pre"||tag=="listing" {if p.position<len(p.input)&&p.input[p.position]=='\n' {p.position+=1}}
    if html_void(tag)||token.self_closing&&html_foreign(p)||token.self_closing&&(tag=="svg"||tag=="math") {return}
    if len(p.stack)<256 {append(&p.stack,node)}
    if html_formatting(tag)&&len(p.formatting)<256 {append(&p.formatting,node)}
    if tag=="button"||tag=="template" {append(&p.formatting,-1)}
}
html_end_tag :: proc(p:^HTML_Parser,tag:string) {
    if p.document&&(tag=="html"||tag=="body") {html_begin_body(p);clear(&p.stack);append(&p.stack,p.html,p.body);return}
    if tag=="head"&&p.document {html_begin_body(p);return}
    if tag=="br" {html_start_tag(p,HTML_Token{kind=.Start_Tag,tag="br"});return}
    if tag=="td"||tag=="th" {html_close_cell(p);return}
    if tag=="tr"||tag=="tbody"||tag=="thead"||tag=="tfoot"||tag=="table" {html_close_cell(p)}
    if html_formatting(tag) {html_formatting_end(p,tag);return}
    if tag=="p"&&html_stack_index(p,"p")<0 {html_start_tag(p,HTML_Token{kind=.Start_Tag,tag="p"})}
    if tag=="caption"||tag=="button"||tag=="template" {html_clear_formatting(p)}
    html_pop_tag(p,tag)
}
native_parse_html :: proc(doc:^Native_Document,input:string,parent:int=0) {
    if !doc.initialized||parent<0||parent>=len(doc.nodes) {return}
    context.allocator=vmem.arena_allocator(&doc.arena)
    p:=HTML_Parser{doc=doc,input=html_normalize_input(input),parent=parent,document=parent==0&&len(doc.nodes)==1,html=-1,head=-1,body=-1,merged_text_node=-1}
    if !p.document {
        tag:=doc.nodes[parent].tag
        if html_raw_tag(tag) {
            text:=p.input;if tag=="textarea"||tag=="title" {text=native_entity(text)}
            if text!="" {native_add_node(doc,parent,"#text",text)}
            if tag=="textarea" {doc.nodes[parent].value=text};return
        }
    }
    if p.document {
        p.html=native_add_node(doc,0,"html","");p.head=native_add_node(doc,p.html,"head","");p.body=native_add_node(doc,p.html,"body","")
        append(&p.stack,p.html,p.head)
    } else {append(&p.stack,parent)}
    for {
        token:=html_next_token(&p)
        switch token.kind {
        case .End:return
        case .Text:
            if p.document&&!p.body_started&&html_stack_index(&p,"template")<0&&strings.trim_space(token.text)!="" {html_begin_body(&p)}
            if token.text!="" {html_reconstruct_formatting(&p);text:=token.text;if !token.literal {text=native_entity(text)};html_insert(&p,"#text",text,nil,html_table_context(&p)>=0&&strings.trim_space(token.text)!="")}
        case .Start_Tag:html_start_tag(&p,token)
        case .End_Tag:html_end_tag(&p,token.tag)
        case .Comment:html_insert(&p,"#comment",token.text)
        case .Declaration:
        }
    }
}

// Template descendants are inert until cloned into the live document.
html_node_inert :: proc(doc:^Native_Document,node:int)->bool {
    for current:=node;current>=0&&current<len(doc.nodes);current=doc.nodes[current].parent {if doc.nodes[current].tag=="template" {return true}}
    return false
}

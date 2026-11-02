#+build linux
package main

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"

native_shell_text_locale :: proc(shell:^Native_Shell)->string {
    previous:=strings.clone(string(libc.setlocale(.ALL,nil)))
    all,_:=native_shell_value_get(shell,"LC_ALL")
    language,_:=native_shell_value_get(shell,"LANG")
    for item in ([]struct {name:string,category:libc.Locale_Category}{{"LC_CTYPE",.CTYPE},{"LC_COLLATE",.COLLATE}}) {
        value:=all
        if value=="" {value,_=native_shell_value_get(shell,item.name)}
        if value=="" {value=language}
        if value=="" {value="C"}
        _=libc.setlocale(item.category,strings.clone_to_cstring(value))
    }
    return previous
}
native_shell_text_locale_restore :: proc(previous:string) {
    _=libc.setlocale(.ALL,strings.clone_to_cstring(previous));delete(previous)
}

// Decode and encode with the active shell locale, including byte-oriented C
// locale and invalid multibyte sequences, rather than assuming all text is UTF-8.
native_shell_text_character :: proc(text:string)->(rune,int,bool) {
    return native_shell_printf_character(text)
}
native_shell_text_encode :: proc(character:rune)->string {
    bytes:[64]c.char;state:libc.mbstate_t
    count:=libc.wcrtomb(&bytes[0],libc.wchar_t(character),&state)
    if count>c.size_t(len(bytes)) {return ""}
    return strings.clone(string(bytes[:int(count)]))
}
native_shell_text_case :: proc(value:string,upper:bool,first_only:bool=false)->string {
    output:=make([dynamic]u8)
    for at:=0;at<len(value); {
        character,count,valid:=native_shell_text_character(value[at:]);count=max(1,count)
        changed:=character
        if valid {if upper {changed=rune(libc.towupper(libc.wint_t(character)))} else {changed=rune(libc.towlower(libc.wint_t(character)))}}
        if changed!=character {
            encoded:=native_shell_text_encode(changed)
            if encoded!="" {append(&output,encoded)} else {append(&output,value[at:at+count])}
        } else {append(&output,value[at:at+count])}
        at+=count
        if first_only {append(&output,value[at:]);break}
    }
    return string(output[:])
}

native_shell_single_word :: proc(value:string)->[]string {result:=make([]string,1);result[0]=value;return result}

native_shell_expansion_join :: proc(parts:..string)->string {return strings.concatenate(parts)}

native_shell_variable :: proc(shell:^Native_Shell,name:string)->(string,bool) {return native_shell_value_get(shell,name)}

// Keep quoting and split provenance until all expansions have completed. A
// literal IFS character is not a delimiter; the same byte from an unquoted
// parameter is. This also preserves argument boundaries for quoted "$@".
Native_Shell_Field :: struct {
    bytes,pattern:[dynamic]u8,
    quoted,splittable:[dynamic]bool,
    present,glob,protected_empty:bool,
}
Native_Shell_Expansion :: struct {fields:[dynamic]Native_Shell_Field,current:Native_Shell_Field,split:bool}
Native_Shell_Parameter :: struct {fields:[dynamic]Native_Shell_Field,star:bool,error:string}

native_shell_field_byte :: proc(expansion:^Native_Shell_Expansion,ch:u8,quoted:bool,split:bool=false) {
    expansion.current.present=true
    append(&expansion.current.bytes,ch)
    append(&expansion.current.quoted,quoted)
    append(&expansion.current.splittable,split&&!quoted)
}
native_shell_field_finish :: proc(expansion:^Native_Shell_Expansion) {
    if expansion.current.present {append(&expansion.fields,expansion.current);expansion.current={}}
}
native_shell_expansion_text :: proc(expansion:^Native_Shell_Expansion,value:string,quoted:bool,split:bool) {
    if quoted {expansion.current.present=true}
    for ch in transmute([]u8)value {native_shell_field_byte(expansion,ch,quoted,split)}
}
native_shell_parameter_text :: proc(value:string)->Native_Shell_Parameter {
    result:Native_Shell_Parameter
    field:=Native_Shell_Field{present=true}
    append(&field.bytes,value)
    for _ in 0..<len(value) {append(&field.quoted,false);append(&field.splittable,true)}
    append(&result.fields,field)
    return result
}
native_shell_parameter_list :: proc(values:[]string,star:bool=false)->Native_Shell_Parameter {
    result:=Native_Shell_Parameter{star=star}
    for value in values {item:=native_shell_parameter_text(value);append(&result.fields,item.fields[0])}
    return result
}

Native_Shell_Glob :: struct {
    pathc:c.size_t,pathv:^cstring,offs:c.size_t,flags:c.int,
    closedir,readdir,opendir,lstat,stat:rawptr,
}
Native_Shell_Passwd :: struct {name,password:cstring,uid,gid:c.uint,gecos,directory,shell:cstring}
foreign import native_shell_glob_lib "system:c"
foreign native_shell_glob_lib {
    @(link_name="glob") native_shell_glob :: proc(pattern:cstring,flags:c.int,error:rawptr,result:^Native_Shell_Glob)->c.int ---
    @(link_name="globfree") native_shell_glob_free :: proc(result:^Native_Shell_Glob) ---
    @(link_name="fnmatch") native_shell_fnmatch :: proc(pattern,value:cstring,flags:c.int)->c.int ---
    @(link_name="getpwnam") native_shell_getpwnam :: proc(name:cstring)->^Native_Shell_Passwd ---
    @(link_name="getpwuid") native_shell_getpwuid :: proc(uid:c.uint)->^Native_Shell_Passwd ---
}

native_shell_arithmetic_end :: proc(source:string,start:int)->(int,string) {
    i:=start+3;depth:=1;quote:u8
    for i<len(source) {
        ch:=source[i]
        if ch=='\\' {i+=2;continue}
        if quote!=0 {if ch==quote {quote=0};i+=1;continue}
        if ch=='\''||ch=='"' {quote=ch;i+=1;continue}
        if ch=='(' {depth+=1}
        if ch==')' {
            depth-=1
            if depth==0 {
                if i+1<len(source)&&source[i+1]==')' {return i+2,""}
                return 0,"Arithmetic expansion needs a closing ))."
            }
        }
        i+=1
    }
    return 0,"incomplete: unclosed arithmetic expansion"
}
native_shell_legacy_arithmetic_end :: proc(source:string,start:int)->(int,string) {
    i:=start+2;depth:=1;quote:u8
    for i<len(source) {
        ch:=source[i]
        if ch=='\\' {i+=2;continue}
        if quote!=0 {if ch==quote {quote=0};i+=1;continue}
        if ch=='\''||ch=='"' {quote=ch;i+=1;continue}
        if ch=='[' {depth+=1}
        if ch==']' {depth-=1;if depth==0 {return i+1,""}}
        i+=1
    }
    return 0,"incomplete: unclosed arithmetic expansion"
}

native_shell_backtick_end :: proc(source:string,start:int)->(int,string) {
    i:=start+1
    for i<len(source) {if source[i]=='\\' {i+=2;continue};if source[i]=='`' {return i+1,""};i+=1}
    return 0,"incomplete: unclosed backtick substitution"
}
native_shell_process_end :: proc(source:string,start:int)->(int,string) {
    // Reuse the command scanner: its opening marker occupies two bytes too.
    return native_shell_substitution_end(source,start)
}

native_shell_ifs :: proc(shell:^Native_Shell)->string {
    value,present:=shell.variables["IFS"]
    if !present {return " \t\n"}
    return value
}
native_shell_ifs_separator :: proc(shell:^Native_Shell)->string {
    ifs:=native_shell_ifs(shell)
    if ifs=="" {return ""}
    _,width,_:=native_shell_text_character(ifs);return ifs[:max(1,width)]
}
native_shell_parameter_insert :: proc(shell:^Native_Shell,expansion:^Native_Shell_Expansion,value:Native_Shell_Parameter,quoted:bool) {
    if value.star&&quoted {
        parts:=make([dynamic]string)
        for field in value.fields {append(&parts,string(field.bytes[:]))}
        native_shell_expansion_text(expansion,strings.join(parts[:],native_shell_ifs_separator(shell)),true,true)
        return
    }
    for field,index in value.fields {
        if index>0 {native_shell_field_finish(expansion)}
        if quoted {expansion.current.present=true}
        else if field.present&&len(field.bytes)==0 {
            // Only quoted empty fields survive an unquoted expansion.
            protected:=field.protected_empty;for flag in field.quoted {if flag {protected=true;break}}
            if protected {expansion.current.present=true}
        }
        for ch,i in field.bytes {
            protected:=quoted||(i<len(field.quoted)&&field.quoted[i])
            split:=i>=len(field.splittable)||field.splittable[i]
            native_shell_field_byte(expansion,ch,protected,split)
        }
    }
}

native_shell_expand_pattern :: proc(shell:^Native_Shell,raw:string)->(string,string) {return native_shell_pattern(shell,raw)}

native_shell_pattern :: proc(shell:^Native_Shell,raw:string,depth:int=0)->(string,string) {
    fields,error:=native_shell_expand_fields(shell,raw,false,depth+1)
    if error!="" {return "",error}
    output:=make([dynamic]u8)
    for field in fields {
        for ch,i in field.bytes {
            if i<len(field.quoted)&&field.quoted[i]&&(ch=='*'||ch=='?'||ch=='['||ch==']'||ch=='\\'||ch=='('||ch==')'||ch=='|'||ch=='+'||ch=='@'||ch=='!') {append(&output,'\\')}
            append(&output,ch)
        }
    }
    return string(output[:]),""
}
native_shell_pattern_matches :: proc(shell:^Native_Shell,pattern,value:string)->bool {
    previous_locale:=native_shell_text_locale(shell);defer native_shell_text_locale_restore(previous_locale)
    flags:c.int
    if shell.compat!=nil {
        if shell.compat.shopts["globasciiranges"] {_=libc.setlocale(.COLLATE,"C")} 
        if shell.compat.shopts["extglob"] {flags|=32}
        if shell.compat.shopts["nocasematch"] {flags|=16}
    }
    return native_shell_fnmatch(strings.clone_to_cstring(pattern),strings.clone_to_cstring(value),flags)==0
}
native_shell_rune_offsets :: proc(value:string)->[]int {
    offsets:=make([dynamic]int)
    for index:=0;index<len(value); {append(&offsets,index);_,count,_:=native_shell_text_character(value[index:]);index+=max(1,count)}
    append(&offsets,len(value));return offsets[:]
}
native_shell_pattern_remove :: proc(shell:^Native_Shell,value,pattern:string,prefix,longest:bool)->string {
    offsets:=native_shell_rune_offsets(value)
    if prefix {
        if longest {for i:=len(offsets)-1;i>=0;i-=1 {at:=offsets[i];if native_shell_pattern_matches(shell,pattern,value[:at]) {return value[at:]}}}
        else {for at in offsets {if native_shell_pattern_matches(shell,pattern,value[:at]) {return value[at:]}}}
    } else {
        if longest {for at in offsets {if native_shell_pattern_matches(shell,pattern,value[at:]) {return value[:at]}}}
        else {for i:=len(offsets)-1;i>=0;i-=1 {at:=offsets[i];if native_shell_pattern_matches(shell,pattern,value[at:]) {return value[:at]}}}
    }
    return value
}
native_shell_replacement_text :: proc(replacement,match:string)->string {
    output:=make([dynamic]u8)
    for i:=0;i<len(replacement);i+=1 {
        if replacement[i]=='\\'&&i+1<len(replacement) {i+=1;append(&output,replacement[i])}
        else if replacement[i]=='&' {append(&output,match)}
        else {append(&output,replacement[i])}
    }
    return string(output[:])
}
native_shell_pattern_replace :: proc(shell:^Native_Shell,value,pattern,replacement:string,all:bool,anchor:u8)->string {
    output:=make([dynamic]u8);offsets:=native_shell_rune_offsets(value);position:=0;matched:=false
    for position<len(offsets) {
        first:=offsets[position];found:=-1
        if anchor!='%'&&(anchor!='#'||first==0)||anchor=='%' {
            for end:=len(offsets)-1;end>=position;end-=1 {
                last:=offsets[end]
                if anchor=='%'&&last!=len(value) {continue}
                if native_shell_pattern_matches(shell,pattern,value[first:last]) {found=end;break}
            }
        }
        if found>=0 {
            last:=offsets[found];append(&output,native_shell_replacement_text(replacement,value[first:last]));matched=true
            if !all||anchor!=0 {append(&output,value[last:]);break}
            if last==first {
                if position+1<len(offsets) {append(&output,value[first:offsets[position+1]])}
                position+=1
            } else {position=found;if last==len(value) {break}}
        } else {
            if position+1<len(offsets) {append(&output,value[first:offsets[position+1]])}
            position+=1
        }
    }
    if !matched {return value}
    return string(output[:])
}

native_shell_parameter_base :: proc(shell:^Native_Shell,name:string,keys:bool=false)->(values:[]string,multi,star,exists:bool,error:string) {
    if name=="@"||name=="*" {return native_shell_parameters(shell),true,name=="*",true,""}
    if name=="?" {return native_shell_single_word(fmt.aprintf("%d",shell.status)),false,false,true,""}
    if name=="$" {return native_shell_single_word(fmt.aprintf("%d",shell.compat.pid)),false,false,true,""}
    if name=="!" {if shell.last_background>0 {return native_shell_single_word(fmt.aprintf("%d",shell.last_background)),false,false,true,""};return native_shell_single_word(""),false,false,false,""}
    bracket:=strings.index_byte(name,'[')
    if bracket>0&&strings.has_suffix(name,"]") {
        base,index:=name[:bracket],name[bracket+1:len(name)-1]
        if index=="@"||index=="*" {values=native_shell_array_values(shell,base,keys);return values,true,index=="*",len(values)>0,""}
        if array,found:=shell.compat.arrays[base];found&&array.associative_mode {
            expanded,index_error:=native_shell_expand_assignment(shell,index)
            if index_error!="" {return nil,false,false,false,index_error}
            if expanded=="" {return nil,false,false,false,"bad array subscript"}
            value,present:=native_shell_value_get(shell,fmt.aprintf("%s[%s]",base,expanded))
            return native_shell_single_word(value),false,false,present,""
        }
    }
    if native_shell_digits(name)||name=="#"||name=="-" {
        value,present:=native_shell_parameter(shell,name);return native_shell_single_word(value),false,false,present,""
    }
    value,present:=native_shell_value_get(shell,name)
    return native_shell_single_word(value),false,false,present,""
}

native_shell_parameter_attributes :: proc(shell:^Native_Shell,name:string)->string {
    base:=name;if bracket:=strings.index_byte(base,'[');bracket>=0 {base=base[:bracket]}
    flags:=shell.compat.attributes[base]
    if array,found:=shell.compat.arrays[base];found {if array.associative_mode {flags|=NATIVE_SHELL_ASSOCIATIVE} else {flags|=NATIVE_SHELL_INDEXED}}
    if shell.exported[base] {flags|=NATIVE_SHELL_EXPORT}
    output:=make([dynamic]u8)
    flags_list:=[]u32{NATIVE_SHELL_INDEXED,NATIVE_SHELL_ASSOCIATIVE,NATIVE_SHELL_INTEGER,NATIVE_SHELL_LOWER,NATIVE_SHELL_NAMEREF,NATIVE_SHELL_READONLY,NATIVE_SHELL_TRACE,NATIVE_SHELL_UPPER,NATIVE_SHELL_EXPORT}
    letters:="aAilnrtux"
    for flag,index in flags_list {if flags&flag!=0 {append(&output,letters[index])}}
    return string(output[:])
}
native_shell_parameter_quote :: proc(shell:^Native_Shell,value:string)->string {
    previous:=native_shell_printf_locale(shell)
    defer {libc.setlocale(.ALL,strings.clone_to_cstring(previous));delete(previous)}
    return native_shell_printf_quote(value,true)
}
native_shell_parameter_double_quote :: proc(value:string)->string {
    output:=make([dynamic]u8);append(&output,'"')
    for byte in transmute([]u8)value {if byte=='\\'||byte=='"'||byte=='$'||byte=='`' {append(&output,'\\')};append(&output,byte)}
    append(&output,'"');return string(output[:])
}
native_shell_parameter_prompt :: proc(shell:^Native_Shell,value:string)->string {
    result:=native_shell_prompt_value(shell,value)
    result,_=strings.replace_all(result,"\x01","");result,_=strings.replace_all(result,"\x02","")
    return result
}

// Separate a substring's offset and length without consuming a colon
// belonging to an arithmetic conditional, array subscript or substitution.
native_shell_substring_separator :: proc(source:string)->int {
    parentheses,brackets,ternaries:int;quote:u8
    for i:=0;i<len(source);i+=1 {
        ch:=source[i]
        if ch=='\\' {i+=1;continue}
        if quote!=0 {if ch==quote {quote=0};continue}
        if ch=='\''||ch=='"' {quote=ch;continue}
        if ch=='$'&&i+1<len(source) {
            end:int;error:string
            switch source[i+1] {
            case '{':end,error=native_shell_parameter_end(source,i)
            case '(':end,error=native_shell_substitution_end(source,i)
            case '[':end,error=native_shell_legacy_arithmetic_end(source,i)
            }
            if end>i&&error=="" {i=end-1;continue}
        }
        if ch=='`' {end,error:=native_shell_backtick_end(source,i);if error=="" {i=end-1;continue}}
        if ch=='(' {parentheses+=1};if ch==')' {parentheses-=1}
        if ch=='[' {brackets+=1};if ch==']' {brackets-=1}
        if parentheses!=0||brackets!=0 {continue}
        if ch=='?' {ternaries+=1}
        if ch==':' {if ternaries>0 {ternaries-=1} else {return i}}
    }
    return -1
}

native_shell_parameter_expression :: proc(shell:^Native_Shell,expression:string,depth:int,quoted:bool=false)->Native_Shell_Parameter {
    if depth>=64 {return Native_Shell_Parameter{error="Parameter expansion nesting limit reached."}}
    if strings.has_prefix(expression,NATIVE_SHELL_TRANSLATION_PREFIX) {
        translated_text,translation_decode_error:=native_shell_translation_text(expression[len(NATIVE_SHELL_TRANSLATION_PREFIX):])
        if translation_decode_error!="" {return Native_Shell_Parameter{error=translation_decode_error}}
        translated_fields,translation_expand_error:=native_shell_expand_fields(shell,translated_text,false,depth+1,true)
        if translation_expand_error!="" {return Native_Shell_Parameter{error=translation_expand_error}}
        for &field in translated_fields {
            field.protected_empty=true
            for &flag in field.quoted {flag=true}
            for &flag in field.splittable {flag=false}
        }
        if len(translated_fields)==0 {translated_empty:=native_shell_parameter_text("");translated_empty.fields[0].protected_empty=true;return translated_empty}
        return Native_Shell_Parameter{fields=translated_fields}
    }
    length,indirect:=false,false
    source:=expression
    if len(source)>1&&source[0]=='#' {length=true;source=source[1:]}
    else if len(source)>1&&source[0]=='!'&&!(shell.compat.options["posix"]&&(source[1]=='#'||source[1]=='?')) {indirect=true;source=source[1:]}
    end:=0
    if len(source)>0 {
        if native_shell_name_start(source[0]) {end=1;for end<len(source)&&native_shell_name_byte(source[end]) {end+=1}}
        else if source[0]>='0'&&source[0]<='9' {end=1;for end<len(source)&&source[end]>='0'&&source[end]<='9' {end+=1}}
        else if strings.contains_any(source[:1],"@*#?$!-") {end=1}
    }
    if end==0 {return Native_Shell_Parameter{error=native_shell_expansion_join("bad substitution: ",expression)}}
    if end<len(source)&&source[end]=='[' {
        brackets:=1;end+=1
        for end<len(source)&&brackets>0 {if source[end]=='[' {brackets+=1};if source[end]==']' {brackets-=1};end+=1}
        if brackets!=0 {return Native_Shell_Parameter{error="bad array subscript"}}
    }
    name:=source[:end];operation:=source[end:]
    if quoted&&shell.compat.options["posix"]&&native_shell_compat_level(shell)==42&&(operation==""||strings.index_byte("#%/^,",operation[0])<0) {
        probe:=native_shell_expansion_join("${",expression,"}")
        _,quote_error:=native_shell_parameter_end(probe,0,0,false)
        if quote_error!="" {return Native_Shell_Parameter{error="bad substitution: unmatched single quote in parameter word"}}
    }
    if indirect&&(operation=="@"||operation=="*")&&native_shell_name(name) {
        names:=make([dynamic]string)
        for variable in shell.variables {if strings.has_prefix(variable,name) {append(&names,variable)}}
        slice.sort(names[:]);return native_shell_parameter_list(names[:],operation=="*")
    }
    if indirect&&operation==""&&shell.compat.attributes[name]&NATIVE_SHELL_NAMEREF!=0 {
        return native_shell_parameter_text(shell.variables[name])
    }
    values,multi,star,exists,error:=native_shell_parameter_base(shell,name,indirect&&strings.contains(name,"["))
    if error!="" {return Native_Shell_Parameter{error=error}}
    if indirect&&!strings.has_suffix(name,"[@]")&&!strings.has_suffix(name,"[*]") {
        if len(values)==0||values[0]=="" {return Native_Shell_Parameter{error="invalid indirect expansion"}}
        name=values[0];values,multi,star,exists,error=native_shell_parameter_base(shell,name)
        if error!="" {return Native_Shell_Parameter{error=error}}
    }
    if length {
        if !exists&&!multi&&shell.compat.options["nounset"] {return Native_Shell_Parameter{error=native_shell_expansion_join(name,": unbound variable")}}
        if operation!="" {return Native_Shell_Parameter{error=native_shell_expansion_join("bad substitution: ",expression)}}
        count:=0;if multi {count=len(values)} else if len(values)>0 {count=len(native_shell_rune_offsets(values[0]))-1}
        return native_shell_parameter_text(fmt.aprintf("%d",count))
    }
    text:="";if len(values)>0 {text=values[0]}
    if operation=="" {
        if !exists&&!multi&&shell.compat.options["nounset"] {return Native_Shell_Parameter{error=native_shell_expansion_join(name,": unbound variable")}}
        return native_shell_parameter_list(values,star)
    }
    mode:=operation
    nonnull:=strings.has_prefix(mode,":")&&len(mode)>1&&strings.contains_any(mode[1:2],"-+=?")
    if nonnull {mode=mode[1:]}
    if len(mode)>0&&strings.contains_any(mode[:1],"-+=?") {
        missing:=!exists||(nonnull&&text=="")
        selected:=missing
        if mode[0]=='+' {selected=!missing}
        if !selected {if mode[0]=='+' {return native_shell_parameter_text("")};return native_shell_parameter_list(values,star)}
        fields,fallback_error:=native_shell_expand_fields(shell,mode[1:],false,depth+1,quoted)
        if fallback_error!="" {return Native_Shell_Parameter{error=fallback_error}}
        result:=Native_Shell_Parameter{fields=fields}
        if len(result.fields)==0 {result=native_shell_parameter_text("")}
        for &field in result.fields {for &flag,i in field.splittable {flag= !field.quoted[i]}}
        replacement:="";for field in fields {replacement=native_shell_expansion_join(replacement,string(field.bytes[:]))}
        if mode[0]=='?' {if replacement=="" {replacement="parameter is unset or empty"};return Native_Shell_Parameter{error=native_shell_expansion_join(name,": ",replacement)}}
        if mode[0]=='=' {
            if set_error:=native_shell_value_set(shell,name,replacement);set_error!="" {return Native_Shell_Parameter{error=set_error}}
            if native_shell_compat_level(shell)>51 {assigned,_:=native_shell_value_get(shell,name);return native_shell_parameter_text(assigned)}
            return native_shell_parameter_text(replacement)
        }
        return result
    }
    if !exists&&!multi&&shell.compat.options["nounset"] {return Native_Shell_Parameter{error=native_shell_expansion_join(name,": unbound variable")}}
    result:=make([dynamic]string)
    if strings.has_prefix(operation,":") {
        operands:=operation[1:];colon:=native_shell_substring_separator(operands)
        offset_source:=operands;length_source:=""
        if colon>=0 {offset_source=operands[:colon];length_source=operands[colon+1:]}
        offset,offset_error:=native_shell_arithmetic(shell,offset_source,true)
        if offset_error!="" {return Native_Shell_Parameter{error=offset_error}}
        amount:i64=0;has_length:=colon>=0
        if has_length {length_error:string;amount,length_error=native_shell_arithmetic(shell,length_source,true);if length_error!="" {return Native_Shell_Parameter{error=length_error}}}
        if multi {
            if has_length&&amount<0 {return Native_Shell_Parameter{error="substring expression < 0"}}
            if bracket:=strings.index_byte(name,'[');bracket>0 {
                base:=name[:bracket]
                if array,found:=shell.compat.arrays[base];found&&!array.associative_mode {
                    // Indexed-array offsets refer to array indices, including
                    // holes; the length still counts assigned elements.
                    keys:=native_shell_array_values(shell,base,true)
                    beginning:=offset
                    if beginning<0 {
                        maximum:i64= -1
                        for index in array.indexed {maximum=max(maximum,i64(index))}
                        beginning+=maximum+1
                    }
                    selected:=make([dynamic]string)
                    if beginning>=0 {for key,index in keys {at,_:=strconv.parse_i64(key);if at>=beginning&&(!has_length||i64(len(selected))<amount) {append(&selected,values[index])}}}
                    return native_shell_parameter_list(selected[:],star)
                }
            }
            start:=int(offset)
            if name=="@"||name=="*" {
                if start<0 {start=len(values)+1+start}
                if start==0 {full:=make([dynamic]string);append(&full,shell.compat.arg0);append(&full,..values);values=full[:]}
                else if start>0 {start-=1}
            } else if start<0 {start=len(values)+start}
            if start<0||start>len(values) {return native_shell_parameter_list(nil,star)}
            last:=len(values)
            if has_length&&amount<i64(last-start) {last=start+int(amount)}
            return native_shell_parameter_list(values[start:last],star)
        }
        for value in values {
            offsets:=native_shell_rune_offsets(value);count:=len(offsets)-1;start:=int(offset)
            if start<0 {start=count+start}
            if start<0||start>count {append(&result,"");continue}
            last:=count
            if has_length {
                if amount<0 {last=count+int(amount);if last<start {return Native_Shell_Parameter{error="substring expression < 0"}}}
                else if amount<i64(count-start) {last=start+int(amount)}
            }
            append(&result,value[offsets[start]:offsets[last]])
        }
    } else if operation[0]=='#'||operation[0]=='%' {
        prefix:=operation[0]=='#';longest:=len(operation)>1&&operation[1]==operation[0];skip:=1;if longest {skip=2}
        pattern,pattern_error:=native_shell_pattern(shell,operation[skip:],depth)
        if pattern_error!="" {return Native_Shell_Parameter{error=pattern_error}}
        for value in values {append(&result,native_shell_pattern_remove(shell,value,pattern,prefix,longest))}
    } else if operation[0]=='/' {
        rest:=operation[1:];all:=strings.has_prefix(rest,"/");if all {rest=rest[1:]}
        anchor:u8;if strings.has_prefix(rest,"#")||strings.has_prefix(rest,"%") {anchor=rest[0];rest=rest[1:]}
        separator:=-1;quote:u8
        for i:=0;i<len(rest);i+=1 {
            if rest[i]=='\\' {i+=1;continue}
            if quote!=0 {if rest[i]==quote {quote=0};continue}
            if rest[i]=='\''||rest[i]=='"' {quote=rest[i];continue}
            if rest[i]=='$'&&i+1<len(rest)&&(rest[i+1]=='{'||rest[i+1]=='('||rest[i+1]=='[') {
                scan_end:int;scan_error:string
                switch rest[i+1] {case '{':scan_end,scan_error=native_shell_parameter_end(rest,i);case '(':scan_end,scan_error=native_shell_substitution_end(rest,i);case '[':scan_end,scan_error=native_shell_legacy_arithmetic_end(rest,i)}
                if scan_error!="" {return Native_Shell_Parameter{error=scan_error}};i=scan_end-1;continue
            }
            if rest[i]=='`' {scan_end,scan_error:=native_shell_backtick_end(rest,i);if scan_error!="" {return Native_Shell_Parameter{error=scan_error}};i=scan_end-1;continue}
            if rest[i]=='/' {separator=i;break}
        }
        pattern_source,replacement_source:=rest,"";if separator>=0 {pattern_source=rest[:separator];replacement_source=rest[separator+1:]}
        pattern,pattern_error:=native_shell_pattern(shell,pattern_source,depth)
        if pattern_error!="" {return Native_Shell_Parameter{error=pattern_error}}
        retain_quotes:=quoted&&native_shell_compat_level(shell)<=42
        replacement_fields,replacement_error:=native_shell_expand_fields(shell,replacement_source,false,depth+1,false,retain_quotes)
        if replacement_error!="" {return Native_Shell_Parameter{error=replacement_error}}
        replacement_bytes:=make([dynamic]u8)
        for field in replacement_fields {for i:=0;i<len(field.bytes);i+=1 {
            ch:=field.bytes[i]
            if retain_quotes&&ch=='\\'&&i+1<len(field.bytes)&&(field.bytes[i+1]=='\\'||field.bytes[i+1]=='&') {append(&replacement_bytes,'\\',field.bytes[i+1]);i+=1;continue}
            if ch=='\\'||ch=='&'&&(!shell.compat.shopts["patsub_replacement"]||i<len(field.quoted)&&field.quoted[i]) {append(&replacement_bytes,'\\')}
            append(&replacement_bytes,ch)
        }}
        for value in values {append(&result,native_shell_pattern_replace(shell,value,pattern,string(replacement_bytes[:]),all,anchor))}
    } else if operation[0]=='^'||operation[0]==',' {
        upper:=operation[0]=='^';all:=len(operation)>1&&operation[1]==operation[0];skip:=1;if all {skip=2}
        pattern,pattern_error:=native_shell_pattern(shell,operation[skip:],depth)
        if pattern_error!="" {return Native_Shell_Parameter{error=pattern_error}}
        if pattern=="" {pattern="?"}
        for value in values {
            output:=make([dynamic]u8);first:=true
            for at:=0;at<len(value); {
                _,count,_:=native_shell_text_character(value[at:]);count=max(1,count)
                character:=value[at:at+count]
                if (all||first)&&native_shell_pattern_matches(shell,pattern,character) {append(&output,native_shell_text_case(character,upper))} else {append(&output,character)}
                at+=count;first=false
            }
            append(&result,string(output[:]))
        }
    } else if strings.has_prefix(operation,"@")&&len(operation)==2 {
        transform:=operation[1]
        if transform=='a' {return native_shell_parameter_text(native_shell_parameter_attributes(shell,name))}
        if !exists&&!multi {
            if transform=='A'&&(shell.compat.declared[name]||shell.compat.attributes[name]!=0) {
                attributes:=native_shell_parameter_attributes(shell,name)
                if attributes=="" {attributes="-"}
                return native_shell_parameter_text(fmt.aprintf("declare -%s %s",attributes,name))
            }
            return native_shell_parameter_text("")
        }
        if transform=='A'||transform=='K'||transform=='k' {
            base:=name;if bracket:=strings.index_byte(base,'[');bracket>=0 {base=base[:bracket]}
            array,has_array:=shell.compat.arrays[base]
            if multi&&has_array {
                keys:=native_shell_array_values(shell,base,true);parts:=make([dynamic]string)
                if transform=='k' {for key,index in keys {append(&parts,key,values[index])};return native_shell_parameter_list(parts[:],star)}
                pairs:=make([dynamic]string)
                for key,index in keys {
                    quoted_value:=native_shell_parameter_double_quote(values[index])
                    if transform=='A' {append(&pairs,fmt.aprintf("[%s]=%s",key,quoted_value))} else {append(&pairs,fmt.aprintf("%s %s",key,quoted_value))}
                }
                body:=strings.join(pairs[:]," ");if array.associative_mode&&len(pairs)>0 {body=native_shell_expansion_join(body," ")}
                if transform=='K' {return native_shell_parameter_text(body)}
                attributes:=native_shell_parameter_attributes(shell,base)
                append(&parts,"declare",native_shell_expansion_join("-",attributes),fmt.aprintf("%s=(%s)",base,body))
                return native_shell_parameter_list(parts[:],star)
            }
            if transform=='A' {
                attributes:=native_shell_parameter_attributes(shell,name);assignment:=native_shell_expansion_join(name,"=",native_shell_parameter_quote(shell,text))
                if attributes!="" {assignment=fmt.aprintf("declare -%s %s",attributes,assignment)}
                return native_shell_parameter_text(assignment)
            }
            for value in values {append(&result,native_shell_parameter_quote(shell,value))};return native_shell_parameter_list(result[:],star)
        }
        for value in values {
            switch operation[1] {
            case 'Q':append(&result,native_shell_parameter_quote(shell,value))
            case 'E':decoded,_,decode_error:=native_shell_ansi_decode(value,0,false);if decode_error!="" {return Native_Shell_Parameter{error=decode_error}};append(&result,decoded)
            case 'U':append(&result,native_shell_text_case(value,true))
            case 'L':append(&result,native_shell_text_case(value,false))
            case 'u':append(&result,native_shell_text_case(value,true,true))
            case 'P':append(&result,native_shell_parameter_prompt(shell,value))
            case:return Native_Shell_Parameter{error=native_shell_expansion_join("unsupported parameter transformation: ",operation)}
            }
        }
    } else {return Native_Shell_Parameter{error=native_shell_expansion_join("bad substitution: ",expression)}}
    return native_shell_parameter_list(result[:],star)
}

native_shell_ansi_decode :: proc(raw:string,start:int,closing:bool)->(string,int,string) {
    bytes:=make([dynamic]u8);i:=start
    for i<len(raw) {
        ch:=raw[i];i+=1
        if closing&&ch=='\'' {return string(bytes[:]),i,""}
        if ch!='\\'||i>=len(raw) {append(&bytes,ch);continue}
        escaped:=raw[i];i+=1
        switch escaped {
        case 'a':append(&bytes,7)
        case 'b':append(&bytes,8)
        case 'e','E':append(&bytes,27)
        case 'f':append(&bytes,12)
        case 'n':append(&bytes,10)
        case 'r':append(&bytes,13)
        case 't':append(&bytes,9)
        case 'v':append(&bytes,11)
        case '\\','\'','"','?':append(&bytes,escaped)
        case '\n':
        case 'c':if i<len(raw) {append(&bytes,raw[i]&31);i+=1}
        case 'x','u','U','0','1','2','3','4','5','6','7':
            base:=16;limit:=2;value:u32;count:=0;unicode_value:=false
            if escaped=='u' {limit=4;unicode_value=true}
            else if escaped=='U' {limit=8;unicode_value=true}
            else if escaped>='0'&&escaped<='7' {base=8;limit=3;value=u32(escaped-'0');count=1}
            for count<limit&&i<len(raw) {
                digit:=-1;next:=raw[i]
                if next>='0'&&next<='9' {digit=int(next-'0')};if next>='a'&&next<='f' {digit=int(next-'a')+10};if next>='A'&&next<='F' {digit=int(next-'A')+10}
                if digit<0||digit>=base {break};value=value*u32(base)+u32(digit);count+=1;i+=1
            }
            if count==0 {append(&bytes,'\\',escaped)}
            else if unicode_value&&value!=0 {
                encoded:=native_shell_text_encode(rune(value))
                if encoded!="" {append(&bytes,encoded)}
                else {if escaped=='u' {append(&bytes,fmt.aprintf("\\u%04X",value))} else {append(&bytes,fmt.aprintf("\\U%08X",value))}}
            } else if !unicode_value&&value&255!=0 {append(&bytes,u8(value&255))}
            else {
                // Shell strings cannot contain NUL; ANSI-C quoting discards
                // the remainder of this string, while still consuming it.
                if !closing {return string(bytes[:]),len(raw),""}
                for i<len(raw)&&raw[i]!='\'' {if raw[i]=='\\'&&i+1<len(raw) {i+=1};i+=1}
            }
        case:append(&bytes,'\\',escaped)
        }
    }
    if closing {return "",0,"incomplete: unclosed ANSI-C quote"}
    return string(bytes[:]),i,""
}

native_shell_expand_parameter :: proc(shell:^Native_Shell,raw:string,offset:^int,depth:int=0,quoted:bool=false)->(string,string) {
    parameter:=native_shell_parameter_at(shell,raw,offset,depth,quoted)
    if parameter.error!="" {return "",parameter.error}
    parts:=make([dynamic]string);for field in parameter.fields {append(&parts,string(field.bytes[:]))}
    return strings.join(parts[:],native_shell_ifs_separator(shell)),""
}
native_shell_parameter_at :: proc(shell:^Native_Shell,raw:string,offset:^int,depth:int,quoted:bool=false)->Native_Shell_Parameter {
    i:=offset^+1
    if i>=len(raw) {offset^=i;return native_shell_parameter_text("$")}
    if raw[i]=='(' {
        if i+1<len(raw)&&raw[i+1]=='(' {
            end,error:=native_shell_arithmetic_end(raw,offset^)
            if error!="" {return Native_Shell_Parameter{error=error}}
            // The arithmetic evaluator owns the one shell-expansion phase.
            // Re-expanding its output here could execute substitution syntax
            // introduced by a variable value instead of treating it as data.
            expression:=raw[i+2:end-2];offset^=end
            value,arithmetic_error:=native_shell_arithmetic(shell,expression,true)
            if arithmetic_error!="" {return Native_Shell_Parameter{error=arithmetic_error}}
            return native_shell_parameter_text(fmt.aprintf("%d",value))
        }
        end,error:=native_shell_substitution_end(raw,offset^)
        if error!="" {return Native_Shell_Parameter{error=error}}
        value,capture_error:=native_shell_capture(shell,raw[i+1:end-1]);offset^=end
        if capture_error!="" {return Native_Shell_Parameter{error=capture_error}}
        return native_shell_parameter_text(value)
    }
    if raw[i]=='[' {
        end,error:=native_shell_legacy_arithmetic_end(raw,offset^)
        if error!="" {return Native_Shell_Parameter{error=error}}
        value,arithmetic_error:=native_shell_arithmetic(shell,raw[i+1:end-1],true);offset^=end
        if arithmetic_error!="" {return Native_Shell_Parameter{error=arithmetic_error}}
        return native_shell_parameter_text(fmt.aprintf("%d",value))
    }
    if raw[i]=='{' {
        beginning:=offset^
        end,error:=native_shell_parameter_end(raw,offset^,0,quoted)
        if error!="" {return Native_Shell_Parameter{error=error}}
        offset^=end
        if native_shell_brace_command(raw,beginning) {
            reply:=raw[i+1]=='|';first:=i+1;if reply {first+=1}
            value,capture_error:=native_shell_capture_current(shell,raw[first:end-1],reply)
            if capture_error!="" {return Native_Shell_Parameter{error=capture_error}}
            return native_shell_parameter_text(value)
        }
        return native_shell_parameter_expression(shell,raw[i+1:end-1],depth+1,quoted)
    }
    if native_shell_name_start(raw[i]) {
        start:=i;i+=1;for i<len(raw)&&native_shell_name_byte(raw[i]) {i+=1};offset^=i
        return native_shell_parameter_expression(shell,raw[start:i],depth+1,quoted)
    }
    if raw[i]>='0'&&raw[i]<='9'||strings.contains_any(raw[i:i+1],"@*#?$!-") {offset^=i+1;return native_shell_parameter_expression(shell,raw[i:i+1],depth+1,quoted)}
    offset^=i;return native_shell_parameter_text("$")
}

native_shell_expand_fields :: proc(shell:^Native_Shell,raw:string,split:bool,depth:int=0,inherited_quote:bool=false,preserve_quotes:bool=false)->(fields:[dynamic]Native_Shell_Field,error:string) {
    previous_locale:=native_shell_text_locale(shell);defer native_shell_text_locale_restore(previous_locale)
    if depth>=64 {return fields,"Expansion nesting limit reached."}
    expansion:=Native_Shell_Expansion{split=split};quote:u8;double_value:=false
    if inherited_quote {quote='"'}
    for i:=0;i<len(raw); {
        ch:=raw[i]
        if quote=='\'' {if ch=='\'' {quote=0} else {native_shell_field_byte(&expansion,ch,true)};i+=1;continue}
        if ch=='\\' {
            if i+1==len(raw) {return fields,"incomplete: trailing escape"}
            next:=raw[i+1]
            if next=='\n' {i+=2;continue}
            if quote=='"'&&next!='$'&&next!='`'&&next!='"'&&next!='\\' {native_shell_field_byte(&expansion,ch,true);i+=1;continue}
            native_shell_field_byte(&expansion,next,true);double_value=true;i+=2;continue
        }
        if ch=='"' {
            if preserve_quotes {native_shell_field_byte(&expansion,ch,true);i+=1;continue}
            if quote=='"' {if !double_value {expansion.current.present=true;expansion.current.protected_empty=true};quote=0}
            else {quote='"';double_value=false}
            i+=1;continue
        }
        if quote==0&&ch=='\'' {
            if preserve_quotes {native_shell_field_byte(&expansion,ch,false);i+=1;continue}
            quote='\'';expansion.current.present=true;expansion.current.protected_empty=true;i+=1;continue
        }
        if (quote==0||inherited_quote&&quote=='"')&&ch=='$'&&i+1<len(raw)&&raw[i+1]=='\'' {
            decoded,end,decode_error:=native_shell_ansi_decode(raw,i+2,true)
            if decode_error!="" {return fields,decode_error}
            native_shell_expansion_text(&expansion,decoded,true,false);i=end;continue
        }
        if quote==0&&ch=='$'&&i+1<len(raw)&&raw[i+1]=='"' {i+=1;continue}
        if ch=='$' {
            value:=native_shell_parameter_at(shell,raw,&i,depth,quote=='"')
            if value.error!="" {return fields,value.error}
            native_shell_parameter_insert(shell,&expansion,value,quote!=0);double_value=true;continue
        }
        if ch=='`' {
            end,scan_error:=native_shell_backtick_end(raw,i)
            if scan_error!="" {return fields,scan_error}
            body:=make([dynamic]u8);source:=raw[i+1:end-1]
            for j:=0;j<len(source);j+=1 {if source[j]=='\\'&&j+1<len(source)&&(source[j+1]=='$'||source[j+1]=='`'||source[j+1]=='\\'||source[j+1]=='\n') {j+=1;if source[j]=='\n' {continue}};append(&body,source[j])}
            value,capture_error:=native_shell_capture(shell,string(body[:]))
            if capture_error!="" {return fields,capture_error}
            native_shell_expansion_text(&expansion,value,quote!=0,true);double_value=true;i=end;continue
        }
        if quote==0&&(ch=='<'||ch=='>')&&i+1<len(raw)&&raw[i+1]=='(' {
            end,scan_error:=native_shell_process_end(raw,i)
            if scan_error!="" {return fields,scan_error}
            value,process_error:=native_shell_process_substitute(shell,raw[i+2:end-1],ch=='<')
            if process_error!="" {return fields,process_error}
            native_shell_expansion_text(&expansion,value,true,false);i=end;continue
        }
        if quote==0&&ch=='~'&&(i==0||!split&&(raw[i-1]=='='||raw[i-1]==':')) {
            end:=i+1;for end<len(raw)&&raw[end]!='/'&&(!(!split&&raw[end]==':')) {end+=1}
            user:=raw[i+1:end];home:="";resolved:=false
            if user=="" {
                home,resolved=native_shell_variable(shell,"HOME")
                if !resolved {entry:=native_shell_getpwuid(c.uint(posix.getuid()));if entry!=nil {home=string(entry.directory);resolved=true}}
            } else if user=="+" {home,resolved=native_shell_variable(shell,"PWD")}
            else if user=="-" {home,resolved=native_shell_variable(shell,"OLDPWD")}
            else {
                number:=user;reverse:=false
                if len(number)>1&&(number[0]=='+'||number[0]=='-') {reverse=number[0]=='-';number=number[1:]}
                if native_shell_digits(number) {
                    index,valid:=strconv.parse_int(number)
                    if valid {
                        stack:=native_shell_directory_stack_values(shell)
                        if reverse {index=len(stack)-1-index}
                        if index>=0&&index<len(stack) {home=stack[index];resolved=true}
                    }
                } else {entry:=native_shell_getpwnam(strings.clone_to_cstring(user));if entry!=nil {home=string(entry.directory);resolved=true}}
            }
            if resolved {native_shell_expansion_text(&expansion,home,true,false);i=end;continue}
        }
        native_shell_field_byte(&expansion,ch,quote!=0);if quote=='"' {double_value=true};i+=1
    }
    expected_quote:u8;if inherited_quote {expected_quote='"'}
    if quote!=expected_quote {return fields,"incomplete: unclosed quote"}
    native_shell_field_finish(&expansion)
    return expansion.fields,""
}

native_shell_split_character :: proc(field:^Native_Shell_Field,ifs:string,at:int)->(width:int,delimiter,white:bool) {
    ch,n,_:=native_shell_text_character(string(field.bytes[at:]));if n<=0 {n=1}
    for i:=at;i<at+n;i+=1 {if i>=len(field.splittable)||!field.splittable[i] {return n,false,false}}
    for index:=0;index<len(ifs); {separator,count,_:=native_shell_text_character(ifs[index:]);if separator==ch {return n,true,ch==' '||ch=='\t'||ch=='\n'};index+=max(1,count)}
    return n,false,false
}
native_shell_split_fields :: proc(shell:^Native_Shell,fields:[]Native_Shell_Field)->[]Native_Shell_Field {
    result:=make([dynamic]Native_Shell_Field);ifs:=native_shell_ifs(shell)
    for &field in fields {
        if ifs=="" {append(&result,field);continue}
        expansion:Native_Shell_Expansion
        for i:=0;i<len(field.bytes); {
            width,delimiter,white:=native_shell_split_character(&field,ifs,i)
            if !delimiter {
                for j:=i;j<i+width;j+=1 {native_shell_field_byte(&expansion,field.bytes[j],j<len(field.quoted)&&field.quoted[j])}
                i+=width;continue
            }
            if white {
                j:=i
                for j<len(field.bytes) {n,is_separator,is_white:=native_shell_split_character(&field,ifs,j);if !is_separator||!is_white {break};j+=n}
                if j<len(field.bytes) {_,is_separator,is_white:=native_shell_split_character(&field,ifs,j);if is_separator&&!is_white {i=j;continue}}
                native_shell_field_finish(&expansion);i=j;continue
            }
            if !expansion.current.present {expansion.current.present=true}
            native_shell_field_finish(&expansion);i+=width
            for i<len(field.bytes) {n,is_separator,is_white:=native_shell_split_character(&field,ifs,i);if !is_separator||!is_white {break};i+=n}
        }
        if expansion.current.present {native_shell_field_finish(&expansion)}
        else if len(field.bytes)==0&&field.present {append(&expansion.fields,field)}
        append(&result,..expansion.fields[:])
    }
    return result[:]
}

native_shell_brace_expand :: proc(raw:string,depth:int=0)->([]string,string) {
    if depth>=32 {return nil,"Brace expansion nesting limit reached."}
    quote:u8;opening:=-1
    for i:=0;i<len(raw);i+=1 {
        ch:=raw[i]
        if ch=='\\' {i+=1;continue}
        if quote!=0 {if ch==quote {quote=0};continue}
        if ch=='\''||ch=='"'||ch=='`' {quote=ch;continue}
        if ch=='$'&&i+1<len(raw)&&(raw[i+1]=='{'||raw[i+1]=='(') {
            end:int;error:string
            if raw[i+1]=='{' {end,error=native_shell_parameter_end(raw,i)} else if i+2<len(raw)&&raw[i+2]=='(' {end,error=native_shell_arithmetic_end(raw,i)} else {end,error=native_shell_substitution_end(raw,i)}
            if error!="" {return nil,error};i=end-1;continue
        }
        if (ch=='<'||ch=='>')&&i+1<len(raw)&&raw[i+1]=='(' {
            end,error:=native_shell_process_end(raw,i);if error!="" {return nil,error};i=end-1;continue
        }
        if ch=='{' {opening=i;break}
    }
    if opening<0 {return native_shell_single_word(raw),""}
    nesting:=1;closing:=-1;commas:=make([dynamic]int);quote=0
    for i:=opening+1;i<len(raw);i+=1 {
        ch:=raw[i];if ch=='\\' {i+=1;continue}
        if quote!=0 {if ch==quote {quote=0};continue};if ch=='\''||ch=='"' {quote=ch;continue}
        if ch=='{' {nesting+=1};if ch=='}' {nesting-=1;if nesting==0 {closing=i;break}}
        if ch==','&&nesting==1 {append(&commas,i)}
    }
    if closing<0 {return native_shell_single_word(raw),""}
    choices:=make([dynamic]string)
    if len(commas)>0 {
        start:=opening+1;for comma in commas {append(&choices,raw[start:comma]);start=comma+1};append(&choices,raw[start:closing])
    } else {
        expression:=raw[opening+1:closing];parts:=strings.split(expression,"..")
        if len(parts)==2||len(parts)==3 {
            first,first_ok:=strconv.parse_i64(parts[0]);last,last_ok:=strconv.parse_i64(parts[1]);step:i64=1
            if len(parts)==3 {parsed,ok:=strconv.parse_i64(parts[2]);if !ok {return native_shell_single_word(raw),""};step=abs(parsed);if step==0 {step=1}}
            letters:=!first_ok&&!last_ok&&len(parts[0])==1&&len(parts[1])==1&&((parts[0][0]>='a'&&parts[0][0]<='z')||(parts[0][0]>='A'&&parts[0][0]<='Z'))&&((parts[1][0]>='a'&&parts[1][0]<='z')||(parts[1][0]>='A'&&parts[1][0]<='Z'))
            if letters {first=i64(parts[0][0]);last=i64(parts[1][0]);first_ok=true;last_ok=true}
            if first_ok&&last_ok {
                if first>last {step= -step}
                padded:=len(parts[0])>1&&parts[0][0]=='0'||len(parts[1])>1&&parts[1][0]=='0'||len(parts[0])>2&&parts[0][:2]=="-0"||len(parts[1])>2&&parts[1][:2]=="-0";width:=max(len(parts[0]),len(parts[1]))
                for value:=first;(step>0&&value<=last)||(step<0&&value>=last); {
                    text:=fmt.aprintf("%d",value)
                    if letters {letter:=[1]u8{u8(value)};text=strings.clone(string(letter[:]))}
                    else if padded {negative:=value<0;digits:=text;if negative {digits=digits[1:]};padding:=width-len(digits);if negative {padding-=1};zeros:=make([]u8,max(0,padding));for &byte in zeros {byte='0'};text=native_shell_expansion_join(string(zeros),digits);if negative {text=native_shell_expansion_join("-",text)}}
                    append(&choices,text)
                    if value==last {break}
                    next:=i64(u64(value)+u64(step))
                    if step>0&&next<value||step<0&&next>value {break}
                    value=next
                }
            }
        }
    }
    if len(choices)==0 {
        inner,error:=native_shell_brace_expand(raw[opening+1:closing],depth+1);if error!="" {return nil,error}
        suffix,suffix_error:=native_shell_brace_expand(raw[closing+1:],depth+1);if suffix_error!="" {return nil,suffix_error}
        result:=make([dynamic]string)
        for value in inner {for tail in suffix {append(&result,native_shell_expansion_join(raw[:opening],"{",value,"}",tail))}}
        return result[:],""
    }

    result:=make([dynamic]string)
    for choice in choices {
        expanded,error:=native_shell_brace_expand(native_shell_expansion_join(raw[:opening],choice,raw[closing+1:]),depth+1)
        if error!="" {return nil,error}
        append(&result,..expanded)
    }
    return result[:],""
}

native_shell_field_pattern :: proc(shell:^Native_Shell,field:^Native_Shell_Field) {
    clear(&field.pattern);field.glob=false
    for ch,i in field.bytes {
        quoted:=i<len(field.quoted)&&field.quoted[i]
        if quoted&&(ch=='*'||ch=='?'||ch=='['||ch==']'||ch=='\\') {append(&field.pattern,'\\')}
        if !quoted&&(ch=='*'||ch=='?'||ch=='[') {field.glob=true}
        if !quoted&&shell.compat.shopts["extglob"]&&(ch=='@'||ch=='+'||ch=='!')&&i+1<len(field.bytes)&&field.bytes[i+1]=='(' {field.glob=true}
        append(&field.pattern,ch)
    }
}
native_shell_filename_matches :: proc(shell:^Native_Shell,pattern,value:string)->bool {
    previous:=strings.clone(string(libc.setlocale(.COLLATE,nil)))
    defer {if previous!="" {_=libc.setlocale(.COLLATE,strings.clone_to_cstring(previous))};delete(previous)}
    if shell.compat.shopts["globasciiranges"] {_=libc.setlocale(.COLLATE,"C")}
    flags:c.int
    if shell.compat.shopts["extglob"] {flags|=32}
    if shell.compat.shopts["nocaseglob"] {flags|=16}
    return native_shell_fnmatch(strings.clone_to_cstring(pattern),strings.clone_to_cstring(value),flags)==0
}
native_shell_dotglob :: proc(shell:^Native_Shell)->bool {return shell.compat.shopts["dotglob"]}
native_shell_glob_accept :: proc(shell:^Native_Shell,path:string,pattern:string="")->bool {
    path_parts:=strings.split(strings.trim_right(path,"/"),"/")
    pattern_parts:=strings.split(strings.trim_right(pattern,"/"),"/")
    if len(path_parts)==len(pattern_parts) {
        // glob(3) includes . and .. in intermediate components as well as
        // the final component. Literal ./.. components remain valid.
        for component,index in path_parts {
            if component!="."&&component!=".." {continue}
            part:=pattern_parts[index]
            if part!="."&&part!=".."&&(shell.compat.shopts["globskipdots"]||shell.variables["GLOBIGNORE"]!=""||!strings.has_prefix(part,".")) {return false}
        }
    }
    ignore:=shell.variables["GLOBIGNORE"]
    for ignored_pattern in strings.split_iterator(&ignore,":") {if ignored_pattern!=""&&native_shell_filename_matches(shell,ignored_pattern,path) {return false}}
    return true
}
native_shell_globstar :: proc(shell:^Native_Shell,pattern:string)->([]string,string) {
    // Walk only when ** is an entire pathname component. Symlink directories
    // are matched, but never recursively traversed, so cycles cannot spin.
    parts:=strings.split(pattern,"/");absolute:=strings.has_prefix(pattern,"/")
    results:=make([dynamic]string)
    initial:="";if absolute {initial="/"}
    error:=native_shell_globstar_walk(shell,parts,0,initial,&results,0)
    if strings.has_suffix(pattern,"/") {for &value in results {if !strings.has_suffix(value,"/") {value=native_shell_expansion_join(value,"/")}}}
    native_shell_glob_sort(shell,results[:]);return results[:],error
}

native_shell_globstar_walk :: proc(shell:^Native_Shell,parts:[]string,index:int,path:string,results:^[dynamic]string,depth:int)->string {
        if depth>128 {return "globstar traversal depth exceeded"}
        if index>=len(parts) {if path!="" {append(results,path)};return ""}
        part:=parts[index]
        if part=="" {return native_shell_globstar_walk(shell,parts,index+1,path,results,depth+1)}
        directory:=path;if directory=="" {directory="."}
        if part=="."||part==".." {
            child:=part;if path!="" {if path=="/" {child=native_shell_expansion_join(path,part)} else {child=native_shell_expansion_join(path,"/",part)}}
            return native_shell_globstar_walk(shell,parts,index+1,child,results,depth+1)
        }
        if part=="**"&&shell.compat.shopts["globstar"] {
            if index+1<len(parts) {if error:=native_shell_globstar_walk(shell,parts,index+1,path,results,depth+1);error!="" {return error}}
            entries,error:=os.read_all_directory_by_path(directory,context.allocator);if error!=nil {return ""}
            for entry in entries {
                if entry.name=="."||entry.name==".."||strings.has_prefix(entry.name,".")&&!native_shell_dotglob(shell) {continue}
                child:=entry.name;if path!="" {if path=="/" {child=native_shell_expansion_join(path,entry.name)} else {child=native_shell_expansion_join(path,"/",entry.name)}}
                if index+1==len(parts) {append(results,child)}
                if entry.type==.Directory {if recurse_error:=native_shell_globstar_walk(shell,parts,index,child,results,depth+1);recurse_error!="" {return recurse_error}}
            }
            return ""
        }
        entries,error:=os.read_all_directory_by_path(directory,context.allocator);if error!=nil {return ""}
        if !shell.compat.shopts["globskipdots"]&&shell.variables["GLOBIGNORE"]==""&&strings.has_prefix(part,".") {
            for name in ([]string{".",".."}) {
                if !native_shell_filename_matches(shell,part,name) {continue}
                child:=name;if path!="" {if path=="/" {child=native_shell_expansion_join(path,name)} else {child=native_shell_expansion_join(path,"/",name)}}
                if index+1==len(parts) {append(results,child)} else {if recurse_error:=native_shell_globstar_walk(shell,parts,index+1,child,results,depth+1);recurse_error!="" {return recurse_error}}
            }
        }
        for entry in entries {
            if strings.has_prefix(entry.name,".")&&!strings.has_prefix(part,".")&&!native_shell_dotglob(shell) {continue}
            if !native_shell_filename_matches(shell,part,entry.name) {continue}
            child:=entry.name;if path!="" {if path=="/" {child=native_shell_expansion_join(path,entry.name)} else {child=native_shell_expansion_join(path,"/",entry.name)}}
            if index+1==len(parts) {append(results,child)} else {
                directory:=entry.type==.Directory
                if !directory {if info,stat_error:=os.stat(child,context.allocator);stat_error==nil {directory=info.type==.Directory}}
                if directory {if recurse_error:=native_shell_globstar_walk(shell,parts,index+1,child,results,depth+1);recurse_error!="" {return recurse_error}}
            }
        }
        return ""
    }

native_shell_expand :: proc(shell:^Native_Shell,word:Native_Shell_Word,split:bool=true,glob:bool=true)->(words:[]string,error:string) {
    previous_locale:=native_shell_text_locale(shell);defer native_shell_text_locale_restore(previous_locale)
    spellings:=[]string{word.raw}
    if shell.compat.options["braceexpand"] {brace_error:string;spellings,brace_error=native_shell_brace_expand(word.raw);if brace_error!="" {return nil,brace_error}}
    result:=make([dynamic]string)
    for spelling in spellings {
        fields,expand_error:=native_shell_expand_fields(shell,spelling,true)
        if expand_error!="" {return nil,expand_error}
        split_fields:=fields[:]
        if split {split_fields=native_shell_split_fields(shell,fields[:])}
        for &field in split_fields {
            native_shell_field_pattern(shell,&field)
            if !glob||!field.glob||shell.compat.options["noglob"] {append(&result,string(field.bytes[:]));continue}
            if shell.compat.shopts["globstar"]&&strings.contains(string(field.pattern[:]),"**")||shell.compat.shopts["extglob"]||shell.compat.shopts["nocaseglob"]||shell.compat.shopts["globasciiranges"]&&strings.contains(string(field.pattern[:]),"[") {
                paths,glob_error:=native_shell_globstar(shell,string(field.pattern[:]))
                if glob_error!="" {return nil,glob_error}
                before:=len(result)
                for path in paths {if native_shell_glob_accept(shell,path,string(field.pattern[:])) {append(&result,path)}}
                if len(result)>before {continue}
                if shell.compat.shopts["failglob"] {return nil,native_shell_expansion_join("no match: ",string(field.bytes[:]))}
                if !shell.compat.shopts["nullglob"] {append(&result,string(field.bytes[:]))};continue
            }
            matches:Native_Shell_Glob
            flags:c.int=4 // GLOB_NOSORT; GLOBSORT controls ordering below.
            if native_shell_dotglob(shell) {flags|=128}
            code:=native_shell_glob(strings.clone_to_cstring(string(field.pattern[:])),flags,nil,&matches)
            if code==0 {
                paths:=cast([^]cstring)matches.pathv
                before:=len(result)
                for i in 0..<int(matches.pathc) {name:=string(paths[i]);if native_shell_glob_accept(shell,name,string(field.pattern[:])) {append(&result,strings.clone(name))}}
                native_shell_glob_sort(shell,result[before:])
                if len(result)==before {
                    if shell.compat.shopts["failglob"] {native_shell_glob_free(&matches);return nil,native_shell_expansion_join("no match: ",string(field.bytes[:]))}
                    if !shell.compat.shopts["nullglob"] {append(&result,string(field.bytes[:]))}
                }
            } else if code==3 {
                if shell.compat.shopts["failglob"] {native_shell_glob_free(&matches);return nil,native_shell_expansion_join("no match: ",string(field.bytes[:]))}
                if !shell.compat.shopts["nullglob"] {append(&result,string(field.bytes[:]))}
            }
            native_shell_glob_free(&matches)
            if code!=0&&code!=3 {return nil,"Could not expand filename pattern."}
        }
    }
    return result[:],""
}

native_shell_expand_assignment :: proc(shell:^Native_Shell,raw:string)->(string,string) {
    fields,error:=native_shell_expand_fields(shell,raw,false)
    if error!="" {return "",error}
    values:=make([dynamic]string);for field in fields {append(&values,string(field.bytes[:]))}
    return strings.join(values[:]," "),""
}

native_shell_expand_heredoc :: proc(shell:^Native_Shell,body:string)->(string,string) {
    previous_locale:=native_shell_text_locale(shell);defer native_shell_text_locale_restore(previous_locale)
    result:=make([dynamic]u8)
    for i:=0;i<len(body); {
        ch:=body[i]
        if ch=='\\'&&i+1<len(body)&&(body[i+1]=='$'||body[i+1]=='`'||body[i+1]=='\\'||body[i+1]=='\n') {i+=1;if body[i]!='\n' {append(&result,body[i])};i+=1;continue}
        if ch=='$' {
            value,error:=native_shell_expand_parameter(shell,body,&i,0,true)
            if error!="" {return "",error};append(&result,value);continue
        }
        if ch=='`' {
            end,error:=native_shell_backtick_end(body,i);if error!="" {return "",error}
            value,capture_error:=native_shell_capture(shell,body[i+1:end-1]);if capture_error!="" {return "",capture_error}
            append(&result,value);i=end;continue
        }
        append(&result,ch);i+=1
    }
    return string(result[:]),""
}

#+build linux
package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// Shell processes are isolated from the GUI. Parser options are process-local
// and inherited by native forked subshells, like their shell state.
native_shell_parser_shell:^Native_Shell
native_shell_parser_posix :: proc()->bool {return native_shell_parser_shell!=nil&&native_shell_parser_shell.compat!=nil&&native_shell_parser_shell.compat.options["posix"]}
native_shell_parser_compat :: proc()->int {return native_shell_compat_level(native_shell_parser_shell)}

Native_Shell_Word :: struct {raw:string}
Native_Shell_Redirect :: struct {fd:int, operator:string, target:Native_Shell_Word, body:string, expand_body:bool, variable:string}
Native_Shell_Command :: struct {words:[dynamic]Native_Shell_Word, redirects:[dynamic]Native_Shell_Redirect, compound:^Native_Shell_Compound, line:int}
Native_Shell_Pipeline :: struct {source:string, commands:[dynamic]Native_Shell_Command, connector:string, background,negate:bool, pipe_stderr:[]bool}
Native_Shell_Program :: struct {pipelines:[dynamic]Native_Shell_Pipeline}
Native_Shell_Token :: struct {raw:string, operator:bool, start,end:int, body:string, expand_body:bool}
Native_Shell_Compound :: struct {
    kind,name,source:string,
    line,source_line:int,
    condition_lines,body_lines:[]int,
    conditions,bodies:[]string,
    words:[]Native_Shell_Word,
    patterns:[][]Native_Shell_Word,
    terminators:[]string,
}
Native_Shell_Parser :: struct {source:string, tokens:[]Native_Shell_Token, position:int, error:string, depth:int, line_offsets:[]int}
Native_Shell_Heredoc :: struct {token:int, delimiter:string, strip_tabs:bool, expand:bool}

native_shell_name_start :: proc(ch:u8)->bool {return ch=='_'||(ch>='A'&&ch<='Z')||(ch>='a'&&ch<='z')}
native_shell_name_byte :: proc(ch:u8)->bool {return native_shell_name_start(ch)||(ch>='0'&&ch<='9')}
native_shell_name :: proc(name:string)->bool {
    if len(name)==0||!native_shell_name_start(name[0]) {return false}
    for ch in transmute([]u8)name {if !native_shell_name_byte(ch) {return false}}
    return true
}
// Bash function identifiers are unquoted shell words, rather than variable
// identifiers. Dashes, dots, digits and slashes are valid in function names.
native_shell_function_name :: proc(name:string)->bool {
    if name=="" {return false}
    for byte in transmute([]u8)name {
        if native_shell_delimiter(byte)||byte==0||strings.index_byte("'\"\\$`=",byte)>=0 {return false}
    }
    return true
}
native_shell_digits :: proc(text:string)->bool {if text=="" {return false};for byte in transmute([]u8)text {if byte<'0'||byte>'9' {return false}};return true}
native_shell_space :: proc(ch:u8)->bool {return ch==' '||ch=='\t'||ch=='\r'}
native_shell_delimiter :: proc(ch:u8)->bool {return native_shell_space(ch)||ch=='\n'||ch==';'||ch=='|'||ch=='&'||ch=='<'||ch=='>'||ch=='('||ch==')'}

// Bash 5.3's ${ command; } and ${| command; } execute in the current
// environment. Their closing brace follows a complete shell command, so a
// brace in a quoted string, nested compound, parameter or heredoc is data.
native_shell_brace_command :: proc(source:string,start:int)->bool {
    if start+2>=len(source) {return false}
    ch:=source[start+2]
    return ch==' '||ch=='\t'||ch=='\n'||ch=='|'
}
native_shell_brace_command_end :: proc(source:string,start:int,depth:int)->(int,string) {
    if depth>=128 {return 0,"Command substitution nesting limit reached."}
    body_start:=start+2
    if source[body_start]=='|' {body_start+=1}
    for i:=body_start;i<len(source);i+=1 {
        if source[i]!='}'||i==body_start||!native_shell_delimiter(source[i-1])&&source[i-1]!='}' {continue}
        body:=source[body_start:i]
        program,error:=native_shell_parse(body)
        if error!=""||len(program.pipelines)==0 {continue}
        // A simple command must be terminated before the closing brace.
        // A compound command's own terminator is sufficient.
        last:=len(body)-1
        for last>=0&&native_shell_space(body[last]) {last-=1}
        terminated:=last>=0&&(body[last]==';'||body[last]=='\n'||body[last]=='&')
        pipeline:=program.pipelines[len(program.pipelines)-1]
        if !terminated&&len(pipeline.commands)>0&&pipeline.commands[len(pipeline.commands)-1].compound==nil {continue}
        return i+1,""
    }
    return 0,"incomplete: unclosed current-environment command substitution"
}

native_shell_parameter_name_end :: proc(source:string,start:int)->int {
    at:=start+2
    if at>=len(source) {return at}
    if source[at]=='!'||source[at]=='#' {at+=1}
    if at>=len(source) {return at}
    if native_shell_name_start(source[at]) {at+=1;for at<len(source)&&native_shell_name_byte(source[at]) {at+=1}}
    else if source[at]>='0'&&source[at]<='9' {at+=1;for at<len(source)&&source[at]>='0'&&source[at]<='9' {at+=1}}
    else {at+=1}
    if at<len(source)&&source[at]=='[' {
        brackets:=1;at+=1;quote:u8
        for at<len(source)&&brackets>0 {
            ch:=source[at]
            if ch=='\\' {at+=2;continue}
            if quote!=0 {if ch==quote {quote=0};at+=1;continue}
            if ch=='\''||ch=='"' {quote=ch;at+=1;continue}
            if ch=='[' {brackets+=1};if ch==']' {brackets-=1};at+=1
        }
    }
    return at
}
native_shell_parameter_pattern_operator :: proc(source:string,start:int)->bool {
    at:=native_shell_parameter_name_end(source,start)
    return at<len(source)&&strings.index_byte("#%/^,",source[at])>=0
}

native_shell_parameter_end :: proc(source:string,start:int,depth:int=0,double_quoted:bool=false)->(int,string) {
    if depth>=128 {return 0,"Parameter expansion nesting limit reached."}
    if native_shell_brace_command(source,start) {return native_shell_brace_command_end(source,start,depth+1)}
    i:=start+2;quote:u8
    special_single:=!double_quoted||!native_shell_parser_posix()||native_shell_parser_compat()<=42||native_shell_parameter_pattern_operator(source,start)
    name_end:=native_shell_parameter_name_end(source,start)
    unmatched_close:=0
    for i<len(source) {
        ch:=source[i]
        if ch==0 {return 0,"NUL bytes are not valid shell input."}
        if quote=='\'' {if ch=='\'' {quote=0};if ch=='}'&&unmatched_close==0 {unmatched_close=i+1};i+=1;continue}
        if ch=='\\' {i+=2;continue}
        if ch=='$'&&i+1<len(source)&&source[i+1]=='{' {end,error:=native_shell_parameter_end(source,i,depth+1,double_quoted||quote=='"');if error!="" {return 0,error};i=end;continue}
        if ch=='$'&&i+1<len(source)&&source[i+1]=='(' {end,error:=native_shell_substitution_end(source,i,depth+1);if error!="" {return 0,error};i=end;continue}
        if ch=='`' {end,error:=native_shell_backtick_end(source,i);if error!="" {return 0,error};i=end;continue}
        if ch=='"' {if quote=='"' {quote=0} else {quote='"'};i+=1;continue}
        if quote==0 {if ch=='\''&&(special_single||i<name_end) {quote='\'';unmatched_close=0;i+=1;continue};if ch=='}' {return i+1,""}}
        i+=1
    }
    if quote=='\''&&unmatched_close>0&&double_quoted&&native_shell_parser_posix()&&native_shell_parser_compat()==42 {return unmatched_close,""}
    return 0,"incomplete: unclosed parameter expansion"
}

native_shell_substitution_end :: proc(source:string,start:int,depth:int=0)->(int,string) {
    if depth>=128 {return 0,"Command substitution nesting limit reached."}
    if start+2<len(source)&&source[start+2]=='(' {return native_shell_arithmetic_end(source,start)}
    i:=start+2;quote:u8;parentheses:=1
    for i<len(source) {
        ch:=source[i]
        if ch==0 {return 0,"NUL bytes are not valid shell input."}
        if quote=='\'' {if ch=='\'' {quote=0};i+=1;continue}
        if ch=='\\' {i+=2;continue}
        if quote==0&&ch=='#'&&(i==start+2||native_shell_delimiter(source[i-1])) {for i<len(source)&&source[i]!='\n' {i+=1};continue}
        if ch=='$'&&i+1<len(source)&&source[i+1]=='{' {end,error:=native_shell_parameter_end(source,i,depth+1,quote=='"');if error!="" {return 0,error};i=end;continue}
        if ch=='$'&&i+1<len(source)&&source[i+1]=='(' {end,error:=native_shell_substitution_end(source,i,depth+1);if error!="" {return 0,error};i=end;continue}
        if ch=='`' {end,error:=native_shell_backtick_end(source,i);if error!="" {return 0,error};i=end;continue}
        if ch=='"' {if quote=='"' {quote=0} else {quote='"'};i+=1;continue}
        if quote==0 {
            if ch=='\'' {quote='\'';i+=1;continue}
            if ch=='(' {parentheses+=1}
            if ch==')' {
                parentheses-=1
                if parentheses==0 {
                    // A case-pattern terminator is shell grammar, not the
                    // substitution's closing parenthesis. Validate its body
                    // at candidate boundaries instead of truncating it.
                    fragment:=source[start+2:i]
                    if strings.contains(fragment,"case") {
                        _,fragment_error:=native_shell_parse(fragment)
                        if strings.has_prefix(fragment_error,"incomplete:") {parentheses=1;i+=1;continue}
                    }
                    return i+1,""
                }
            }
        }
        i+=1
    }
    return 0,"incomplete: unclosed command substitution"
}

native_shell_parenthesis_end :: proc(source:string,start:int)->(int,string) {
    // Reuse command-substitution quote/nesting rules without expanding it.
    synthetic:=strings.concatenate([]string{"$",source[start:]})
    end,error:=native_shell_substitution_end(synthetic,0)
    return start+end-1,error
}
native_shell_heredoc_delimiter :: proc(raw:string)->(string,bool) {
    result:=make([dynamic]u8);quote:u8;quoted:=false
    for i:=0;i<len(raw);i+=1 {
        ch:=raw[i]
        if quote!=0 {if ch==quote {quote=0;quoted=true;continue};if ch=='\\'&&quote=='"'&&i+1<len(raw) {i+=1;ch=raw[i]};append(&result,ch);continue}
        if ch=='$'&&i+1<len(raw)&&raw[i+1]=='\'' {
            decoded,end,decode_error:=native_shell_ansi_decode(raw,i+2,true)
            if decode_error=="" {append(&result,decoded);quoted=true;i=end-1;continue}
        }
        if ch=='\''||ch=='"' {quote=ch;quoted=true;continue}
        if ch=='\\'&&i+1<len(raw) {quoted=true;i+=1;ch=raw[i]}
        append(&result,ch)
    }
    return string(result[:]),!quoted
}

native_shell_tokens :: proc(source:string)->(tokens:[dynamic]Native_Shell_Token,error:string) {
    pending:=make([dynamic]Native_Shell_Heredoc)
    for i:=0;i<len(source); {
        if native_shell_space(source[i]) {i+=1;continue}
        if source[i]==0 {return tokens,"NUL bytes are not valid shell input."}
        if source[i]=='\\'&&i+1<len(source)&&source[i+1]=='\n' {i+=2;continue}
        if source[i]=='#' {for i<len(source)&&source[i]!='\n' {i+=1};continue}
        begin:=i
        if source[i]=='\n' {
            append(&tokens,Native_Shell_Token{raw="\n",operator=true,start=i,end=i+1});i+=1
            for document in pending {
                body:=make([dynamic]u8);found:=false
                for i<=len(source) {
                    end:=i;for end<len(source)&&source[end]!='\n' {end+=1}
                    line:=source[i:end]
                    if document.strip_tabs {for len(line)>0&&line[0]=='\t' {line=line[1:]}}
                    if line==document.delimiter {i=end;if i<len(source) {i+=1};found=true;break}
                    append(&body,line);if end<len(source) {append(&body,'\n')}
                    if end==len(source) {break};i=end+1
                }
                if !found {return tokens,fmt.tprintf("incomplete: heredoc needs delimiter %s",document.delimiter)}
                tokens[document.token].body=string(body[:]);tokens[document.token].expand_body=document.expand
            }
            clear(&pending);continue
        }
        if source[i]=='('&&i+1<len(source)&&source[i+1]=='(' {
            synthetic:=strings.concatenate([]string{"$",source[i:]});end,scan_error:=native_shell_arithmetic_end(synthetic,0)
            if scan_error!="" {return tokens,scan_error};i+=end-1
            append(&tokens,Native_Shell_Token{raw=source[begin:i],start=begin,end=i});continue
        }
        if strings.has_prefix(source[i:],"[[")&&(i+2==len(source)||native_shell_delimiter(source[i+2])) {
            i+=2;quote:u8;found:=false
            for i<len(source) {
                ch:=source[i]
                if ch=='\\' {i+=2;continue}
                if quote=='\'' {if ch=='\'' {quote=0};i+=1;continue}
                if ch=='$'&&i+1<len(source)&&(source[i+1]=='('||source[i+1]=='{') {
                    end:int;scan_error:string
                    if source[i+1]=='(' {end,scan_error=native_shell_substitution_end(source,i)} else {end,scan_error=native_shell_parameter_end(source,i,0,quote=='"')}
                    if scan_error!="" {return tokens,scan_error};i=end;continue
                }
                if ch=='`' {end,scan_error:=native_shell_backtick_end(source,i);if scan_error!="" {return tokens,scan_error};i=end;continue}
                if ch=='"' {if quote=='"' {quote=0} else {quote='"'};i+=1;continue}
                if quote=='"' {i+=1;continue}
                if ch=='\'' {quote=ch;i+=1;continue}
                if strings.has_prefix(source[i:],"]]")&&(i==begin+2||native_shell_delimiter(source[i-1]))&&(i+2==len(source)||native_shell_delimiter(source[i+2])) {i+=2;found=true;break};i+=1
            }
            if !found {return tokens,"incomplete: conditional command needs ]]"}
            append(&tokens,Native_Shell_Token{raw=source[begin:i],start=begin,end=i});continue
        }
        process:=i+1<len(source)&&(source[i]=='<'||source[i]=='>')&&source[i+1]=='('
        if !process&&(source[i]==';'||source[i]=='|'||source[i]=='&'||source[i]=='<'||source[i]=='>'||source[i]=='('||source[i]==')') {
            i+=1
            if i+1<len(source) {
                triple:=source[begin:i+2]
                switch triple {case ";;&","<<<","<<-","&>>":i+=2}
            }
            if i==begin+1&&i<len(source) {
                pair:=source[begin:i+1]
                switch pair {case "&&","||",">>","<<",">&","<&","<>",">|","&>","|&",";;",";&":i+=1}
            }
            append(&tokens,Native_Shell_Token{raw=source[begin:i],operator=true,start=begin,end=i});continue
        }
        quote:u8
        for i<len(source) {
            ch:=source[i]
            if ch==0 {return tokens,"NUL bytes are not valid shell input."}
            if quote=='\'' {i+=1;if ch=='\'' {quote=0};continue}
            if ch=='\\' {if i+1==len(source) {return tokens,"incomplete: trailing escape"};i+=2;continue}
            if ch=='`' {end,scan_error:=native_shell_backtick_end(source,i);if scan_error!="" {return tokens,scan_error};i=end;continue}
            if ch=='$'&&i+1<len(source)&&source[i+1]=='[' {end,scan_error:=native_shell_legacy_arithmetic_end(source,i);if scan_error!="" {return tokens,scan_error};i=end;continue}
            if ch=='$'&&i+1<len(source)&&source[i+1]=='(' {end,scan_error:=native_shell_substitution_end(source,i);if scan_error!="" {return tokens,scan_error};i=end;continue}
            if ch=='$'&&i+1<len(source)&&source[i+1]=='{' {end,scan_error:=native_shell_parameter_end(source,i,0,quote=='"');if scan_error!="" {return tokens,scan_error};i=end;continue}
            if quote==0&&ch=='$'&&i+1<len(source)&&source[i+1]=='\'' {
                i+=2;found:=false
                for i<len(source) {if source[i]=='\\' {i+=2;continue};if source[i]=='\'' {i+=1;found=true;break};i+=1}
                if !found {return tokens,"incomplete: unclosed ANSI-C quote"};continue
            }
            if quote=='"' {i+=1;if ch=='"' {quote=0};continue}
            if ch=='\''||ch=='"' {quote=ch;i+=1;continue}
            if (ch=='<'||ch=='>')&&i+1<len(source)&&source[i+1]=='(' {end,scan_error:=native_shell_process_end(source,i);if scan_error!="" {return tokens,scan_error};i=end;continue}
            if ch=='('&&i>begin&&(source[i-1]=='='||source[i-1]=='@'||source[i-1]=='!'||source[i-1]=='?'||source[i-1]=='*'||source[i-1]=='+') {
                end,scan_error:=native_shell_parenthesis_end(source,i);if scan_error!="" {return tokens,scan_error};i=end;continue
            }
            if native_shell_delimiter(ch) {break};i+=1
        }
        if quote!=0 {return tokens,"incomplete: unclosed quote"}
        if i==begin {return tokens,"Invalid shell input."}
        append(&tokens,Native_Shell_Token{raw=source[begin:i],start=begin,end=i})
        if len(tokens)>=2 {
            previous:=tokens[len(tokens)-2]
            if previous.raw=="<<"||previous.raw=="<<-" {delimiter,expand:=native_shell_heredoc_delimiter(source[begin:i]);append(&pending,Native_Shell_Heredoc{len(tokens)-2,delimiter,previous.raw=="<<-",expand})}
        }
    }
    if len(pending)>0 {return tokens,"incomplete: heredoc needs a newline and delimiter"}
    return
}

native_shell_redirect_operator :: proc(word:string)->bool {
    switch word {case "<",">",">>","<&",">&","<<","<<-","<<<","<>",">|","&>","&>>":return true};return false
}
native_shell_reserved :: proc(word:string)->bool {switch word {case "if","then","elif","else","fi","for","while","until","do","done","case","esac","in","function","select","coproc","time","{","}","!":return true};return false}
native_shell_parser_peek :: proc(p:^Native_Shell_Parser)->string {if p.position>=len(p.tokens) {return ""};return p.tokens[p.position].raw}
native_shell_parser_at :: proc(p:^Native_Shell_Parser,choices:[]string)->bool {word:=native_shell_parser_peek(p);for choice in choices {if word==choice {return true}};return false}
native_shell_parser_error :: proc(p:^Native_Shell_Parser,message:string) {if p.error=="" {p.error=message}}
native_shell_parser_expect :: proc(p:^Native_Shell_Parser,word:string)->bool {
    if native_shell_parser_peek(p)!=word {prefix:="";if p.position>=len(p.tokens) {prefix="incomplete: "};native_shell_parser_error(p,fmt.tprintf("%sexpected %s",prefix,word));return false};p.position+=1;return true
}
native_shell_parser_newlines :: proc(p:^Native_Shell_Parser) {for native_shell_parser_peek(p)=="\n" {p.position+=1}}
native_shell_parser_line :: proc(p:^Native_Shell_Parser,index:int)->int {
    offset:=len(p.source);if index<len(p.tokens) {offset=p.tokens[index].start}
    first,last:=0,len(p.line_offsets)
    for first<last {middle:=(first+last)/2;if p.line_offsets[middle]<offset {first=middle+1} else {last=middle}}
    return first+1
}
native_shell_parser_source :: proc(p:^Native_Shell_Parser,first,last:int)->string {
    if first>=len(p.tokens)||first==last {return ""}
    end:=len(p.source);if last<len(p.tokens) {end=p.tokens[last].start}
    return p.source[p.tokens[first].start:end]
}
native_shell_parser_body :: proc(p:^Native_Shell_Parser,stops:[]string,required:bool=true)->string {
    start:=p.position;body:=native_shell_parser_list(p,stops)
    if required&&len(body.pipelines)==0&&p.error=="" {prefix:="";if p.position>=len(p.tokens) {prefix="incomplete: "};native_shell_parser_error(p,strings.concatenate([]string{prefix,"expected a command"}))}
    return native_shell_parser_source(p,start,p.position)
}

native_shell_parser_redirect :: proc(p:^Native_Shell_Parser,command:^Native_Shell_Command)->bool {
    if p.position>=len(p.tokens) {return false}
    token:=p.tokens[p.position];fd:=-1;variable:=""
    if !token.operator&&p.position+1<len(p.tokens)&&token.end==p.tokens[p.position+1].start&&native_shell_redirect_operator(p.tokens[p.position+1].raw) {
        if native_shell_digits(token.raw) {number,ok:=strconv.parse_int(token.raw);if !ok||number<0||number>2147483647 {native_shell_parser_error(p,"Invalid redirection descriptor.");return true};fd=number;p.position+=1;token=p.tokens[p.position]}
        else if len(token.raw)>2&&token.raw[0]=='{'&&token.raw[len(token.raw)-1]=='}'&&native_shell_name(token.raw[1:len(token.raw)-1]) {variable=token.raw[1:len(token.raw)-1];p.position+=1;token=p.tokens[p.position]}
    }
    if !native_shell_redirect_operator(token.raw) {return false}
    if fd<0 {fd=1;if token.raw[0]=='<' {fd=0}}
    p.position+=1
    if p.position>=len(p.tokens) {native_shell_parser_error(p,"incomplete: redirection needs a target");return true}
    target:=p.tokens[p.position]
    if target.operator {native_shell_parser_error(p,"Redirection needs a word as its target.");return true}
    p.position+=1
    append(&command.redirects,Native_Shell_Redirect{fd=fd,operator=token.raw,target={raw=target.raw},body=token.body,expand_body=token.expand_body,variable=variable})
    return true
}

native_shell_parser_time_reserved :: proc(p:^Native_Shell_Parser)->bool {
    if !native_shell_parser_posix()||native_shell_parser_compat()<=41 {return true}
    return p.position+1>=len(p.tokens)||!strings.has_prefix(p.tokens[p.position+1].raw,"-")
}

native_shell_parser_compound :: proc(p:^Native_Shell_Parser)->^Native_Shell_Compound {
    if p.depth>=128 {native_shell_parser_error(p,"Shell grammar nesting limit reached.");return nil}
    p.depth+=1;defer {p.depth-=1}
    word:=native_shell_parser_peek(p)
    if word=="time"&&!native_shell_parser_time_reserved(p) {return nil}
    compound:=new(Native_Shell_Compound);compound.kind=word;compound.line=native_shell_parser_line(p,p.position);compound.source_line=compound.line
    if strings.has_prefix(word,"((")&&strings.has_suffix(word,"))") {compound.kind="arithmetic";compound.source=word[2:len(word)-2];p.position+=1;return compound}
    if strings.has_prefix(word,"[[")&&strings.has_suffix(word,"]]") {
        compound.kind="conditional";compound.source=word[2:len(word)-2]
        tokens,token_error:=native_shell_conditional_tokens(compound.source)
        conditional:=Native_Shell_Conditional{shell=native_shell_parser_shell,tokens=tokens[:]}
        if token_error=="" {_=native_shell_conditional_or(&conditional,false)}
        if token_error!=""||conditional.error!=""||conditional.position<len(tokens) {native_shell_parser_error(p,"Invalid conditional expression.")}
        p.position+=1;return compound
    }
    switch word {
    case "{","(":
        p.position+=1;end:="}";compound.kind="group";if word=="(" {end=")";compound.kind="subshell"}
        compound.source_line=native_shell_parser_line(p,p.position);compound.source=native_shell_parser_body(p,[]string{end});_=native_shell_parser_expect(p,end);return compound
    case "if":
        p.position+=1;conditions:=make([dynamic]string);bodies:=make([dynamic]string);condition_lines:=make([dynamic]int);body_lines:=make([dynamic]int)
        for {
            append(&condition_lines,native_shell_parser_line(p,p.position));append(&conditions,native_shell_parser_body(p,[]string{"then"}));if !native_shell_parser_expect(p,"then") {break}
            append(&body_lines,native_shell_parser_line(p,p.position));append(&bodies,native_shell_parser_body(p,[]string{"elif","else","fi"}))
            if native_shell_parser_peek(p)=="elif" {p.position+=1;continue}
            if native_shell_parser_peek(p)=="else" {p.position+=1;append(&body_lines,native_shell_parser_line(p,p.position));append(&bodies,native_shell_parser_body(p,[]string{"fi"}))}
            _=native_shell_parser_expect(p,"fi");break
        }
        compound.conditions=conditions[:];compound.bodies=bodies[:];compound.condition_lines=condition_lines[:];compound.body_lines=body_lines[:];return compound
    case "while","until":
        p.position+=1;condition_line:=native_shell_parser_line(p,p.position);condition:=native_shell_parser_body(p,[]string{"do"});_=native_shell_parser_expect(p,"do")
        body_line:=native_shell_parser_line(p,p.position);body:=native_shell_parser_body(p,[]string{"done"});_=native_shell_parser_expect(p,"done")
        compound.conditions=make([]string,1);compound.conditions[0]=condition;compound.bodies=make([]string,1);compound.bodies[0]=body;compound.condition_lines=make([]int,1);compound.condition_lines[0]=condition_line;compound.body_lines=make([]int,1);compound.body_lines[0]=body_line;return compound
    case "for","select":
        p.position+=1
        header:=native_shell_parser_peek(p);brace_separator:=false
        if word=="for"&&strings.has_prefix(header,"((")&&strings.has_suffix(header,"))") {
            brace_separator=true
            compound.kind="for-arithmetic";expression:=header[2:len(header)-2];parts:=strings.split(expression,";")
            if len(parts)!=3 {native_shell_parser_error(p,"Arithmetic for requires init; condition; update.")} else {compound.conditions=parts}
            p.position+=1
        } else {
            if !native_shell_name(header) {native_shell_parser_error(p,"for/select requires a variable name.");return compound}
            compound.name=header;p.position+=1;brace_separator=native_shell_parser_at(p,[]string{";","\n"});native_shell_parser_newlines(p)
            words:=make([dynamic]Native_Shell_Word)
            if native_shell_parser_peek(p)=="in" {
                p.position+=1
                for p.position<len(p.tokens)&&!native_shell_parser_at(p,[]string{";","\n"}) {if p.tokens[p.position].operator {native_shell_parser_error(p,"Invalid for word list.");break};append(&words,Native_Shell_Word{raw=p.tokens[p.position].raw});p.position+=1}
                compound.words=words[:]
            } else if word=="for" {compound.kind="for-args"}
        }
        if native_shell_parser_at(p,[]string{";","\n"}) {brace_separator=true}
        if native_shell_parser_peek(p)==";" {p.position+=1};native_shell_parser_newlines(p)
        end:="done"
        if native_shell_parser_peek(p)=="{" {if !brace_separator {native_shell_parser_error(p,"Expected a separator before {.");return compound};p.position+=1;end="}"} else {_=native_shell_parser_expect(p,"do")}
        compound.body_lines=make([]int,1);compound.body_lines[0]=native_shell_parser_line(p,p.position);compound.bodies=make([]string,1);compound.bodies[0]=native_shell_parser_body(p,[]string{end});_=native_shell_parser_expect(p,end);return compound
    case "case":
        p.position+=1;if p.position>=len(p.tokens) {native_shell_parser_error(p,"incomplete: case needs a word");return compound}
        compound.words=make([]Native_Shell_Word,1);compound.words[0]=Native_Shell_Word{raw=p.tokens[p.position].raw};p.position+=1;native_shell_parser_newlines(p);_=native_shell_parser_expect(p,"in")
        patterns:=make([dynamic][]Native_Shell_Word);bodies:=make([dynamic]string);terminators:=make([dynamic]string);body_lines:=make([dynamic]int)
        for p.error=="" {
            native_shell_parser_newlines(p);if native_shell_parser_peek(p)=="esac" {p.position+=1;break}
            if p.position>=len(p.tokens) {native_shell_parser_error(p,"incomplete: case needs esac");break}
            if native_shell_parser_peek(p)=="(" {p.position+=1}
            alternatives:=make([dynamic]Native_Shell_Word)
            for {
                if p.position>=len(p.tokens) {native_shell_parser_error(p,"incomplete: case pattern needs )");break}
                if p.tokens[p.position].operator {native_shell_parser_error(p,"Invalid case pattern.");break}
                append(&alternatives,Native_Shell_Word{raw=p.tokens[p.position].raw});p.position+=1
                if native_shell_parser_peek(p)=="|" {p.position+=1;continue};break
            }
            _=native_shell_parser_expect(p,")");append(&patterns,alternatives[:]);append(&body_lines,native_shell_parser_line(p,p.position));append(&bodies,native_shell_parser_body(p,[]string{";;",";&",";;&","esac"},false))
            terminator:=native_shell_parser_peek(p);append(&terminators,terminator)
            if terminator=="esac" {p.position+=1;break}
            if terminator!=";;"&&terminator!=";&"&&terminator!=";;&" {native_shell_parser_error(p,"incomplete: case arm needs ;; or esac");break};p.position+=1
        }
        compound.patterns=patterns[:];compound.bodies=bodies[:];compound.terminators=terminators[:];compound.body_lines=body_lines[:];return compound
    case "function":
        p.position+=1;compound.kind="function";compound.name=native_shell_parser_peek(p)
        if !native_shell_function_name(compound.name) {native_shell_parser_error(p,"function requires an unquoted name.");return compound}
        if native_shell_parser_posix()&&native_shell_special_builtin(compound.name) {native_shell_parser_error(p,"POSIX special builtin cannot be a function name.");return compound};p.position+=1
        if native_shell_parser_peek(p)=="(" {p.position+=1;_=native_shell_parser_expect(p,")")};native_shell_parser_newlines(p)
        start:=p.position;compound.source_line=native_shell_parser_line(p,start);body:=native_shell_parser_compound(p)
        if body==nil {message:="function requires a compound body.";if p.position>=len(p.tokens) {message="incomplete: function requires a compound body"};native_shell_parser_error(p,message)}
        compound.source=native_shell_parser_source(p,start,p.position);return compound
    case "coproc":
        p.position+=1;compound.name="COPROC"
        candidate:=native_shell_parser_peek(p)
        if native_shell_name(candidate)&&p.position+1<len(p.tokens) {
            body:=p.tokens[p.position+1].raw
            named:=body=="{"||body=="("||body=="if"||body=="while"||body=="until"||body=="for"||body=="select"||body=="case"||body=="function"||strings.has_prefix(body,"[[")||strings.has_prefix(body,"((")
            if named {compound.name=candidate;p.position+=1}
        }
        native_shell_parser_newlines(p);start:=p.position;compound.source_line=native_shell_parser_line(p,start)
        _=native_shell_parser_pipeline(p,"")
        compound.source=native_shell_parser_source(p,start,p.position)
        return compound
    case "time":
        p.position+=1;if native_shell_parser_peek(p)=="-p" {p.position+=1;compound.name="-p"}
        start:=p.position;compound.source_line=native_shell_parser_line(p,start)
        if p.position<len(p.tokens)&&!native_shell_parser_at(p,[]string{";","\n","&","&&","||","}",")"}) {_=native_shell_parser_pipeline(p,"")}
        compound.source=native_shell_parser_source(p,start,p.position);return compound
    }
    return nil
}

native_shell_parser_command :: proc(p:^Native_Shell_Parser)->Native_Shell_Command {
    command:=Native_Shell_Command{line=native_shell_parser_line(p,p.position)}
    if p.position>=len(p.tokens) {native_shell_parser_error(p,"incomplete: expected a command");return command}
    first:=native_shell_parser_peek(p)
    if native_shell_function_name(first)&&!native_shell_reserved(first)&&p.position+2<len(p.tokens)&&p.tokens[p.position+1].raw=="("&&p.tokens[p.position+2].raw==")" {
        if native_shell_parser_posix()&&native_shell_special_builtin(first) {native_shell_parser_error(p,"POSIX special builtin cannot be a function name.");return command}
        p.position+=3;native_shell_parser_newlines(p);start:=p.position;body:=native_shell_parser_compound(p)
        if body==nil {message:="Function definition requires a compound body.";if p.position>=len(p.tokens) {message="incomplete: function requires a compound body"};native_shell_parser_error(p,message)}
        command.compound=new(Native_Shell_Compound);command.compound^=Native_Shell_Compound{kind="function",name=first,source=native_shell_parser_source(p,start,p.position),line=command.line,source_line=native_shell_parser_line(p,start)}
    } else {command.compound=native_shell_parser_compound(p)}
    if command.compound!=nil {
        redirect_start:=p.position
        for native_shell_parser_redirect(p,&command)&&p.error=="" {}
        if command.compound.kind=="function"&&p.position>redirect_start {
            command.compound.source=strings.concatenate([]string{command.compound.source,native_shell_parser_source(p,redirect_start,p.position)})
            clear(&command.redirects)
        }
        return command
    }
    if native_shell_reserved(first)&&!(first=="time"&&!native_shell_parser_time_reserved(p)) {native_shell_parser_error(p,fmt.tprintf("Unexpected reserved word: %s",first));return command}
    for p.position<len(p.tokens)&&p.error=="" {
        if native_shell_parser_redirect(p,&command) {continue}
        token:=p.tokens[p.position]
        if token.operator {break}
        append(&command.words,Native_Shell_Word{raw=token.raw});p.position+=1
    }
    if len(command.words)==0&&len(command.redirects)==0 {native_shell_parser_error(p,fmt.tprintf("Expected a command before %s",first))}
    return command
}

native_shell_parser_pipeline :: proc(p:^Native_Shell_Parser,connector:string)->Native_Shell_Pipeline {
    begin:=p.position
    pipeline:=Native_Shell_Pipeline{connector=connector}
    for native_shell_parser_peek(p)=="!" {pipeline.negate=!pipeline.negate;p.position+=1;native_shell_parser_newlines(p)}
    stderr:=make([dynamic]bool)
    for p.error=="" {
        append(&pipeline.commands,native_shell_parser_command(p))
        next:=native_shell_parser_peek(p)
        if next!="|"&&next!="|&" {break}
        append(&stderr,next=="|&");p.position+=1;native_shell_parser_newlines(p)
        if p.position>=len(p.tokens) {native_shell_parser_error(p,"incomplete: expected a command after pipe");break}
    }
    pipeline.pipe_stderr=stderr[:];pipeline.source=strings.trim_space(native_shell_parser_source(p,begin,p.position));return pipeline
}

native_shell_parser_list :: proc(p:^Native_Shell_Parser,stops:[]string)->Native_Shell_Program {
    program:Native_Shell_Program;connector:="";chain_start:=0;chain_token:=p.position
    for p.error=="" {
        native_shell_parser_newlines(p)
        if p.position>=len(p.tokens)||native_shell_parser_at(p,stops) {break}
        if connector=="" {chain_start=len(program.pipelines);chain_token=p.position}
        pipeline:=native_shell_parser_pipeline(p,connector)
        if p.error!="" {break}
        next:=native_shell_parser_peek(p)
        if next=="&" {
            if chain_start<len(program.pipelines) {
                source:=native_shell_parser_source(p,chain_token,p.position)
                resize(&program.pipelines,chain_start)
                compound:=new(Native_Shell_Compound);compound^=Native_Shell_Compound{kind="group",source=source,line=native_shell_parser_line(p,chain_token),source_line=native_shell_parser_line(p,chain_token)}
                pipeline=Native_Shell_Pipeline{source=strings.trim_space(source),commands=make([dynamic]Native_Shell_Command)};append(&pipeline.commands,Native_Shell_Command{compound=compound,line=compound.line})
            }
            pipeline.background=true
        }
        append(&program.pipelines,pipeline)
        if next=="&&"||next=="||" {connector=next;p.position+=1;native_shell_parser_newlines(p);if p.position>=len(p.tokens) {native_shell_parser_error(p,"incomplete: expected a command after operator")};continue}
        connector=""
        if next==";"||next=="\n"||next=="&" {p.position+=1;continue}
        if next==""||native_shell_parser_at(p,stops) {break}
        native_shell_parser_error(p,fmt.tprintf("Unexpected shell token: %s",next))
    }
    return program
}

// ANSI-C quoting is lexical: a locale assignment earlier on the same
// command line must not change literals already read, including literals in
// stored function/control bodies. Store byte escapes so subsequent reparsing
// is independent of the locale while retaining the original newline count.
native_shell_ansi_literal :: proc(value,original:string)->string {
    output:=make([dynamic]u8);append(&output,"$'")
    for byte in transmute([]u8)value {append(&output,'\\',u8('0'+((byte>>6)&7)),u8('0'+((byte>>3)&7)),u8('0'+(byte&7)))}
    for byte in transmute([]u8)original {if byte=='\n' {append(&output,'\\','\n')}}
    append(&output,u8('\''));return string(output[:])
}
NATIVE_SHELL_TRANSLATION_PREFIX :: "__terminal_plus_i18n@"

native_shell_translation_end :: proc(source:string,start:int)->(int,string) {
    for at:=start+2;at<len(source); {
        ch:=source[at]
        if ch=='\\' {at+=2;continue}
        if ch=='$'&&at+1<len(source)&&(source[at+1]=='{'||source[at+1]=='('||source[at+1]=='[') {
            end:int;scan_error:string
            switch source[at+1] {case '{':end,scan_error=native_shell_parameter_end(source,at,0,true);case '(':end,scan_error=native_shell_substitution_end(source,at);case '[':end,scan_error=native_shell_legacy_arithmetic_end(source,at)}
            if scan_error!="" {return 0,scan_error};at=end;continue
        }
        if ch=='`' {end,scan_error:=native_shell_backtick_end(source,at);if scan_error!="" {return 0,scan_error};at=end;continue}
        if ch=='"' {return at+1,""}
        at+=1
    }
    return 0,"incomplete: unclosed translated quote"
}

// A translated string is word-expansion input, never new shell grammar.
// Encode its bytes in an internal parameter node so a translator's quotes or
// semicolons cannot introduce commands when stored source is reparsed later.
native_shell_translation_literal :: proc(text,original:string)->string {
    output:=make([dynamic]u8);append(&output,"${");append(&output,NATIVE_SHELL_TRANSLATION_PREFIX)
    digits:="0123456789abcdef"
    for byte in transmute([]u8)text {append(&output,digits[int(byte>>4)],digits[int(byte&15)])}
    for byte in transmute([]u8)original {if byte=='\n' {append(&output,'\\','\n')}}
    append(&output,u8('}'));return string(output[:])
}
native_shell_translation_text :: proc(source:string)->(string,string) {
    output:=make([dynamic]u8)
    for at:=0;at<len(source); {
        if source[at]=='\\'&&at+1<len(source)&&source[at+1]=='\n' {at+=2;continue}
        if at+1>=len(source) {return "","invalid internal translated string"}
        high:=native_shell_printf_digit(source[at]);low:=native_shell_printf_digit(source[at+1])
        if high<0||low<0 {return "","invalid internal translated string"}
        append(&output,u8(high*16+low));at+=2
    }
    return string(output[:]),""
}

native_shell_parse_literal_fragment :: proc(source:string,depth:int,inherited_quote:bool=false,line_offset:int=0)->(string,string) {
    if !strings.contains(source,"$'")&&!strings.contains(source,"$\"") {return source,""}
    if depth>=128 {return "","Shell literal nesting limit reached."}
    output:=make([dynamic]u8);quote:u8
    if inherited_quote {quote='"'}
    for at:=0;at<len(source); {
        byte:=source[at]
        if quote=='\'' {append(&output,byte);at+=1;if byte=='\'' {quote=0};continue}
        if byte=='\\' {end:=min(len(source),at+2);append(&output,source[at:end]);at=end;continue}
        if (quote==0||inherited_quote&&quote=='"')&&byte=='$'&&at+1<len(source)&&source[at+1]=='"' {
            end,scan_error:=native_shell_translation_end(source,at)
            if scan_error!="" {return "",scan_error}
            message:=source[at+2:end-1]
            if native_shell_dump_strings_enabled {native_shell_dump_translation(message,source[:at],line_offset)}
            translated:=message;changed:=false
            if native_shell_parser_shell!=nil {translated,changed=native_shell_translate(native_shell_parser_shell,message)}
            if changed {
                if native_shell_parser_shell.compat.shopts["noexpand_translation"] {append(&output,native_shell_ansi_literal(translated,source[at:end]))}
                else {append(&output,native_shell_translation_literal(translated,source[at:end]))}
            } else {append(&output,source[at+1:end])}
            at=end;continue
        }
        if (quote==0||inherited_quote&&quote=='"')&&byte=='$'&&at+1<len(source)&&source[at+1]=='\'' {
            value,end,decode_error:=native_shell_ansi_decode(source,at+2,true)
            if decode_error!="" {return "",decode_error}
            original:=source[at:end]
            if strings.contains(original,"\\u")||strings.contains(original,"\\U") {append(&output,native_shell_ansi_literal(value,original))} else {append(&output,original)}
            at=end;continue
        }
        if byte=='$'&&at+1<len(source)&&source[at+1]=='{' {
            end,scan_error:=native_shell_parameter_end(source,at,0,quote=='"')
            if scan_error!="" {return "",scan_error}
            first:=at+2;body:string;body_error:string
            if native_shell_brace_command(source,at) {
                if source[first]=='|' {append(&output,"${|");first+=1} else {append(&output,"${")}
                body,body_error=native_shell_parse_literals(source[first:end-1],depth+1,line_offset+native_shell_dump_line_count(source[:first]))
            } else {
                append(&output,"${")
                body,body_error=native_shell_parse_literal_fragment(source[first:end-1],depth+1,quote=='"'&&!native_shell_parameter_pattern_operator(source,at),line_offset+native_shell_dump_line_count(source[:first]))
            }
            if body_error!="" {return "",body_error};append(&output,body);append(&output,u8('}'));at=end;continue
        }
        if byte=='$'&&at+1<len(source)&&(source[at+1]=='('||source[at+1]=='[') {
            end:int;scan_error:string;first:=at+2;last_skip:=1;arithmetic:=source[at+1]=='['
            if source[at+1]=='[' {end,scan_error=native_shell_legacy_arithmetic_end(source,at)}
            else if at+2<len(source)&&source[at+2]=='(' {arithmetic=true;end,scan_error=native_shell_arithmetic_end(source,at);first+=1;last_skip=2}
            else {end,scan_error=native_shell_substitution_end(source,at)}
            if scan_error!="" {return "",scan_error}
            body:string;body_error:string
            if arithmetic {body,body_error=native_shell_parse_literal_fragment(source[first:end-last_skip],depth+1,false,line_offset+native_shell_dump_line_count(source[:first]))}
            else {body,body_error=native_shell_parse_literals(source[first:end-last_skip],depth+1,line_offset+native_shell_dump_line_count(source[:first]))}
            if body_error!="" {return "",body_error}
            append(&output,source[at:first]);append(&output,body);append(&output,source[end-last_skip:end]);at=end;continue
        }
        if quote==0&&(byte=='<'||byte=='>')&&at+1<len(source)&&source[at+1]=='(' {
            end,scan_error:=native_shell_process_end(source,at);if scan_error!="" {return "",scan_error}
            body,body_error:=native_shell_parse_literals(source[at+2:end-1],depth+1,line_offset+native_shell_dump_line_count(source[:at+2]));if body_error!="" {return "",body_error}
            append(&output,source[at:at+2]);append(&output,body);append(&output,u8(')'));at=end;continue
        }
        if byte=='`' {
            end,scan_error:=native_shell_backtick_end(source,at);if scan_error!="" {return "",scan_error}
            body,body_error:=native_shell_parse_literals(source[at+1:end-1],depth+1,line_offset+native_shell_dump_line_count(source[:at+1]));if body_error!="" {return "",body_error}
            append(&output,u8('`'));append(&output,body);append(&output,u8('`'));at=end;continue
        }
        if byte=='"' {if quote=='"' {quote=0} else {quote='"'}}
        else if byte=='\''&&quote==0 {quote='\''}
        append(&output,byte);at+=1
    }
    return string(output[:]),""
}
native_shell_parse_literals :: proc(source:string,depth:int=0,line_offset:int=0)->(string,string) {
    if !strings.contains(source,"$'")&&!strings.contains(source,"$\"") {return source,""}
    if depth>=128 {return "","Shell literal nesting limit reached."}
    tokens,lex_error:=native_shell_tokens(source)
    if lex_error!="" {return "",lex_error}
    output:=make([dynamic]u8);previous:=0
    for token in tokens {
        append(&output,source[previous:token.start])
        if token.operator {append(&output,token.raw)} else {
            raw,literal_error:=native_shell_parse_literal_fragment(token.raw,depth+1,false,line_offset+native_shell_dump_line_count(source[:token.start]))
            if literal_error!="" {return "",literal_error}
            append(&output,raw)
        }
        previous=token.end
    }
    append(&output,source[previous:]);return string(output[:]),""
}

native_shell_parse :: proc(input:string)->(program:Native_Shell_Program,error:string) {
    previous_locale:=""
    if native_shell_parser_shell!=nil {previous_locale=native_shell_text_locale(native_shell_parser_shell)}
    defer {if previous_locale!="" {native_shell_text_locale_restore(previous_locale)}}
    source,literal_error:=native_shell_parse_literals(input)
    if literal_error!="" {return program,literal_error}
    tokens,lex_error:=native_shell_tokens(source)
    if lex_error!="" {return program,lex_error}
    line_offsets:=make([dynamic]int);for byte,index in transmute([]u8)source {if byte=='\n' {append(&line_offsets,index)}}
    parser:=Native_Shell_Parser{source=source,tokens=tokens[:],line_offsets=line_offsets[:]}
    program=native_shell_parser_list(&parser,nil)
    return program,parser.error
}

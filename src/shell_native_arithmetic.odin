#+build linux
package main

import "core:fmt"
import "core:strings"

// Arithmetic is evaluated directly from a token stream. Keeping references
// lazy lets assignment create an unset variable under nounset, and parsing a
// skipped &&/||/?: branch checks its grammar without applying side effects.
Native_Shell_Arithmetic_Token_Kind :: enum {End,Number,Name,Parameter,String,Operator}
Native_Shell_Arithmetic_Token :: struct {
    kind:Native_Shell_Arithmetic_Token_Kind,
    text:string,
    start,end:int,
}
Native_Shell_Arithmetic_Value :: struct {number:i64, reference:string, loaded:bool}
Native_Shell_Arithmetic_Parser :: struct {
    shell:^Native_Shell,
    source:string,
    tokens:[dynamic]Native_Shell_Arithmetic_Token,
    offset,depth:int,
    error:string,
}

native_shell_arithmetic_tokenize :: proc(source:string)->(tokens:[dynamic]Native_Shell_Arithmetic_Token,error:string) {
    for i:=0;i<len(source); {
        ch:=source[i]
        if ch==' '||ch=='\t'||ch=='\r'||ch=='\n' {i+=1;continue}
        begin:=i
        if ch>='0'&&ch<='9' {
            i+=1
            for i<len(source) {
                next:=source[i]
                if !native_shell_name_byte(next)&&next!='#'&&next!='@' {break}
                i+=1
            }
            append(&tokens,Native_Shell_Arithmetic_Token{.Number,source[begin:i],begin,i});continue
        }
        if native_shell_name_start(ch) {
            i+=1;for i<len(source)&&native_shell_name_byte(source[i]) {i+=1}
            append(&tokens,Native_Shell_Arithmetic_Token{.Name,source[begin:i],begin,i});continue
        }
        if ch=='$' {
            i+=1
            if i>=len(source) {return tokens,"arithmetic: expected a parameter after $"}
            switch source[i] {
            case '{':
                end,scan_error:=native_shell_parameter_end(source,begin)
                if scan_error!="" {return tokens,scan_error};i=end
            case '[':
                end,scan_error:=native_shell_legacy_arithmetic_end(source,begin)
                if scan_error!="" {return tokens,scan_error};i=end
            case '(':
                end,scan_error:=native_shell_substitution_end(source,begin)
                if scan_error!="" {return tokens,scan_error};i=end
            case:
                if native_shell_name_start(source[i]) {i+=1;for i<len(source)&&native_shell_name_byte(source[i]) {i+=1}}
                else if strings.index_byte("0123456789?$!#@*-_",source[i])>=0 {i+=1}
                else {return tokens,"arithmetic: invalid parameter expansion"}
            }
            append(&tokens,Native_Shell_Arithmetic_Token{.Parameter,source[begin:i],begin,i});continue
        }
        if ch=='`' {
            i+=1
            for i<len(source)&&source[i]!='`' {if source[i]=='\\' {i+=1};i+=1}
            if i>=len(source) {return tokens,"arithmetic: unclosed command substitution"}
            i+=1;append(&tokens,Native_Shell_Arithmetic_Token{.Parameter,source[begin:i],begin,i});continue
        }
        if ch=='\''||ch=='"' {
            quote:=ch;i+=1
            for i<len(source)&&source[i]!=quote {if source[i]=='\\'&&quote=='"' {i+=1};i+=1}
            if i>=len(source) {return tokens,"arithmetic: unclosed quote"}
            i+=1;append(&tokens,Native_Shell_Arithmetic_Token{.String,source[begin:i],begin,i});continue
        }
        found:=false
        for operator in ([]string{"<<=",">>=","**","++","--","+=","-=","*=","/=","%=","<<",">>","<=",">=","==","!=","&&","||","&=","^=","|="}) {
            if strings.has_prefix(source[i:],operator) {
                i+=len(operator);append(&tokens,Native_Shell_Arithmetic_Token{.Operator,operator,begin,i});found=true;break
            }
        }
        if found {continue}
        if strings.index_byte("+-*/%<>=!~&^|?:,()[]",ch)>=0 {
            i+=1;append(&tokens,Native_Shell_Arithmetic_Token{.Operator,source[begin:i],begin,i});continue
        }
        return tokens,fmt.tprintf("arithmetic: invalid character %q",source[i:i+1])
    }
    append(&tokens,Native_Shell_Arithmetic_Token{kind=.End,start=len(source),end=len(source)})
    return
}

native_shell_arithmetic_number :: proc(text:string)->(i64,string) {
    if text=="" {return 0,"arithmetic: empty integer"}
    base:u64=10;digits:=text
    if hash:=strings.index_byte(text,'#');hash>=0 {
        if hash==0 {return 0,"arithmetic: invalid base"}
        base=0
        for ch in transmute([]u8)text[:hash] {
            if ch<'0'||ch>'9'||base>64 {return 0,"arithmetic: invalid base"}
            base=base*10+u64(ch-'0')
        }
        if base<2||base>64 {return 0,"arithmetic: base must be between 2 and 64"}
        digits=text[hash+1:]
    } else if len(text)>=2&&text[0]=='0'&&(text[1]=='x'||text[1]=='X') {
        base=16;digits=text[2:]
    } else if len(text)>1&&text[0]=='0' {base=8;digits=text[1:]}
    if digits=="" {return 0,"arithmetic: integer has no digits"}
    value:u64
    for ch in transmute([]u8)digits {
        digit:u64=64
        switch {
        case ch>='0'&&ch<='9':digit=u64(ch-'0')
        case ch>='a'&&ch<='z':digit=u64(ch-'a')+10
        case ch>='A'&&ch<='Z':digit=u64(ch-'A')+10;if base>36 {digit+=26}
        case ch=='@':digit=62
        case ch=='_':digit=63
        }
        if digit>=base {return 0,fmt.tprintf("arithmetic: %s contains a digit outside base %d",text,base)}
        value=value*base+digit
    }
    return i64(value),""
}

native_shell_arithmetic_peek :: proc(parser:^Native_Shell_Arithmetic_Parser)->Native_Shell_Arithmetic_Token {
    return parser.tokens[min(parser.offset,len(parser.tokens)-1)]
}
native_shell_arithmetic_take :: proc(parser:^Native_Shell_Arithmetic_Parser)->Native_Shell_Arithmetic_Token {
    token:=native_shell_arithmetic_peek(parser)
    if token.kind!=.End {parser.offset+=1}
    return token
}
native_shell_arithmetic_expect :: proc(parser:^Native_Shell_Arithmetic_Parser,text:string)->bool {
    token:=native_shell_arithmetic_peek(parser)
    if token.text!=text {if parser.error=="" {parser.error=fmt.tprintf("arithmetic: expected %s before %s",text,token.text)};return false}
    parser.offset+=1;return true
}

native_shell_arithmetic_load :: proc(parser:^Native_Shell_Arithmetic_Parser,value:Native_Shell_Arithmetic_Value,evaluate:bool)->i64 {
    if !evaluate||parser.error!="" {return 0}
    if value.loaded {return value.number}
    text,exists:=native_shell_value_get(parser.shell,value.reference)
    if !exists&&parser.shell.compat!=nil&&parser.shell.compat.options["nounset"] {
        parser.error=fmt.tprintf("arithmetic: %s: unbound variable",value.reference);return 0
    }
    if text=="" {return 0}
    // Bash recursively interprets a variable's value as arithmetic syntax,
    // but does not apply another round of shell parameter expansion to it.
    result,error:=native_shell_arithmetic_internal(parser.shell,text,false)
    if error!="" {parser.error=error}
    return result
}

native_shell_arithmetic_store :: proc(parser:^Native_Shell_Arithmetic_Parser,reference:string,number:i64,evaluate:bool) {
    if !evaluate||parser.error!="" {return}
    error:=native_shell_value_set(parser.shell,reference,fmt.tprintf("%d",number),u32(1<<31))
    if error!="" {parser.error=error}
}

native_shell_arithmetic_prefix :: proc(parser:^Native_Shell_Arithmetic_Parser,evaluate:bool)->Native_Shell_Arithmetic_Value {
    token:=native_shell_arithmetic_take(parser)
    switch token.kind {
    case .Number:
        number,error:=native_shell_arithmetic_number(token.text)
        if error!="" {parser.error=error}
        return {number=number,loaded=true}
    case .Name:
        reference:=token.text
        if native_shell_arithmetic_peek(parser).text=="[" {
            opening:=native_shell_arithmetic_take(parser)
            associative:=false
            if parser.shell.compat!=nil {if array,exists:=parser.shell.compat.arrays[reference];exists&&array!=nil {associative=array.associative_mode}}
            key:string
            if associative {
                depth:=1;ending:=opening.end
                for depth>0 {
                    item:=native_shell_arithmetic_take(parser)
                    if item.kind==.End {parser.error="arithmetic: unclosed array subscript";return {loaded=true}}
                    if item.text=="[" {depth+=1}
                    if item.text=="]" {depth-=1;if depth==0 {ending=item.start;break}}
                }
                if evaluate {
                    var_error:string
                    key,var_error=native_shell_expand_assignment(parser.shell,parser.source[opening.end:ending])
                    if var_error!="" {parser.error=var_error}
                    if key=="" {parser.error="arithmetic: bad array subscript"}
                }
            } else {
                // Expansion of an indexed subscript happens when that
                // reference is evaluated, and uses the same arithmetic rules.
                // Preserve its spelling while finding the matching bracket.
                depth:=1;ending:=opening.end
                for depth>0 {
                    item:=native_shell_arithmetic_take(parser)
                    if item.kind==.End {parser.error="arithmetic: unclosed array subscript";return {loaded=true}}
                    if item.text=="[" {depth+=1}
                    if item.text=="]" {depth-=1;if depth==0 {ending=item.start;break}}
                }
                if evaluate {
                    number,index_error:=native_shell_arithmetic(parser.shell,parser.source[opening.end:ending])
                    if index_error!="" {parser.error=index_error}
                    key=fmt.tprintf("%d",number)
                } else {
                    // A skipped reference does not evaluate its subscript.
                    // Parameter expansion could change its grammar entirely.
                    key="0"
                }
            }
            reference=strings.concatenate([]string{reference,"[",key,"]"})
        }
        return {reference=reference}
    case .Parameter:
        if !evaluate {return {loaded=true}}
        parser.error="arithmetic: unexpected parameter syntax in a variable value"
        return {loaded=true}
    case .Operator:
        if token.text=="(" {
            value:=native_shell_arithmetic_parse(parser,1,evaluate)
            _=native_shell_arithmetic_expect(parser,")")
            return value
        }
        if token.text=="+"||token.text=="-"||token.text=="!"||token.text=="~"||token.text=="++"||token.text=="--" {
            value:=native_shell_arithmetic_parse(parser,15,evaluate)
            number:=native_shell_arithmetic_load(parser,value,evaluate)
            switch token.text {
            case "+":
            case "-":number=i64(u64(0)-u64(number))
            case "!":if number==0 {number=1} else {number=0}
            case "~":number=~number
            case "++","--":
                if value.reference=="" {parser.error="arithmetic: increment requires a variable";return {loaded=true}}
                if token.text=="++" {number=i64(u64(number)+1)} else {number=i64(u64(number)-1)}
                native_shell_arithmetic_store(parser,value.reference,number,evaluate)
            }
            return {number=number,loaded=true}
        }
    case .End,.String:
    }
    if parser.error=="" {parser.error=fmt.tprintf("arithmetic: expected an operand before %s",token.text)}
    return {loaded=true}
}

native_shell_arithmetic_precedence :: proc(operator:string)->(precedence:int,right:bool) {
    switch operator {
    case ",":return 1,false
    case "=","+=","-=","*=","/=","%=","<<=",">>=","&=","^=","|=":return 2,true
    case "?":return 3,true
    case "||":return 4,false
    case "&&":return 5,false
    case "|":return 6,false
    case "^":return 7,false
    case "&":return 8,false
    case "==","!=":return 9,false
    case "<","<=",">",">=":return 10,false
    case "<<",">>":return 11,false
    case "+","-":return 12,false
    case "*","/","%":return 13,false
    case "**":return 14,true
    case "++","--":return 17,false
    }
    return 0,false
}

native_shell_arithmetic_binary :: proc(parser:^Native_Shell_Arithmetic_Parser,operator:string,left,right:i64,evaluate:bool)->i64 {
    if !evaluate||parser.error!="" {return 0}
    switch operator {
    case "+":return i64(u64(left)+u64(right))
    case "-":return i64(u64(left)-u64(right))
    case "*":return i64(u64(left)*u64(right))
    case "/","%":
        if right==0 {parser.error="arithmetic: division by zero";return 0}
        if left==(-9223372036854775807-1)&&right== -1 {if operator=="%" {return 0};return left}
        if operator=="%" {return left%right};return left/right
    case "**":
        if right<0 {parser.error="arithmetic: exponent must be nonnegative";return 0}
        value:u64=1;base:=u64(left);exponent:=u64(right)
        for exponent>0 {if exponent&1!=0 {value*=base};exponent>>=1;if exponent>0 {base*=base}}
        return i64(value)
    case "<<":return i64(u64(left)<<uint(u64(right)&63))
    case ">>":return left>>uint(u64(right)&63)
    case "&":return left&right
    case "^":return left~right
    case "|":return left|right
    case "<":if left<right {return 1};return 0
    case "<=":if left<=right {return 1};return 0
    case ">":if left>right {return 1};return 0
    case ">=":if left>=right {return 1};return 0
    case "==":if left==right {return 1};return 0
    case "!=":if left!=right {return 1};return 0
    case "&&":if left!=0&&right!=0 {return 1};return 0
    case "||":if left!=0||right!=0 {return 1};return 0
    case ",":return right
    }
    parser.error=fmt.tprintf("arithmetic: unknown operator %s",operator)
    return 0
}

native_shell_arithmetic_parse :: proc(parser:^Native_Shell_Arithmetic_Parser,minimum:int,evaluate:bool)->Native_Shell_Arithmetic_Value {
    if parser.depth>=512 {parser.error="arithmetic: expression nesting limit reached";return {loaded=true}}
    parser.depth+=1
    defer {parser.depth-=1}
    left:=native_shell_arithmetic_prefix(parser,evaluate)
    for parser.error=="" {
        token:=native_shell_arithmetic_peek(parser)
        if token.kind!=.Operator {break}
        precedence,right_associative:=native_shell_arithmetic_precedence(token.text)
        if precedence==0||precedence<minimum {break}
        _=native_shell_arithmetic_take(parser)
        if token.text=="++"||token.text=="--" {
            if left.reference=="" {parser.error="arithmetic: increment requires a variable";break}
            old:=native_shell_arithmetic_load(parser,left,evaluate)
            updated:=i64(u64(old)+1);if token.text=="--" {updated=i64(u64(old)-1)}
            native_shell_arithmetic_store(parser,left.reference,updated,evaluate)
            left={number=old,loaded=true};continue
        }
        if token.text=="?" {
            condition:=native_shell_arithmetic_load(parser,left,evaluate)
            yes:=native_shell_arithmetic_parse(parser,1,evaluate&&condition!=0)
            yes_number:=native_shell_arithmetic_load(parser,yes,evaluate&&condition!=0)
            if !native_shell_arithmetic_expect(parser,":") {break}
            no:=native_shell_arithmetic_parse(parser,3,evaluate&&condition==0)
            no_number:=native_shell_arithmetic_load(parser,no,evaluate&&condition==0)
            selected:=no_number;if condition!=0 {selected=yes_number}
            left={number=selected,loaded=true};continue
        }
        assignment:=precedence==2
        if assignment&&left.reference=="" {parser.error="arithmetic: assignment requires a variable";break}
        lhs:i64
        if token.text!="=" {lhs=native_shell_arithmetic_load(parser,left,evaluate)}
        next_minimum:=precedence+1;if right_associative {next_minimum=precedence}
        evaluate_right:=evaluate
        if token.text=="&&"&&lhs==0||token.text=="||"&&lhs!=0 {evaluate_right=false}
        right:=native_shell_arithmetic_parse(parser,next_minimum,evaluate_right)
        rhs:=native_shell_arithmetic_load(parser,right,evaluate_right)
        if assignment {
            result:=rhs
            if token.text!="=" {result=native_shell_arithmetic_binary(parser,token.text[:len(token.text)-1],lhs,rhs,evaluate)}
            native_shell_arithmetic_store(parser,left.reference,result,evaluate)
            left={number=result,loaded=true}
        } else {
            left={number=native_shell_arithmetic_binary(parser,token.text,lhs,rhs,evaluate),loaded=true}
        }
    }
    return left
}

// Shell expansion precedes arithmetic parsing. In particular, with a='2+3',
// `$a*2` is 2+3*2, whereas `a*2` recursively reads a as a single operand.
// Array subscripts retain their spelling for their own evaluation rules.
native_shell_legacy_array_expansion :: proc(shell:^Native_Shell)->bool {
    return native_shell_compat_level(shell)<=51&&!shell.compat.shopts["assoc_expand_once"]&&!shell.compat.shopts["array_expand_once"]
}

native_shell_arithmetic_word_fragment :: proc(shell:^Native_Shell,source:string,first_quote,last_quote:u8)->(string,string) {
    if first_quote==0&&last_quote==0 {return native_shell_expand_assignment(shell,source)}
    fragment:=make([dynamic]u8)
    if first_quote=='"' {append(&fragment,u8('"'))}
    append(&fragment,source)
    if last_quote=='"' {append(&fragment,u8('"'))}
    return native_shell_expand_assignment(shell,string(fragment[:]))
}

native_shell_arithmetic_expand_input :: proc(shell:^Native_Shell,expression:string,repeat_subscripts:bool=false)->(string,string) {
    // Older word-arithmetic contexts first expand the complete expression,
    // then evaluate its array subscripts. Let/variable-value arithmetic does
    // not have that extra word-expansion phase. Never re-expand plain variable
    // values as shell source, even at historical compatibility levels.
    if repeat_subscripts {return native_shell_expand_assignment(shell,expression)}
    output:=make([dynamic]u8)
    start:=0;i:=0;quote,fragment_quote:u8
    for i<len(expression) {
        ch:=expression[i]
        if ch=='\\' {i+=2;continue}
        if quote=='\'' {if ch=='\'' {quote=0};i+=1;continue}
        if ch=='`' {
            i+=1
            for i<len(expression)&&expression[i]!='`' {if expression[i]=='\\' {i+=1};i+=1}
            if i>=len(expression) {return "","arithmetic: unclosed command substitution"}
            i+=1;continue
        }
        if ch=='$'&&i+1<len(expression)&&expression[i+1]=='[' {end,error:=native_shell_legacy_arithmetic_end(expression,i);if error!="" {return "",error};i=end;continue}
        if ch=='$'&&i+1<len(expression)&&(expression[i+1]=='{'||expression[i+1]=='(') {
            end:int;scan_error:string
            if expression[i+1]=='{' {end,scan_error=native_shell_parameter_end(expression,i)} else {end,scan_error=native_shell_substitution_end(expression,i)}
            if scan_error!="" {return "",scan_error};i=end;continue
        }
        if ch=='"' {if quote=='"' {quote=0} else {quote='"'};i+=1;continue}
        if ch=='\''&&quote==0 {quote=ch;i+=1;continue}
        if ch=='['&&(quote==0||quote=='"') {
            prefix,error:=native_shell_arithmetic_word_fragment(shell,expression[start:i],fragment_quote,quote)
            if error!="" {return "",error}
            append(&output,prefix)
            begin:=i;depth:=1;i+=1;inner_quote:u8
            for i<len(expression)&&depth>0 {
                next:=expression[i]
                if next=='\\' {i+=2;continue}
                if inner_quote=='\'' {if next=='\'' {inner_quote=0};i+=1;continue}
                if next=='$'&&i+1<len(expression)&&(expression[i+1]=='{'||expression[i+1]=='(') {
                    end:int;scan_error:string
                    if expression[i+1]=='{' {end,scan_error=native_shell_parameter_end(expression,i)} else {end,scan_error=native_shell_substitution_end(expression,i)}
                    if scan_error!="" {return "",scan_error};i=end;continue
                }
                if next=='`' {
                    i+=1;for i<len(expression)&&expression[i]!='`' {if expression[i]=='\\' {i+=1};i+=1}
                    if i>=len(expression) {return "","arithmetic: unclosed command substitution"}
                    i+=1;continue
                }
                if next=='"' {if inner_quote=='"' {inner_quote=0} else {inner_quote='"'};i+=1;continue}
                if next=='\''&&inner_quote==0 {inner_quote=next;i+=1;continue}
                if inner_quote!=0 {i+=1;continue}
                if next=='[' {depth+=1}
                if next==']' {depth-=1}
                i+=1
            }
            if depth!=0 {return "","arithmetic: unclosed array subscript"}
            append(&output,expression[begin:i]);start=i;fragment_quote=quote;continue
        }
        i+=1
    }
    if quote!=0 {return "","arithmetic: unclosed quote"}
    suffix,error:=native_shell_arithmetic_word_fragment(shell,expression[start:],fragment_quote,0)
    if error!="" {return "",error}
    append(&output,suffix)
    return string(output[:]),""
}

native_shell_arithmetic_internal :: proc(shell:^Native_Shell,source:string,expand_input:bool,word_context:bool=false)->(i64,string) {
    entered:=false
    if shell.compat!=nil {
        if shell.compat.arithmetic_depth>=128 {return 0,"arithmetic: variable expression recursion limit reached"}
        shell.compat.arithmetic_depth+=1
        entered=true
    }
    defer {if entered {shell.compat.arithmetic_depth-=1}}
    expression:=source
    if expand_input {
        expanded,expand_error:=native_shell_arithmetic_expand_input(shell,source,word_context&&native_shell_legacy_array_expansion(shell))
        if expand_error!="" {return 0,expand_error}
        expression=expanded
    }
    if strings.trim_space(expression)=="" {return 0,""}
    tokens,error:=native_shell_arithmetic_tokenize(expression)
    if error!="" {return 0,error}
    parser:=Native_Shell_Arithmetic_Parser{shell=shell,source=expression,tokens=tokens}
    value:=native_shell_arithmetic_parse(&parser,1,true)
    if parser.error==""&&native_shell_arithmetic_peek(&parser).kind!=.End {parser.error=fmt.tprintf("arithmetic: unexpected token %s",native_shell_arithmetic_peek(&parser).text)}
    number:=native_shell_arithmetic_load(&parser,value,true)
    return number,parser.error
}

native_shell_arithmetic :: proc(shell:^Native_Shell,expression:string,word_context:bool=false)->(i64,string) {
    return native_shell_arithmetic_internal(shell,expression,true,word_context)
}

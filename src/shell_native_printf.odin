#+build linux
package main

import "core:c"
import libc "core:c/libc"
import "core:fmt"
import "core:strings"
import big "core:math/big"
import "core:unicode/utf8"
import posix "core:sys/posix"

// printf field widths and precisions use the host C int ABI. Total output
// is bounded only by addressable memory and checked append arithmetic.
NATIVE_SHELL_PRINTF_FIELD_MAX :: int(0x7fffffff)

// A shell's locale variables can be changed without exporting them. Apply
// those values while formatting, then restore the embedding process locale.
// In particular %ls/%lc count characters, while %s/%c still count bytes.
native_shell_printf_locale :: proc(shell:^Native_Shell)->string {
    previous:=strings.clone(string(libc.setlocale(.ALL,nil)))
    all,_:=native_shell_value_get(shell,"LC_ALL")
    language,_:=native_shell_value_get(shell,"LANG")
    for item in ([]struct {name:string,category:libc.Locale_Category}{
        {"LC_CTYPE",.CTYPE},{"LC_NUMERIC",.NUMERIC},{"LC_TIME",.TIME},
    }) {
        value:=all
        if value=="" {value,_=native_shell_value_get(shell,item.name)}
        if value=="" {value=language}
        if value=="" {value="C"}
        _=libc.setlocale(item.category,strings.clone_to_cstring(value))
    }
    return previous
}

native_shell_printf_character :: proc(text:string)->(rune,int,bool) {
    if text=="" {return 0,0,true}
    if libc.MB_CUR_MAX()==1 {return rune(text[0]),1,true}
    state:libc.mbstate_t
    character:libc.wchar_t
    count:=libc.mbrtowc(cast([^]libc.wchar_t)&character,cast(cstring)raw_data(text),c.size_t(len(text)),&state)
    if count>c.size_t(len(text)) {return 0,1,false}
    if count==0 {return 0,1,true}
    return rune(character),int(count),true
}

native_shell_printf_wide :: proc(text:string,width,precision:int,left:bool)->string {
    characters:=0;end:=0
    for end<len(text)&&(precision<0||characters<precision) {
        _,count,valid:=native_shell_printf_character(text[end:])
        if !valid {return native_shell_printf_pad("",max(0,width-characters),-1,left)}
        end+=count;characters+=1
    }
    // Use the character count for the padding, preserving every byte of each
    // selected character in the actual output.
    return native_shell_printf_pad(text[:end],max(0,width-characters)+end,-1,left)
}

native_shell_printf_digit :: proc(ch:u8)->int {
    if ch>='0'&&ch<='9' {return int(ch-'0')}
    if ch>='a'&&ch<='f' {return int(ch-'a')+10}
    if ch>='A'&&ch<='F' {return int(ch-'A')+10}
    return -1
}

// Escapes are consumed while scanning, so an escaped percent stays literal
// instead of becoming a second format directive after quote removal.
native_shell_printf_escape :: proc(text:string,offset:^int,operand:bool)->(string,bool,bool) {
    i:=offset^+1
    if i>=len(text) {offset^=i;return "\\",false,false}
    ch:=text[i];i+=1;offset^=i
    switch ch {
    case 'a':return "\a",false,false
    case 'b':return "\b",false,false
    case 'e','E':return "\x1b",false,false
    case 'f':return "\f",false,false
    case 'n':return "\n",false,false
    case 'r':return "\r",false,false
    case 't':return "\t",false,false
    case 'v':return "\v",false,false
    case '\\':return "\\",false,false
    case 'c':if operand {return "",true,false};return "\\c",false,false
    }
    if ch>='0'&&ch<='7'||ch=='x'||ch=='u'||ch=='U' {
        base:=16;maximum:=2;value:=0;count:=0
        if ch>='0'&&ch<='7' {
            base=8;maximum=3;value=int(ch-'0');count=1
            if operand&&ch=='0' {count=0}
        } else if ch=='u' {maximum=4} else if ch=='U' {maximum=8}
        for count<maximum&&i<len(text) {
            digit:=native_shell_printf_digit(text[i]);if digit<0||digit>=base {break}
            value=value*base+digit;count+=1;i+=1
        }
        offset^=i
        if count==0&&ch!='0' {return strings.clone(text[offset^-2:offset^]),false,true}
        if ch=='u'||ch=='U' {
            if value>0x10ffff||value>=0xd800&&value<=0xdfff {return "",false,true}
            encoded:[32]c.char;state:libc.mbstate_t
            count:=libc.wcrtomb(&encoded[0],libc.wchar_t(value),&state)
            if count>c.size_t(len(encoded)) {
                if ch=='u' {return fmt.aprintf("\\u%04X",value),false,false}
                return fmt.aprintf("\\U%08X",value),false,false
            }
            return strings.clone(string(encoded[:int(count)])),false,false
        }
        byte:=[1]u8{u8(value&255)};return strings.clone(string(byte[:])),false,false
    }
    return strings.clone(text[offset^-2:offset^]),false,false
}

native_shell_printf_decode :: proc(text:string)->(string,bool,bool) {
    output:=make([dynamic]u8);bad:=false
    for i:=0;i<len(text); {
        if text[i]!='\\' {append(&output,text[i]);i+=1;continue}
        value,stop,invalid:=native_shell_printf_escape(text,&i,true)
        append(&output,value);bad=bad||invalid
        if stop {return string(output[:]),true,bad}
    }
    return string(output[:]),false,bad
}

native_shell_printf_quote :: proc(text:string,alternate:bool)->string {
    if text=="" {return "''"}
    ansi:=!utf8.valid_string(text)
    for i:=0;i<len(text); {
        ch,count,valid:=native_shell_printf_character(text[i:])
        if !valid||libc.iswprint(libc.wint_t(ch))==0 {ansi=true;break}
        i+=count
    }
    if alternate&&!ansi {return explorer_quote(text)}
    output:=make([dynamic]u8)
    if ansi {
        append(&output,"$'")
        for i:=0;i<len(text);i+=1 {
            byte:=text[i]
            if byte>=0x80 {
                ch,n,valid:=native_shell_printf_character(text[i:])
                if valid&&n>1&&libc.iswprint(libc.wint_t(ch))!=0 {append(&output,text[i:i+n]);i+=n-1;continue}
                append(&output,'\\',u8('0'+((byte>>6)&7)),u8('0'+((byte>>3)&7)),u8('0'+(byte&7)));continue
            }
            switch byte {
            case 7:append(&output,"\\a")
            case 8:append(&output,"\\b")
            case 9:append(&output,"\\t")
            case 10:append(&output,"\\n")
            case 11:append(&output,"\\v")
            case 12:append(&output,"\\f")
            case 13:append(&output,"\\r")
            case 27:append(&output,"\\E")
            case '\'':append(&output,"\\'")
            case '\\':append(&output,"\\\\")
            case:
                if byte<32||byte==127 {append(&output,'\\',u8('0'+((byte>>6)&7)),u8('0'+((byte>>3)&7)),u8('0'+(byte&7)))} else {append(&output,byte)}
            }
        }
        append(&output,u8('\''));return string(output[:])
    }
    for byte,i in transmute([]u8)text {
        if strings.index_byte(" \t\n\r\\'\"`$&;|<>()[]{}*?!^,",byte)>=0||i==0&&(byte=='~'||byte=='#') {append(&output,u8('\\'))}
        append(&output,byte)
    }
    return string(output[:])
}

native_shell_printf_number :: proc(value:string,unsigned:bool=false)->(u64,bool) {
    if value=="" {return 0,true}
    if value[0]=='\''||value[0]=='"' {
        if len(value)==1 {return 0,true}
        ch,_,valid:=native_shell_printf_character(value[1:]);if !valid {return u64(value[1]),true};return u64(ch),true
    }
    literal:=strings.clone_to_cstring(value)
    end:[^]c.char;posix.errno(.NONE)
    result:u64
    if unsigned {result=u64(libc.strtoull(literal,&end,0))} else {result=u64(libc.strtoll(literal,&end,0))}
    valid:=end!=nil&&uintptr(end)!=uintptr(raw_data(string(literal)))&&end[0]==0&&posix.errno()!=.ERANGE
    return result,valid
}

// Bash uses the x87 long-double format on Linux x86_64. Quantize the input
// rational to its 64-bit significand in Odin rather than narrowing it to f64.
Native_Shell_Printf_Extended :: struct {mantissa:u64, exponent:int, negative:bool, special:u8, valid:bool}

native_shell_printf_round :: proc(numerator,denominator:^big.Int)->big.Int {
    quotient,remainder,twice:big.Int
    _=big.divmod(&quotient,&remainder,numerator,denominator)
    _=big.shl(&twice,&remainder,1)
    comparison,_:=big.cmp(&twice,denominator)
    odd,_:=big.is_odd(&quotient)
    if comparison>0||comparison==0&&odd {_=big.add(&quotient,&quotient,big.DIGIT(1))}
    return quotient
}

native_shell_printf_extended :: proc(input:string)->Native_Shell_Printf_Extended {
    result:=Native_Shell_Printf_Extended{valid=true}
    value:=input
    for len(value)>0&&strings.index_byte(" \t\r\n\v\f",value[0])>=0 {value=value[1:]}
    if value=="" {result.valid=input=="";return result}
    if value[0]=='\''||value[0]=='"' {number,_:=native_shell_printf_number(value);value=fmt.aprintf("%d",number)}
    if value[0]=='+'||value[0]=='-' {result.negative=value[0]=='-';value=value[1:]}
    if value=="" {result.valid=false;return result}
    lower:=strings.to_lower(value)
    if strings.has_prefix(lower,"inf") {result.special=1;result.valid=lower=="inf"||lower=="infinity";return result}
    if strings.has_prefix(lower,"nan") {result.special=2;result.valid=lower=="nan"||strings.has_prefix(lower,"nan(")&&strings.has_suffix(lower,")");return result}
    base:=10;i:=0
    if len(value)>=2&&value[0]=='0'&&(value[1]=='x'||value[1]=='X') {base=16;i=2}
    digits:=make([dynamic]u8);fraction:=0;point:=false
    decimal:=".";if locale:=libc.localeconv();locale!=nil&&locale.decimal_point!=nil {decimal=string(locale.decimal_point)}
    for i<len(value) {
        ch:=value[i]
        if !point&&(ch=='.'||decimal!=""&&strings.has_prefix(value[i:],decimal)) {
            point=true;if ch=='.' {i+=1} else {i+=len(decimal)};continue
        }
        digit:=native_shell_printf_digit(ch)
        if digit<0||digit>=base {break}
        append(&digits,ch);if point {fraction+=1};i+=1
    }
    if len(digits)==0 {result.valid=false;return result}
    exponent:=0
    if i<len(value)&&(base==10&&(value[i]=='e'||value[i]=='E')||base==16&&(value[i]=='p'||value[i]=='P')) {
        marker:=i;i+=1;negative:=false
        if i<len(value)&&(value[i]=='+'||value[i]=='-') {negative=value[i]=='-';i+=1}
        begin:=i
        for i<len(value)&&value[i]>='0'&&value[i]<='9' {exponent=min(100000,exponent*10+int(value[i]-'0'));i+=1}
        if i==begin {i=marker;exponent=0} else if negative {exponent= -exponent}
    }
    result.valid=i==len(value)
    if base==10 {exponent-=fraction} else {exponent-=fraction*4}
    numerator,denominator:big.Int
    _=big.set(&numerator,string(digits[:]),i8(base));_=big.set(&denominator,1)
    zero,_:=big.is_zero(&numerator)
    if zero {return result}
    limit:=5000;if base==16 {limit=17000}
    if exponent>limit {result.special=1;result.valid=false;return result}
    if exponent< -limit-len(digits)*4 {result.valid=false;return result}
    if base==10 {
        power:big.Int;_=big.pow(&power,10,abs(exponent))
        if exponent>=0 {_=big.mul(&numerator,&numerator,&power)} else {denominator=power}
    } else if exponent>=0 {_=big.shl(&numerator,&numerator,exponent)} else {_=big.shl(&denominator,&denominator,-exponent)}
    numerator_bits,_:=big.count_bits(&numerator);denominator_bits,_:=big.count_bits(&denominator)
    binary_exponent:=numerator_bits-denominator_bits
    comparison:big.Int
    if binary_exponent>=0 {_=big.shl(&comparison,&denominator,binary_exponent);order,_:=big.cmp(&numerator,&comparison);if order<0 {binary_exponent-=1}}
    else {_=big.shl(&comparison,&numerator,-binary_exponent);order,_:=big.cmp(&comparison,&denominator);if order<0 {binary_exponent-=1}}
    if binary_exponent>16383 {result.special=1;result.valid=false;return result}
    subnormal:=binary_exponent< -16382
    if subnormal {binary_exponent= -16382}
    shift:=63-binary_exponent
    if shift>=0 {_=big.shl(&numerator,&numerator,shift)} else {_=big.shl(&denominator,&denominator,-shift)}
    if subnormal {
        quotient,remainder:big.Int;_=big.divmod(&quotient,&remainder,&numerator,&denominator)
        exact,_:=big.is_zero(&remainder);if !exact {result.valid=false}
    }
    significand:=native_shell_printf_round(&numerator,&denominator)
    bits,_:=big.count_bits(&significand)
    if bits>64 {_=big.shr(&significand,&significand,1);binary_exponent+=1}
    result.mantissa,_=big.get_u64(&significand);result.exponent=binary_exponent-63
    if result.mantissa==0 {result.valid=false}
    if binary_exponent>16383 {result.special=1;result.valid=false}
    return result
}

native_shell_printf_ratio :: proc(value:Native_Shell_Printf_Extended)->(big.Int,big.Int) {
    numerator,denominator:big.Int;_=big.set(&numerator,value.mantissa);_=big.set(&denominator,1)
    if value.exponent>=0 {_=big.shl(&numerator,&numerator,value.exponent)} else {_=big.shl(&denominator,&denominator,-value.exponent)}
    return numerator,denominator
}

native_shell_printf_scaled :: proc(numerator,denominator:^big.Int,places:int)->string {
    // The denominator is a power of two. Once its bit count has been
    // exhausted, every further requested decimal digit is exactly zero.
    // This keeps %.20000f inexpensive without restricting its precision.
    denominator_bits,_:=big.count_bits(denominator)
    exact_places:=max(0,denominator_bits-1)
    working_places:=min(places,exact_places)
    top,bottom,power:big.Int;_=big.copy(&top,numerator);_=big.copy(&bottom,denominator)
    _=big.pow(&power,10,abs(working_places))
    if working_places>=0 {_=big.mul(&top,&top,&power)} else {_=big.mul(&bottom,&bottom,&power)}
    rounded:=native_shell_printf_round(&top,&bottom);text,_:=big.int_to_string(&rounded)
    if places>working_places {text=strings.concatenate([]string{text,native_shell_printf_zeroes(places-working_places)})}
    return text
}

native_shell_printf_decimal_exponent :: proc(numerator,denominator:^big.Int)->int {
    zero,_:=big.is_zero(numerator);if zero {return 0}
    top,_:=big.int_to_string(numerator);bottom,_:=big.int_to_string(denominator)
    exponent:=len(top)-len(bottom)
    power,scaled:big.Int;_=big.pow(&power,10,abs(exponent))
    if exponent>=0 {_=big.mul(&scaled,denominator,&power);comparison,_:=big.cmp(numerator,&scaled);if comparison<0 {exponent-=1}}
    else {_=big.mul(&scaled,numerator,&power);comparison,_:=big.cmp(&scaled,denominator);if comparison<0 {exponent-=1}}
    return exponent
}

native_shell_printf_zeroes :: proc(count:int)->string {bytes:=make([]u8,max(0,count));for &byte in bytes {byte='0'};return string(bytes)}

native_shell_printf_decimal :: proc(value:Native_Shell_Printf_Extended,conversion:u8,precision:int,alternate:bool)->string {
    numerator,denominator:=native_shell_printf_ratio(value)
    lower:=conversion;if lower>='A'&&lower<='Z' {lower+=32}
    places:=precision;if places<0 {places=6}
    exponent:=0
    if lower=='g'||lower=='e' {
        exponent=native_shell_printf_decimal_exponent(&numerator,&denominator)
        significant:=places;if lower=='e' {significant+=1} else if significant==0 {significant=1}
        requested_significant:=significant
        if lower=='g'&&!alternate {
            denominator_bits,_:=big.count_bits(&denominator)
            // %g discards trailing zeroes, so it need not first allocate a
            // potentially huge precision's worth of zeroes merely to trim it.
            significant=min(significant,max(1,exponent+denominator_bits))
        }
        rounded:=native_shell_printf_scaled(&numerator,&denominator,significant-1-exponent)
        previous_exponent:=exponent
        if len(rounded)>significant {exponent+=1}
        if lower=='g' {
            if exponent< -4||exponent>=requested_significant {
                lower='e';places=significant-1
                // glibc's long-double %#g emits only the decimal point when
                // rounding crosses from fixed to scientific representation.
                if alternate&&previous_exponent<significant&&exponent>=significant {places=0}
            } else {lower='f';places=max(0,significant-exponent-1)}
        }
    }
    text:=""
    if lower=='f' {
        digits:=native_shell_printf_scaled(&numerator,&denominator,places)
        if len(digits)<=places {digits=strings.concatenate([]string{native_shell_printf_zeroes(places+1-len(digits)),digits})}
        point:=len(digits)-places;text=digits[:point]
        if places>0||alternate {text=strings.concatenate([]string{text,".",digits[point:]})}
    } else {
        digits:=native_shell_printf_scaled(&numerator,&denominator,places-exponent)
        if len(digits)>places+1 {digits=digits[:places+1]}
        if len(digits)<places+1 {digits=strings.concatenate([]string{native_shell_printf_zeroes(places+1-len(digits)),digits})}
        text=digits[:1]
        if places>0||alternate {text=strings.concatenate([]string{text,".",digits[1:]})}
    }
    if (conversion=='g'||conversion=='G')&&!alternate {
        if strings.index_byte(text,'.')>=0 {for len(text)>0&&text[len(text)-1]=='0' {text=text[:len(text)-1]};if strings.has_suffix(text,".") {text=text[:len(text)-1]}}
    }
    if lower=='e' {
        letter:="e";if conversion>='A'&&conversion<='Z' {letter="E"}
        sign:="+";if exponent<0 {sign="-"}
        digits:=fmt.aprintf("%d",abs(exponent));if len(digits)<2 {digits=strings.concatenate([]string{"0",digits})}
        text=strings.concatenate([]string{text,letter,sign,digits})
    }
    return text
}

native_shell_printf_hexadecimal :: proc(value:Native_Shell_Printf_Extended,conversion:u8,precision:int,alternate:bool)->string {
    exponent:=value.exponent+60;mantissa:=value.mantissa
    if mantissa==0 {exponent=0}
    places:=precision
    text:=""
    if places>=0&&places<15 {
        shift:=uint(4*(15-places));rounded:=mantissa>>shift;remainder:=mantissa&((u64(1)<<shift)-1);half:=u64(1)<<(shift-1)
        if remainder>half||remainder==half&&rounded&1!=0 {rounded+=1}
        digits:=fmt.aprintf("%x",rounded)
        if len(digits)>places+1 {digits=digits[:places+1];exponent+=4}
        if len(digits)<places+1 {digits=strings.concatenate([]string{native_shell_printf_zeroes(places+1-len(digits)),digits})}
        text=digits[:1];if places>0||alternate {text=strings.concatenate([]string{text,".",digits[1:]})}
    } else {
        digits:=fmt.aprintf("%016x",mantissa)
        fraction:=digits[1:]
        if places<0 {for len(fraction)>0&&fraction[len(fraction)-1]=='0' {fraction=fraction[:len(fraction)-1]}}
        else if places>15 {fraction=strings.concatenate([]string{fraction,native_shell_printf_zeroes(places-15)})}
        text=digits[:1];if len(fraction)>0||alternate {text=strings.concatenate([]string{text,".",fraction})}
    }
    sign:="+";if exponent<0 {sign="-"}
    text=strings.concatenate([]string{"0x",text,"p",sign,fmt.aprintf("%d",abs(exponent))})
    if conversion=='A' {text=strings.to_upper(text)}
    return text
}

native_shell_printf_extended_format :: proc(value:Native_Shell_Printf_Extended,conversion:u8,flags:string,width,precision:int)->string {
    alternate:=strings.index_byte(flags,'#')>=0;left:=strings.index_byte(flags,'-')>=0
    text:=""
    if value.special!=0 {text="inf";if value.special==2 {text="nan"};if conversion>='A'&&conversion<='Z' {text=strings.to_upper(text)}}
    else if conversion=='a'||conversion=='A' {text=native_shell_printf_hexadecimal(value,conversion,precision,alternate)}
    else {text=native_shell_printf_decimal(value,conversion,precision,alternate)}
    if value.special==0 {
        locale:=libc.localeconv()
        if locale!=nil {
            had_decimal:=strings.index_byte(text,'.')>=0
            if strings.index_byte(flags,'\'')>=0&&strings.index_byte("fFgG",conversion)>=0&&strings.index_byte(text,'e')<0&&strings.index_byte(text,'E')<0 {
                text=native_shell_printf_group(text,locale)
            }
            decimal:=string(locale.decimal_point)
            if had_decimal&&decimal!=""&&decimal!="." {if point:=strings.last_index_byte(text,'.');point>=0 {text=strings.concatenate([]string{text[:point],decimal,text[point+1:]})}}
        }
    }
    sign:=""
    if value.negative {sign="-"} else if strings.index_byte(flags,'+')>=0 {sign="+"} else if strings.index_byte(flags,' ')>=0 {sign=" "}
    if !left&&value.special==0&&strings.index_byte(flags,'0')>=0&&len(sign)+len(text)<width {
        zeroes:=native_shell_printf_zeroes(width-len(sign)-len(text))
        if strings.has_prefix(text,"0x")||strings.has_prefix(text,"0X") {text=strings.concatenate([]string{text[:2],zeroes,text[2:]})} else {text=strings.concatenate([]string{zeroes,text})}
    }
    return native_shell_printf_pad(strings.concatenate([]string{sign,text}),width,-1,left)
}

native_shell_printf_group :: proc(text:string,locale:^libc.lconv)->string {
    separator:=string(locale.thousand_sep);groups:=string(locale.grouping)
    if separator==""||len(groups)==0||groups[0]==0||groups[0]>=127 {return text}
    end:=len(text);if point:=strings.index_byte(text,'.');point>=0 {end=point}
    parts:=make([dynamic]string);at:=end;group:=int(groups[0]);index:=0
    for at>group&&group>0&&group<127 {
        append(&parts,text[at-group:at]);at-=group
        if index+1<len(groups) {index+=1;next:=int(groups[index]);if next!=0 {group=next}}
    }
    append(&parts,text[:at])
    output:=make([dynamic]u8)
    for i:=len(parts)-1;i>=0;i-=1 {append(&output,parts[i]);if i>0 {append(&output,separator)}}
    append(&output,text[end:]);return string(output[:])
}

native_shell_printf_pad :: proc(text:string,width,precision:int,left:bool)->string {
    value:=text
    if precision>=0 {value=value[:min(len(value),precision)]}
    padding:=max(0,width-len(value))
    if padding==0 {return value}
    output:=make([]u8,len(value)+padding)
    for &byte in output {byte=' '}
    at:=padding;if left {at=0}
    copy(output[at:at+len(value)],transmute([]u8)value)
    return string(output)
}

native_shell_printf_time :: proc(shell:^Native_Shell,pattern:string,number:i64)->string {
    stamp:=posix.time_t(number)
    if number==-1 {stamp=posix.time(nil)}
    if number==-2 {stamp=shell.compat.started_wall}
    old:=posix.getenv("TZ");previous:="";had_previous:=old!=nil
    if had_previous {previous=strings.clone(string(old))}
    timezone,has_timezone:=native_shell_value_get(shell,"TZ")
    if has_timezone {_=posix.setenv("TZ",strings.clone_to_cstring(timezone),true)} else {_=posix.unsetenv("TZ")}
    posix.tzset()
    defer {if had_previous {_=posix.setenv("TZ",strings.clone_to_cstring(previous),true)} else {_=posix.unsetenv("TZ")};posix.tzset()}
    local:posix.tm
    if posix.localtime_r(&stamp,&local)==nil {return ""}
    if pattern=="" {return ""}
    // A suffix distinguishes a legitimately empty expansion (for example
    // an empty locale AM/PM marker) from a buffer that was too small.
    cpattern:=strings.clone_to_cstring(strings.concatenate([]string{pattern,"\x01"}))
    capacity:=256
    for {
        bytes:=make([]u8,capacity)
        amount:=posix.strftime(raw_data(bytes),c.size_t(len(bytes)),cpattern,&local)
        if amount>0 {return string(bytes[:int(amount)-1])}
        if capacity>max(int)/2 {return ""}
        capacity*=2
    }
}

native_shell_printf :: proc(shell:^Native_Shell,args:[]string)->(status:int) {
    previous_locale:=native_shell_printf_locale(shell)
    defer {_=libc.setlocale(.ALL,strings.clone_to_cstring(previous_locale));delete(previous_locale)}
    index:=1;destination:=""
    for index<len(args)&&strings.has_prefix(args[index],"-v") {
        if args[index]=="-v" {
            if index+1>=len(args) {fmt.eprintln("printf: -v requires a variable name");return 2}
            destination=args[index+1];index+=2
        } else {destination=args[index][2:];index+=1}
        base,_,_:=native_shell_reference(destination);if !native_shell_name(base) {fmt.eprintf("printf: %s: not a valid identifier\n",destination);return 2}
    }
    terminated:=false
    if index<len(args)&&args[index]=="--" {index+=1;terminated=true}
    if index>=len(args) {fmt.eprintln("printf: usage: printf [-v VARIABLE] FORMAT [ARGUMENT ...]");return 2}
    if !terminated&&strings.has_prefix(args[index],"-") {fmt.eprintf("printf: invalid option: %s\n",args[index]);return 2}
    format:=args[index];index+=1
    output:=make([dynamic]u8);status=0;finished:=false
    defer {
        if destination!="" {
            value:=string(output[:]);if zero:=strings.index_byte(value,0);zero>=0 {value=value[:zero]}
            if error:=native_shell_value_set(shell,destination,value);error!="" {fmt.eprintf("printf: %s\n",error);status=1}
        } else {fmt.print(string(output[:]))}
    }
    for !finished {
        previous_index:=index;converted:=false
        for i:=0;i<len(format); {
            if format[i]=='\\' {
                escaped,_,invalid:=native_shell_printf_escape(format,&i,false)
                append(&output,escaped);if invalid {fmt.eprintln("printf: invalid escape");status=1};continue
            }
            if format[i]!='%' {append(&output,format[i]);i+=1;continue}
            i+=1
            if i<len(format)&&format[i]=='%' {append(&output,u8('%'));i+=1;continue}
            flags:=make([dynamic]u8);left,alternate:=false,false
            for i<len(format)&&strings.index_byte("-+ #0'",format[i])>=0 {
                if format[i]=='-' {left=true};if format[i]=='#' {alternate=true};append(&flags,format[i]);i+=1
            }
            width:=0
            if i<len(format)&&format[i]=='*' {
                value:="";if index<len(args) {value=args[index];index+=1}
                number,valid:=native_shell_printf_number(value);if !valid {fmt.eprintf("printf: %s: invalid number\n",value);status=1}
                signed:=i64(number)
                if signed<0 {
                    left=true;append(&flags,u8('-'))
                    if signed< -i64(NATIVE_SHELL_PRINTF_FIELD_MAX) {fmt.eprintln("printf: field width exceeds platform C int range");return 1}
                    signed= -signed
                }
                width=int(min(u64(signed),u64(NATIVE_SHELL_PRINTF_FIELD_MAX+1)));i+=1
            } else {for i<len(format)&&format[i]>='0'&&format[i]<='9' {width=min(NATIVE_SHELL_PRINTF_FIELD_MAX+1,width*10+int(format[i]-'0'));i+=1}}
            precision:=-1
            if i<len(format)&&format[i]=='.' {
                i+=1;precision=0
                if i<len(format)&&format[i]=='*' {
                    value:="";if index<len(args) {value=args[index];index+=1}
                    number,valid:=native_shell_printf_number(value);if !valid {fmt.eprintf("printf: %s: invalid number\n",value);status=1}
                    signed:=i64(number);if signed<0 {precision= -1} else {precision=int(min(u64(signed),u64(NATIVE_SHELL_PRINTF_FIELD_MAX+1)))};i+=1
                } else {for i<len(format)&&format[i]>='0'&&format[i]<='9' {precision=min(NATIVE_SHELL_PRINTF_FIELD_MAX+1,precision*10+int(format[i]-'0'));i+=1}}
            }
            if width>NATIVE_SHELL_PRINTF_FIELD_MAX||precision>NATIVE_SHELL_PRINTF_FIELD_MAX {fmt.eprintln("printf: field width/precision exceeds platform C int range");return 1}
            wide:=false
            for i<len(format)&&strings.index_byte("hlLjzt",format[i])>=0 {if format[i]=='l' {wide=true};i+=1}
            if i>=len(format) {fmt.eprintln("printf: incomplete format");return 1}
            conversion:=format[i];time_format:="";time_conversion:=false
            if conversion=='(' {
                begin:=i+1;i+=1
                for i+1<len(format)&&!(format[i]==')'&&format[i+1]=='T') {i+=1}
                if i+1>=len(format) {fmt.eprintln("printf: incomplete time format");return 1}
                time_format=format[begin:i];conversion='T';time_conversion=true;i+=1
            }
            i+=1;converted=true
            value:="";supplied:=index<len(args)
            if supplied {value=args[index];index+=1}
            rendered:="";stop:=false
            switch conversion {
            case 's','S':
                if wide||conversion=='S' {rendered=native_shell_printf_wide(value,width,precision,left)} else {rendered=native_shell_printf_pad(value,width,precision,left)}
            case 'c','C':
                if value=="" {value="\x00"} else if wide||conversion=='C' {
                    _,count,valid:=native_shell_printf_character(value)
                    if valid {value=value[:count]} else {value=""}
                } else {value=value[:1]}
                if wide||conversion=='C' {rendered=native_shell_printf_wide(value,width,-1,left)} else {rendered=native_shell_printf_pad(value,width,-1,left)}
            case 'b':
                decoded,stop_output,invalid:=native_shell_printf_decode(value);stop=stop_output
                if invalid {fmt.eprintln("printf: invalid escape");status=1}
                rendered=native_shell_printf_pad(decoded,width,precision,left)
            case 'q','Q':
                if conversion=='Q'&&precision>=0 {value=value[:min(len(value),precision)]}
                rendered=native_shell_printf_quote(value,alternate)
                limit:=precision;if conversion=='Q' {limit= -1}
                rendered=native_shell_printf_pad(rendered,width,limit,left)
            case 'n':
                if value!="" {
                    if !native_shell_name(value) {fmt.eprintf("printf: %s: not a valid identifier\n",value);return 1}
                    if error:=native_shell_value_set(shell,value,fmt.aprintf("%d",len(output)));error!="" {fmt.eprintf("printf: %s\n",error);status=1}
                }
            case 'T':
                if !time_conversion {fmt.eprintln("printf: invalid format character: T");return 1}
                number:i64= -1
                if supplied {raw,valid:=native_shell_printf_number(value);number=i64(raw);if !valid {fmt.eprintf("printf: %s: invalid number\n",value);status=1}}
                rendered=native_shell_printf_pad(native_shell_printf_time(shell,time_format,number),width,precision,left)
            case 'd','i','u','o','x','X','f','F','e','E','g','G','a','A':
                numeric_format:=strings.concatenate([]string{"%",string(flags[:]),fmt.aprintf("%d",width)})
                if precision>=0 {numeric_format=strings.concatenate([]string{numeric_format,".",fmt.aprintf("%d",precision)})}
                floating:=strings.index_byte("fFeEgGaA",conversion)>=0
                if !floating {numeric_format=strings.concatenate([]string{numeric_format,"ll"})}
                code:=[1]u8{conversion};numeric_format=strings.concatenate([]string{numeric_format,string(code[:])})
                cformat:=strings.clone_to_cstring(numeric_format)
                size:c.int
                integer:u64
                valid:=true
                if floating {
                    extended:=native_shell_printf_extended(value)
                    if !extended.valid {fmt.eprintf("printf: %s: invalid number\n",value);status=1}
                    rendered=native_shell_printf_extended_format(extended,conversion,string(flags[:]),width,precision)
                    break
                }
                integer,valid=native_shell_printf_number(value,conversion!='d'&&conversion!='i');if conversion=='d'||conversion=='i' {size=libc.snprintf(nil,0,cformat,c.longlong(i64(integer)))} else {size=libc.snprintf(nil,0,cformat,c.ulonglong(integer))}
                if !valid {fmt.eprintf("printf: %s: invalid number\n",value);status=1}
                if size<0 {fmt.eprintln("printf: numeric output exceeds platform C int range");return 1}
                bytes:=make([]u8,int(size)+1)
                if conversion=='d'||conversion=='i' {libc.snprintf(raw_data(bytes),c.size_t(len(bytes)),cformat,c.longlong(i64(integer)))}
                else {libc.snprintf(raw_data(bytes),c.size_t(len(bytes)),cformat,c.ulonglong(integer))}
                rendered=string(bytes[:int(size)])
            case:fmt.eprintf("printf: invalid format character: %c\n",conversion);return 1
            }
            if len(rendered)>max(int)-len(output) {fmt.eprintln("printf: output length exceeds addressable memory");return 1}
            append(&output,rendered)
            if stop {finished=true;break}
        }
        if !converted||index>=len(args)||index==previous_index {break}
    }
    if destination!="" {
        // Validate before the deferred assignment, so failed -v writes are
        // reflected in the builtin's exit status as well as its diagnostic.
        base,_,_:=native_shell_reference(destination)
        if !native_shell_name(base)||shell.compat.attributes[base]&NATIVE_SHELL_READONLY!=0 {return 1}
    }
    return status
}

native_shell_has_function :: proc(shell:^Native_Shell,name:string)->bool {
    if shell.compat==nil {return false}
    if (shell.compat.options["posix"]||shell.compat.restricted)&&strings.contains(name,"/") {return false}
    _,exists:=shell.compat.functions[name];return exists
}

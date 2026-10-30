package main

import vmem "core:mem/virtual"
import "core:math"
import "core:strconv"
import "core:strings"

native_css_strip_comments :: proc(css:string)->string {
    if !strings.contains(css,"/*") {return css}
    out:=make([dynamic]u8);quote:u8
    for i:=0;i<len(css);i+=1 {b:=css[i];if quote!=0 {append(&out,b);if b=='\\'&&i+1<len(css) {i+=1;append(&out,css[i])} else if b==quote {quote=0};continue};if b=='\''||b=='"' {quote=b;append(&out,b);continue};if i+1<len(css)&&b=='/'&&css[i+1]=='*' {end:=strings.index(css[i+2:],"*/");if end<0 {break};i+=end+3;append(&out,' ');continue};append(&out,b)}
    return string(out[:])
}
native_css_specificity :: proc(selector:string,depth:int=0)->int {
    if depth>24 {return 0};result:=0;tag:=true
    for i:=0;i<len(selector); {
        b:=selector[i]
        if b==' '||b=='>'||b=='+'||b=='~'||b==',' {tag=true;i+=1;continue}
        if b=='*' {tag=false;i+=1;continue}
        if b=='[' {result+=100;end:=strings.index_byte(selector[i:],']');if end<0 {break};i+=end+1;tag=false;continue}
        if b==':' {i+=1;start:=i;for i<len(selector)&&native_css_word(selector,selector[i]) {i+=1};name:=selector[start:i]
            if i<len(selector)&&selector[i]=='(' {i+=1;start=i;nesting:=1;for i<len(selector)&&nesting>0 {if selector[i]=='(' {nesting+=1};if selector[i]==')' {nesting-=1};i+=1};if nesting>0 {break};if name=="is"||name=="not"||name=="has" {best:=0;for part in native_css_parts(selector[start:i-1],',') {best=max(best,native_css_specificity(part,depth+1))};result+=best} else if name!="where" {result+=100}} else {result+=100};tag=false;continue}
        if b=='#'||b=='.' {if b=='#' {result+=10000} else {result+=100};i+=1;for i<len(selector)&&native_css_word(selector,selector[i]) {i+=1};tag=false;continue}
        if native_css_word(selector,b) {if tag {result+=1};for i<len(selector)&&native_css_word(selector,selector[i]) {i+=1};tag=false;continue};i+=1
    }
    return result
}
native_css_parse :: proc(doc:^Native_Document,raw_css:string) {
    css:=native_css_strip_comments(raw_css)
    for i:=0;i<len(css); {
        if strings.has_prefix(css[i:],"/*") {end:=strings.index(css[i+2:],"*/");if end<0 {return};i+=end+4;continue}
        for i<len(css)&&(css[i]==' '||css[i]=='\t'||css[i]=='\r'||css[i]=='\n') {i+=1};if i>=len(css) {return}
        open:=strings.index_byte(css[i:],'{');if open<0 {return};open+=i
        if css[i]=='@' {semicolon:=strings.index_byte(css[i:],';');if semicolon>=0&&i+semicolon<open {i+=semicolon+1;continue}}
        close:=open+1;depth:=1;quote:u8
        for close<len(css)&&depth>0 {b:=css[close];if quote!=0 {if b=='\\' {close+=1} else if b==quote {quote=0}} else if b=='\''||b=='"' {quote=b} else if b=='{' {depth+=1} else if b=='}' {depth-=1};close+=1}
        if depth!=0 {return}
        selector:=strings.trim_space(css[i:open]);body:=css[open+1:close-1];i=close
        if strings.has_prefix(selector,"@layer") {native_css_parse(doc,body);continue}
        if strings.has_prefix(selector,"@supports") {if native_css_supports(selector[9:]) {native_css_parse(doc,body)};continue}
        if strings.has_prefix(selector,"@media") {
            if strings.contains(selector,"print") {continue}
            previous_dark,previous_light:=doc.media_dark,doc.media_light
            previous_min,previous_max:=doc.media_min_width,doc.media_max_width
            doc.media_dark=doc.media_dark||strings.contains(selector,"prefers-color-scheme:dark")||strings.contains(selector,"prefers-color-scheme: dark")
            doc.media_light=doc.media_light||strings.contains(selector,"prefers-color-scheme:light")||strings.contains(selector,"prefers-color-scheme: light")
            if position:=strings.index(selector,"min-width:");position>=0 {text:=selector[position+10:];end:=strings.index_byte(text,')');if end>=0 {doc.media_min_width=max(doc.media_min_width,native_css_length(text[:end],16))}}
            if position:=strings.index(selector,"max-width:");position>=0 {text:=selector[position+10:];end:=strings.index_byte(text,')');if end>=0 {bound:=native_css_length(text[:end],16);if doc.media_max_width<=0 {doc.media_max_width=bound} else {doc.media_max_width=min(bound,doc.media_max_width)}}}
            native_css_parse(doc,body)
            doc.media_dark=previous_dark;doc.media_light=previous_light;doc.media_min_width=previous_min;doc.media_max_width=previous_max
            continue
        }
        if strings.has_prefix(selector,"@") {continue}
        for raw_item in strings.split_iterator(&selector,",") {
            item:=strings.trim_space(raw_item);if item=="" {continue}
            specificity:=native_css_specificity(item)
            rule:=Native_CSS_Rule{selector=strings.clone(item),declarations=strings.clone(body),specificity=specificity,dark_only=doc.media_dark,light_only=doc.media_light,min_width=doc.media_min_width,max_width=doc.media_max_width}
            append(&doc.rules,rule)
            j:=len(doc.rules)-1
            for j>0&&doc.rules[j-1].specificity>specificity {doc.rules[j]=doc.rules[j-1];j-=1}
            doc.rules[j]=rule
        }
    }
}
native_css_supports :: proc(raw_query:string,depth:int=0)->bool {
    if depth>24 {return false};query:=strings.trim_space(raw_query)
    if strings.has_prefix(query,"not ") {return !native_css_supports(query[4:],depth+1)}
    nesting:=0
    for i:=0;i<len(query);i+=1 {if query[i]=='(' {nesting+=1};if query[i]==')' {nesting-=1};if nesting==0&&strings.has_prefix(query[i:]," or ") {return native_css_supports(query[:i],depth+1)||native_css_supports(query[i+4:],depth+1)};if nesting==0&&strings.has_prefix(query[i:]," and ") {return native_css_supports(query[:i],depth+1)&&native_css_supports(query[i+5:],depth+1)}}
    if len(query)>1&&query[0]=='('&&query[len(query)-1]==')' {query=strings.trim_space(query[1:len(query)-1])}
    colon:=strings.index_byte(query,':');if colon<0 {return false};name:=strings.trim_space(query[:colon]);value:=strings.trim_space(query[colon+1:])
    switch name {
    case "display":return value=="block"||value=="inline"||value=="inline-block"||value=="flex"||value=="grid"||value=="table"
    case "position":return value=="static"||value=="relative"||value=="absolute"||value=="fixed"||value=="sticky"
    case "color","background-color","width","height","gap","row-gap","column-gap","box-sizing","grid-template-columns","grid-template-rows","flex","flex-direction","flex-wrap","justify-content","align-items","margin","padding":return value!=""
    }
    return strings.has_prefix(name,"--")
}
native_css_word :: proc(text:string,b:u8)->bool {return b>='a'&&b<='z'||b>='A'&&b<='Z'||b>='0'&&b<='9'||b=='-'||b=='_'||b>=128}
native_css_parts :: proc(text:string,separator:u8=' ')->[dynamic]string {
    parts:=make([dynamic]string,context.temp_allocator);start:=0;depth:=0;quote:u8
    for i:=0;i<len(text);i+=1 {
        b:=text[i]
        if quote!=0 {if b=='\\' {i+=1} else if b==quote {quote=0};continue}
        if b=='\''||b=='"' {quote=b;continue}
        if b=='('||b=='[' {depth+=1};if b==')'||b==']' {depth-=1}
        split:=b==separator;if separator==' ' {split=b==' '||b=='\t'||b=='\n'||b=='\r'}
        if split&&depth==0 {if part:=strings.trim_space(text[start:i]);part!="" {append(&parts,part)};start=i+1}
    }
    if part:=strings.trim_space(text[start:]);part!="" {append(&parts,part)}
    return parts
}
native_css_previous :: proc(doc:^Native_Document,node:int)->int {
    if node<0||node>=len(doc.nodes)||doc.nodes[node].parent<0 {return -1}
    previous:=-1;child:=doc.nodes[doc.nodes[node].parent].first
    for child>=0&&child!=node {if !strings.has_prefix(doc.nodes[child].tag,"#") {previous=child};child=doc.nodes[child].next}
    return previous
}
native_css_nth :: proc(expression:string,index:int)->bool {
    text,_:=strings.replace_all(strings.to_lower(strings.trim_space(expression),context.temp_allocator)," ","",context.temp_allocator)
    if text=="odd" {return index%2==1};if text=="even" {return index%2==0}
    n:=strings.index_byte(text,'n')
    if n<0 {number,ok:=strconv.parse_int(text);return ok&&index==number}
    a:=1;b:=0
    if text[:n]=="-" {a=-1} else if text[:n]!=""&&text[:n]!="+" {value,ok:=strconv.parse_int(text[:n]);if !ok {return false};a=value}
    if n+1<len(text) {value,ok:=strconv.parse_int(text[n+1:]);if !ok {return false};b=value}
    if a==0 {return index==b};return (index-b)%a==0&&(index-b)/a>=0
}
native_css_simple :: proc(doc:^Native_Document,node:int,selector:string)->bool {
    if node<0||node>=len(doc.nodes)||strings.has_prefix(doc.nodes[node].tag,"#") {return false}
    n:=doc.nodes[node]
    for i:=0;i<len(selector); {
        b:=selector[i]
        if b=='*' {i+=1;continue}
        if b=='#'||b=='.' {
            i+=1;start:=i;for i<len(selector)&&native_css_word(selector,selector[i]) {i+=1};value:=selector[start:i]
            if b=='#' {if native_attr(doc,node,"id")!=value {return false}}
            else {classes:=native_attr(doc,node,"class");matched:=false;for class in strings.fields(classes,context.temp_allocator) {if class==value {matched=true;break}};if !matched {return false}}
        } else if b=='[' {
            end:=strings.index_byte(selector[i:],']');if end<0 {return false};end+=i
            expression:=strings.trim_space(selector[i+1:end]);equal:=strings.index_byte(expression,'=')
            if equal<0 {if !native_has_attr(doc,node,expression) {return false}}
            else {
                name:=strings.trim_space(expression[:equal]);operator:u8='=';if len(name)>0&&strings.contains("~|^$*",string(name[len(name)-1:])) {operator=name[len(name)-1];name=strings.trim_space(name[:len(name)-1])}
                wanted:=strings.trim_space(expression[equal+1:]);insensitive:=strings.has_suffix(wanted," i")||strings.has_suffix(wanted," I");if insensitive {wanted=strings.trim_space(wanted[:len(wanted)-2])};wanted=strings.trim(wanted,"\"'")
                if !native_has_attr(doc,node,name) {return false};actual:=native_attr(doc,node,name)
                if insensitive {actual=strings.to_lower(actual,context.temp_allocator);wanted=strings.to_lower(wanted,context.temp_allocator)}
                switch operator {case '=':if actual!=wanted {return false};case '^':if !strings.has_prefix(actual,wanted) {return false};case '$':if !strings.has_suffix(actual,wanted) {return false};case '*':if !strings.contains(actual,wanted) {return false};case '|':if actual!=wanted&&!strings.has_prefix(actual,strings.concatenate([]string{wanted,"-"},context.temp_allocator)) {return false};case '~':found:=false;for word in strings.fields(actual,context.temp_allocator) {if word==wanted {found=true}};if !found {return false}}
            }
            i=end+1
        } else if b==':' {
            i+=1;start:=i;for i<len(selector)&&native_css_word(selector,selector[i]) {i+=1};name:=selector[start:i];argument:=""
            if i<len(selector)&&selector[i]=='(' {i+=1;start=i;depth:=1;for i<len(selector)&&depth>0 {if selector[i]=='(' {depth+=1};if selector[i]==')' {depth-=1};i+=1};if depth!=0 {return false};argument=selector[start:i-1]}
            switch name {
            case "root":if n.tag!="html"&&node!=0 {return false}
            case "not","is","where":
                found:=false;for part in native_css_parts(argument,',') {if native_css_matches(doc,node,part) {found=true;break}};if name=="not" {found=!found};if !found {return false}
            case "first-child","last-child","only-child","first-of-type","last-of-type","only-of-type","nth-child","nth-last-child","nth-of-type","nth-last-of-type":
                if n.parent<0 {return false};position,count:=0,0;child:=doc.nodes[n.parent].first;of_type:=strings.contains(name,"of-type")
                for child>=0 {other:=doc.nodes[child];if !strings.has_prefix(other.tag,"#")&&(!of_type||other.tag==n.tag) {count+=1;if child==node {position=count}};child=other.next}
                if strings.has_prefix(name,"first-")&&position!=1||strings.has_prefix(name,"last-")&&position!=count||strings.has_prefix(name,"only-")&&count!=1 {return false}
                if strings.has_prefix(name,"nth-") {if strings.contains(name,"last-") {position=count-position+1};if !native_css_nth(argument,position) {return false}}
            case "empty":child:=n.first;for child>=0 {if doc.nodes[child].tag!="#comment"&&(doc.nodes[child].tag!="#text"||doc.nodes[child].text!="") {return false};child=doc.nodes[child].next}
            case "hover","active","focus","focus-visible","focus-within":
                view:=cast(^Document_View)doc.script.host.data;if view==nil {return false}
                candidate:=view.focused_node
                if name=="hover"||name=="active" {candidate=view.hovered_node;if name=="active"&&view.buttons==0 {return false}}
                if name=="focus"||name=="focus-visible" {if candidate!=node {return false}} else {found:=false;for candidate>=0&&candidate<len(doc.nodes) {if candidate==node {found=true;break};candidate=doc.nodes[candidate].parent};if !found {return false}}
            case "read-only":if (n.tag=="input"||n.tag=="textarea")&&!native_has_attr(doc,node,"readonly")&&!native_has_attr(doc,node,"disabled") {return false}
            case "read-write":if (n.tag!="input"&&n.tag!="textarea")||native_has_attr(doc,node,"readonly")||native_has_attr(doc,node,"disabled") {return false}
            case "placeholder-shown":if n.value!=""||native_attr(doc,node,"placeholder")=="" {return false}
            case "checked":if !n.checked {return false}
            case "disabled":if !native_has_attr(doc,node,"disabled") {return false}
            case "enabled":if native_has_attr(doc,node,"disabled") {return false}
            case "required":if !native_has_attr(doc,node,"required") {return false}
            case "optional":if native_has_attr(doc,node,"required") {return false}
            case "link","any-link","visited":if n.tag!="a"||!native_has_attr(doc,node,"href") {return false}
            case "lang":language:=native_attr(doc,node,"lang");if language!=argument&&!strings.has_prefix(language,strings.concatenate([]string{argument,"-"},context.temp_allocator)) {return false}
            case:return false
            }
        } else {
            start:=i;for i<len(selector)&&native_css_word(selector,selector[i]) {i+=1};if start==i||!strings.equal_fold(n.tag,selector[start:i]) {return false}
        }
    }
    return true
}
native_css_matches :: proc(doc:^Native_Document,node:int,raw_selector:string)->bool {
    selector:=strings.trim_space(raw_selector);if selector=="" {return false}
    parts:=native_css_parts(selector,',');if len(parts)>1 {for part in parts {if native_css_matches(doc,node,part) {return true}};return false}
    last:=-1;depth:=0;quote:u8;combinator:u8=' '
    for i:=len(selector)-1;i>=0;i-=1 {
        b:=selector[i]
        if quote!=0 {if b==quote {quote=0};continue};if b=='\''||b=='"' {quote=b;continue}
        if b==')'||b==']' {depth+=1};if b=='('||b=='[' {depth-=1}
        if depth==0&&(b=='>'||b=='+'||b=='~'||b==' ') {last=i;combinator=b;break}
    }
    if last<0 {return native_css_simple(doc,node,selector)}
    right:=strings.trim_space(selector[last+1:]);before:=strings.trim_space(selector[:last])
    if right=="" {return false}
    if combinator==' '&&len(before)>0 {end:=before[len(before)-1];if end=='>'||end=='+'||end=='~' {combinator=end;before=strings.trim_space(before[:len(before)-1])}}
    if !native_css_simple(doc,node,right) {return false}
    if combinator=='+' {return native_css_matches(doc,native_css_previous(doc,node),before)}
    if combinator=='~' {previous:=native_css_previous(doc,node);for previous>=0 {if native_css_matches(doc,previous,before) {return true};previous=native_css_previous(doc,previous)};return false}
    if node<0||node>=len(doc.nodes) {return false};parent:=doc.nodes[node].parent
    for parent>=0 {if native_css_matches(doc,parent,before) {return true};if combinator=='>' {break};parent=doc.nodes[parent].parent}
    return false
}
native_css_color :: proc(doc:^Native_Document,raw_value:string,fallback:Color)->Color {
    value:=strings.trim_space(raw_value)
    if strings.has_prefix(value,"var(")&&strings.has_suffix(value,")") {
        variable:=strings.trim_space(value[4:len(value)-1]);comma:=strings.index_byte(variable,',')
        if comma>=0 {if replacement,ok:=doc.variables[strings.trim_space(variable[:comma])];ok {return native_css_color(doc,replacement,fallback)};return native_css_color(doc,variable[comma+1:],fallback)}
        if replacement,ok:=doc.variables[variable];ok {return native_css_color(doc,replacement,fallback)}
        return fallback
    }
    if strings.has_prefix(value,"#") {
        hex:=value[1:];color:=Color{0,0,0,1}
        if len(hex)==3||len(hex)==4 {for i in 0..<len(hex) {n,ok:=strconv.parse_uint(hex[i:i+1],16);if !ok {return fallback};color[i]=f32(n)/15};return color}
        if len(hex)==6||len(hex)==8 {for i in 0..<len(hex)/2 {n,ok:=strconv.parse_uint(hex[i*2:i*2+2],16);if !ok {return fallback};color[i]=f32(n)/255};return color}
    }
    if strings.has_prefix(value,"rgb(")||strings.has_prefix(value,"rgba(")||strings.has_prefix(value,"hsl(")||strings.has_prefix(value,"hsla(") {
        start:=strings.index_byte(value,'(')+1;end:=strings.last_index_byte(value,')');if end<=start {return fallback}
        body,_:=strings.replace_all(value[start:end],","," ",context.temp_allocator);body,_=strings.replace_all(body,"/"," ",context.temp_allocator);parts:=strings.fields(body,context.temp_allocator)
        if len(parts)<3 {return fallback};color:=Color{0,0,0,1};hsl:=strings.has_prefix(value,"hsl")
        for item,i in parts[:min(4,len(parts))] {part:=strings.trim_space(item);factor:f32=1;if strings.has_suffix(part,"%") {part=part[:len(part)-1];factor=0.01} else if i<3&&!hsl {factor=1.0/255};if hsl&&i==0 {if strings.has_suffix(part,"deg") {part=part[:len(part)-3]} else if strings.has_suffix(part,"turn") {part=part[:len(part)-4];factor=360} else if strings.has_suffix(part,"rad") {part=part[:len(part)-3];factor=180/math.PI}};n,ok:=strconv.parse_f32(part);if !ok {return fallback};color[i]=n*factor}
        if hsl {h:=color[0]-math.floor(color[0]/360)*360;saturation:=clamp(color[1],0,1);lightness:=clamp(color[2],0,1);chroma:=(1-abs(2*lightness-1))*saturation;sector:=h/60;fraction:=sector-math.floor(sector/2)*2;x:=chroma*(1-abs(fraction-1));m:=lightness-chroma/2;rgb:=Color{0,0,0,color[3]};if sector<1 {rgb[0]=chroma;rgb[1]=x} else if sector<2 {rgb[0]=x;rgb[1]=chroma} else if sector<3 {rgb[1]=chroma;rgb[2]=x} else if sector<4 {rgb[1]=x;rgb[2]=chroma} else if sector<5 {rgb[0]=x;rgb[2]=chroma} else {rgb[0]=chroma;rgb[2]=x};for i in 0..<3 {rgb[i]+=m};return rgb}
        for i in 0..<4 {color[i]=clamp(color[i],0,1)};return color
    }
    switch strings.to_lower(value,context.temp_allocator) {
    case "transparent","none":return {0,0,0,0}
    case "black":return {0,0,0,1}
    case "white":return {1,1,1,1}
    case "red":return {1,0,0,1}
    case "green":return {0,0.5,0,1}
    case "blue":return {0,0,1,1}
    case "yellow":return {1,1,0,1}
    case "gray","grey":return {0.5,0.5,0.5,1}
    case "silver":return {0.75,0.75,0.75,1}
    case "orange":return {1,0.65,0,1}
    case "purple":return {0.5,0,0.5,1}
    case "rebeccapurple":return {0.4,0.2,0.6,1}
    case "navy":return {0,0,0.5,1}
    case "teal":return {0,0.5,0.5,1}
    case "currentcolor":return fallback
    }
    return fallback
}
native_css_resolve :: proc(raw_value:string,size,basis,viewport_width,viewport_height:f32,fallback:f32=0,depth:int=0)->f32 {
    value:=strings.trim_space(raw_value);if depth>24||value=="" {return fallback};if value=="auto"||value=="none" {return -1}
    if strings.has_prefix(value,"calc(")&&strings.has_suffix(value,")") {return native_css_resolve(value[5:len(value)-1],size,basis,viewport_width,viewport_height,fallback,depth+1)}
    if (strings.has_prefix(value,"min(")||strings.has_prefix(value,"max(")||strings.has_prefix(value,"clamp("))&&strings.has_suffix(value,")") {
        open:=strings.index_byte(value,'(');parts:=native_css_parts(value[open+1:len(value)-1],',');if len(parts)==0 {return fallback}
        result:=native_css_resolve(parts[0],size,basis,viewport_width,viewport_height,fallback,depth+1)
        if open==5&&len(parts)==3 {preferred:=native_css_resolve(parts[1],size,basis,viewport_width,viewport_height,fallback,depth+1);upper:=native_css_resolve(parts[2],size,basis,viewport_width,viewport_height,fallback,depth+1);return max(result,min(preferred,upper))}
        for part in parts[1:] {n:=native_css_resolve(part,size,basis,viewport_width,viewport_height,fallback,depth+1);if strings.has_prefix(value,"min(") {result=min(result,n)} else {result=max(result,n)}};return result
    }
    nesting:=0
    for i:=len(value)-1;i>0;i-=1 {b:=value[i];if b==')' {nesting+=1};if b=='(' {nesting-=1};if nesting==0&&(b=='+'||b=='-')&&value[i-1]==' ' {a:=native_css_resolve(value[:i],size,basis,viewport_width,viewport_height,fallback,depth+1);c:=native_css_resolve(value[i+1:],size,basis,viewport_width,viewport_height,fallback,depth+1);if b=='+' {return a+c};return a-c}}
    nesting=0
    for i:=len(value)-1;i>0;i-=1 {b:=value[i];if b==')' {nesting+=1};if b=='(' {nesting-=1};if nesting==0&&(b=='*'||b=='/') {a:=native_css_resolve(value[:i],size,basis,viewport_width,viewport_height,fallback,depth+1);c:=native_css_resolve(value[i+1:],size,basis,viewport_width,viewport_height,fallback,depth+1);if b=='*' {return a*c};if c!=0 {return a/c};return fallback}}
    factor:f32=1
    if strings.has_suffix(value,"rem") {value=value[:len(value)-3];factor=16}
    else if strings.has_suffix(value,"vmin") {value=value[:len(value)-4];factor=min(viewport_width,viewport_height)/100}
    else if strings.has_suffix(value,"vmax") {value=value[:len(value)-4];factor=max(viewport_width,viewport_height)/100}
    else if strings.has_suffix(value,"em") {value=value[:len(value)-2];factor=size}
    else if strings.has_suffix(value,"vw")||strings.has_suffix(value,"dvw")||strings.has_suffix(value,"svw")||strings.has_suffix(value,"lvw") {n:=2;if len(value)>2&&(value[len(value)-3]=='d'||value[len(value)-3]=='s'||value[len(value)-3]=='l') {n=3};value=value[:len(value)-n];factor=viewport_width/100}
    else if strings.has_suffix(value,"vh")||strings.has_suffix(value,"dvh")||strings.has_suffix(value,"svh")||strings.has_suffix(value,"lvh") {n:=2;if len(value)>2&&(value[len(value)-3]=='d'||value[len(value)-3]=='s'||value[len(value)-3]=='l') {n=3};value=value[:len(value)-n];factor=viewport_height/100}
    else if strings.has_suffix(value,"px") {value=value[:len(value)-2]}
    else if strings.has_suffix(value,"pt") {value=value[:len(value)-2];factor=4.0/3}
    else if strings.has_suffix(value,"pc") {value=value[:len(value)-2];factor=16}
    else if strings.has_suffix(value,"in") {value=value[:len(value)-2];factor=96}
    else if strings.has_suffix(value,"cm") {value=value[:len(value)-2];factor=96/2.54}
    else if strings.has_suffix(value,"mm") {value=value[:len(value)-2];factor=96/25.4}
    else if strings.has_suffix(value,"ch")||strings.has_suffix(value,"ex") {value=value[:len(value)-2];factor=size*0.5}
    else if strings.has_suffix(value,"%") {value=value[:len(value)-1];factor=basis/100}
    number,ok:=strconv.parse_f32(value);if !ok||math.is_nan(number)||math.is_inf(number) {return fallback};return number*factor
}
native_css_length :: proc(value:string,size:f32,fallback:f32=0)->f32 {return native_css_resolve(value,size,size,0,0,fallback)}
native_css_edges :: proc(value:string,size:f32)->[4]f32 {
    parts:=native_css_parts(value);edges:[4]f32;if len(parts)==0 {return edges}
    for i in 0..<4 {index:=i;if len(parts)==1 {index=0} else if len(parts)==2 {index=i%2} else if len(parts)==3&&i==3 {index=1};edges[i]=native_css_length(parts[min(index,len(parts)-1)],size)};return edges
}
native_css_edge_rules :: proc(value:string)->[4]string {
    parts:=native_css_parts(value);edges:[4]string;if len(parts)==0 {return edges}
    for i in 0..<4 {index:=i;if len(parts)==1 {index=0} else if len(parts)==2 {index=i%2} else if len(parts)==3&&i==3 {index=1};edges[i]=parts[min(index,len(parts)-1)]};return edges
}
native_css_alignment :: proc(value:string,default_value:Native_Alignment=.Start)->Native_Alignment {
    switch value {case "start","flex-start","left":return .Start;case "end","flex-end","right":return .End;case "center":return .Center;case "stretch","normal":return .Stretch;case "space-between":return .Between;case "space-around":return .Around;case "space-evenly":return .Evenly;case "baseline":return .Baseline};return default_value
}
native_css_grid_line :: proc(raw_value:string)->(start,span:int) {
    parts:=native_css_parts(raw_value,'/');start=0;span=1
    if len(parts)==0 {return}
    first:=strings.trim_space(parts[0]);if strings.has_prefix(first,"span ") {n,ok:=strconv.parse_int(strings.trim_space(first[5:]));if ok {span=clamp(n,1,128)}} else {n,ok:=strconv.parse_int(first);if ok {start=n}}
    if len(parts)>1 {last:=strings.trim_space(parts[1]);if strings.has_prefix(last,"span ") {n,ok:=strconv.parse_int(strings.trim_space(last[5:]));if ok {span=clamp(n,1,128)}} else {n,ok:=strconv.parse_int(last);if ok&&start>0&&n>start {span=clamp(n-start,1,128)}}}
    return
}
native_css_variable :: proc(doc:^Native_Document,raw_value:string,depth:int=0,properties:map[string]string=nil)->string {
    value:=strings.trim_space(raw_value);if depth>24 {return ""}
    start:=strings.index(value,"var(");if start<0 {return value};end:=start+4;nesting:=1
    for end<len(value)&&nesting>0 {if value[end]=='(' {nesting+=1};if value[end]==')' {nesting-=1};end+=1};if nesting!=0 {return value}
    parts:=native_css_parts(value[start+4:end-1],',');replacement:="";if len(parts)>0 {if properties!=nil {replacement=properties[strings.trim_space(parts[0])]} else {replacement=doc.variables[strings.trim_space(parts[0])]};if replacement==""&&len(parts)>1 {replacement=parts[1]}}
    replacement=native_css_variable(doc,replacement,depth+1,properties)
    return native_css_variable(doc,strings.concatenate([]string{value[:start],replacement,value[end:]},context.temp_allocator),depth+1,properties)
}
native_css_custom_declarations :: proc(style:^Native_Style,declarations:string,important_pass:bool) {
    for item in native_css_parts(declarations,';') {colon:=strings.index_byte(item,':');if colon<0 {continue};name:=strings.trim_space(item[:colon]);if !strings.has_prefix(name,"--") {continue};value:=strings.trim_space(item[colon+1:]);important:=strings.has_suffix(value,"!important");if important==important_pass {style.custom_properties[name]=strings.trim_space(strings.trim_suffix(value,"!important"))}}
}
native_css_declarations :: proc(doc:^Native_Document,style:^Native_Style,raw_declarations:string,important_pass:bool=false) {
    for item in native_css_parts(raw_declarations,';') {
        colon:=strings.index_byte(item,':');if colon<0 {continue}
        raw_name:=strings.trim_space(item[:colon]);name:=raw_name;value:=strings.trim_space(item[colon+1:]);important:=strings.has_suffix(value,"!important");if important!=important_pass {continue};value=strings.trim_space(strings.trim_suffix(value,"!important"))
        if strings.has_prefix(name,"--") {style.custom_properties[name]=value;doc.variables[name]=value;continue}
        name=strings.to_lower(name,context.temp_allocator)
        value=native_css_variable(doc,value,properties=style.custom_properties)
        switch name {
        case "display":switch value {case "none":style.display=.None;case "block","list-item","flow-root":style.display=.Block;case "flex","inline-flex":style.display=.Flex;case "grid","inline-grid":style.display=.Grid;case "table","inline-table":style.display=.Table;case "table-row":style.display=.Row;case "table-cell":style.display=.Cell;case "inline":style.display=.Inline;case "inline-block":style.display=.Inline_Block}
        case "position":switch value {case "static":style.position=.Static;case "relative":style.position=.Relative;case "absolute":style.position=.Absolute;case "fixed":style.position=.Fixed;case "sticky":style.position=.Sticky}
        case "top":style.inset[0]=value
        case "right":style.inset[1]=value
        case "bottom":style.inset[2]=value
        case "left":style.inset[3]=value
        case "inset":style.inset=native_css_edge_rules(value)
        case "box-sizing":style.border_box=value=="border-box"
        case "z-index":n,ok:=strconv.parse_int(value);if ok {style.z_index=n}
        case "visibility":style.hidden=value=="hidden"||value=="collapse"
        case "overflow":style.clip_x=value=="hidden"||value=="clip"||value=="auto"||value=="scroll";style.clip_y=style.clip_x
        case "overflow-x":style.clip_x=value=="hidden"||value=="clip"||value=="auto"||value=="scroll"
        case "overflow-y":style.clip_y=value=="hidden"||value=="clip"||value=="auto"||value=="scroll"
        case "color":style.color=native_css_color(doc,value,style.color)
        case "background","background-color":style.background=native_css_color(doc,value,style.background)
        case "font-size":style.size=max(1,native_css_resolve(value,style.parent_size,style.parent_size,doc.width,doc.height,style.size))
        case "font-family":style.mono=strings.contains(value,"mono")||strings.contains(strings.to_lower(value,context.temp_allocator),"courier")
        case "font-weight":n,ok:=strconv.parse_int(value);style.bold=value=="bold"||value=="bolder"||ok&&n>=600
        case "font-style":style.italic=value=="italic"||value=="oblique"
        case "font":parts:=native_css_parts(value);for part in parts {if strings.contains(part,"px")||strings.contains(part,"em") {size:=native_css_parts(part,'/');style.size=max(1,native_css_length(size[0],style.parent_size,style.size));if len(size)>1 {if number,ok:=strconv.parse_f32(size[1]);ok {style.line_height=number} else {style.line_height=native_css_length(size[1],style.size,style.size*1.5)/style.size}}} else if part=="italic" {style.italic=true} else if part=="bold" {style.bold=true} else if strings.contains(part,"mono") {style.mono=true}}
        case "line-height":number,ok:=strconv.parse_f32(value);if ok {style.line_height=number} else {style.line_height=native_css_length(value,style.size,style.size*1.5)/style.size}
        case "white-space":style.pre=value=="pre"||value=="pre-wrap"||value=="break-spaces";style.pre_wrap=value=="pre-wrap"||value=="break-spaces";style.nowrap=value=="nowrap"||value=="pre"
        case "text-decoration","text-decoration-line":style.underline=strings.contains(value,"underline")
        case "text-align":style.align=0;if value=="center" {style.align=1} else if value=="right"||value=="end" {style.align=2} else if value=="justify" {style.align=3}
        case "width":style.width_rule=value;style.width=native_css_length(value,style.size,-1);if strings.has_suffix(value,"%") {n,ok:=strconv.parse_f32(value[:len(value)-1]);if ok {style.width_percent=n/100}} else {style.width_percent=0}
        case "height":style.height_rule=value;style.height=native_css_length(value,style.size,-1)
        case "min-width":style.min_width_rule=value
        case "max-width":style.max_width_rule=value;style.max_width=native_css_length(value,style.size,-1)
        case "min-height":style.min_height_rule=value
        case "max-height":style.max_height_rule=value
        case "margin":style.margin=native_css_edges(value,style.size);style.margin_rule=native_css_edge_rules(value)
        case "padding":style.padding=native_css_edges(value,style.size);style.padding_rule=native_css_edge_rules(value)
        case "margin-top","margin-right","margin-bottom","margin-left":side:=0;if name=="margin-right" {side=1} else if name=="margin-bottom" {side=2} else if name=="margin-left" {side=3};style.margin[side]=native_css_length(value,style.size);style.margin_rule[side]=value
        case "padding-top","padding-right","padding-bottom","padding-left":side:=0;if name=="padding-right" {side=1} else if name=="padding-bottom" {side=2} else if name=="padding-left" {side=3};style.padding[side]=native_css_length(value,style.size);style.padding_rule[side]=value
        case "border","border-bottom","border-top","border-left","border-right":
            width:=f32(1);color:=style.border;for part in native_css_parts(value) {n:=native_css_length(part,style.size,-1);if n>=0 {width=n};if part=="none"||part=="hidden" {width=0};color=native_css_color(doc,part,color)}
            style.border=color;if name=="border" {style.border_width=width;style.border_edges={width,width,width,width}} else {side:=0;if name=="border-right" {side=1} else if name=="border-bottom" {side=2} else if name=="border-left" {side=3};style.border_edges[side]=width}
        case "border-width":style.border_edges=native_css_edges(value,style.size);style.border_width=style.border_edges[0]
        case "border-color":style.border=native_css_color(doc,value,style.border)
        case "opacity":n,ok:=strconv.parse_f32(value);if ok {style.color[3]*=clamp(n,0,1);style.background[3]*=clamp(n,0,1)}
        case "gap":parts:=native_css_parts(value);if len(parts)>0 {style.gap[0]=parts[0];style.gap[1]=parts[0]};if len(parts)>1 {style.gap[1]=parts[1]}
        case "row-gap":style.gap[0]=value
        case "column-gap":style.gap[1]=value
        case "flex-direction":switch value {case "row":style.flex_direction=0;case "column":style.flex_direction=1;case "row-reverse":style.flex_direction=2;case "column-reverse":style.flex_direction=3}
        case "flex-wrap":style.flex_wrap=0;if value=="wrap" {style.flex_wrap=1} else if value=="wrap-reverse" {style.flex_wrap=2}
        case "flex-flow":for part in native_css_parts(value) {switch part {case "row":style.flex_direction=0;case "column":style.flex_direction=1;case "row-reverse":style.flex_direction=2;case "column-reverse":style.flex_direction=3;case "wrap":style.flex_wrap=1;case "wrap-reverse":style.flex_wrap=2;case "nowrap":style.flex_wrap=0}}
        case "flex-grow":n,ok:=strconv.parse_f32(value);if ok {style.flex_grow=max(0,n)}
        case "flex-shrink":n,ok:=strconv.parse_f32(value);if ok {style.flex_shrink=max(0,n)}
        case "flex-basis":style.flex_basis=value
        case "flex":
            if value=="none" {style.flex_grow=0;style.flex_shrink=0;style.flex_basis="auto"} else if value=="auto" {style.flex_grow=1;style.flex_shrink=1;style.flex_basis="auto"} else {style.flex_grow=1;style.flex_shrink=1;style.flex_basis="0px";numeric:=0;for part in native_css_parts(value) {n,ok:=strconv.parse_f32(part);if ok&&numeric<2 {if numeric==0 {style.flex_grow=max(0,n)} else {style.flex_shrink=max(0,n)};numeric+=1} else {style.flex_basis=part}}}
        case "justify-content":style.justify=native_css_alignment(value)
        case "align-items":style.align_items=native_css_alignment(value,.Stretch)
        case "align-content":style.align_content=native_css_alignment(value,.Stretch)
        case "align-self":style.align_self=native_css_alignment(value,.Stretch);style.self_explicit=value!="auto"
        case "justify-items":style.justify_items=native_css_alignment(value,.Stretch)
        case "justify-self":style.justify_self=native_css_alignment(value,.Stretch);style.justify_self_explicit=value!="auto"
        case "place-items":parts:=native_css_parts(value);if len(parts)>0 {style.align_items=native_css_alignment(parts[0],.Stretch);style.justify_items=style.align_items};if len(parts)>1 {style.justify_items=native_css_alignment(parts[1],.Stretch)}
        case "order":n,ok:=strconv.parse_int(value);if ok {style.order=n}
        case "grid-template-columns":style.grid_columns=value
        case "grid-template-rows":style.grid_rows=value
        case "grid-auto-columns":style.grid_auto_columns=value
        case "grid-auto-rows":style.grid_auto_rows=value
        case "grid-auto-flow":style.grid_column_flow=strings.contains(value,"column")
        case "grid-column":style.grid_column,style.grid_column_span=native_css_grid_line(value)
        case "grid-row":style.grid_row,style.grid_row_span=native_css_grid_line(value)
        case "grid-column-start":n,ok:=strconv.parse_int(value);if ok {style.grid_column=n}
        case "grid-row-start":n,ok:=strconv.parse_int(value);if ok {style.grid_row=n}
        case "grid-column-end":_,span:=native_css_grid_line(value);style.grid_column_span=span;if n,ok:=strconv.parse_int(value);ok&&n>style.grid_column&&style.grid_column>0 {style.grid_column_span=n-style.grid_column}
        case "grid-row-end":_,span:=native_css_grid_line(value);style.grid_row_span=span;if n,ok:=strconv.parse_int(value);ok&&n>style.grid_row&&style.grid_row>0 {style.grid_row_span=n-style.grid_row}
        }
    }
}
native_style_default :: proc(doc:^Native_Document,node:int,markdown,dark:bool)->Native_Style {
    n:=doc.nodes[node]
    style:=Native_Style{color={0.08,0.08,0.08,1},size=16,parent_size=16,line_height=1.5,width=-1,height=-1,max_width=-1,flex_shrink=1,align_items=.Stretch,align_content=.Stretch,justify_items=.Stretch,justify_self=.Stretch,grid_column_span=1,grid_row_span=1,border_edges={-1,-1,-1,-1},border={0.3,0.3,0.3,1}}
    style.custom_properties=n.style.custom_properties
    if style.custom_properties==nil {style.custom_properties=make(map[string]string,vmem.arena_allocator(&doc.arena))} else {clear(&style.custom_properties)}
    if markdown||dark {style.color=TEXT;style.border=LINE}
    if n.parent>=0 {
        inherited:=doc.nodes[n.parent].style
        for key,value in inherited.custom_properties {style.custom_properties[key]=value}
        style.color=inherited.color;style.size=inherited.size;style.parent_size=inherited.size;style.line_height=inherited.line_height
        style.bold=inherited.bold;style.italic=inherited.italic;style.mono=inherited.mono;style.pre=inherited.pre;style.underline=inherited.underline
        style.align=inherited.align;style.nowrap=inherited.nowrap;style.pre_wrap=inherited.pre_wrap
    }
    switch n.tag {
    case "#document","html","body","main","div","section","article","header","footer","nav","aside","figure","figcaption","form","fieldset","p","ul","ol","li","blockquote","dl","dt","dd","details","summary":style.display=.Block
    case "#comment","head","title","meta","link","style","script","source","template":style.display=.None
    case "h1","h2","h3","h4","h5","h6":
        style.display=.Block;style.bold=true;style.line_height=1.25
        sizes:=[6]f32{32,26,22,20,18,16};style.size=sizes[int(n.tag[1]-'1')];style.margin={16,0,10,0}
    case "table":style.display=.Table;style.margin={10,0,10,0}
    case "thead","tbody","tfoot":style.display=.Block
    case "tr":style.display=.Row
    case "td","th":style.display=.Cell;style.padding={6,10,6,10};style.border_width=1;if n.tag=="th" {style.bold=true}
    case "br":style.display=.Block
    case "hr":style.display=.Block;style.height=1;style.margin={16,0,16,0};style.background=style.border
    case "b","strong":style.bold=true
    case "i","em":style.italic=true
    case "code","kbd","samp","pre":style.mono=true;style.size=14;style.background=LINE;if n.tag=="pre" {style.display=.Block;style.pre=true;style.padding={12,14,12,14};style.margin={10,0,10,0}}
    case "a":style.color={0.25,0.53,0.9,1};style.underline=true
    case "mark":style.background={0.7,0.55,0.1,1}
    case "input","textarea","select","button","video","audio":style.background={0.16,0.16,0.16,1};style.color=TEXT;style.padding={5,8,5,8};style.border_width=1
    }
    if n.tag=="body"&&!markdown {style.margin={8,8,8,8}}
    if n.tag=="p"||n.tag=="ul"||n.tag=="ol"||n.tag=="blockquote" {style.margin={8,0,8,0}}
    if n.tag=="ul"||n.tag=="ol"||n.tag=="blockquote"||n.tag=="dd" {style.padding[3]=24}
    if n.hidden {style.display=.None}
    if native_has_attr(doc,node,"hidden") {style.display=.None}
    for important in ([2]bool{false,true}) {
        for rule in doc.rules {if rule.dark_only&&!dark||rule.light_only&&dark||doc.width<rule.min_width||rule.max_width>0&&doc.width>rule.max_width {continue};if native_css_matches(doc,node,rule.selector) {native_css_custom_declarations(&style,rule.declarations,important)}}
        native_css_custom_declarations(&style,native_attr(doc,node,"style"),important)
    }
    for important in ([2]bool{false,true}) {
        for rule in doc.rules {if rule.dark_only&&!dark||rule.light_only&&dark||doc.width<rule.min_width||rule.max_width>0&&doc.width>rule.max_width {continue};if native_css_matches(doc,node,rule.selector) {native_css_declarations(doc,&style,rule.declarations,important)}}
        native_css_declarations(doc,&style,native_attr(doc,node,"style"),important)
    }
    if width:=native_attr(doc,node,"width");width!="" {if style.width_rule=="" {style.width=native_css_length(width,style.size,-1)}}
    if height:=native_attr(doc,node,"height");height!="" {if style.height_rule=="" {style.height=native_css_length(height,style.size,-1)}}
    if dark&&!markdown {
        luminance:=style.color[0]*0.2126+style.color[1]*0.7152+style.color[2]*0.0722
        if luminance<0.45 {for i in 0..<3 {style.color[i]=max(style.color[i],0.76)}}
        luminance=style.background[0]*0.2126+style.background[1]*0.7152+style.background[2]*0.0722
        if style.background[3]>0&&luminance>0.5 {for i in 0..<3 {style.background[i]=0.10+(1-style.background[i])*0.15}}
    }
    return style
}

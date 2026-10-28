package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"

// Readline supplies the actual edited command, independent of prompt layout,
// wrapping, Unicode, shell history, or terminal applications' keyboard input.
// Decode only a single literal word; never eval a command or its substitutions.
SHELL_RESTORE_DIRECTORY :: `
if [[ -n ${MINOR_TERMINAL_RESTORE_DIR-} ]]; then
    builtin cd -- "$MINOR_TERMINAL_RESTORE_DIR" || printf 'Could not restore terminal directory: %s\n' "$MINOR_TERMINAL_RESTORE_DIR" >&2
fi
unset MINOR_TERMINAL_RESTORE_DIR
`
SHELL_DOCUMENT_INTEGRATION :: SHELL_RESTORE_DIRECTORY + `
__minor_emit_metadata() {
    if [[ -n ${TMUX-} ]]; then
        printf '\033Ptmux;\033\033]777;%s;%s\007\033\\' "$1" "$2"
    else
        printf '\033]777;%s;%s\007' "$1" "$2"
    fi
}
__minor_report_directory() {
    local status=$?
    if [[ ${__minor_last_directory-} == "$PWD" ]]; then return "$status"; fi
    __minor_last_directory=$PWD
    local LC_ALL=C hex= byte i
    for ((i=0; i<${#PWD}; i++)); do
        printf -v byte '%02x' "'${PWD:i:1}"
        hex+=$byte
    done
    __minor_emit_metadata minor-cwd "$hex"
    return "$status"
}
PROMPT_COMMAND+=(__minor_report_directory)
__minor_literal_path() {
    local line=$1 partial=${2-} path= quote= ch ended=0 started=0 expand_home=0 i
    for ((i=0; i<${#line}; i++)); do
        ch=${line:i:1}
        if [[ $quote == single ]]; then
            if [[ $ch == "'" ]]; then quote=; else path+=$ch; fi
        elif [[ $quote == double ]]; then
            case $ch in
                '"') quote= ;;
                '$'|$'\x60') return 1 ;;
                \\)
                    ((i++)); ((i<${#line})) || return 1
                    ch=${line:i:1}
                    case $ch in '$'|$'\x60'|'"'|\\) ;; *) path+='\' ;; esac
                    path+=$ch ;;
                *) path+=$ch ;;
            esac
        else
            case $ch in
                ' '|$'\t') ((started)) && ended=1; continue ;;
            esac
            ((ended)) && return 1
            case $ch in
                "'") quote=single ;;
                '"') quote=double ;;
                \\)
                    ((i++)); ((i<${#line})) || return 1
                    path+=${line:i:1} ;;
                '$'|$'\x60'|'*'|'?'|'['|']'|'{'|'}'|'('|')'|';'|'&'|'|'|'<'|'>'|'!'|$'\n'|$'\r') return 1 ;;
                '~') ((started)) || expand_home=1; path+=$ch ;;
                *) path+=$ch ;;
            esac
            started=1
        fi
    done
    [[ -z $quote || $partial == partial ]] || return 1
    [[ -n $path || $partial == partial ]] || return 1
    if ((expand_home)); then
        case $path in '~') path=$HOME ;; '~/'*) path=$HOME/${path:2} ;; *) return 1 ;; esac
    fi
    __minor_path=$path
}
__minor_complete_initial() {
    local __minor_path candidate cur=${COMP_WORDS[COMP_CWORD]}
    COMPREPLY=()
    __minor_literal_path "$cur" partial || return
    cur=$__minor_path
    compopt -o filenames
    while IFS= read -r candidate; do
        if [[ -d $candidate || -x $candidate ]]; then
            COMPREPLY+=("$candidate")
        elif [[ -f $candidate && -r $candidate ]]; then
            case ${candidate,,} in
                *.html|*.htm|*.xhtml|*.md|*.markdown|*.mdown|*.mkd|*.mkdn|*.mdwn) COMPREPLY+=("$candidate") ;;
            esac
        fi
    done < <(compgen -f -- "$cur")
    if [[ $cur != */* ]]; then
        while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -c -- "$cur")
    fi
}
complete -I -F __minor_complete_initial -o bashdefault -o default
__minor_document_enter() {
    local __minor_path
    __minor_literal_path "$READLINE_LINE" || return
    local path=$__minor_path
    case ${path,,} in *.html|*.htm|*.xhtml|*.md|*.markdown|*.mdown|*.mkd|*.mkdn|*.mdwn) ;; *) return ;; esac
    [[ -f $path && -r $path ]] || return
    [[ $path == /* ]] || path=$PWD/$path
    local LC_ALL=C hex= byte
    ((${#path}<=4096)) || return
    for ((i=0; i<${#path}; i++)); do
        printf -v byte '%02x' "'${path:i:1}"
        hex+=$byte
    done
    builtin history -s -- "$READLINE_LINE"
    READLINE_LINE= READLINE_POINT=0
    __minor_emit_metadata minor-open "$hex"
}
for __minor_keymap in emacs-standard vi-insert; do
    bind -m "$__minor_keymap" -x '"\C-x\C-o":__minor_document_enter'
    bind -m "$__minor_keymap" '"\C-x\C-j":accept-line'
    bind -m "$__minor_keymap" '"\C-m":"\C-x\C-o\C-x\C-j"'
    bind -m "$__minor_keymap" '"\C-j":"\C-x\C-o\C-x\C-j"'
done
unset __minor_keymap
`

shell_integration_path :: proc()->string {
    if !explorer_backend_init() {return ""}
    path:=fmt.tprintf("%s/bashrc",file_runtime_directory)
    if _,error:=os.stat(path,context.temp_allocator);error==nil {return path}
    script:=fmt.tprintf("if [[ -r ~/.bashrc ]]; then source ~/.bashrc; fi\n%s",SHELL_DOCUMENT_INTEGRATION)
    if os.write_entire_file(path,script,{.Read_User,.Write_User})!=nil {return ""}
    return path
}

shell_remote_command :: proc(directory:string="")->string {
    // The remote rc removes itself immediately. User startup files remain owned
    // by the user; each SSH shell receives the same per-session integration.
    // Compose shell text literally: Odin's formatter also interprets braces,
    // which must retain their Bash parameter-expansion meaning here.
    script:=strings.concatenate([]string{`command rm -f -- "${BASH_SOURCE[0]}"
if [[ -r /etc/profile ]]; then source /etc/profile; fi
if [[ -r ~/.bash_profile ]]; then source ~/.bash_profile
elif [[ -r ~/.bash_login ]]; then source ~/.bash_login
elif [[ -r ~/.profile ]]; then source ~/.profile
elif [[ -r ~/.bashrc ]]; then source ~/.bashrc; fi
MINOR_TERMINAL_RESTORE_DIR=`,explorer_quote(directory),"\n",SHELL_DOCUMENT_INTEGRATION},context.temp_allocator)
    encoded:=base64.encode(transmute([]u8)script,allocator=context.temp_allocator)
    return strings.concatenate([]string{`if [ "${SHELL##*/}" = bash ]; then
minor_rc=$(mktemp "${TMPDIR:-/tmp}/minor-shell-XXXXXXXX") || exit 1
if printf '%s' '`,encoded,`' | base64 -d > "$minor_rc"; then
    bash --rcfile "$minor_rc" -i
    minor_status=$?
else minor_status=1; fi
rm -f -- "$minor_rc"
exit "$minor_status"
else exec "${SHELL:-/bin/sh}" -l; fi`},context.temp_allocator)
}

terminal_shell_metadata :: proc(t:^Terminal,value:[]u8) {
    prefix:="minor-open;"
    directory:=strings.has_prefix(string(value),"minor-cwd;")
    if directory {prefix="minor-cwd;"}
    if !strings.has_prefix(string(value),prefix) {return}
    hex:=value[len(prefix):]
    if len(hex)==0||len(hex)>8192||len(hex)%2!=0 {return}
    path:=make([]u8,len(hex)/2)
    digit :: proc(b:u8)->int {
        if b>='0'&&b<='9' {return int(b-'0')}
        if b>='a'&&b<='f' {return int(b-'a')+10}
        if b>='A'&&b<='F' {return int(b-'A')+10}
        return -1
    }
    for &byte,i in path {
        high,low:=digit(hex[i*2]),digit(hex[i*2+1])
        if high<0||low<0 {delete(path);return}
        byte=u8(high*16+low)
        if byte==0 {delete(path);return}
    }
    if directory {terminal_directory(t,string(path));delete(path);return}
    if path[0]!='/'||document_kind(string(path))==.None||len(t.document_requests)>=MAX_TABS {delete(path);return}
    append(&t.document_requests,string(path))
}

terminal_directory :: proc(t:^Terminal,path:string) {
    if len(path)==0||path[0]!='/'||len(path)>=len(t.cwd)||strings.contains(path,"\x00") {return}
    if path==string(t.cwd[:t.cwd_len]) {return}
    t.cwd_len=copy(t.cwd[:],transmute([]u8)path);t.cwd[t.cwd_len]=0;t.cwd_changed=true
}

terminal_directory_uri :: proc(t:^Terminal,value:string) {
    path:=value
    if strings.has_prefix(path,"file://") {
        slash:=strings.index(path[7:],"/")
        if slash<0 {return}
        decoded,valid:=document_url_decode(path[7+slash:])
        if !valid {return}
        defer delete(decoded)
        terminal_directory(t,decoded)
    } else {terminal_directory(t,path)}
}

app_terminal_directory :: proc(a:^App,tab:^Tab) {
    t:=&tab.terminal
    if !t.cwd_changed {return}
    t.cwd_changed=false
    path:=string(t.cwd[:t.cwd_len])
    if path==tab.restore_path {return}
    delete(tab.restore_path);tab.restore_path=strings.clone(path)
    if a.session_save_allowed {session_touch(a)}
}

app_shell_documents :: proc(a:^App) {
    for source in a.tabs {
        for path in source.terminal.document_requests {
            document_open_tab(a,source,path)
            delete(path)
        }
        clear(&source.terminal.document_requests)
    }
}

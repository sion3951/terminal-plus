#!/usr/bin/env python3
"""Focused native-shell comparisons with the host Bash; no desktop required."""
import argparse
import concurrent.futures
import os
from pathlib import Path
import runpy
import signal
import subprocess
import tempfile


CASES = {
    "quotes": r'''printf '<%s>\n' 'a b' "" a\ b 'a"b' ''',
    "if-elif": r'''if false; then echo bad; elif [ 3 -gt 2 ]; then echo yes; else echo bad; fi''',
    "while": r'''i=0; while ((i<4)); do printf '%s ' "$i"; ((i++)); done; echo''',
    "until-break": r'''i=0; until ((i==9)); do ((i++)); if ((i==3)); then break; fi; done; echo "$i"''',
    "for-words": r'''for x in one 'two words' three; do printf '<%s>\n' "$x"; done''',
    "for-arithmetic": r'''for ((i=0;i<5;i++)); do if ((i==2)); then continue; fi; printf '%s' "$i"; done; echo''',
    "nested-break": r'''for a in 1 2; do for b in 3 4; do echo "$a:$b"; break 2; done; done''',
    "case": r'''x=abc; case "$x" in a*) echo first ;;& *c) echo second ;; *) echo bad ;; esac''',
    "case-fallthrough": r'''case x in x) echo one ;& y) echo two ;; esac''',
    "function-locals": r'''x=outer; f() { local x=inner; printf '%s:%s:%s\n' "$x" "$#" "$1"; return 7; }; f 'two words'; echo "$?:$x"''',
    "function-keyword": r'''function f { echo "$1"; }; f value''',
    "function-recursion": r'''f() { local n=$1; if ((n>0)); then printf '%s' "$n"; f "$((n-1))"; fi; }; f 3; echo''',
    "function-pipeline": r'''f() { printf '%s\n' one two; }; f | tr a-z A-Z''',
    "subshell": r'''x=outer; ( x=inner; echo "$x" ); echo "$x"''',
    "group-redirect": r'''{ printf one; printf two; } >group; cat group''',
    "positional": r'''set -- one 'two words' ''; printf '[%s]\n' "$@"; printf '%s:%s\n' "$#" "$2"; shift 2; printf '<%s>\n' "$@"''',
    "positional-concatenation": r'''set -- one 'two words'; printf '<%s>\n' pre"$@"post''',
    "getopts": r'''set -- -a -b value rest; while getopts ':ab:' opt; do printf '%s:%s\n' "$opt" "$OPTARG"; done; shift "$((OPTIND-1))"; echo "$1"''',
    "source-args": r'''set -- outer; source ./fixture.sh inner 'two words'; printf 'after:%s\n' "$1"''',
    "indexed-array": r'''a=(one 'two words' three); a[5]=five; a+=(six); printf '<%s>\n' "${a[@]}"; echo "${#a[@]}:${a[-1]}"''',
    "associative-array": r'''declare -A a=([first]='one two' [second]=three); printf '<%s>\n' "${a[first]}" "${a[second]}"; echo "${#a[@]}"''',
    "integer-attribute": r'''declare -i n=2+3; n+=4; echo "$n"; let 'n*=2'; echo "$n"''',
    "nameref": r'''x=value; declare -n ref=x; ref=changed; echo "$x:$ref"''',
    "readonly": r'''readonly x=one; x=two; echo "$x"''',
    "defaults": r'''unset x; echo "${x:=default}"; echo "$x:${x:+set}:${missing-fallback}"''',
    "substring": r'''x=abcdef; echo "${x:1:3}:${x: -2}:${#x}"''',
    "parameter-patterns": r'''x=a/b/c.txt; echo "${x#*/}:${x##*/}:${x%/*}:${x%%/*}:${x//\//-}"''',
    "parameter-case": r'''x=oneTwo; echo "${x^^}:${x,,}:${x^}:${x,}"''',
    "indirect": r'''name=target; target=value; echo "${!name}"''',
    "ansi-c": r'''printf '<%s>\n' $'one\ntwo' $'\u03bb' $'\x41\101' ''',
    "backticks": r'''printf '<%s>\n' "`printf 'a b'`"''',
    "arithmetic": r'''a=2; echo "$((a++ + 3*4)):$a:$((0 && 1/0)):$((1 ? 7 : 1/0))"; echo "$((16#ff)):$( (true) )"''',
    "brace-expansion": r'''printf '<%s>\n' pre{a,b}{1..3}post {05..01..2} {c..a}''',
    "ifs": r'''IFS=:; x=':a::b:'; printf '<%s>\n' $x; set -- one 'two words'; printf '<%s>\n' "$*"''',
    "nullglob": r'''shopt -s nullglob; a=(missing-*.xyz); echo "${#a[@]}"''',
    "extglob": "shopt -s extglob\ntouch a.txt b.txt c.md\nprintf '%s\\n' @(a|b).txt\n",
    "heredoc": '''x=value; cat <<EOF\nhello "$x" $(printf nested)\nEOF\n''',
    "quoted-heredoc": '''x=value; cat <<'EOF'\nhello "$x" $(printf nested)\nEOF\n''',
    "tab-heredoc": '''cat <<-EOF\n\tone\n\tEOF\n''',
    "here-string": r'''read -r a b <<< 'one two three'; printf '%s:%s\n' "$a" "$b"''',
    "read-pipeline": r'''printf 'one two three\n' | { read a b; printf '%s:%s\n' "$a" "$b"; }''',
    "mapfile": r'''mapfile -t a < <(printf 'one\ntwo\n'); printf '<%s>\n' "${a[@]}"''',
    "process-substitution": r'''cat <(printf one) <(printf two)''',
    "pipefail": r'''set -o pipefail; false | true; printf '%s:%s\n' "$?" "${PIPESTATUS[*]}"''',
    "negation": r'''! false; echo "$?"; ! true; echo "$?"''',
    "errexit": r'''set -e; false; echo bad''',
    "errexit-conditions": r'''set -e; if false; then echo bad; fi; false && echo bad; echo survived''',
    "errexit-function": r'''set -e; f() { false; echo survived; }; if f; then echo yes; fi''',
    "test-pattern": r'''x='one two'; [[ $x == o* && $x != z* ]]; echo "$?"; [[ $x == "o*" ]]; echo "$?"''',
    "test-regex": r'''[[ abc123 =~ ([a-z]+)([0-9]+) ]]; printf '<%s>\n' "${BASH_REMATCH[@]}"''',
    "alias-lines": "shopt -s expand_aliases\nalias hi='printf hello'\nhi\n",
    "trap-exit": r'''trap 'printf "exit:%s\n" "$?"' EXIT; false''',
    "trap-return": r'''trap 'echo returned' RETURN; f() { echo body; }; f''',
    "trap-err": r'''trap 'echo error' ERR; false; echo after''',
    "trap-exit-override": r'''trap 'exit 42' EXIT; exit 7''',
    "compgen": r'''compgen -W 'one two three' -- t''',
    "history-expansion": r'''history -s 'echo old'; history -p '!!' ''',
    "dynamic-descriptor": r'''exec {fd}>descriptor; printf hello >&$fd; exec {fd}>&-; cat descriptor''',
    "read-write-descriptor": r'''printf original >rw; exec 3<>rw; printf new >&3; exec 3>&-; cat rw''',
    "source-stream-input": 'read x\ninput for read\nprintf \'<%s>\\n\' "$x"\n',
    "script-reader-descriptor": "exec 3>descriptor\nprintf after\\n\n",
    "array-self-assignment": r'''a=(one 'two words'); a=("${a[@]}"); printf '<%s>\n' "${a[@]}"''',
    "array-temporary-assignment": r'''a=(one two); a=temporary true; printf '<%s>\n' "${a[@]}"''',
    "array-temporary-index": r'''a=(one two); a[1]=temporary true; printf '<%s>\n' "${a[@]}"''',
    "associative-order": r'''declare -A a=([first]=one [second]=two [third]=three [a]=four [z]=five); printf '<%s>\n' "${!a[@]}" "${a[@]}"''',
    "arithmetic-no-reparse": r'''value='$(printf INJECTED >&2)'; printf '%s\n' "$(( $value ))"''',
    "lastpipe": r'''shopt -s lastpipe; printf 'foo\n' | read x; printf '<%s>:%s\n' "$x" "${PIPESTATUS[*]}"''',
    "lastpipe-function": r'''shopt -s lastpipe; f() { read x; saved=$x; }; printf 'foo\n' | f; echo "$saved"''',
    "lastpipe-subshell": r'''shopt -s lastpipe; printf 'foo\n' | ( read x ); echo "${x-unset}"''',
    "background-conditional": r'''true && printf done & wait; printf '\n' ''',
    "coprocess": r'''coproc C { read -r line; printf 'coproc:%s\n' "$line"; }; printf 'hello\n' >&"${C[1]}"; read -r answer <&"${C[0]}"; echo "$answer"; wait''',
    "eval-alias-lines": "eval $'shopt -s expand_aliases\\nalias hi=\"printf hello\"\\nhi'",
    "subshell-exit-trap": r'''trap 'echo outer' EXIT; ( trap 'echo inner' EXIT; : ); printf body\n''',
    "error-trap-function": r'''trap 'echo ERR' ERR; f() { false; echo body; }; f; set -E; f''',
    "return-trap-local": r'''f() { local x=inner; trap 'echo "return:$x"' RETURN; echo body; }; f''',
    "printf-variable": r'''printf -v result '%04d:%s' 7 'two words'; echo "$result"''',
    "printf-numbers": r'''printf '%+08d|%#x|%#o|%*.*f|%.5g|%e|%a\n' 42 255 9 8 3 1.25 123.456 .25 3''',
    "printf-quote": r'''printf '<%q>\n' '' 'one two' $'a\nb' 'a;$(no)' ''',
    "printf-character-number": r'''printf '%d:%d:%d\n' "'A" 077 0xff''',
    "line-numbers": 'echo "$LINENO"\nf() {\n echo "$LINENO"\n}\nf\necho "$LINENO"\n',
    "array-index-side-effects": r'''i=0; a=(one two); a[i++]=x; printf '%s:%s\n' "$i" "${a[*]}"''',
    "random-seed": r'''RANDOM=42; a=$RANDOM; RANDOM=42; b=$RANDOM; [[ $a == "$b" ]]; echo "$?"''',
    "seconds-assignment": r'''SECONDS=12; [[ $SECONDS -ge 12 ]]; echo "$?"''',
    "nounset": r'''set -u; echo "$unset_variable_for_check"; echo BAD''',
    "high-descriptor": r'''exec 4096>descriptor; printf high >&4096; exec 4096>&-; cat descriptor''',
    "large-capture": r'''x=$(head -c 20000000 /dev/zero | tr '\0' x); echo "${#x}"''',
    "printf-large-width": r'''printf '%20000000s' x''',
    "printf-large-precision": r'''printf '%.20000f' 1.25''',
    "random-exact-sequence": r'''for seed in 42 0 -42 36586 43073 4294967296; do RANDOM=$seed; printf '%s:%s:%s:%s\n' "$seed" "$RANDOM" "$RANDOM" "$RANDOM"; done''',
    "fc-substitute": r'''history -s 'printf old'; fc -s old=new''',
    "builtin-inventory": r'''for name in caller fc suspend; do type "$name" >/dev/null; printf '%s:%s\n' "$name" "$?"; done''',
    "type-flags": r'''f() { :; }; for name in printf f for missing_name_for_check; do type -t "$name"; done; type -P printf''',
    "type-path-builtin": r'''type -p printf; printf 'status:%s\n' "$?"''',
    "command-flags": r'''command -V printf; command -p printf '<%s>\n' value; command -v printf''',
    "alias-type": "alias hi='echo hello'\ntype -t hi\ncommand -v hi\n",
    "wait-next": r'''sleep .01 & wait -n -p completed; test -n "$completed"; echo "$?"''',
    "printf-long-double": r'''printf '%.20f:%a\n' 0.1 0.1; printf '%#g\n' 999999.9999''',
    "logical-directories": r'''start=$PWD; mkdir -p real/sub; ln -s real/sub link; cd link; [[ $PWD == "$start/link" ]]; echo "$?"; actual=$(pwd -P); [[ $actual == "$start/real/sub" ]]; echo "$?"; cd ..; [[ $PWD == "$start" ]]; echo "$?"; cd -P link; [[ $PWD == "$start/real/sub" ]]; echo "$?"; cd -L "$start/link/.."; [[ $PWD == "$start" ]]; echo "$?"''',
    "cdpath": r'''start=$PWD; mkdir -p catalog/target; CDPATH=$PWD/catalog; cd target >"$start/cdout"; [[ $PWD == "$start/catalog/target" ]]; echo "$?"; test -s "$start/cdout"; echo "$?"''',
    "source-path": r'''mkdir scripts; printf 'VALUE=from-path\n' >scripts/envfile; PATH=$PWD/scripts:$PATH; . envfile; echo "$VALUE"''',
    "startup-defaults": r'''printf '%s:%s:%s:%s:%s\n' "$OSTYPE" "$HOSTTYPE" "$MACHTYPE" "$OPTIND" "$OPTERR"''',
    "fc-edit-single-entry": r'''history -s 'printf old'; FCEDIT='sed -i s/old/new/'; fc''',
    "fc-editor": r'''history -s 'printf old'; history -s 'printf unused'; FCEDIT='sed -i s/old/new/'; fc''',
    "read-exact-newline": r'''read -r -N 3 value <<< $'a\nb'; printf '<%s>\n' "$value"''',
    "read-exact-ifs": r'''IFS=: read -r -N 5 value <<< 'a:b:c'; printf '<%s>\n' "$value"''',
    "read-character-count": r'''read -r -n 2 value <<< 'éλ字'; printf '<%s>\n' "$value"''',
    "read-escaped-ifs": r'''IFS=: read a b c <<< 'one\:two:three:four'; printf '<%s>\n' "$a" "$b" "$c"''',
    "read-zero-count": r'''exec 3<<< hello; read -n 0 value <&3; read -r rest <&3; printf '%s:%s\n' "$value" "$rest"''',
    "read-timeout-probe": r'''exec 3<<< hello; read -t 0 value <&3; echo "$?"; read -r rest <&3; echo "$rest"''',
    "mapfile-callback": r'''callback() { printf '%s:<%s>\n' "$1" "$2"; }; mapfile -tc 1 -C callback rows < <(printf 'one\ntwo\n'); printf '<%s>\n' "${rows[@]}"''',
    "mapfile-offset-zero": r'''rows=(old tail last); mapfile -t -O 0 rows <<< new; printf '<%s>\n' "${rows[@]}"''',
    "local-declared-unset": r'''x=outer; f() { local x; declare -p x; echo "${x-unset}"; x=inner; local x; echo "$x"; }; f; echo "$x"''',
    "local-readonly-shadow": r'''readonly x=outer; f() { local x=inner; echo "status:$? value:$x"; }; f; echo "$x"''',
    "local-inherit": r'''x=outer; declare -i y=4; f() { local -I x y; declare -p x y; }; f; shopt -s localvar_inherit; g() { local x y; declare -p x y; }; g''',
    "local-set-options": r'''f() { local -; set -f; set -o pipefail; }; f; [[ $- == *f* ]]; echo $?; set -o | grep pipefail''',
    "local-global-binding": r'''x=outer; f() { local x=inner; declare -g x=changed; echo "$x"; }; f; echo "$x"''',
    "local-unset-caller": r'''x=outer; f() { local x=inner; g; echo "${x-unset}"; }; g() { unset x; echo "${x-unset}"; }; f; shopt -s localvar_unset; f; echo "$x"''',
    "declare-trace": r'''declare -t value=hello; declare -p value; echo "${value@a}"''',
    "declare-unset": r'''declare empty; declare -p empty; unset empty; declare -p empty; echo $?''',
    "nameref-indexed-element": r'''a=(one two); declare -n ref=a; echo "${ref[1]}"; ref[1]=new; echo "${a[*]}"''',
    "nameref-unset-target": r'''x=one; declare -n ref=x; unset ref; echo "${x-unset}:${ref-unset}"; declare -p ref''',
    "nameref-unset-reference": r'''x=one; declare -n ref=x; unset -n ref; echo "$x:${ref-unset}"''',
    "readonly-function": r'''f() { :; }; readonly -f f; unset -f f; echo $?; f() { echo BAD; }; f''',
    "current-environment-capture": r'''x=outer; y=${ local x=inner; printf '%s\n\n' "$x"; }; printf '<%s>:%s\n' "$y" "$x"''',
    "current-environment-reply": r'''REPLY=old; y=${| REPLY=$'hi\n'; }; printf '<%s>:<%s>\n' "$y" "$REPLY"''',
    "sparse-array-slice": r'''a=([4]=four [9]=nine [12]=twelve); printf '<%s>\n' "${a[@]:5:2}" "${a[@]: -4}"''',
    "substring-ternary": r'''x=abcdef; printf '<%s>\n' "${x:1?2:3}" "${x:0?2:3:2}"''',
    "posix-regex-longest": r'''[[ aa =~ (a|aa)(z)? ]]; printf '<%s>\n' "${BASH_REMATCH[@]}"''',
    "parameter-declaration-quotes": r'''x=$'one\ntwo'; printf '<%s>\n' "${x@Q}" "${x@A}"; unset x; printf '<%s>\n' "${x@Q}" "${x@A}"''',
    "legacy-arithmetic": r'''x=2; echo "$[x+3*4]"; [[ $[x+1] == 3 ]]; echo $?''',
    "byte-locale-expansion": r'''LC_ALL=C; x='λßa'; printf '<%s>\n' "${#x}" "${x:1:2}" "${x^^}" $'\u03bb' ''',
    "multibyte-locale-expansion": r'''LC_ALL=C.UTF-8; x='λßa'; printf '<%s>\n' "${#x}" "${x:1:2}" "${x^^}" $'\u03bb' ''',
    "printf-wide-strings": r'''printf '<%ls>|<%.2ls>|<%5lc>|<%S>\n' 'éλ字' 'éλ字' λ éλ''',
    "printf-attached-variable": r'''printf -vresult %s value; echo "$result"''',
    "command-hash": r'''hash -p /bin/echo custom; hash -t custom; custom hello; hash -d custom; hash -t custom; echo $?''',
    "keyword-assignment": r'''set -k; printf '<%s>\n' before VAR=value after; echo "${VAR-unset}"''',
    "exec-custom-name": r'''exec -a custom /bin/sh -c 'printf "%s\n" "$0"' ''',
    "command-not-found-handler": r'''command_not_found_handle() { printf 'missing:%s\n' "$1"; return 42; }; missing_command_for_check''',
    "substitution-errexit-default": r'''set -e; x=$(false; echo survived); echo "$x"''',
    "substitution-errexit-inherit": r'''set -e; shopt -s inherit_errexit; x=$(false; echo BAD); echo BAD''',
    "directory-stack-rotation": r'''mkdir a b c; pushd a >/dev/null; pushd ../b >/dev/null; pushd ../c >/dev/null; pushd +2 >/dev/null; printf '%s\n' "${DIRSTACK[0]##*/}" "${DIRSTACK[2]##*/}" "${DIRSTACK[3]##*/}"; popd -1 >/dev/null; printf '%s\n' "${DIRSTACK[2]##*/}"''',
    "directory-stack-assignment": r'''pushd -n a >/dev/null; pushd -n b >/dev/null; DIRSTACK[1]=changed; printf '<%s>\n' "${DIRSTACK[@]:1}"; unset DIRSTACK; DIRSTACK=(plain); printf '<%s>\n' "${DIRSTACK[@]}"''',
    "resource-limit-inventory": r'''for arg in -l -m -u -i -q -e -r -R -p; do ulimit "$arg"; done''',
    "signal-inventory": r'''kill -l 4 31 34 64 128 HUP RTMIN+15 SIGRTMAX-2''',
    "signal-trap-query": r'''trap ':' XCPU RTMIN KILL STOP; trap -p XCPU RTMIN KILL STOP''',
    "enable-inventory-flags": r'''enable -n printf; enable -np; enable printf; type -t printf''',
    "special-alias-array": r'''BASH_ALIASES[hello]='printf hello'; alias hello; unset 'BASH_ALIASES[hello]'; alias hello''',
    "special-hash-array": r'''BASH_CMDS[custom]=/bin/echo; hash -t custom; custom hello''',
    "special-argv0": r'''BASH_ARGV0=changed; echo "$0:$BASH_ARGV0"; unset BASH_ARGV0; echo "$0:${BASH_ARGV0-unset}"''',
    "compatibility-random": r'''BASH_COMPAT=50; RANDOM=42; echo "$RANDOM:$RANDOM:$RANDOM"; BASH_COMPAT=53; RANDOM=42; echo "$RANDOM:$RANDOM:$RANDOM"''',
    "symbolic-umask-copy": r'''umask 022; umask g=u; umask -S; umask o=g-w; umask -S''',
    "completion-glob": r'''touch alpha.txt beta.txt; compgen -G '*.txt' -- ignored; compgen -G 'missing*'; echo $?''',
    "completion-variable": r'''compgen -V matches -W 'one two three' -- t; printf '<%s>\n' "${matches[@]}"''',
    "compatibility-option-query": r'''shopt -s compat42; echo "$BASH_COMPAT"; shopt -u compat42; echo "$BASH_COMPAT"; BASH_COMPAT=4.1; shopt -p compat31 compat41 compat42''',
    "debug-argument-stack": r'''set -- a b; printf '<%s>|<%s>\n' "${BASH_ARGC[*]}" "${BASH_ARGV[*]}"; shopt -s extdebug; f() { printf '<%s>|<%s>\n' "${BASH_ARGC[*]}" "${BASH_ARGV[*]}"; g z; }; g() { printf '<%s>|<%s>\n' "${BASH_ARGC[*]}" "${BASH_ARGV[*]}"; }; f one two''',
    "special-variable-unset": r'''unset BASHPID LINENO EPOCHSECONDS EPOCHREALTIME; echo "${BASHPID-unset}:${LINENO-unset}:${EPOCHSECONDS-unset}:${EPOCHREALTIME-unset}"; BASHPID=plain; echo "$BASHPID"''',
    "posix-option-side-effects": r'''set -o posix; echo "$POSIXLY_CORRECT"; shopt -p inherit_errexit shift_verbose interactive_comments; set +o posix; echo "${POSIXLY_CORRECT-unset}"; shopt -p inherit_errexit shift_verbose''',
    "function-punctuation": r'''foo-bar() { printf dash; }; function foo.bar { printf dot; }; foo/bar() { printf slash; }; foo-bar; foo.bar; foo/bar; echo''',
    "function-export-punctuation": r'''foo-bar() { printf exported; }; export -f foo-bar; "$BASH" --noprofile --norc -c foo-bar''',
    "globsort-numeric": r'''touch 2 10 001 alpha; GLOBSORT=numeric; printf '<%s>\n' *; GLOBSORT=-name; printf '<%s>\n' *''',
    "globsort-size": r'''printf a >a; printf bbb >b; printf cc >c; GLOBSORT=size; printf '<%s>\n' *; GLOBSORT=-size; printf '<%s>\n' *''',
    "echo-unicode": r'''echo -e '\u03bb\U0001f642\123\x41' ''',
    "history-session-append": r'''printf 'old1\nold2\n' >input; history -s local; history -r input; history -a output; cat output''',
    "history-timestamp-late-format": r'''printf '#1234567890\necho first\necho second\n#1234567891\necho third\n' >input; history -r input; HISTTIMEFORMAT='stamp|'; history''',
    "history-timestamp-multiline": r'''printf '#1234567890\necho first\necho second\n#1234567891\necho third\n' >input; HISTTIMEFORMAT='%s|'; history -r input; history''',
    "trap-signal-variable": r'''echo "${BASH_TRAPSIG-unset}"; trap 'echo "$BASH_TRAPSIG"' USR1; kill -USR1 $$; echo "${BASH_TRAPSIG-unset}"; trap 'echo "exit:$BASH_TRAPSIG"' EXIT''',
    "monotonic-clock-variable": r'''a=$BASH_MONOSECONDS; b=$BASH_MONOSECONDS; [[ $a -ge 0 && $b -ge $a ]]; echo $?; unset BASH_MONOSECONDS; echo "${BASH_MONOSECONDS-unset}"; BASH_MONOSECONDS=plain; echo "$BASH_MONOSECONDS"''',
    "subscript-option-alias": r'''shopt -s array_expand_once; shopt -p array_expand_once assoc_expand_once; shopt -u assoc_expand_once; shopt -p array_expand_once assoc_expand_once''',
    "enable-print-with-names": r'''enable -n printf; enable -p printf | grep '^enable.*printf$'; type -t printf; enable -a printf | grep '^enable.*printf$'; type -t printf''',
    "kill-repeated-options": r'''kill -s 0 -n 0 $$ 2>errors; test ! -s errors; echo "$?"''',
}

for suite in ("completion", "execution", "invocation", "options"):
    CASES.update(runpy.run_path(Path(__file__).with_name(f"shell_{suite}_cases.py"))["CASES"])


def invoke(argv, source, directory, environment, stdin_script=False):
    proc = subprocess.Popen(argv + ([] if stdin_script else ["-c", source]),
                            cwd=directory, env=environment, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    try:
        out, err = proc.communicate(source.encode() if stdin_script else b"", timeout=5)
    except subprocess.TimeoutExpired:
        proc.send_signal(signal.SIGTERM)
        try:
            out, err = proc.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate(timeout=1)
        return "TIMEOUT", out, err
    return proc.returncode, out, err


def check(item, binary, bash):
    name, source = item
    with tempfile.TemporaryDirectory(prefix="terminal-shell-compat-") as temp:
        root = Path(temp)
        environment = dict(os.environ, HOME=temp, XDG_CONFIG_HOME=temp + "/config",
                           XDG_STATE_HOME=temp + "/state", HISTFILE=temp + "/history",
                           LC_ALL="C.UTF-8")
        for key in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"):
            environment.pop(key, None)
        for key in list(environment):
            if key.startswith("BASH_FUNC_"):
                del environment[key]
        (root / "fixture.sh").write_text("printf 'source:%s:%s\\n' \"$1\" \"$2\"\n")
        native_dir = root / "native"
        bash_dir = root / "bash"
        native_dir.mkdir()
        bash_dir.mkdir()
        for folder in (native_dir, bash_dir):
            (folder / "fixture.sh").write_bytes((root / "fixture.sh").read_bytes())
        stream = name == "source-stream-input"
        expected = invoke([bash, "--noprofile", "--norc"], source, bash_dir, environment, stream)
        actual = invoke([str(binary), "--native-shell", "--noprofile", "--norc"],
                        source, native_dir, environment, stream)
        if actual[:2] == expected[:2] and bool(actual[2]) == bool(expected[2]):
            return name, None
        return name, {"expected": expected, "actual": actual}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("build/terminal"))
    parser.add_argument("--bash", default="/bin/bash")
    parser.add_argument("--filter", default="")
    args = parser.parse_args()
    selected = [(name, source) for name, source in CASES.items() if args.filter in name]
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(32, os.cpu_count() or 1)) as pool:
        results = list(pool.map(lambda item: check(item, args.binary.resolve(), args.bash), selected))
    failures = 0
    for name, failure in results:
        if failure:
            failures += 1
            print("FAIL", name)
            for kind, (status, out, err) in failure.items():
                print(f"  {kind}: exit={status} stdout={out[:800]!r} ({len(out)} bytes) stderr={err[:800]!r}")
    print(f"{len(results) - failures}/{len(results)} focused Bash comparisons passed")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())

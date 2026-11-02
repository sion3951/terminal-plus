"""Focused shell option, declaration, and Bash 5.3 trap comparisons."""

CASES = {
    "shopt-full-inventory": r'''shopt -p''',
    "shopt-filter-does-not-set": r'''shopt -s | grep -E 'nullglob|globstar|checkwinsize'; shopt -p nullglob globstar''',
    "shopt-filter-does-not-unset": r'''shopt -u | grep -E 'nullglob|globstar|checkwinsize'; shopt -p checkwinsize''',
    "shopt-query-options": r'''shopt -q; echo $?; shopt -- nullglob; echo $?; shopt -su nullglob; echo $?; shopt -p nullglob''',
    "shopt-standard-print": r'''shopt -so vi; shopt -po vi; shopt -uo vi; shopt -po vi''',
    "globskipdots-disabled": r'''touch .hidden visible; shopt -u globskipdots; printf '<%s>\n' .*; shopt -s dotglob; printf '<%s>\n' *; printf '<%s>\n' .*/''',
    "globskipdots-extended": r'''touch .hidden visible; shopt -su globskipdots; shopt -u globskipdots; shopt -s extglob; printf '<%s>\n' .*; printf '<%s>\n' .*/''',
    "globskipdots-literal-components": r'''mkdir -p .hidden/sub; printf '<%s>\n' .*/.. .*/.; shopt -s extglob; printf '<%s>\n' .*/.. .*/.''',
    "globignore-dotglob-state": r'''touch .hidden visible; GLOBIGNORE=x; shopt -p dotglob; shopt -u dotglob; printf '<%s>\n' *; GLOBIGNORE=; shopt -p dotglob; unset GLOBIGNORE; shopt -p dotglob''',
    "declare-array-format": r'''declare -a a=([2]=x [7]='two words'); declare -p a; declare -A b=([simple]=x ['two words']=y ['*']=z); declare -p b''',
    "declare-empty-arrays": r'''declare -a a; declare -A b; declare -p a b; a=(); b=(); declare -p a b; a=(x); unset 'a[@]'; declare -p a''',
    "declare-control-characters": r'''x=$'one\ntwo'; declare -p x; a=($'a\tb'); declare -p a''',
    "local-posix-options": r'''f() { local -; set -o posix; }; f; echo "${POSIXLY_CORRECT-unset}"; shopt -p inherit_errexit shift_verbose; g() { local -; shopt -s inherit_errexit nullglob; }; g; shopt -p inherit_errexit nullglob''',
    "set-restricted": r'''set -r; [[ $- == *r* ]]; echo $?; set +r; echo $?; cd /; echo $?''',
    "set-nolog": r'''set -o nolog; set -o | grep nolog; set +o nolog; set -o | grep nolog''',
    "trap-action-query": r'''trap 'printf hello' USR1; trap '' USR2; trap -P USR1 USR2 INT; trap -P; echo $?; trap -pP USR1; echo $?''',
    "trap-query-case-options": r'''trap 'echo hello' sigusr1; trap -p -- usr1; trap -P -- SiGuSr1; trap -p -z; echo $?; kill -l hup sigusr2''',
    "trap-query-order": r'''trap : EXIT USR1 ERR DEBUG RETURN; trap --''',
}

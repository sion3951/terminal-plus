"""Focused Bash programmable-completion comparisons for check-shell-compat.py."""

CASES = {
    "completion-wordlist-no-pathname-expansion": r'''touch alpha.txt; compgen -W '*.txt' -- '' ''',
    "completion-wordlist-ifs": r'''IFS=:; compgen -W 'one:two:"three:four"'; IFS=" "; compgen -W 'a&b ab aab' -- a''',
    "completion-attached-options": r'''compgen -abW'one two three' -- tw; compgen -Vmatches -W'one two three' -- t; printf '<%s>\n' "${matches[@]}"''',
    "completion-separate-default-options": r'''complete -o bashdefault -W values demo; compopt demo | grep -o '[+-]o [a-z]*' | grep -E 'bashdefault|default$'; compopt -o default +o bashdefault demo; compopt demo | grep -o '[+-]o [a-z]*' | grep -E 'bashdefault|default$' ''',
    "completion-builtin-discovery": r'''for item in . : [ caller suspend; do compgen -A builtin -- "$item" | grep -Fx -- "$item"; done''',
    "completion-directory-spelling": r'''mkdir directory; compgen -d -- dire; compgen -f -- dire''',
    "completion-function-context": r'''f() { printf '%s:%s:%s:%s:%s:%s\n' "$COMP_LINE" "$COMP_POINT" "$COMP_CWORD" "${#COMP_WORDS[@]}" "$COMP_TYPE" "$COMP_KEY"; COMPREPLY=(reply); }; COMP_LINE=old; compgen -F f -- prefix; printf '%s:%s:%s\n' "${COMP_LINE-unset}" "${COMP_WORDS-unset}" "${COMPREPLY-unset}"''',
    "completion-command-context": r'''compgen -C 'printf "%s:%s:%s:%s\n" "$COMP_LINE" "$COMP_POINT" "$COMP_TYPE" "$COMP_KEY"; :' -- prefix; printf '%s:%s\n' "${COMP_LINE-unset}" "${COMP_POINT-unset}"''',
    "completion-filter-literal-ampersand": r'''compgen -W 'a&b ab aab' -X 'a\&b' -- a''',
    "completion-filter-nocasematch": r'''shopt -s nocasematch; compgen -W 'Alpha apple' -X 'A*' -- ''; echo status:$?''',
    "completion-directory-fallback-after-filter": r'''mkdir fallback; compgen -o dirnames -W 'first' -X '*' -- f''',
    "completion-options-shopt-inventory": r'''compgen -A shopt -- progcomp; compgen -A shopt -- direxpand; compgen -A shopt -- no_empty_cmd_completion''',
}

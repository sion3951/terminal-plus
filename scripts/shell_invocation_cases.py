"""Focused native help/startup comparisons (invocation flags are checked separately)."""

CASES = {
    "help-read-synopsis": r'''help -s read''',
    "help-prefix": r'''help -s re''',
    "help-pattern": r'''help -d "r*"''',
    "help-multiple": r'''help -s printf source trap''',
    "help-some-match": r'''help -d read no_such_topic''',
    "help-unmatched": r'''help no_such_topic; echo "$?"''',
    "help-invalid-option": r'''help -z; echo "$?"''',
    "help-mode-precedence": r'''help -dms read''',
    "builtin-help-status": r'''for name in printf read set declare eval . help; do "$name" --help >/dev/null; printf "%s:%s\n" "$name" "$?"; done''',
    "builtin-help-operands": r'''echo --help; true --help; echo "$?"; false --help; echo "$?"; test --help; echo "$?"''',
    "source-fullpath-option": r'''printf 'printf "<%%s>\n" "${BASH_SOURCE[0]}"\n' >fixture-source.sh; shopt -s bash_source_fullpath; result=$(source ./fixture-source.sh); [[ $result == "<$PWD/fixture-source.sh>" ]]; echo "$?"''',
    "eval-syntax-aborts-input": r'''eval $'echo before\nif ; then\necho BAD\nfi\necho after'; echo OUTER''',
    "source-syntax-aborts-input": r'''printf 'echo before\nif ; then\necho BAD\nfi\necho after\n' >bad; source ./bad; echo OUTER''',
    "command-syntax-aborts-input": "echo before\nif ; then\necho BAD\nfi\necho after",
}

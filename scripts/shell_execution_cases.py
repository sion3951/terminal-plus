"""Focused execution comparisons for Bash 5.3 native-shell behavior."""

CASES = {'pipeline-expansion-scope': 'i=0; printf \'%s\\n\' $((i++)) | cat; printf \'after:%s\\n\' "$i"',
 'pipeline-default-assignment-scope': 'unset x; printf \'%s\\n\' "${x:=child}" | cat; echo "${x-unset}"',
 'pipeline-sibling-expansions': 'i=0; printf \'%s\\n\' $((++i)) | { read -r value; printf \'%s:%s\\n\' "$value" "$i"; '
                                '}; echo "$i"',
 'pipeline-expansion-failure': 'set -u; printf \'%s\' "$missing_pipeline_variable" | cat; echo survived; echo '
                               '"${PIPESTATUS[*]}"',
 'pipeline-assignment-only': 'x=one | x=two; echo "${x-unset}:${PIPESTATUS[*]}"',
 'pipeline-substitution-only': '$(exit 7) | true; printf \'%s\\n\' "${PIPESTATUS[*]}"',
 'background-expansion-scope': 'i=0; printf \'%s\\n\' $((i++)) & wait; printf \'after:%s\\n\' "$i"',
 'lastpipe-expansion-order': 'shopt -s lastpipe; i=0; printf \'%s\' "$i" | read -n 1 x$((++i)); printf \'%s:%s\\n\' '
                             '"$i" "$x1"',
 'lastpipe-external-expansion': 'shopt -s lastpipe; i=0; printf x | /bin/echo $((i++)); echo "$i"',
 'lastpipe-subshell-scope': 'shopt -s lastpipe; i=0; printf x | (read -n 1 x; i=9); echo "$i:${x-unset}"',
 'function-nesting-limit': 'FUNCNEST=2; f() { echo f; g; }; g() { echo g; h; }; h() { echo BAD; }; f; echo BAD',
 'function-nesting-unlimited': 'FUNCNEST=0; f() { g; }; g() { echo ok; }; f',
 'for-brace-body': 'for x in a b; { printf \'<%s>\\n\' "$x"; }',
 'for-arithmetic-brace-body': 'for ((i=0;i<3;i++)); { printf \'%s\\n\' "$i"; }',
 'for-arguments-brace-body': 'set -- a \'two words\'; for x { printf \'<%s>\\n\' "$x"; }',
 'coprocess-named-if': 'coproc C if true; then echo hi; fi; read -r value <&"${C[0]}"; echo "$value"; wait',
 'coprocess-named-for': 'coproc C for x in a b; do echo "$x"; done; cat <&"${C[0]}"; wait',
 'conditional-invalid-empty': '[[ ]]; echo BAD',
 'conditional-invalid-operand': '[[ x && ]]; echo BAD',
 'source-explicit-search-path': 'mkdir sourced; printf \'printf "<%%s>\\\\n" "$1"\\n\' >sourced/input; source -p '
                                'sourced input value',
 'source-attached-search-path': "mkdir sourced; printf 'echo source-ok\\n' >sourced/input; shopt -u sourcepath; . "
                                '-psourced input',
 'source-parameters-shift': 'printf \'shift\\n\' >input; set -- outer tail; source ./input; printf \'<%s>\\n\' "$@"; '
                            'set -- outer tail; source ./input inner next; printf \'<%s>\\n\' "$@"',
 'source-parameters-set': "printf 'set -- changed\\n' >input; set -- outer tail; source ./input inner; printf "
                          '\'<%s>\\n\' "$@"',
 'source-parameters-nested-function': "printf 'f() { set -- local; }; f\\n' >input; set -- outer tail; source ./input "
                                      'inner; printf \'<%s>\\n\' "$@"',
 'exit-double-dash': 'exit -- 17',
 'exit-whitespace-number': "exit ' 42 '",
 'exit-invalid-before-extra': 'exit invalid extra; echo BAD',
 'for-arguments-brace-separated': 'set -- a \'two words\'; for x; { printf \'<%s>\\n\' "$x"; }',
 'conditional-empty-if-condition': 'if then :; fi; echo BAD',
 'conditional-empty-then-body': 'if true; then fi; echo BAD',
 'conditional-empty-loop-body': 'for x in a; do done; echo BAD',
 'empty-case-arm-valid': 'case x in x) ;; esac; echo ok'}

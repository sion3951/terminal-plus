# Native shell

Local tabs run a Bash-compatible shell written in Odin and compiled into
Terminal+. It never falls back to launching Bash. Scripts that ask for Bash
in their shebang still run with the host's Bash.

## Invocation

```sh
terminal+ -e 'command'                        # open Terminal+ running a command
terminal+ --native-shell                      # interactive, no GUI
terminal+ --native-shell -c 'command' name args...
terminal+ --native-shell script.sh args...
```

Accepted options: `--noprofile`, `--norc`, `--rcfile`, `--noediting`,
`--verbose`, `--debugger`, `--restricted`/`-r`, `-D`/`--dump-strings`,
`--dump-po-strings`, and combined short options.

## Startup files

| Shell | Reads |
| --- | --- |
| Login | `/etc/profile`, then the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile` |
| Interactive | `/etc/bash.bashrc`, `~/.bashrc`, `$XDG_CONFIG_HOME/terminal-plus/shellrc` |
| Non-interactive | `$BASH_ENV` |

History is saved to `~/.bash_history` and respects `HISTFILE`, `HISTSIZE`,
`HISTCONTROL`, and `HISTIGNORE`.

## Supported features

The target is Bash 5.3 behavior.

- **Language**: conditionals, loops, functions with local scope, `case`,
  groups and subshells, arithmetic, indexed and associative arrays, aliases,
  parameter transformations, brace and glob expansion (`GLOBSORT`), and
  command and process substitution, including Bash 5.3 `${ cmd; }` and
  `${| cmd; }`
- **I/O**: heredocs, here strings, fd allocation, redirection, pipelines,
  `lastpipe`, coprocesses
- **Jobs**: job control, traps, `huponexit`, stopped-job warnings, `FUNCNEST`
- **Builtins**: full `printf`, `read`, `mapfile`, `shopt` (the whole Bash 5.3
  option set), `source -p`, `trap -P`, `help -d/-m/-s`, `--help` on builtins,
  command hashing, directory stack, and the `BASH_*` variables
- **Editing**: PS1/PS2, `PROMPT_COMMAND`, Emacs and basic vi modes, inputrc,
  keymaps, kill/yank, undo, history search and expansion, bracketed paste,
  macros, and `bind -x`
- **Completion**: `complete`, `compgen`, `compopt`, completion functions with
  the full `COMP_*` context, and menu cycling
- **Other**: `$"..."` translation via gettext, and mail checks (`MAIL`, `MAILPATH`, `MAILCHECK`)

Typing a Markdown, HTML, or media filename, or running `tview <file>`, opens
it in the built-in viewer.

## Limitations

Compatibility is still being verified. Passing the comparison tests doesn't mean
full Bash conformance. Known gaps:

- Loadable C builtins (the GNU Bash ABI) and exhaustive GNU Readline behavior
  are out of scope.
- POSIX-mode edge cases, job-notification timing, uncommon editing behavior,
  and exact diagnostics need more coverage.
- Locale testing covers C and C.UTF-8. Other locales need to be installed to test.

## Testing

```sh
python3 tests/shell-compat.py        # requires Bash on the host
python3 tests/shell-compat.py --filter NAME --binary build/terminal
```

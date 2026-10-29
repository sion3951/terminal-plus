# Build

Requires Odin, make, glslc, GLFW 3.4+, Wayland client libraries, FreeType, SQLite with FTS5 trigram support,
MD4C-HTML, OpenSSH, and Vulkan. Image/video viewing uses the host's FFmpeg
(5 or newer); ffprobe and ffplay are not required.

```sh
make -j
./build/terminal
```

Local tabs and `-e` commands run the native Odin shell in another process of the
same executable; no Bash or Readline library is required. SSH sessions use the
remote host's configured shell and tmux. AppImage launch/install/update helpers
still require the host's POSIX `sh` and standard Linux utilities.

Use `make appimage` for the distributable. Release instructions are in
[RELEASING.md](RELEASING.md).

## Native shell

Local tabs use the Odin shell compiled into Terminal+. `-e 'command'` uses the
same interpreter. `--native-shell` starts it without the GUI;
`--native-shell -c 'command' name args...` and `--native-shell script args...`
provide command and script invocation. Bash is not launched as a fallback.

The interpreter targets Bash 5.3 behavior. It implements conditionals, loops,
functions and local scope, case clauses, groups/subshells, arithmetic commands
and expressions, indexed/associative arrays, positional parameters, aliases,
parameter transformations, brace/glob expansion, command/process substitution,
heredocs/here strings, descriptor allocation and redirection, pipelines,
background conditional lists, coprocesses, jobs, traps and shell options.
`lastpipe` runs the final builtin/function/group in the parent when job control
is off. `printf` includes variable assignment, numeric/float formats, shell
quoting, wide characters, locale formatting, escapes and timestamps. Bash 5.3
`${ command; }` and `${| command; }` substitutions run in the current shell.
Declarations support inherited locals, global bindings hidden by locals,
function tracing/readonly attributes and function-scoped option restoration.
`read` supports exact character counts, editing, timeouts and signal handling;
`mapfile` supports callbacks. Command hashing, directory-stack rotation and
the `BASH_ALIASES`, `BASH_CMDS`, `BASH_ARGV0`, `BASH_ARGC` and `BASH_ARGV`
interfaces are native. `GLOBSORT` controls filename ordering by name, numeric
name, size, timestamps or allocated blocks. Locale message catalogs for
`$"..."` use the existing libc gettext support. Historical arithmetic expansion
honors `BASH_COMPAT` and the array expansion options. Enter `help` for the
builtin list.

The Bash 5.3 shell-option inventory is shared by `shopt`, startup options and
completion. This includes `bash_source_fullpath`, `checkjobs`, `direxpand`,
`gnu_errfmt`, `histreedit`, `mailwarn`, `no_empty_cmd_completion`, and
`progcomp_alias`. `source -p` searches an explicit path, `trap -P` returns trap
actions, and `help -d/-m/-s` looks up builtin and syntax topics. Builtin
`--help` requests return usage information without executing the builtin.
Pipeline and background-command expansion is isolated from the parent shell;
`lastpipe` preserves changes made by the final command. `FUNCNEST` limits
function recursion. Normal shell exit, stopped-job warnings and `huponexit`
follow the shell's interactive/login state.

Interactive startup reads Bash startup files: login shells use `/etc/profile`
and the first readable `~/.bash_profile`, `~/.bash_login`, or `~/.profile`;
non-login interactive shells read `/etc/bash.bashrc` and `~/.bashrc`.
`--noprofile`, `--norc`, `--rcfile`, and combined short options are accepted.
`--noediting`, `--verbose`, `--debugger`, `-D`/`--dump-strings`, and
`--dump-po-strings` are also supported. Debugger profiles execute through the
native interpreter; translated-string extraction does not execute commands.
`--restricted`/`-r` enforces restricted-shell rules after startup files run.
Noninteractive shells read `BASH_ENV` when set. The optional
`$XDG_CONFIG_HOME/terminal-plus/shellrc` is also read for interactive sessions.
History defaults to `~/.bash_history` and honors `HISTFILE`, `HISTSIZE`,
`HISTCONTROL`, and `HISTIGNORE`.

The editor supports expandable PS1/PS2, PROMPT_COMMAND, UTF-8 and word editing,
history search/expansion, bracketed paste, common Emacs bindings, basic vi mode,
key macros, `bind -x`, and programmable completion through `complete`,
`compgen`, `compopt`, and shell functions. Inputrc files, configurable keymaps,
kill/yank, undo, timestamped history, history file limits and append behavior
are handled by the native editor. Programs receive a real controlling
PTY with canonical terminal settings restored before execution. Readable
Markdown/HTML/media filenames and `tview` open the embedded viewers.
Completion functions receive the full `COMP_LINE`, cursor position and word
context, with temporary completion variables restored afterward. Alias
completion, directory expansion, list-only completion and menu cycling use
their respective completion modes. `MAIL`, `MAILPATH` and `MAILCHECK` enable
mailbox and Maildir checks before the primary prompt, including custom
notifications and `mailwarn` read notifications.

The compatibility target is native Bash-style scripting and interactive use.
The GNU Bash loadable C builtin ABI and exhaustive GNU Readline behavior are
outside that target. Compatibility is still being verified: passing selected
comparisons does not establish complete Bash conformance. Historical/POSIX
mode edge cases, signal/job notification timing, uncommon editing behavior and
exact diagnostics need further coverage. General locale comparisons cover C
and C.UTF-8; message translation is also checked with a temporary non-C locale
and generated catalogs. Other locale-specific behavior needs an installation
that provides those locales.
External programs/scripts retain their own dependencies,
including Bash when their shebang or command explicitly requests it.

Run the focused comparison checks against an installed Bash with:

```sh
python3 scripts/check-shell-compat.py
```

The checks cover selected behavior, not complete GNU Bash conformance.

## Rendering

The application requires native Wayland; X11 and XWayland are unsupported.
Release packaging requires GLFW built with `GLFW_BUILD_WAYLAND=ON` and
`GLFW_BUILD_X11=OFF` (as configured by `scripts/ci/setup-linux.sh`).
Document previews remain embedded in the Vulkan window.
The native document engine supports HTML recovery and named entities, flex/grid
and positioned layout, native Canvas 2D geometry/text, images and SVG through
FFmpeg, classes/prototypes/regular expressions/modules/promises/async JavaScript,
DOM events, local/SSH/HTTP navigation, GET/POST forms, fetch, selection/copy, find,
zoom, dark mode, and reload. HTTP/TLS and cookies reuse the existing curl transport;
text encodings use libc already linked by the application. No browser engine or
additional library dependency is used. HTML audio/video controls open FFmpeg.

Open `examples/html/index.html` to exercise representative pages. A bounded
pipeline diagnostic can run without a compositor:

```sh
./build/terminal --document-check examples/html/*.html
```

These pages/checks do not establish full web-platform conformance. Remaining gaps
include CSS transforms/keyframes/floats/subgrid and full table sizing; complete
HTML tree construction/foreign namespaces; generators/private classes/top-level
await and exact ECMAScript semantics; file uploads; and canvas gradients/pixel
operations/WebGL and other browser APIs. Live rendering still needs a Wayland
desktop.
Existing settings and session archives retain the `minor-terminal` storage paths.

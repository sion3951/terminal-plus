#!/bin/sh
# Install a portable, user-owned AppImage. Updates replace the same file.
set -eu
appdir=$1
shift
[ "$#" -eq 0 ] || { echo 'Usage: Terminal+.AppImage --install' >&2; exit 2; }
[ -n "${APPIMAGE:-}" ] && [ -f "$APPIMAGE" ] || { echo 'Run --install from the AppImage itself.' >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo 'Install as your ordinary desktop user.' >&2; exit 1; }
base=${XDG_DATA_HOME:-$HOME/.local/share}
install_dir=$HOME/.local/lib/terminal-plus
bin_dir=$HOME/.local/bin
mkdir -p "$install_dir" "$bin_dir" "$base/applications" "$base/icons/hicolor/scalable/apps"
target=$install_dir/Terminal+.AppImage
link=$bin_dir/terminal+
if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "Refusing to replace existing non-symlink command: $link" >&2
    exit 1
fi
# mktemp and rename avoid changing an executable that an existing window uses.
staged=$(mktemp "$install_dir/.install-XXXXXX")
trap 'rm -f "$staged"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
cp -- "$APPIMAGE" "$staged"
chmod 755 "$staged"
mv -f -- "$staged" "$target"
ln -sfn "$target" "$link"
install -m 644 "$appdir/usr/share/icons/hicolor/scalable/apps/terminal-plus.svg" "$base/icons/hicolor/scalable/apps/terminal-plus.svg"
# Desktop Exec quoting is distinct from shell quoting. Escape its reserved
# backslash, quote, backtick, dollar and field-code characters.
# Use sed rather than requiring Python on end-user machines.
escaped=$(printf '%s' "$target" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g; s/%/%%/g')
{
    printf '[Desktop Entry]\nType=Application\nName=Terminal+\nComment=GPU terminal, SSH, files and documents\n'
    printf 'Exec="%s"\n' "$escaped"
    printf 'Icon=terminal-plus\nTerminal=false\nCategories=System;TerminalEmulator;\nStartupWMClass=terminal-plus\n'
} > "$base/applications/terminal-plus.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$base/applications" >/dev/null 2>&1 || true; fi
printf 'Installed Terminal+. Launch from your applications menu or run terminal+\n'
case :$PATH: in
    *:"$bin_dir":*) ;;
    *) printf 'For this shell, add the command directory to PATH:\n  export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac

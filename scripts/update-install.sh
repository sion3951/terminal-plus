#!/bin/sh
# Portable AppImage updates only; this helper never requests elevation.
set -eu
umask 077
image=$1
package=$2
stage=$3
parent=$4
wanted=$5
size=$6
result=$(dirname -- "$stage")/install-result.txt
next=
finish() {
    [ -z "$next" ] || rm -f -- "$next"
    rm -rf -- "$stage"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
fail() { printf '%s\n' "$1" > "$result"; exit 1; }
[ "$(id -u)" != 0 ] || fail 'Do not run the updater as root.'
# Wait for saved windows and terminal hosts to detach cleanly.
tries=0
while kill -0 "$parent" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 120 ] || fail 'The application did not finish closing; the update was not installed.'
    sleep 1
done
[ -f "$image" ] && [ ! -L "$image" ] && [ -w "$image" ] || fail 'The AppImage is no longer writable.'
[ "$(stat -c %u -- "$image")" = "$(id -u)" ] || fail 'The AppImage owner changed.'
[ "$(wc -c < "$package" | tr -d ' ')" = "$size" ] || fail 'Update size verification failed.'
actual=$(sha256sum -- "$package")
actual=${actual%% *}
[ "$actual" = "$wanted" ] || fail 'Update checksum verification failed.'
next=$(mktemp "$(dirname -- "$image")/.terminal-plus-update.XXXXXXXX")
cp -- "$package" "$next" || fail 'Could not copy the update beside the AppImage.'
chmod 755 "$next"
actual=$(sha256sum -- "$next")
actual=${actual%% *}
[ "$actual" = "$wanted" ] || fail 'Copied update checksum verification failed.'
sync -f "$next"
mv -f -- "$next" "$image" || fail 'Could not replace the AppImage.'
next=
sync -f "$(dirname -- "$image")"
printf 'success\n' > "$result"
# The new runtime must not inherit paths into the old AppImage mount.
unset APPIMAGE APPDIR ARGV0 LD_LIBRARY_PATH LD_PRELOAD TERMINAL_PLUS_CURL TERMINAL_PLUS_OPENSSL
finish
trap - EXIT
# Redirect away from the deleted staging log before launching the replacement.
exec "$image" </dev/null >/dev/null 2>&1

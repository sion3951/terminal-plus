#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) [ "$#" -ge 2 ] || exit 2; version=$2; shift 2 ;;
        *) echo 'Usage: sh scripts/build-appimage.sh --version VERSION' >&2; exit 2 ;;
    esac
done
[ -n "$version" ] || { echo 'A release version is required.' >&2; exit 2; }
case "$version" in *[!0-9A-Za-z.+-]*|dev) echo 'Invalid release version.' >&2; exit 2 ;; esac
[ "$(uname -s):$(uname -m)" = Linux:x86_64 ] || { echo 'This release builds Linux x86_64 only.' >&2; exit 1; }
for tool in python3 patchelf curl openssl strip; do command -v "$tool" >/dev/null 2>&1 || { echo "Missing $tool" >&2; exit 1; }; done
[ -x build/terminal ] || { echo 'Build the release binary first.' >&2; exit 1; }
# Prevent inadvertently signing an archive containing a development binary.
[ "$(build/terminal --version)" = "Terminal+ $version" ] || { echo 'Binary version does not match packaging version.' >&2; exit 1; }
mkdir -p build/packages
work=$(mktemp -d build/.appimage-stage-XXXXXX)
work=$(CDPATH= cd -- "$work" && pwd)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
appdir=$work/Terminal+.AppDir
mkdir -p "$appdir/usr/bin" "$appdir/usr/lib/terminal-plus" "$appdir/usr/share/applications" \
    "$appdir/usr/share/icons/hicolor/scalable/apps" "$appdir/usr/share/doc/terminal-plus" "$appdir/usr/share/terminal-plus"
python3 scripts/bundle-linux-libraries.py build/terminal "$appdir/usr/bin/terminal+" "$appdir/usr/lib/terminal-plus"
for utility in curl openssl; do
    python3 scripts/bundle-linux-libraries.py "/usr/bin/$utility" "$appdir/usr/bin/$utility" "$appdir/usr/lib/terminal-plus" --utility
done
python3 scripts/bundle-libdecor.py "$appdir/usr/lib/terminal-plus"
python3 scripts/bundle-linux-data.py "$appdir"
python3 scripts/collect-linux-licenses.py "$appdir/usr/lib/terminal-plus" "$appdir/usr/share/doc/terminal-plus/licenses"
find "$appdir/usr/bin" "$appdir/usr/lib/terminal-plus" -type f \( -name terminal+ -o -name curl -o -name openssl -o -name '*.so*' \) -exec strip --strip-unneeded {} +
install -m 755 packaging/linux/AppRun "$appdir/AppRun"
install -m 644 packaging/linux/terminal-plus.desktop "$appdir/usr/share/applications/terminal-plus.desktop"
install -m 644 packaging/linux/terminal-plus.svg "$appdir/usr/share/icons/hicolor/scalable/apps/terminal-plus.svg"
install -m 755 scripts/install-appimage.sh "$appdir/usr/share/terminal-plus/install-appimage.sh"
install -m 644 README.md LICENSE "$appdir/usr/share/doc/terminal-plus/"
ln -s usr/share/applications/terminal-plus.desktop "$appdir/terminal-plus.desktop"
ln -s usr/share/icons/hicolor/scalable/apps/terminal-plus.svg "$appdir/terminal-plus.svg"
ln -s terminal-plus.svg "$appdir/.DirIcon"
tools=build/toolchains/appimage
if [ -z "${APPIMAGETOOL:-}" ] || [ -z "${APPIMAGE_RUNTIME:-}" ]; then python3 scripts/fetch-appimage-tools.py "$tools"; fi
appimagetool=$(realpath "${APPIMAGETOOL:-$tools/appimagetool-x86_64.AppImage}")
runtime=$(realpath "${APPIMAGE_RUNTIME:-$tools/runtime-x86_64}")
(
    unset OWD APPIMAGE APPDIR ARGV0
    ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$appimagetool" --comp zstd \
        --mksquashfs-opt -b --mksquashfs-opt 1048576 \
        --runtime-file "$runtime" "$appdir" "$work/package.AppImage"
)
chmod 755 "$work/package.AppImage"
output=build/packages/terminal+-$version-x86_64.AppImage
mv "$work/package.AppImage" "$output"
echo "Built $output"

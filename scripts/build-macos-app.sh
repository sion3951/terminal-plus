#!/bin/sh
# Package build/terminal as Terminal+.app and a drag-to-Applications disk image.
#
# Signing: ad-hoc by default, so the app runs on the Mac that built it and on
# others after Gatekeeper approval. Set CODESIGN_IDENTITY to a "Developer ID
# Application" identity to sign for distribution, and either NOTARY_PROFILE
# (a notarytool keychain profile) or APPLE_ID, APPLE_TEAM_ID and
# APPLE_APP_PASSWORD to notarize and staple the disk image.
set -eu
cd "$(dirname "$0")/.."
version=
dmg=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) [ "$#" -ge 2 ] || exit 2; version=$2; shift 2 ;;
        --dmg) dmg=1; shift ;;
        *) echo 'Usage: sh scripts/build-macos-app.sh --version VERSION [--dmg]' >&2; exit 2 ;;
    esac
done
[ -n "$version" ] || { echo 'A release version is required.' >&2; exit 2; }
case "$version" in *[!0-9A-Za-z.+-]*) echo 'Invalid release version.' >&2; exit 2 ;; esac
[ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || { echo 'The macOS app builds on Apple silicon (arm64) only.' >&2; exit 1; }
for tool in python3 otool install_name_tool codesign hdiutil ditto strip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing $tool" >&2; exit 1; }
done
[ -x build/terminal ] || { echo 'Build the release binary first (make).' >&2; exit 1; }
# Prevent packaging a development binary under a release version.
[ "$(build/terminal --version)" = "Terminal+ $version" ] || { echo 'Binary version does not match packaging version.' >&2; exit 1; }
lipo -archs build/terminal 2>/dev/null | grep -qx arm64 || { echo 'build/terminal is not an arm64 executable.' >&2; exit 1; }
minimum=${MACOS_MINIMUM:-15.0}
identity=${CODESIGN_IDENTITY:--}

mkdir -p build/packages
work=$(mktemp -d build/.macos-stage-XXXXXX)
work=$(CDPATH= cd -- "$work" && pwd)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

app=$work/Terminal+.app
contents=$app/Contents
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/licenses"
cp build/terminal "$contents/MacOS/terminal+"
chmod 755 "$contents/MacOS/terminal+"
sed -e "s/@VERSION@/$version/g" -e "s/@MINIMUM_MACOS@/$minimum/g" packaging/macos/Info.plist > "$contents/Info.plist"
printf 'APPL????' > "$contents/PkgInfo"
cp packaging/macos/Terminal+.icns "$contents/Resources/Terminal+.icns"
python3 scripts/bundle-macos-libraries.py "$contents/MacOS/terminal+" "$contents/Frameworks" "$contents/Resources/licenses"
cp LICENSE "$contents/Resources/licenses/Terminal+-LICENSE.txt"
cp packaging/linux/GLFW-LICENSE.txt "$contents/Resources/licenses/"
cp assets/*LICENSE*.txt "$contents/Resources/licenses/"
cp README.md "$contents/Resources/"

# Strip local symbols, then sign inside-out: libraries before the app.
strip -x "$contents/MacOS/terminal+"
for library in "$contents/Frameworks"/*.dylib; do
    [ -e "$library" ] || continue
    strip -x "$library"
done
if [ "$identity" = - ]; then
    sign() { codesign --force --sign - "$@"; }
else
    sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
fi
for library in "$contents/Frameworks"/*.dylib; do
    [ -e "$library" ] || continue
    sign "$library"
done
sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"
"$contents/MacOS/terminal+" --version >/dev/null

rm -rf "build/packages/Terminal+.app"
ditto "$app" "build/packages/Terminal+.app"
echo "Built build/packages/Terminal+.app"
[ "$dmg" = 1 ] || exit 0

stage=$work/dmg
mkdir -p "$stage"
ditto "$app" "$stage/Terminal+.app"
ln -s /Applications "$stage/Applications"
output=build/packages/terminal+-$version-arm64.dmg
rm -f "$output"
hdiutil create -volname "Terminal+ $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$work/package.dmg" >/dev/null
if [ "$identity" != - ]; then
    codesign --force --timestamp --sign "$identity" "$work/package.dmg"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$work/package.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$work/package.dmg"
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
        xcrun notarytool submit "$work/package.dmg" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
        xcrun stapler staple "$work/package.dmg"
    else
        echo 'Signed but not notarized: set NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD.' >&2
    fi
fi
hdiutil verify "$work/package.dmg" >/dev/null
mv "$work/package.dmg" "$output"
echo "Built $output"

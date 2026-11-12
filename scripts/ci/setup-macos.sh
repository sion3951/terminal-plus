#!/bin/sh
# Apple silicon build dependencies. GLFW, stb and Metal come with Odin and the
# macOS SDK; FreeType, MD4C and SQLite (FTS5 trigram) are bundled into the app.
set -eu
[ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || { echo 'macOS builds target Apple silicon only.' >&2; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew install freetype md4c sqlite

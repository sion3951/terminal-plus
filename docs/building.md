# Building from source

## Dependencies

### Linux

- Odin, make, glslc
- GLFW 3.4+ built for Wayland (`GLFW_BUILD_WAYLAND=ON`, `GLFW_BUILD_X11=OFF`)
- Wayland client libraries, Vulkan
- FreeType, SQLite (with FTS5 trigram), MD4C-HTML
- OpenSSH
- FFmpeg 5+ (runtime only, for media viewing)

`scripts/ci/setup-linux.sh` shows the exact CI setup.

### macOS (Apple silicon)

- Xcode Command Line Tools (`xcode-select --install`)
- Odin `dev-2026-09` (later 2026 builds hit an Objective-C code-generation
  bug; `scripts/ci/setup-odin.sh` installs the pinned compiler)
- Homebrew `freetype md4c sqlite` (`sh scripts/ci/setup-macos.sh`)
- FFmpeg (runtime only, for media viewing: `brew install ffmpeg`)

GLFW and stb come prebuilt with Odin; Metal and Cocoa come with macOS.

## Build

```sh
make -j
./build/terminal
```

| Target | Description |
| --- | --- |
| `make run` | Build and launch |
| `make check` | Run the built-in self-check |
| `make appimage` | Build the distributable AppImage into `build/packages/` (Linux) |
| `make macos-app` | Build `build/packages/Terminal+.app` with its libraries bundled (macOS) |
| `make dmg` | Build the app and `terminal+-VERSION-arm64.dmg` (macOS) |
| `make clean` | Remove build output |

## Tests

```sh
make check                                     # parser + shell PTY self-check
python3 tests/shell-compat.py                  # compare native shell with host Bash
./build/terminal --document-check examples/html/*.html   # headless document pipeline
```

## Repository layout

| Path | Contents |
| --- | --- |
| `src/` | Application source (one Odin package), shaders, and `updater_security` |
| `assets/` | Embedded fonts, licenses, and the update public key |
| `examples/` | Sample HTML pages for the document engine |
| `tests/` | Native shell compatibility tests |
| `scripts/` | Packaging, CI, and update tooling |
| `packaging/` | AppImage desktop entry and launcher; macOS `Info.plist` and icon |
| `docs/` | Documentation |

## Runtime notes

- Linux: native Wayland only; X11 and XWayland are unsupported.
- macOS: Metal renders into a Cocoa window at the display's backing scale.
  Platform differences (sockets, PTYs, `/proc`, `poll` on terminals) live in
  `src/platform_linux.odin` and `src/platform_darwin.odin`.
- Local tabs and `-e` commands run the [native shell](native-shell.md) and don't
  need Bash. SSH tabs use the remote host's shell and tmux.
- The AppImage launch, install, and update helpers need POSIX `sh` and standard
  Linux utilities on the host.
- On macOS the native shell's `extglob` patterns and gettext translations are
  unavailable (BSD libc has no `FNM_EXTMATCH` or gettext); other globbing works.
- Settings and session archives are still stored under `minor-terminal` paths.

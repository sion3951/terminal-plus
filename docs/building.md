# Building from source

## Dependencies

- Odin, make, glslc
- GLFW 3.4+ built for Wayland (`GLFW_BUILD_WAYLAND=ON`, `GLFW_BUILD_X11=OFF`)
- Wayland client libraries, Vulkan
- FreeType, SQLite (with FTS5 trigram), MD4C-HTML
- OpenSSH
- FFmpeg 5+ (runtime only, for media viewing)

`scripts/ci/setup-linux.sh` shows the exact CI setup.

## Build

```sh
make -j
./build/terminal
```

| Target | Description |
| --- | --- |
| `make run` | Build and launch |
| `make check` | Run the built-in self-check |
| `make appimage` | Build the distributable AppImage into `build/packages/` |
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
| `packaging/` | AppImage desktop entry, icon, and launcher |
| `docs/` | Documentation |

## Runtime notes

- Native Wayland only; X11 and XWayland are unsupported.
- Local tabs and `-e` commands run the [native shell](native-shell.md) and don't
  need Bash. SSH tabs use the remote host's shell and tmux.
- The AppImage launch, install, and update helpers need POSIX `sh` and standard
  Linux utilities on the host.
- Settings and session archives are still stored under `minor-terminal` paths.

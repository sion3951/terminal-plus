# Build

Requires Odin, make, glslc, GLFW 3.4+, FreeType, SQLite with FTS5 trigram support,
MD4C-HTML, Bash, OpenSSH, and Vulkan. Chromium/Chrome enables document previews.

```sh
make -j
./build/terminal
```

Use `make appimage` for the distributable. Release instructions are in
[RELEASING.md](RELEASING.md).

Wayland sessions always use native Wayland, including the embedded viewer.
Existing settings and session archives retain the `minor-terminal` storage paths.

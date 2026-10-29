# Terminal+

A fast Linux terminal with Vulkan rendering, persistent local and SSH sessions,
a file browser, and embedded Markdown/HTML previews. Requires native Wayland.

[Download the AppImage](https://github.com/sion3951/terminal-plus/releases/latest),
then install it:

```sh
chmod +x terminal+-*.AppImage
./terminal+-*.AppImage --install
terminal+
```

Linux x86_64; requires a Vulkan driver. Local tabs use the native Odin shell
compiled into Terminal+; Bash is not required. `~/.local/bin` must be on your PATH.
The [native shell](BUILD.md#native-shell) supports Bash-style scripts, startup files,
arrays, job control, completion and history. Compatibility is still being verified.
Image and video viewing requires FFmpeg (5 or newer), with no ffprobe or ffplay
requirement. In a new terminal tab, enter an image/video filename directly or run
`tview 'path/to/file.mp4'`. You can also open media from **Files**. Frames render
inside the Vulkan window; **Esc** or **Ctrl+C** closes the viewer and returns to
the terminal. Videos loop by default, preserving mute and volume settings, and
use FFmpeg's audio output when available. The playback bar
provides play/pause, replay, a draggable seek bar, elapsed/total time, ten-second
skip buttons, mute and volume. **Space** pauses/resumes, **Left/Right** seek five
seconds, **J/L** skip ten seconds, **Up/Down** adjust volume, and **M** toggles mute.
**Home/End** seek to the beginning/end. Audio files use the same controls.

Markdown/HTML previews use native Odin parsing, CSS layout, JavaScript, and Vulkan
rendering, including flex/grid, positioning, Canvas 2D, modules, async fetch,
form submission and network navigation. Open `examples/html/index.html` from a
new terminal tab or Files to try the included layout, forms, scripts, canvas and
media pages. Each page explains the expected result.

Full browser compatibility remains incomplete. CSS transforms/animations,
complete web APIs, file uploads, advanced canvas/WebGL and some HTML/JavaScript
standards behavior remain unsupported. Script and resource errors appear in
the document viewer.

Updates download automatically, verify signed releases, and install when you choose
**Update and restart**. Keep the AppImage somewhere you can write to.

Build from source: see [BUILD.md](BUILD.md). [MIT license](LICENSE).

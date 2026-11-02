# Terminal+

A fast, Vulkan-rendered terminal for Linux on native Wayland.

- **Persistent sessions** for local and SSH tabs
- **Built-in shell**: a native Bash-compatible shell, so Bash isn't required
- **File browser**
- **Document viewer**: Markdown and HTML rendered in the window, no browser engine
- **Media viewer**: images, video and audio via FFmpeg
- **Signed auto-updates**: keep the AppImage somewhere writable

## Install

[Download the latest AppImage](https://github.com/sion3951/terminal-plus/releases/latest), then:

```sh
chmod +x terminal+-*.AppImage
./terminal+-*.AppImage --install   # adds the app menu entry and `terminal+` command
terminal+
```

**Requires:** Linux x86_64, a Wayland compositor, a Vulkan driver, and
`~/.local/bin` on your `PATH`. FFmpeg 5+ is optional and enables media viewing.

## Usage

To view a file, type its name in a tab (or run `tview <file>`), or open it from **Files**.

| Media viewer key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Seek 5 s |
| J / L | Skip 10 s |
| ↑ / ↓ | Volume |
| M | Mute |
| O | Choose audio output |
| Esc / Ctrl+C | Close viewer |

To try the document engine, open `examples/html/index.html`.

## Documentation

- [Building from source](docs/building.md)
- [Native shell](docs/native-shell.md)
- [Document engine](docs/document-engine.md)
- [Releasing](docs/releasing.md)

## License

[MIT](LICENSE)

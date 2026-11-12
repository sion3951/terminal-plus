# Terminal+

A fast, GPU-rendered terminal for Linux (Vulkan on native Wayland) and
Apple silicon Macs (Metal).

- **Persistent sessions** for local and SSH tabs
- **Built-in shell**: a native Bash-compatible shell, so Bash isn't required
- **File browser**
- **Document viewer**: Markdown and HTML rendered in the window, no browser engine
- **Media viewer**: images, video and audio via FFmpeg
- **Signed auto-updates**: keep the AppImage somewhere writable; on macOS the
  verified disk image opens in Finder

## Install

### Linux

[Download the latest AppImage](https://github.com/sion3951/terminal-plus/releases/latest), then:

```sh
chmod +x terminal+-*.AppImage
./terminal+-*.AppImage --install   # adds the app menu entry and `terminal+` command
terminal+
```

**Requires:** Linux x86_64, a Wayland compositor, a Vulkan driver, and
`~/.local/bin` on your `PATH`. FFmpeg 5+ is optional and enables media viewing.

### macOS (Apple silicon, experimental)

macOS support is new and lightly tested; please report problems.


1. [Download](https://github.com/sion3951/terminal-plus/releases/latest)
   `terminal+-VERSION-arm64.dmg` and open it.
2. Drag **Terminal+** onto **Applications**.
3. Open Terminal+ from Applications or Launchpad. Builds that aren't
   notarized are blocked the first time: open **System Settings → Privacy &
   Security** and click **Open Anyway** (or run
   `xattr -dr com.apple.quarantine /Applications/Terminal+.app`).

To start it from a shell, link the command once:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/Terminal+.app/Contents/MacOS/terminal+ /usr/local/bin/terminal+
```

**Requires:** macOS 14 or later on Apple silicon. FFmpeg is optional and
enables media viewing (`brew install ffmpeg`). ⌘ shortcuts mirror the Linux
Ctrl+Shift ones: ⌘C/⌘V copy and paste, ⌘N new window, ⌘W close tab, ⌘K clear,
⌘T remote machines, ⌘1…9 select tabs, ⌘+/⌘−/⌘0 zoom. Ctrl keeps its terminal
meaning, so Ctrl+C still interrupts.

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

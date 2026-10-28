# Terminal+

A fast Linux terminal with Vulkan rendering, persistent local and SSH sessions,
a file browser, and embedded Markdown/HTML previews. Native Wayland on Wayland desktops.

[Download the AppImage](https://github.com/sion3951/terminal-plus/releases/latest),
then install it:

```sh
chmod +x terminal+-*.AppImage
./terminal+-*.AppImage --install
terminal+
```

Linux x86_64; requires a Vulkan driver. `~/.local/bin` must be on your PATH.
Rendered document previews also require Chromium or Google Chrome.

Updates download automatically, verify signed releases, and install when you choose
**Update and restart**. Keep the AppImage somewhere you can write to.

Build from source: see [BUILD.md](BUILD.md). [MIT license](LICENSE).

# Platforms

- Linux: native Wayland with Vulkan.
- macOS: Apple silicon (arm64) only, with Metal in a Cocoa window. Do not add an Intel macOS build.
- Keep platform differences in `src/platform_linux.odin` / `src/platform_darwin.odin` and the per-backend renderers (`renderer.odin` for Vulkan, `renderer_darwin.odin` for Metal); shared code stays platform-neutral.

# Rendering requirements

- Never use XWayland for this application, including terminal UI, HTML, Markdown, or embedded document rendering.
- On Linux, require native Wayland. Do not add X11 support or switch to XWayland to work around embedding or scaling problems.
- On macOS, render through Metal only. Do not use OpenGL, MoltenVK, or another Vulkan translation layer.
- Keep document viewers inside the main application window while preserving sharp rendering at the monitor's actual scale.
- Render Markdown, HTML, CSS, and JavaScript through the native Odin document engine (Vulkan on Linux, Metal on macOS). Do not use Chromium, WebKit/WKWebView, or another browser engine.
- Decode images and videos with FFmpeg and display them inside the native window at physical framebuffer resolution. Do not add another media runtime (no AVFoundation playback on macOS).
- Do not change compositor or display scaling settings as a workaround.

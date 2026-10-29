# Rendering requirements

- Never use XWayland for this application, including terminal UI, HTML, Markdown, or embedded document rendering.
- Require native Wayland. Do not add X11 support or switch to XWayland to work around embedding or scaling problems.
- Keep document viewers inside the main application window while preserving sharp rendering at the monitor's actual scale.
- Render Markdown, HTML, CSS, and JavaScript through the native Odin/Vulkan document engine. Do not use Chromium or another browser engine.
- Decode images and videos with FFmpeg and display them inside the native Vulkan window at physical framebuffer resolution. Do not add another media runtime.
- Do not change compositor scaling settings as a workaround.

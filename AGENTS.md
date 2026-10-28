# Rendering requirements

- Never use XWayland for this application, including terminal UI, HTML, Markdown, or embedded document rendering.
- Use native Wayland on Wayland desktops. Do not switch to XWayland to work around embedding or scaling problems.
- Keep document viewers inside the main application window while preserving sharp rendering at the monitor's actual scale.
- Never substitute an external browser window for the embedded viewer. Composite browser output into the native Vulkan window at physical framebuffer resolution.
- Do not change compositor scaling settings as a workaround.

# Document engine

Markdown and HTML are parsed, laid out, scripted, and rendered natively in
Odin and Vulkan, inside the main window. There is no browser engine and no
extra library dependency. HTTP, TLS, and cookies reuse the existing curl
transport.

## Supported

- **HTML**: error recovery and named entities
- **CSS**: flex, grid, and positioned layout, plus dark mode
- **JavaScript**: classes, prototypes, regex, modules, promises, async/await,
  and DOM events
- **Canvas 2D**: geometry and text
- **Media**: images and SVG decoded by FFmpeg; `<audio>`/`<video>` open the media viewer
- **Navigation**: local, SSH, and HTTP; GET/POST forms and `fetch`
- **Viewer**: selection and copy, find, zoom, reload

Script and resource errors show up in the viewer.

## Not yet supported

- CSS transforms, keyframes, floats, subgrid, and full table sizing
- Complete HTML tree construction and foreign namespaces
- Generators, private class fields, top-level await, and exact ECMAScript semantics
- File uploads
- Canvas gradients and pixel operations, WebGL, and many other web APIs

## Examples and checks

`examples/html/index.html` links to sample layout, forms, scripts, canvas, and
media pages. Each page describes what you should see.

To run the pipeline headlessly, without a compositor:

```sh
./build/terminal --document-check examples/html/*.html
```

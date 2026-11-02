#version 450
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv;
layout(location=2) in vec4 color;
layout(location=3) in float texture_kind;
layout(location=4) in vec4 shape;
layout(location=0) out vec2 frag_uv;
layout(location=1) out vec4 frag_color;
layout(location=2) flat out float frag_texture;
layout(location=3) flat out vec4 frag_shape;
layout(push_constant) uniform Viewport { vec2 extent; } view;
void main() {
    gl_Position = vec4(position / view.extent * 2.0 - 1.0, 0, 1);
    frag_uv = uv;
    frag_color = color;
    frag_texture = texture_kind;
    frag_shape = shape;
}

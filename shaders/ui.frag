#version 450
layout(location=0) in vec2 frag_uv;
layout(location=1) in vec4 frag_color;
layout(location=2) flat in float frag_texture;
layout(location=0) out vec4 output_color;
layout(binding=0) uniform sampler2D atlas;
layout(binding=1) uniform sampler2D document_page;
void main() {
    if (frag_texture > 0.5) {
        output_color = texture(document_page, frag_uv) * frag_color;
        return;
    }
    // Glyph coordinates retain a 4096-row basis as the atlas grows.
    vec2 uv = frag_uv * vec2(1.0, 4096.0 / float(textureSize(atlas, 0).y));
    output_color = vec4(frag_color.rgb, frag_color.a * texture(atlas, uv).r);
}

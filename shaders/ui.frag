#version 450
layout(location=0) in vec2 frag_uv;
layout(location=1) in vec4 frag_color;
layout(location=2) flat in float frag_texture;
layout(location=3) flat in vec4 frag_shape;
layout(location=0) out vec4 output_color;
layout(binding=0) uniform sampler2D atlas;
layout(binding=1) uniform sampler2D document_page;
void main() {
    if (frag_texture > 3.5) {
        // Capsule stroke: UV runs along/across the segment in framebuffer
        // pixels, giving smooth edges and round caps at any monitor scale.
        vec2 nearest = vec2(clamp(frag_uv.x, 0.0, frag_shape.x), 0.0);
        float distance = length(frag_uv - nearest) - frag_shape.y;
        output_color = vec4(frag_color.rgb, frag_color.a * clamp(0.5 - distance, 0.0, 1.0));
        return;
    }
    if (frag_texture > 1.5) {
        // Rounded rectangle: UV is the pixel offset from the centre and shape
        // holds half extents, corner radius and either a border or blur width.
        vec2 q = abs(frag_uv) - frag_shape.xy + frag_shape.z;
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - frag_shape.z;
        float coverage;
        if (frag_texture > 2.5) {
            coverage = 1.0 - smoothstep(-frag_shape.w, frag_shape.w, distance);
        } else {
            if (frag_shape.w > 0.0) {distance = abs(distance + frag_shape.w * 0.5) - frag_shape.w * 0.5;}
            coverage = clamp(0.5 - distance, 0.0, 1.0);
        }
        output_color = vec4(frag_color.rgb, frag_color.a * coverage);
        return;
    }
    if (frag_texture > 0.5) {
        output_color = texture(document_page, frag_uv) * frag_color;
        return;
    }
    // Glyph coordinates retain a 4096-row basis as the atlas grows.
    vec2 uv = frag_uv * vec2(1.0, 4096.0 / float(textureSize(atlas, 0).y));
    output_color = vec4(frag_color.rgb, frag_color.a * texture(atlas, uv).r);
}

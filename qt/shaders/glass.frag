#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 region;          // the part of the blurred sheet behind this panel: x, y, width, height in 0..1
    vec2 size;            // the panel's size
    float radius;         // its corner radius
    vec4 tint;            // the panel's colour; its alpha is how much of it covers the blur
    vec4 backdropColor;   // what the sheet is drawn over, since the sheet itself is transparent where nothing is
    float saturation;
    float brightness;
};
layout(binding = 1) uniform sampler2D source;

// Signed distance to a rounded rectangle centred on the origin: negative inside.
float roundedBox(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// A panel of frosted glass: the blurred sheet behind it, a little more saturated, under the panel's tint, cut to a rounded
// rectangle with an antialiased edge.
void main() {
    vec2 px = qt_TexCoord0 * size;
    float mask = 1.0 - smoothstep(-0.5, 0.5, roundedBox(px - 0.5 * size, 0.5 * size, radius));
    vec4 blurred = texture(source, region.xy + qt_TexCoord0 * region.zw);
    vec3 rgb = blurred.rgb + backdropColor.rgb * (1.0 - blurred.a);      // premultiplied "over" the backdrop
    float grey = dot(rgb, vec3(0.299, 0.587, 0.114));
    rgb = mix(vec3(grey), rgb, saturation) + brightness;
    rgb = mix(rgb, tint.rgb, tint.a);
    // A gradient on a dark, blurred background spans only a few of the 256 levels, which shows as bands; a little noise of
    // half a level either way breaks them up.
    float noise = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
    rgb += noise / 255.0;
    fragColor = vec4(rgb, 1.0) * mask * qt_Opacity;
}

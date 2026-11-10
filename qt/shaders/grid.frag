#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;          // the item's size
    vec2 pan;           // where the grid's origin is
    float pitch;        // distance between dots
    float majorEvery;   // every how many dots one is stronger
    float minorRadius;
    float majorRadius;
    vec4 minorColor;
    vec4 majorColor;
};

// The drafting grid, one dot per intersection with every tenth stronger, worked out per pixel on the GPU: nothing is drawn
// on the CPU as the sheet pans or zooms, and the dots sit at exact positions.
void main() {
    vec2 p = qt_TexCoord0 * size - pan;
    vec2 cell = floor(p / pitch + 0.5);
    float d = length(p - cell * pitch);
    bool major = mod(cell.x, majorEvery) == 0.0 && mod(cell.y, majorEvery) == 0.0;
    float r = major ? majorRadius : minorRadius;
    float cover = 1.0 - smoothstep(r - 0.6, r + 0.6, d);
    vec4 c = major ? majorColor : minorColor;
    fragColor = vec4(c.rgb * c.a, c.a) * cover * qt_Opacity;
}

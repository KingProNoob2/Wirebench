#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 texel;     // the step to the next sample: (1/width, 0) for the horizontal pass, (0, 1/height) for the vertical one
    float sigma;    // the Gaussian's standard deviation, in texels
};
layout(binding = 1) uniform sampler2D source;

// One pass of a separable Gaussian blur. The two passes together give the exact 2-D Gaussian at 2N taps instead of N^2, and
// neighbouring pairs of taps are folded into one bilinear fetch placed between them (weights w1 and w2 at offsets 1 and 2
// become one weight w1+w2 at the weighted-mean offset), which halves the fetches again. Weights are computed here from sigma,
// so the radius can change every frame; the kernel runs to three sigma, where a Gaussian has all but 0.3% of its mass.
void main() {
    float s = max(sigma, 0.05);
    float k = -0.5 / (s * s);
    vec4 sum = texture(source, qt_TexCoord0);
    float total = 1.0;                                  // the centre tap has weight exp(0) = 1
    int pairs = min(int(ceil(3.0 * s * 0.5)), 40);
    for (int n = 0; n < pairs; ++n) {
        float a = float(2 * n + 1), b = float(2 * n + 2);
        float wa = exp(k * a * a), wb = exp(k * b * b);
        float w = wa + wb;
        vec2 offset = texel * ((a * wa + b * wb) / w);
        sum += w * (texture(source, qt_TexCoord0 + offset) + texture(source, qt_TexCoord0 - offset));
        total += 2.0 * w;
    }
    fragColor = sum / total * qt_Opacity;
}

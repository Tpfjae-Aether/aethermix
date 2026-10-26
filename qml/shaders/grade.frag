#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float hueShift;
    float sat;
    float bright;
    float tintAmt;
    float blurPx;
    vec4 tintCol;
    vec2 texel;
};

layout(binding = 1) uniform sampler2D source;

vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
    vec2 d = texel * blurPx;
    vec2 uv = qt_TexCoord0;
    vec4 c = texture(source, uv) * 0.2;
    c += texture(source, uv + vec2(d.x, 0.0)) * 0.0667;
    c += texture(source, uv - vec2(d.x, 0.0)) * 0.0667;
    c += texture(source, uv + vec2(0.0, d.y)) * 0.0667;
    c += texture(source, uv - vec2(0.0, d.y)) * 0.0667;
    c += texture(source, uv + vec2(d.x * 0.7, d.y * 0.7)) * 0.0667;
    c += texture(source, uv - vec2(d.x * 0.7, d.y * 0.7)) * 0.0667;
    c += texture(source, uv + vec2(d.x * 0.7, -d.y * 0.7)) * 0.0667;
    c += texture(source, uv - vec2(d.x * 0.7, -d.y * 0.7)) * 0.0667;
    c += texture(source, uv + vec2(d.x * 2.2, 0.0)) * 0.032;
    c += texture(source, uv - vec2(d.x * 2.2, 0.0)) * 0.032;
    c += texture(source, uv + vec2(0.0, d.y * 2.2)) * 0.032;
    c += texture(source, uv - vec2(0.0, d.y * 2.2)) * 0.032;

    vec3 hsv = rgb2hsv(c.rgb);
    hsv.x = fract(hsv.x + hueShift / 360.0);
    hsv.y = clamp(hsv.y * sat, 0.0, 1.0);
    vec3 rgb = hsv2rgb(hsv) * bright;
    rgb = mix(rgb, tintCol.rgb, clamp(tintAmt, 0.0, 1.0));
    fragColor = vec4(rgb, 1.0) * qt_Opacity;
}

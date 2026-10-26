#version 440
// The dye wash: a drop of ink meeting water.
//
// A room change used to be a slide. Here the whole window is briefly dyed from
// the point you travelled from: a turbulent bloom, filaments pulling away from
// it, the incoming palette in the ink, and then it is gone by the time the new
// page has settled. It reads *through* the interface, so the type is never
// hidden - only tinted for a beat.
//
// Baked with Qt's shader tools (Qt 6 has no runtime GLSL):
//   qsb --glsl 100es,120,150 --hlsl 50 --msl 12 -o dye.frag.qsb dye.frag
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;
    float seed;
    vec2 origin;
    vec4 inkA;
    vec4 inkB;
    float strength;
    float grain;
};

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float amp = 0.55;
    for (int i = 0; i < 4; i++) {
        v += amp * vnoise(p);
        p = p * 2.03 + 11.7;
        amp *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 p = (uv - origin) * vec2(1.78, 1.0);
    float t = clamp(progress, 0.0, 1.0);

    // the drop spreads: early frames are tight and dense, later ones are thin,
    // far filaments that have almost let go of the colour
    float spread = 0.055 + t * 0.62;
    vec2 q = p / spread + vec2(seed * 7.3, seed * 3.1);
    float warp = fbm(q * 1.15 + vec2(0.0, t * 0.55));
    float wisps = fbm(q * 2.35 + warp * 1.35 - t * 0.9);
    float body = fbm(q * 4.6 - warp * 0.6 + t * 1.4);

    // A round bloom that fades with distance, then turbulent holes. The peak
    // was 0.72: at full strength that painted ~0.5 of solid accent over the
    // whole window, which on a neon palette is a green flash rather than a
    // dye. 0.34 with a higher density floor keeps the bloom as a tint you
    // read *through*, never a surface that replaces the room.
    float radial = 1.0 - smoothstep(0.02, 1.15, length(p) / (0.30 + t * 1.30));
    float density = wisps * 0.62 + body * 0.28 + radial * 0.42;
    float a = smoothstep(0.42, 0.92, density);
    a *= 0.72 * (1.0 - smoothstep(0.30, 1.0, t));

    // a brighter thread along the leading edge of the ink
    float rim = 1.0 - smoothstep(0.0, 0.045, abs(density - 0.63));
    rim *= (1.0 - t) * 0.28;

    // the room's own ink dominates and the accent rides on the filaments:
    // mixing 85% toward the accent made every drop a flat colour field.
    vec3 col = mix(inkB.rgb, inkA.rgb, clamp(wisps * 0.85 + 0.20, 0.0, 1.0));
    col += inkA.rgb * rim * 1.4;

    // faint drifting grain so the wash never bands on a dark room
    col += (hash(uv * 900.0 + seed) - 0.5) * 0.012 * grain;

    float alpha = clamp((a + rim) * strength, 0.0, 1.0);
    fragColor = vec4(col, alpha * qt_Opacity);
}

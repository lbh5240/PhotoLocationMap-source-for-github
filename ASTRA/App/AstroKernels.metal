#include <CoreImage/CoreImage.h>
using namespace metal;

[[stitchable]] float4 astroStretch(coreimage::sample_t source, coreimage::sample_t smooth,
                    coreimage::sample_t background,
                    float arc, float masked, float gradient, float nebula, float protect) {
    float3 rgb = max(source.rgb - gradient * (background.rgb - float3(0.015)), float3(0.0));
    float3 low = max(smooth.rgb - gradient * (background.rgb - float3(0.015)), float3(0.0));
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float lowL = dot(low, float3(0.2126, 0.7152, 0.0722));
    float star = smoothstep(0.015, 0.09, max(l - lowL, 0.0));
    float3 base = mix(rgb, low, star * protect);
    float y = dot(base, float3(0.2126, 0.7152, 0.0722));
    float strength = max(arc, 0.001);
    float stretched = arc > 0.0 ? asinh(strength * y) / asinh(strength) : y;
    float core = masked * smoothstep(0.18, 0.75, y);
    float target = mix(stretched, min(y, 1.0), core);
    float3 color = base * (target / max(y, 0.000001));
    float gas = (1.0 - star * protect) * smoothstep(0.012, 0.16, lowL) *
                (1.0 - smoothstep(0.55, 0.9, lowL));
    color = mix(color, max(color * 1.55 +
                           (color - float3(dot(color, float3(0.2126, 0.7152, 0.0722)))) * 0.18,
                           float3(0.0)), gas * nebula);
    color += max(rgb - low, float3(0.0)) * star * protect;
    return float4(color, source.a);
}

[[stitchable]] float4 astroSTF(coreimage::sample_t source, float black, float white) {
    float3 rgb = max(source.rgb - float3(black), float3(0.0));
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float mapped = asinh(8.0 * l / max(white - black, 0.00001)) / asinh(8.0);
    return float4(rgb * (mapped / max(l, 0.000001)), source.a);
}

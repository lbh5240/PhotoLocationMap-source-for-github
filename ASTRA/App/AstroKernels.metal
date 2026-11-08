#include <CoreImage/CoreImage.h>
using namespace metal;

[[stitchable]] float4 astroStretch(coreimage::sample_t source, coreimage::sample_t smooth,
                    coreimage::sample_t background,
                    float arc, float masked, float gradient, float nebula, float protect,
                    float neutral, float green, float reduceStars, float structure, float starColor) {
    float3 sky = background.rgb;
    float skyL = dot(sky, float3(0.2126, 0.7152, 0.0722));
    float3 cast = neutral * (sky - float3(skyL));
    float3 rgb = max(source.rgb - gradient * (sky - float3(0.015)) - cast, float3(0.0));
    float3 low = max(smooth.rgb - gradient * (sky - float3(0.015)) - cast, float3(0.0));
    rgb.g -= green * max(0.0, rgb.g - (rgb.r + rgb.b) * 0.5);
    low.g -= green * max(0.0, low.g - (low.r + low.b) * 0.5);
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float lowL = dot(low, float3(0.2126, 0.7152, 0.0722));
    float star = smoothstep(0.015, 0.09, max(l - lowL, 0.0));
    float3 base = mix(rgb, low, star * min(1.0, protect + reduceStars * (1.0 - protect)));
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
    float3 starSignal = max(rgb - low, float3(0.0)) * star * protect * (1.0 - reduceStars);
    float starL = dot(starSignal, float3(0.2126, 0.7152, 0.0722));
    color += max(float3(starL) + (starSignal - float3(starL)) * (1.0 + starColor), float3(0.0));
    float cloud = (1.0 - star) * smoothstep(0.006, 0.09, lowL);
    color = max(color + (low - sky) * structure * cloud, float3(0.0));
    return float4(color, source.a);
}

[[stitchable]] float4 astroSTF(coreimage::sample_t source, float black, float white) {
    float3 rgb = max(source.rgb - float3(black), float3(0.0));
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float mapped = asinh(8.0 * l / max(white - black, 0.00001)) / asinh(8.0);
    return float4(rgb * (mapped / max(l, 0.000001)), source.a);
}

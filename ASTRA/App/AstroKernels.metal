#include <CoreImage/CoreImage.h>
using namespace metal;

[[stitchable]] float4 astroStretch(coreimage::sample_t source, coreimage::sample_t smooth,
                    coreimage::sample_t background,
                    float arc, float masked, float gradient, float nebula, float protect,
                    float neutral, float green, float reduceStars, float structure, float starColor) {
    float3 sky = background.rgb;
    float skyL = dot(sky, float3(0.2126, 0.7152, 0.0722));
    float3 cast = neutral * (sky - float3(skyL));
    float3 raw = source.rgb - gradient * (sky - float3(0.012)) - cast;
    float3 filtered = smooth.rgb - gradient * (sky - float3(0.012)) - cast;
    // A differentiable floor avoids abrupt black contours around diffuse nebulosity.
    float3 rgb = 0.5 * (raw + sqrt(raw * raw + float3(0.000001)));
    float3 low = 0.5 * (filtered + sqrt(filtered * filtered + float3(0.000001)));
    rgb.g -= green * max(0.0, rgb.g - (rgb.r + rgb.b) * 0.5);
    low.g -= green * max(0.0, low.g - (low.r + low.b) * 0.5);
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float lowL = dot(low, float3(0.2126, 0.7152, 0.0722));
    float residual = max(l - lowL, 0.0);
    float star = residual / (residual + 0.035);
    float3 base = mix(rgb, low, star * min(1.0, protect + reduceStars * (1.0 - protect)));
    float y = dot(base, float3(0.2126, 0.7152, 0.0722));
    float strength = max(arc, 0.001);
    float stretched = arc > 0.0 ? asinh(strength * y) / asinh(strength) : y;
    float core = masked * y / (y + 0.22);
    float target = mix(stretched, min(y, 1.0), core);
    float3 color = base * (target / max(y, 0.000001));
    float chroma = length(low - float3(lowL));
    float gas = (1.0 - star * protect) * lowL / (lowL + 0.035) *
                (0.45 + 0.55 * chroma / (chroma + 0.035)) / (1.0 + 3.0 * lowL);
    color = mix(color, max(color * 1.4 +
                           (color - float3(dot(color, float3(0.2126, 0.7152, 0.0722)))) * 0.12,
                           float3(0.0)), min(gas * nebula, 0.8));
    float3 starSignal = max(rgb - low, float3(0.0)) * star * protect * (1.0 - reduceStars);
    float starL = dot(starSignal, float3(0.2126, 0.7152, 0.0722));
    color += max(float3(starL) + (starSignal - float3(starL)) * (1.0 + starColor), float3(0.0));
    float cloud = (1.0 - star) * lowL / (lowL + 0.04);
    color = max(color + (low - sky) * structure * 0.35 * cloud, float3(0.0));
    return float4(color, source.a);
}

[[stitchable]] float4 astroSTF(coreimage::sample_t source, float blackR, float blackG,
                              float blackB, float white, float method) {
    float3 black = float3(blackR, blackG, blackB);
    float3 rgb = max(source.rgb - black, float3(0.0));
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float sky = dot(black, float3(0.2126, 0.7152, 0.0722));
    float x = l / max(white - sky, 0.00001);
    float mapped;
    if (method < 0.5) {
        // Colour-preserving arcsinh with a continuous shoulder.
        mapped = 1.0 - exp(-1.7 * asinh(8.0 * x) / asinh(8.0));
    } else if (method < 1.5) {
        // Logarithmic compression retains contrast in a bright nebular core.
        mapped = 1.0 - exp(-1.1 * log(1.0 + 3.0 * x) / log(4.0));
    } else {
        // Rational hyperbolic lift puts more emphasis on faint outer gas.
        mapped = 1.0 - exp(-2.0 * x / (x + 0.35));
    }
    float3 output = rgb * (mapped / max(l, 0.000001));
    output /= max(1.0, max(output.r, max(output.g, output.b)));
    return float4(output, source.a);
}

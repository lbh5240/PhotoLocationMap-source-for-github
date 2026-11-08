#include <CoreImage/CoreImage.h>
using namespace metal;

[[stitchable]] float4 astroStretch(coreimage::sample_t source, coreimage::sample_t smooth,
                    coreimage::sample_t background, coreimage::sample_t skyGradient,
                    float arc, float masked, float gradient, float adaptive, float nebula, float protect,
                    float neutral, float green, float reduceStars, float structure, float starColor) {
    float3 sky = background.rgb;
    float skyL = dot(sky, float3(0.2126, 0.7152, 0.0722));
    float3 cast = neutral * (sky - float3(skyL));
    float3 correction = gradient * (sky - float3(0.012)) + adaptive * skyGradient.r + cast;
    float3 raw = source.rgb - correction;
    float3 filtered = smooth.rgb - correction;
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
    color = max(color + (low - float3(0.012)) * structure * 0.2 * cloud, float3(0.0));
    return float4(color, source.a);
}

[[stitchable]] float4 astroSTF(coreimage::sample_t source, float blackR, float blackG,
                              float blackB, float white, float method, float skyNoise, float midtone, float adaptive, float shadowKnee,
                              float dehazeStrength, float colorRecovery) {
    float3 black = float3(blackR, blackG, blackB);
    float sky = dot(black, float3(0.2126, 0.7152, 0.0722));
    float toe = max((white - sky) * 0.02, 0.0005);
    float3 delta = source.rgb - black;
    float3 rgb = 0.5 * (delta + sqrt(delta * delta + float3(toe * toe)));
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    const float span = max(white - sky, 0.005);
    const float signedSignal = dot(delta, float3(0.2126, 0.7152, 0.0722)) / span;
    const float chroma = (max(delta.r, max(delta.g, delta.b)) - min(delta.r, min(delta.g, delta.b))) / span;
    const float noiseFloor = max(0.008, 2.5 * skyNoise / span);
    const float colorSignal = smoothstep(noiseFloor, noiseFloor + 0.13, chroma);
    float x = l / max(white - sky, 0.00001);
    if (adaptive > 0.5 && shadowKnee > 0.0) {
        // Compute signed luminance before the per-channel colour floor.
        // Applying the floor first would turn zero-mean sky noise into glow.
        const float rounding = min(0.002, 0.025 * shadowKnee);
        const float signal = 0.5 * (signedSignal +
            sqrt(signedSignal * signedSignal + rounding * rounding));
        // Smoothly restore unity gain before the brightest parts of the nebula.
        const float extra = max(0.0, dehazeStrength - 1.0);
        const float knee = shadowKnee + min(0.96 - shadowKnee, 0.48 * shadowKnee + 0.09) *
                           extra * mix(1.0, 0.24, colorSignal);
        const float corrected = signal * mix(0.02, 1.0, smoothstep(0.0, knee, signal));
        x = mix(x, corrected, min(dehazeStrength, 1.0));
    } else if (adaptive > 0.5 && (method < 2.5 || method >= 3.5)) {
        // Limit the gain near the measured noise floor across all adaptive curves.
        const float knee = clamp(2.0 * skyNoise / max(white - sky, 0.005), 0.0, 0.20);
        x *= x / max(x + knee, 0.000001);
    }
    float mapped;
    if (method < 0.5) {
        // Colour-preserving arcsinh with a continuous shoulder.
        mapped = 1.0 - exp(-1.7 * asinh(8.0 * x) / asinh(8.0));
    } else if (method < 1.5) {
        // Logarithmic compression retains contrast in a bright nebular core.
        mapped = 1.0 - exp(-1.1 * log(1.0 + 3.0 * x) / log(4.0));
    } else if (method < 2.5) {
        // Rational hyperbolic lift puts more emphasis on faint outer gas.
        mapped = 1.0 - exp(-2.0 * x / (x + 0.35));
    } else if (method < 3.5) {
        // Smoothly attenuate the stretch near the measured sky-noise floor.
        const float knee = clamp(2.5 * skyNoise / max(white - sky, 0.005), 0.015, 0.18);
        const float signal = x * (x / (x + knee));
        mapped = 1.0 - exp(-1.7 * asinh(8.0 * signal) / asinh(8.0));
    } else {
        // MTF on linked luminance with an open highlight shoulder. Solve the
        // midtones balance to move the measured upper midtones toward 0.42.
        const float target = 0.42;
        const float anchorSignal = 2.0 * max(midtone, 0.0);
        const float anchor = clamp(anchorSignal / (1.0 + anchorSignal), 0.06, 0.65);
        const float m = clamp(anchor * (1.0 - target) /
                              (target + anchor * (1.0 - 2.0 * target)), 0.20, 0.66);
        const float u = 2.0 * x / (1.0 + 2.0 * x);
        mapped = (1.0 - m) * u / (m + (1.0 - 2.0 * m) * u);
    }
    // Chroma in the sky is dominated by read noise and colour differences in
    // the background model. Fade it in continuously as genuine signal rises.
    float chromaWeight = smoothstep(0.015, 0.24, x);
    // Recover measured colour from the input signal independently of the
    // shadow curve. Guard the noise floor and taper near bright stellar cores.
    const float recovery = colorRecovery * colorSignal * smoothstep(0.025, 0.16, signedSignal) *
                           (1.0 - smoothstep(0.7, 1.25, signedSignal));
    const float colorGain = chromaWeight + (1.10 - chromaWeight) * recovery;
    float3 balanced = max(float3(l) + (rgb - float3(l)) * colorGain, float3(0.0));
    float3 output = balanced * (mapped / max(l, 0.000001));
    output /= max(1.0, max(output.r, max(output.g, output.b)));
    return float4(output, source.a);
}


[[stitchable]] float4 astroSpikeSeeds(coreimage::sample_t source, coreimage::sample_t broad,
                                   coreimage::sample_t selected) {
    const float3 weights = float3(0.2126, 0.7152, 0.0722);
    const float l = dot(source.rgb, weights);
    const float local = dot(broad.rgb, weights);
    // Positions are already filtered for compactness on the linear image.
    // Seed the rays from local stellar contrast without a second brightness cut.
    const float contrast = clamp((l - local) / max(l, 0.00001), 0.0, 1.0);
    return float4(clamp(source.rgb, 0.0, 1.0) * contrast * selected.r, source.a);
}

[[stitchable]] float4 astroSpikeComposite(coreimage::sample_t source, coreimage::sample_t rays, float gain) {
    const float3 light = 1.0 - exp(-max(rays.rgb, float3(0.0)) * gain);
    const float3 rgb = source.rgb + (1.0 - clamp(source.rgb, 0.0, 1.0)) * light * source.a;
    return float4(rgb, source.a);
}

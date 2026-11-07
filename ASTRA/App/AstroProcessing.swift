import CoreImage
import CoreGraphics
import Foundation

struct AstroProfile {
    let background: CIImage
    let black: Float
    let white: Float
}

enum AstroProcessing {
    // Work in extended linear RGB. These kernels alter a rendered view only;
    // the Float32 stack file is never rewritten by editing or STF.
    private static let stretchKernel = CIColorKernel(source: """
    kernel vec4 astroStretch(__sample source, __sample smooth, __sample background,
                             float arc, float masked, float gradient, float nebula, float protect) {
        vec3 rgb = max(source.rgb - gradient * (background.rgb - vec3(0.015)), vec3(0.0));
        vec3 low = max(smooth.rgb - gradient * (background.rgb - vec3(0.015)), vec3(0.0));
        float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        float lowL = dot(low, vec3(0.2126, 0.7152, 0.0722));
        float star = smoothstep(0.015, 0.09, max(l - lowL, 0.0));
        vec3 base = mix(rgb, low, star * protect);
        float y = dot(base, vec3(0.2126, 0.7152, 0.0722));
        float strength = max(arc, 0.001);
        float stretch = log(strength * y + sqrt(1.0 + strength * strength * y * y)) /
                        log(strength + sqrt(1.0 + strength * strength));
        float core = masked * smoothstep(0.18, 0.75, y);
        float target = mix(stretch, min(y, 1.0), core);
        vec3 color = base * (target / max(y, 0.000001));
        float gas = (1.0 - star * protect) * smoothstep(0.012, 0.16, lowL) *
                    (1.0 - smoothstep(0.55, 0.9, lowL));
        color = mix(color, max(color * 1.55 +
                               (color - vec3(dot(color, vec3(0.2126, 0.7152, 0.0722)))) * 0.18,
                               vec3(0.0)), gas * nebula);
        color += max(rgb - low, vec3(0.0)) * star * protect;
        return vec4(color, source.a);
    }
    """)

    private static let stfKernel = CIColorKernel(source: """
    kernel vec4 astroSTF(__sample source, float black, float white) {
        vec3 rgb = max(source.rgb - vec3(black), vec3(0.0));
        float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        float value = 8.0 * l / max(white - black, 0.00001);
        float mapped = log(value + sqrt(1.0 + value * value)) / log(8.0 + sqrt(65.0));
        return vec4(rgb * (mapped / max(l, 0.000001)), source.a);
    }
    """)

    static func process(_ image: CIImage, adjustments: Adjustments, profile: AstroProfile) throws -> CIImage {
        let arc = adjustments.arcsinh ?? 0
        let masked = adjustments.maskedStretch ?? 0
        let gradient = adjustments.gradientRemoval ?? 0
        let gas = adjustments.nebulaContrast ?? 0
        let protect = adjustments.starProtection ?? 1
        guard arc > 0 || gradient > 0 || gas > 0 else { return image }
        let blur = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7]).cropped(to: image.extent)
        let bg = profile.background.transformed(by: CGAffineTransform(scaleX: image.extent.width / profile.background.extent.width,
                                                                       y: image.extent.height / profile.background.extent.height))
        guard let result = stretchKernel?.apply(extent: image.extent, arguments: [image, blur, bg, arc, masked, gradient, gas, protect]) else {
            throw AstroError.message("星云处理内核不可用，请检查设备系统版本")
        }
        return result
    }

    static func screenStretch(_ image: CIImage, profile: AstroProfile) throws -> CIImage {
        guard let result = stfKernel?.apply(extent: image.extent, arguments: [image, profile.black, profile.white]) else {
            throw AstroError.message("STF 预览内核不可用，请检查设备系统版本")
        }
        return result
    }

    static func profile(_ data: Data, width: Int, height: Int, linear: CGColorSpace,
                        bitmapRowsTopFirst: Bool) -> AstroProfile {
        let gw = 12, gh = 8
        var cells = [[Float]](repeating: [0, 0, 0], count: gw * gh)
        var light: [Float] = []
        data.withUnsafeBytes { bytes in
            let p = bytes.bindMemory(to: Float.self)
            for gy in 0..<gh { for gx in 0..<gw {
                var samples: [(Float, [Float])] = []
                for y in (gy*height/gh)..<((gy+1)*height/gh) {
                    for x in (gx*width/gw)..<((gx+1)*width/gw) {
                        let offset = (y * width + x) * 4
                        guard p[offset+3] > 0.5 else { continue }
                        let rgb = [p[offset],p[offset+1],p[offset+2]]
                        let l = 0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2]
                        guard l.isFinite else { continue }
                        samples.append((l,rgb));light.append(l)
                    }
                }
                samples.sort { $0.0 < $1.0 }
                if !samples.isEmpty { cells[gy*gw+gx] = samples[min(samples.count-1, samples.count/5)].1 }
            } }
        }
        light.sort()
        let black = light.isEmpty ? 0 : light[min(light.count-1, light.count/100)]
        let white = light.isEmpty ? 1 : light[min(light.count-1, light.count*995/1000)]
        var grid = [Float](repeating: 1, count: gw*gh*4)
        for y in 0..<gh { for x in 0..<gw { for c in 0..<3 {
            var local = Float.greatestFiniteMagnitude
            for dy in -1...1 { for dx in -1...1 {
                let nx = min(gw-1,max(0,x+dx)),ny = min(gh-1,max(0,y+dy))
                local = min(local,cells[ny*gw+nx][c])
            } }
            grid[(y*gw+x)*4+c] = local.isFinite ? local : 0
        } } }
        let bytes = grid.withUnsafeBytes { Data($0) }
        var background = CIImage(bitmapData: bytes, bytesPerRow: gw*16,
                                 size: CGSize(width: gw,height: gh), format: .RGBAf, colorSpace: linear)
        if bitmapRowsTopFirst { background = background.oriented(.downMirrored) }
        return AstroProfile(background: background, black: max(0,black), white: max(white,black+0.005))
    }
}

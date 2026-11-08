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
    private static let library: Result<Data, Error> = Result {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            throw AstroError.message("星云处理资源缺失，请重新安装 ASTRA")
        }
        return try Data(contentsOf: url)
    }
    private static let stretchKernel: Result<CIColorKernel, Error> = Result {
        try CIColorKernel(functionName: "astroStretch", fromMetalLibraryData: library.get())
    }
    private static let stfKernel: Result<CIColorKernel, Error> = Result {
        try CIColorKernel(functionName: "astroSTF", fromMetalLibraryData: library.get())
    }

    static func process(_ image: CIImage, adjustments: Adjustments, profile: AstroProfile) throws -> CIImage {
        let arc = adjustments.arcsinh ?? 0
        let masked = adjustments.maskedStretch ?? 0
        let gradient = adjustments.gradientRemoval ?? 0
        let gas = adjustments.nebulaContrast ?? 0
        let protect = adjustments.starProtection ?? 1
        let neutral = adjustments.backgroundNeutralization ?? 0
        let green = adjustments.greenSuppression ?? 0
        let reduceStars = adjustments.starReduction ?? 0
        let structure = adjustments.nebulaStructure ?? 0
        let starColor = adjustments.starSaturation ?? 0
        guard arc > 0 || gradient > 0 || gas > 0 || neutral > 0 || green > 0 ||
              reduceStars > 0 || structure > 0 || starColor > 0 else { return image }
        // Match the same angular blur in the 1600 px proxy and full-resolution export.
        let radius = max(1, max(image.extent.width, image.extent.height) / 1600 * 7)
        let blur = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: image.extent)
        let bg = profile.background.transformed(by: CGAffineTransform(scaleX: image.extent.width / profile.background.extent.width,
                                                                       y: image.extent.height / profile.background.extent.height))
        guard let result = try stretchKernel.get().apply(extent: image.extent,
            arguments: [image, blur, bg, arc, masked, gradient, gas, protect,
                        neutral, green, reduceStars, structure, starColor]) else {
            throw AstroError.message("星云处理渲染失败，请重试")
        }
        return result
    }

    static func screenStretch(_ image: CIImage, profile: AstroProfile) throws -> CIImage {
        guard let result = try stfKernel.get().apply(extent: image.extent, arguments: [image, profile.black, profile.white]) else {
            throw AstroError.message("STF 预览渲染失败，请重试")
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

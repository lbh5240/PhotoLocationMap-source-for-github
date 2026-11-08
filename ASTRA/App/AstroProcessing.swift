import CoreImage
import CoreGraphics
import Foundation

struct AstroProfile {
    let background: CIImage
    let black: Float
    let white: Float
    let blackRGB: [Float]
    let skyNoise: Float
    let midtone: Float
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

    static func screenStretch(_ image: CIImage, profile: AstroProfile, adjustments: Adjustments = .neutral) throws -> CIImage {
        let black = Float(adjustments.autoBlack ?? Double(profile.black))
        let white = Float(adjustments.autoWhite ?? Double(profile.white))
        let red = Float(adjustments.autoBlackRed ?? Double(profile.blackRGB[0]))
        let green = Float(adjustments.autoBlackGreen ?? Double(profile.blackRGB[1]))
        let blue = Float(adjustments.autoBlackBlue ?? Double(profile.blackRGB[2]))
        guard let result = try stfKernel.get().apply(extent: image.extent,
            arguments: [image, red, green, blue, max(white, black + 0.005),
                        Float(adjustments.developMethod?.rawValue ?? 0), profile.skyNoise, profile.midtone]) else {
            throw AstroError.message("STF 预览渲染失败，请重试")
        }
        return result
    }

    static func profile(_ data: Data, width: Int, height: Int, linear: CGColorSpace,
                        bitmapRowsTopFirst: Bool) -> AstroProfile {
        let gw = 12, gh = 8
        var cells = [[Float]](repeating: [0, 0, 0], count: gw * gh)
        var light: [Float] = [], channels = [[Float]](repeating: [], count: 3)
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
                        for c in 0..<3 { channels[c].append(rgb[c]) }
                    }
                }
                samples.sort { $0.0 < $1.0 }
                if !samples.isEmpty { cells[gy*gw+gx] = samples[min(samples.count-1, samples.count/5)].1 }
            } }
        }
        light.sort()
        // The first percentile comes from the vignetted corners. Stretching from
        // there makes the actual sky gray and amplifies its colour noise.
        let blackRGB: [Float] = channels.map { values in
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return max(0, sorted[min(sorted.count-1, sorted.count*55/100)])
        }
        let black = 0.2126*blackRGB[0] + 0.7152*blackRGB[1] + 0.0722*blackRGB[2]
        let white = light.isEmpty ? 1 : light[min(light.count-1, light.count*995/1000)]
        let span = max(white - black, 0.005)
        let upperSky = light.isEmpty ? black : light[light.count * 75 / 100]
        let midtone = light.isEmpty ? 0.15 : (light[light.count * 90 / 100] - black) / span
        // Adjacent differences suppress slow gradients. Only use valid sky pixels
        // to keep stars, cloud structure and the registration border out of the estimate.
        let skyNoise: Float = data.withUnsafeBytes { bytes in
            let p = bytes.bindMemory(to: Float.self)
            func luma(_ i: Int) -> Float { 0.2126*p[i] + 0.7152*p[i+1] + 0.0722*p[i+2] }
            var differences: [Float] = []
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width - 1, by: 2) {
                    let i = (y*width+x)*4, j = i+4
                    guard p[i+3] > 0.98, p[j+3] > 0.98 else { continue }
                    let a = luma(i), b = luma(j)
                    if a.isFinite, b.isFinite, max(a,b) <= upperSky {
                        differences.append(abs(a-b))
                    }
                }
            }
            guard differences.count >= 16 else { return 0 }
            differences.sort()
            return 1.0484 * differences[differences.count / 2]
        }
        let levels = cells.map { 0.2126*$0[0] + 0.7152*$0[1] + 0.0722*$0[2] }.sorted()
        let floor = max(0.005, levels[levels.count / 3])
        var grid = [Float](repeating: 1, count: gw*gh*4)
        for y in 0..<gh { for x in 0..<gw { for c in 0..<3 {
            var sum: Float = 0, total: Float = 0
            for dy in -2...2 { for dx in -2...2 {
                let nx = min(gw-1,max(0,x+dx)),ny = min(gh-1,max(0,y+dy))
                let v = cells[ny*gw+nx]
                let l = 0.2126*v[0] + 0.7152*v[1] + 0.0722*v[2]
                let excess = max(0, l - floor) / floor
                let distance = Float(dx*dx + dy*dy)
                let weight = exp(-distance * 0.38) / (1 + excess * 5)
                sum += v[c] * weight; total += weight
            } }
            grid[(y*gw+x)*4+c] = total > 0 ? sum / total : 0
        } } }
        let bytes = grid.withUnsafeBytes { Data($0) }
        var background = CIImage(bitmapData: bytes, bytesPerRow: gw*16,
                                 size: CGSize(width: gw,height: gh), format: .RGBAf, colorSpace: linear)
        if bitmapRowsTopFirst { background = background.oriented(.downMirrored) }
        background = background.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.9])
            .cropped(to: CGRect(x: 0, y: 0, width: gw, height: gh))
        return AstroProfile(background: background, black: max(0,black), white: black+span, blackRGB: blackRGB, skyNoise: skyNoise, midtone: midtone)
    }
}

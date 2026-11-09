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
    let skyGradient: CIImage?
    let skyGradientLinear: CIImage?
    let skySpread: Double
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

    private static let spikeSeeds: Result<CIColorKernel, Error> = Result {
        try CIColorKernel(functionName: "astroSpikeSeeds", fromMetalLibraryData: library.get())
    }
    private static let spikeComposite: Result<CIColorKernel, Error> = Result {
        try CIColorKernel(functionName: "astroSpikeComposite", fromMetalLibraryData: library.get())
    }

    static func addStarSpikes(_ image: CIImage, selection: CIImage?, adjustments: Adjustments) throws -> CIImage {
        let style = adjustments.starSpikeStyle ?? .off
        let strength = min(1, max(0, adjustments.starSpikeStrength ?? 0.38))
        guard style != .off, strength > 0, let selection else { return image }
        let extent = image.extent
        let size = max(extent.width, extent.height)
        let broad = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1.1, size * 0.0025)])
            .cropped(to: extent)
        guard let seeds = try spikeSeeds.get().apply(extent: extent, arguments: [image, broad, selection]) else {
            throw AstroError.message("星芒亮星检测失败")
        }
        let sixthTurn = Double.pi / 6
        let angles: [Double] = style == .four
            ? [0, Double.pi / 2]
            : [sixthTurn, 3 * sixthTurn, 5 * sixthTurn]
        let radius = max(1.5, size * 0.005)
        let rays = angles.map { angle -> CIImage in
            let parameters: [String: Any] = [kCIInputRadiusKey: radius, kCIInputAngleKey: angle]
            // Repeated convolution produces a smooth taper instead of a hard line.
            return seeds.applyingFilter("CIMotionBlur", parameters: parameters)
                .applyingFilter("CIMotionBlur", parameters: parameters)
                .applyingFilter("CIMotionBlur", parameters: parameters)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.35, size * 0.00035)])
                .cropped(to: extent)
        }
        let combined = rays.dropFirst().reduce(rays[0]) { sum, next in
            next.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sum])
        }
        let gain = Float(strength * 1.6 / sqrt(Double(angles.count)))
        guard let result = try spikeComposite.get().apply(extent: extent, arguments: [image, combined, gain]) else {
            throw AstroError.message("星芒合成失败")
        }
        return result
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
        let method = adjustments.dehazeMethod ?? .balanced
        let skyModel = method == .gentle ? (profile.skyGradientLinear ?? profile.skyGradient) : profile.skyGradient
        let gradientMap = adjustments.adaptiveSky == true ? skyModel : nil
        let modeled = gradientMap.map {
            $0.transformed(by: CGAffineTransform(scaleX: image.extent.width / $0.extent.width,
                                                 y: image.extent.height / $0.extent.height)).clampedToExtent()
        }
        guard let result = try stretchKernel.get().apply(extent: image.extent,
            arguments: [image, blur, bg, modeled ?? bg, arc, masked,
                        modeled == nil ? gradient : 0, modeled == nil ? 0 : gradient, gas, protect,
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
                        Float(adjustments.developMethod?.rawValue ?? 0),
                        Float(adjustments.adaptiveSkyNoise ?? Double(profile.skyNoise)),
                        Float(adjustments.autoMidtone ?? Double(profile.midtone)),
                        adjustments.adaptiveSky == true ? Float(1) : Float(0),
                        Float(adjustments.adaptiveShadowKnee ?? 0),
                        Float(min(2, max(0, adjustments.dehazeStrength ?? 1))),
                        Float(min(1, max(0, adjustments.nebulaColorRecovery ?? 0))),
                        (adjustments.dehazeMethod ?? .balanced).shaderValue]) else {
            throw AstroError.message("STF 预览渲染失败，请重试")
        }
        return result
    }

    static func profile(_ data: Data, width: Int, height: Int, linear: CGColorSpace,
                        bitmapRowsTopFirst: Bool) -> AstroProfile {
        let gw = 12, gh = 8
        var cells = [[Float]](repeating: [0, 0, 0], count: gw * gh)
        var tiles: [AutoDevelop.SkyTile] = []
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
                if !samples.isEmpty { cells[gy*gw+gx] = samples[samples.count/5].1 }
                let area = ((gy+1)*height/gh - gy*height/gh) * ((gx+1)*width/gw - gx*width/gw)
                if samples.count >= max(12, area * 4 / 5) {
                    tiles.append(.init(x: (Double(gx) + 0.5) * 2 / Double(gw) - 1,
                                       y: (Double(gy) + 0.5) * 2 / Double(gh) - 1,
                                       level: Double(samples[samples.count * 35 / 100].0)))
                }
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
        let skyNoise = AutoDevelop.skyNoise((data, width, height, 1)) ?? 0
        func makeGradient(linearModel: Bool) -> (CIImage?, Double) {
            guard let surface = AutoDevelop.fitSky(tiles, noise: skyNoise, linear: linearModel) else {
                return (nil, 0)
            }
            let fitted = tiles.map { surface.value(x: $0.x, y: $0.y) }.sorted()
            let baseline = fitted[fitted.count/2]
            let spread = fitted[fitted.count*9/10] - fitted[fitted.count/10]
            var residual = [Float](repeating: 1, count: gw*gh*4)
            for y in 0..<gh { for x in 0..<gw {
                let value = surface.value(x: (Double(x)+0.5)*2/Double(gw)-1,
                                          y: (Double(y)+0.5)*2/Double(gh)-1)
                for c in 0..<3 { residual[(y*gw+x)*4+c] = Float(value - baseline) }
            } }
            let map = CIImage(bitmapData: residual.withUnsafeBytes { Data($0) }, bytesPerRow: gw*16,
                              size: CGSize(width: gw, height: gh), format: .RGBAf, colorSpace: linear)
            return (bitmapRowsTopFirst ? map.oriented(.downMirrored) : map, spread)
        }
        let (skyGradient, skySpread) = makeGradient(linearModel: false)
        let (skyGradientLinear, _) = makeGradient(linearModel: true)
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
        return AstroProfile(background: background, black: max(0,black), white: black+span, blackRGB: blackRGB, skyNoise: Float(skyNoise), midtone: midtone,
                            skyGradient: skyGradient, skyGradientLinear: skyGradientLinear, skySpread: skySpread)
    }
}

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import ZoraCore

struct ProcessedPreview: Sendable {
    let jpeg: Data
    let histogram: [Int]
    let clippedFraction: Double
    let peakingPNG: Data?
    let zebraPNG: Data?
}

actor ImageProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private func apply(_ recipe: Recipe, cube: CubeLUT?, image: CIImage) throws -> CIImage {
        _ = try recipe.validated()
        let exposure = CIFilter.exposureAdjust(); exposure.inputImage = image; exposure.ev = Float(recipe.exposure)
        let controls = CIFilter.colorControls(); controls.inputImage = exposure.outputImage
        controls.contrast = Float(recipe.contrast); controls.saturation = Float(recipe.saturation)
        let temperature = CIFilter.temperatureAndTint(); temperature.inputImage = controls.outputImage
        temperature.neutral = CIVector(x: CGFloat(recipe.temperature), y: CGFloat(recipe.tint))
        temperature.targetNeutral = CIVector(x: 6500, y: 0)
        guard var result = temperature.outputImage else { throw ZoraError.malformed("滤镜输出") }
        let extent = image.extent
        if recipe.highlightRecovery > 0 || recipe.shadows != 0 {
            let tone = CIFilter.highlightShadowAdjust(); tone.inputImage = result
            tone.highlightAmount = Float(1 - recipe.highlightRecovery); tone.shadowAmount = Float(recipe.shadows)
            if let output = tone.outputImage { result = output.cropped(to: extent) }
        }
        if recipe.vibrance != 0 {
            let vibrance = CIFilter.vibrance(); vibrance.inputImage = result; vibrance.amount = Float(recipe.vibrance)
            if let output = vibrance.outputImage { result = output }
        }
        if recipe.vignette > 0 {
            let vignette = CIFilter.vignette(); vignette.inputImage = result
            vignette.intensity = Float(recipe.vignette); vignette.radius = 1.6
            if let output = vignette.outputImage { result = output.cropped(to: extent) }
        }
        if recipe.grain > 0, let noise = CIFilter.randomGenerator().outputImage {
            // Monochrome noise at constant alpha, soft-light blended: grain without a colour cast.
            let mono = noise.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(recipe.grain * 0.35))
            ]).cropped(to: extent)
            result = mono.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: result]).cropped(to: extent)
        }
        if let cube {
            let lut = CIFilter.colorCube(); lut.inputImage = result; lut.cubeDimension = Float(cube.dimension); lut.cubeData = cube.data
            guard let output = lut.outputImage else { throw ZoraError.malformed("LUT 输出") }; result = output
        }
        return result
    }
    func preview(url: URL, recipe: Recipe, cube: CubeLUT? = nil) throws -> ProcessedPreview {
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw ZoraError.unsupported("系统无法解码该照片；NEF 原片仍保留") }
        let scale = min(1, 1400/max(source.extent.width, source.extent.height))
        return try analyze(apply(recipe, cube: cube, image: source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))))
    }
    func preview(jpeg: Data) throws -> ProcessedPreview {
        guard let image = CIImage(data: jpeg) else { throw ZoraError.malformed("实时 JPEG 解码失败") }
        return try analyze(image)
    }
    private func analyze(_ image: CIImage) throws -> ProcessedPreview {
        guard !image.extent.isEmpty, !image.extent.isInfinite,
              let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [:]) else { throw ZoraError.malformed("JPEG 输出") }
        let scale = min(1, 320/max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        bytes.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: w*4, bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)), format: .RGBA8, colorSpace: colorSpace)
        }
        let analysis = try FrameAnalysis(rgba: bytes, width: w, height: h)
        func overlay(_ mask: [UInt8], zebra: Bool) -> Data? {
            var rgba = [UInt8](repeating: 0, count: w*h*4)
            for i in mask.indices where mask[i] > 0 {
                if zebra && ((i%w+i/w)/5)%2 != 0 { continue }
                rgba[i*4] = zebra ? 255 : 90; rgba[i*4+1] = zebra ? 190 : 255; rgba[i*4+2] = zebra ? 0 : 150; rgba[i*4+3] = 180
            }
            let overlay = CIImage(bitmapData: Data(rgba), bytesPerRow: w*4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: colorSpace)
            return context.pngRepresentation(of: overlay, format: .RGBA8, colorSpace: colorSpace, options: [:])
        }
        return ProcessedPreview(jpeg: jpeg, histogram: analysis.histogram, clippedFraction: analysis.clippedFraction,
                                peakingPNG: overlay(analysis.peaking, zebra: false), zebraPNG: overlay(analysis.zebra, zebra: true))
    }
    /// Keeps source EXIF, resets orientation (pixels are already upright) and adds the
    /// phone-side GPS fix when the user enabled geotagging.
    func export(url: URL, recipe: Recipe, cube: CubeLUT?, location: GeoTag? = nil, to target: URL) throws {
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw ZoraError.unsupported("此 RAW 暂无法解码") }
        var properties = source.properties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1; properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let location, properties[kCGImagePropertyGPSDictionary as String] == nil {
            properties[kCGImagePropertyGPSDictionary as String] = location.exifGPS()
        }
        let result = try apply(recipe, cube: cube, image: source).settingProperties(properties)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
        guard let data = context.jpegRepresentation(of: result, colorSpace: colorSpace, options: options) else { throw ZoraError.malformed("JPEG export") }
        try data.write(to: target, options: .atomic)
    }
}

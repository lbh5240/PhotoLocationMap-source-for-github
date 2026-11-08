import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import UIKit

// Confined to one background worker at a time. Never shared with preview workers.
final class ImagePipeline {
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let display = CGColorSpace(name: CGColorSpace.sRGB)!
    let context: CIContext
    // Core Image bitmap row order is independent of its bottom-left coordinate space.
    // Normalize both pixel formats so that proxy analysis and tiled caches share one grid.
    private lazy var floatRowsTopFirst = renderRowsTopFirst(.RGBAf)
    private lazy var halfRowsTopFirst = renderRowsTopFirst(.RGBAh)
    private lazy var bitmapRowsTopFirst: Bool = {
        let values = Array(repeating: [Float(1), 0, 0, 1], count: 16 * 4).flatMap { $0 } +
                     Array(repeating: [Float(0), 0, 0, 1], count: 16 * 4).flatMap { $0 }
        let image = CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: 16 * 16,
                            size: CGSize(width: 16, height: 8), format: .RGBAf, colorSpace: linear)
        return firstRowIsRed(image, format: .RGBAf) == floatRowsTopFirst
    }()
    init() {
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue), .cacheIntermediates: false, .highQualityDownsample: true])
    }
    private func renderRowsTopFirst(_ format: CIFormat) -> Bool {
        let lower = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))
        let upper = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 4, width: 16, height: 4))
        return firstRowIsRed(upper.composited(over: lower), format: format)
    }

    private func firstRowIsRed(_ image: CIImage, format: CIFormat) -> Bool {
        let rowBytes = Int(image.extent.width) * (format == .RGBAh ? 8 : 16)
        let lastRow = (Int(image.extent.height) - 1) * rowBytes
        var data = Data(count: Int(image.extent.height) * rowBytes)
        return data.withUnsafeMutableBytes { ptr in
            context.render(image, toBitmap: ptr.baseAddress!, rowBytes: rowBytes, bounds: image.extent,
                           format: format, colorSpace: linear)
            if format == .RGBAh {
                return ptr.loadUnaligned(as: UInt16.self) > ptr.loadUnaligned(fromByteOffset: lastRow, as: UInt16.self)
            }
            return ptr.loadUnaligned(as: Float.self) > ptr.loadUnaligned(fromByteOffset: lastRow, as: Float.self)
        }
    }

    private func renderBottomFirst(_ image: CIImage, into data: inout Data, rowBytes: Int,
                                   bounds: CGRect, format: CIFormat, rowsTopFirst: Bool) {
        data.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            context.render(image, toBitmap: base, rowBytes: rowBytes, bounds: bounds, format: format, colorSpace: linear)
            if rowsTopFirst {
                let row = UnsafeMutableRawPointer.allocate(byteCount: rowBytes, alignment: 16)
                defer { row.deallocate() }
                let height = Int(bounds.height)
                for y in 0..<(height / 2) {
                    let a = base.advanced(by: y * rowBytes)
                    let b = base.advanced(by: (height - 1 - y) * rowBytes)
                    row.copyMemory(from: a, byteCount: rowBytes)
                    a.copyMemory(from: b, byteCount: rowBytes)
                    b.copyMemory(from: row, byteCount: rowBytes)
                }
            }
        }
    }

    func decode(_ url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()
        let image: CIImage
        if StackSelection.rawExtensions.contains(ext) {
            guard let raw = CIRAWFilter(imageURL: url) else { throw AstroError.message("系统无法解码 RAW：\(url.lastPathComponent)。请检查机型、压缩类型和系统 RAW 支持；不会使用内嵌 JPEG 替代。") }
            raw.exposure = 0; raw.baselineExposure = 0
            raw.isDraftModeEnabled = false; raw.scaleFactor = 1
            raw.isGamutMappingEnabled = false
            raw.boostAmount = 0; raw.boostShadowAmount = 0
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            raw.luminanceNoiseReductionAmount = 0; raw.colorNoiseReductionAmount = 0
            raw.sharpnessAmount = 0; raw.detailAmount = 0; raw.contrastAmount = 0
            raw.isLensCorrectionEnabled = false
            guard let output = raw.outputImage else { throw AstroError.message("RAW 解码失败：\(url.lastPathComponent)") }
            image = output
        } else {
            guard let output = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw AstroError.message("无法读取图片：\(url.lastPathComponent)") }
            image = output
        }
        let e = image.extent.integral
        guard e.width.isFinite, e.height.isFinite, e.width >= 16, e.height >= 16, e.width <= 30000, e.height <= 30000 else { throw AstroError.message("图片尺寸不支持") }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).cropped(to: CGRect(origin: .zero, size: e.size))
    }
    func rawMetadata(_ url: URL, name: String, stored: String) throws -> FrameRecord {
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        var frame = FrameRecord(name: name, fileName: stored)
        frame.width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        frame.height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            frame.camera = tiff[kCGImagePropertyTIFFModel as String] as? String ?? ""
        }
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            frame.exposure = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
            frame.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        }
        if frame.width < 16 || frame.height < 16 {
            let extent = try decode(url).extent
            frame.width = Int(extent.width); frame.height = Int(extent.height)
        }
        return frame
    }
    func embeddedRAWPreview(_ url: URL, maxSide: Int = 1600) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    func rawPreviewPlaceholder() throws -> CGImage {
        let image = CIImage(color: CIColor(red: 0.075, green: 0.085, blue: 0.12))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: display) else {
            throw AstroError.message("无法生成 NEF 占位预览")
        }
        return result
    }
    func metadata(_ url: URL, image: CIImage, name: String, stored: String) -> FrameRecord {
        var f = FrameRecord(name: name, fileName: stored)
        f.width = Int(image.extent.width); f.height = Int(image.extent.height)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] { f.camera = tiff[kCGImagePropertyTIFFModel as String] as? String ?? "" }
            if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                f.exposure = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
                f.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
            }
        }
        return f
    }
    func registrationCanvas(_ image: CIImage, width: Int, height: Int, divisor: Int) -> CIImage {
        let scaled = image.transformed(by: CGAffineTransform(scaleX: 1 / CGFloat(divisor), y: 1 / CGFloat(divisor)))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (CGFloat(width) - scaled.extent.width) / 2,
            y: (CGFloat(height) - scaled.extent.height) / 2))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let empty = CIImage(color: .clear).cropped(to: bounds)
        return centered.composited(over: empty).cropped(to: bounds)
    }
    func proxy(_ image: CIImage, maxSide: Int = 1600) -> (data: Data, width: Int, height: Int, scale: Double) {
        let scale = min(1, Double(maxSide) / max(image.extent.width, image.extent.height))
        let w = max(1, Int(image.extent.width * scale)), h = max(1, Int(image.extent.height * scale))
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var data = Data(count: w * h * 16)
        let topFirst = floatRowsTopFirst
        renderBottomFirst(resized, into: &data, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                          format: .RGBAf, rowsTopFirst: topFirst)
        return (data, w, h, scale)
    }
    func cache(_ image: CIImage, at url: URL, token: ASCancelToken) throws {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AstroError.message("无法创建临时堆栈文件")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let topFirst = halfRowsTopFirst
        for y in stride(from: 0, to: h, by: 128) {
            if token.isCancelled() { throw CancellationError() }
            try autoreleasepool {
                let rows = min(128, h - y)
                var data = Data(count: w * rows * 8)
                renderBottomFirst(image, into: &data, rowBytes: w * 8, bounds: CGRect(x: 0, y: y, width: w, height: rows),
                                  format: .RGBAh, rowsTopFirst: topFirst)
                try handle.write(contentsOf: data)
            }
        }
        try handle.close()
    }
    func previewSource(_ image: CIImage) throws -> CIImage {
        let scale = min(1, 1600 / max(image.extent.width, image.extent.height))
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let rendered = context.createCGImage(resized, from: resized.extent, format: .RGBAh, colorSpace: linear) else {
            throw AstroError.message("预览渲染失败")
        }
        return CIImage(cgImage: rendered, options: [.colorSpace: linear])
    }
    func master(_ result: StackResult, repository: ProjectRepository, project: AstroProject) throws -> CIImage {
        let url = repository.url(project, result.fileName)
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count == result.width * result.height * 16 else { throw AstroError.message("合成结果损坏，请重新堆栈") }
        let image = CIImage(bitmapData: data, bytesPerRow: result.width * 16, size: CGSize(width: result.width, height: result.height), format: .RGBAf, colorSpace: linear)
        return result.bottomFirst == true && bitmapRowsTopFirst ? image.oriented(.downMirrored) : image
    }
    // Registration leaves incomplete coverage at the outer canvas. Keep the Float32
    // master untouched; trim only the developed view and its matching export.
    func finishedStackView(_ image: CIImage) -> CIImage {
        let e = image.extent.integral
        let dx = max(2, floor(e.width * 0.015)), dy = max(2, floor(e.height * 0.015))
        guard e.width > 4*dx, e.height > 4*dy else { return image }
        let region = e.insetBy(dx: dx, dy: dy).integral
        return image.cropped(to: region).transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
    }
    func astroProfile(_ image: CIImage) -> AstroProfile {
        let sample = proxy(image, maxSide: 256)
        return AstroProcessing.profile(sample.data, width: sample.width, height: sample.height,
                                       linear: linear, bitmapRowsTopFirst: bitmapRowsTopFirst)
    }
    func edit(_ source: CIImage, _ a: Adjustments, profile: AstroProfile? = nil) throws -> CIImage {
        let extent = source.extent
        let needsAstro = (a.arcsinh ?? 0) > 0 || (a.gradientRemoval ?? 0) > 0 || (a.nebulaContrast ?? 0) > 0 ||
                         (a.backgroundNeutralization ?? 0) > 0 || (a.greenSuppression ?? 0) > 0 ||
                         (a.starReduction ?? 0) > 0 || (a.nebulaStructure ?? 0) > 0 || (a.starSaturation ?? 0) > 0
        var im = needsAstro ? try AstroProcessing.process(source, adjustments: a, profile: profile ?? astroProfile(source)) : source
        if a.exposure != 0 { im = im.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.warmth != 0 || a.tint != 0 { im = im.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500 + a.warmth * 25, y: a.tint), "inputTargetNeutral": CIVector(x: 6500, y: 0)]) }
        if a.noise > 0 { im = im.clampedToExtent().applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": a.noise * 0.08, "inputSharpness": 0]).cropped(to: extent) }
        if a.shadows != 0 || a.highlights != 1 { im = im.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": a.shadows, "inputHighlightAmount": a.highlights]) }
        if a.contrast != 1 || a.saturation != 1 { im = im.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation]) }
        if a.vibrance != 0 { im = im.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance]) }
        if a.black != 0 || a.curveLow != 0.25 || a.curveMid != 0.5 || a.curveHigh != 0.75 {
            im = im.applyingFilter("CIToneCurve", parameters: ["inputPoint0": CIVector(x: 0, y: a.black), "inputPoint1": CIVector(x: 0.25, y: a.curveLow), "inputPoint2": CIVector(x: 0.5, y: a.curveMid), "inputPoint3": CIVector(x: 0.75, y: a.curveHigh), "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if a.hsl.contains(where: { $0 != HSLBand() }) || (a.colorGrading ?? ColorGrading()) != ColorGrading() {
            im = im.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": 24,
                "inputCubeData": colorCube(a.hsl, grading: a.colorGrading), "inputColorSpace": display])
        }
        if a.sharpness > 0 { im = im.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness]).cropped(to: extent) }
        return im.cropped(to: extent)
    }
    func preview(image: CIImage, adjustments: Adjustments, maxSide: Int = 1600,
                 profile: AstroProfile? = nil, autoSTF: Bool = false) throws -> CGImage {
        let s = min(1, Double(maxSide) / max(image.extent.width, image.extent.height))
        let resized = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let sharedProfile = profile ?? astroProfile(resized)
        let shown = try adjusted(image: resized, adjustments: adjustments, profile: sharedProfile, screenSTF: autoSTF)
        guard let cg = context.createCGImage(shown, from: shown.extent, format: .RGBA8, colorSpace: display) else { throw AstroError.message("预览渲染失败") }
        return cg
    }
    private func adjusted(image: CIImage, adjustments: Adjustments, profile: AstroProfile,
                          screenSTF: Bool) throws -> CIImage {
        let edited = try edit(image, adjustments, profile: profile)
        return screenSTF ? try AstroProcessing.screenStretch(edited, profile: profile, adjustments: adjustments) : edited
    }
    func export(image: CIImage, adjustments: Adjustments, kind: ExportKind, url: URL,
                screenSTF: Bool = false) throws {
        if kind == .exr {
            try context.writeOpenEXRRepresentation(of: image, to: url, options: [:])
            return
        }
        // Reproduce the profile used by PreviewWorker's 1600 px RGBAh source.
        let profile = astroProfile(try previewSource(image))
        let im = try adjusted(image: image, adjustments: adjustments, profile: profile, screenSTF: screenSTF)
        switch kind {
        case .tiff: try context.writeTIFFRepresentation(of: im, to: url, format: .RGBA16, colorSpace: display, options: [:])
        case .png: try context.writePNGRepresentation(of: im, to: url, format: .RGBA16, colorSpace: display, options: [:])
        case .jpeg: try context.writeJPEGRepresentation(of: im, to: url, colorSpace: display, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.96])
        case .heif: try context.writeHEIFRepresentation(of: im, to: url, format: .RGBA8, colorSpace: display, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
        case .exr: break
        }
    }
    private func colorCube(_ bands: [HSLBand], grading: ColorGrading?) -> Data {
        let dim = 24; var cube = [Float](); cube.reserveCapacity(dim * dim * dim * 4)
        let shifts = GradeRange.allCases.map { range -> [Double] in
            let wheel = grading?[range] ?? WheelGrade()
            let red = wheel.x
            let green = -0.5 * wheel.x + 0.8660254 * wheel.y
            let blue = -0.5 * wheel.x - 0.8660254 * wheel.y
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            return [red, green, blue].map { ($0 - luma) * 0.18 + wheel.lightness * 0.18 }
        }
        func smooth(_ low: Double, _ high: Double, _ value: Double) -> Double {
            let t = min(1, max(0, (value - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }
        for b in 0..<dim { for g in 0..<dim { for r in 0..<dim {
            let rgb = [Double(r), Double(g), Double(b)].map { $0 / Double(dim - 1) }
            let hi = rgb.max()!, lo = rgb.min()!, d = hi - lo, l = (hi + lo) * 0.5
            var h = 0.0
            if d > 0 { if hi == rgb[0] { h = (rgb[1] - rgb[2]) / d }; if hi == rgb[1] { h = (rgb[2] - rgb[0]) / d + 2 }; if hi == rgb[2] { h = (rgb[0] - rgb[1]) / d + 4 }; h = (h / 6 + 1).truncatingRemainder(dividingBy: 1) }
            let saturation = d == 0 ? 0 : d / max(1e-9, 1 - abs(2 * l - 1))
            var dh = 0.0, ds = 0.0, dl = 0.0
            for i in 0..<min(6, bands.count) { let diff = abs(h - Double(i) / 6); let weight = max(0, 1 - min(diff, 1 - diff) * 6); dh += bands[i].hue * weight / 360; ds += bands[i].saturation * weight; dl += bands[i].luminance * weight }
            let hh = (h + dh + 1).truncatingRemainder(dividingBy: 1), ss = min(1, max(0, saturation * (1 + ds))), ll = min(1, max(0, l + dl * saturation * 0.25))
            let c = (1 - abs(2 * ll - 1)) * ss, x = c * (1 - abs((hh * 6).truncatingRemainder(dividingBy: 2) - 1)), m = ll - c * 0.5
            let part = min(5, Int(hh * 6)), triplets = [[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]]
            let color = triplets[part].map { $0 + m }
            let luma = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
            let shadow = 1 - smooth(0.08, 0.56, luma)
            let highlight = smooth(0.44, 0.94, luma)
            let midtone = max(0, 1 - shadow - highlight)
            for channel in 0..<3 {
                let shift = shadow * shifts[0][channel] + midtone * shifts[1][channel] + highlight * shifts[2][channel]
                cube.append(Float(min(1, max(0, color[channel] + shift))))
            }
            cube.append(1)
        } } }
        return cube.withUnsafeBytes { Data($0) }
    }
}

#if DEBUG && targetEnvironment(simulator)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum SimulatorStackFixture {
    static func make(variant: String) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var random = UInt32(1087)
        func next() -> UInt32 { random = random &* 1664525 &+ 1013904223; return random >> 8 }
        let stars = (0..<42).map { _ in (Int(next() % 308) + 36, Int(next() % 180) + 36) }
        return try (0..<3).map { frame in
            let width = 384, height = variant == "mixed" && frame == 2 ? 240 : 256
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for index in 0..<(width * height) {
                let background = UInt8(30 + next() % 12)
                for channel in 0..<3 { rgba[index * 4 + channel] = background }
            }
            for (sx, sy) in stars {
                for y in -4...4 {
                    for x in -4...4 {
                        let dx = sx + x + frame * 2, dy = sy + y - frame
                        let location = (dy * width + dx) * 4
                        let value = Int(195 * exp(-Double(x*x + y*y) / 4.0))
                        for channel in 0..<3 { rgba[location + channel] = UInt8(min(255, Int(rgba[location + channel]) + value)) }
                    }
                }
            }
            // A narrow, star-free filament shifts with the stars and crosses cache strip boundaries.
            for y in (104 - frame)..<(151 - frame) {
                for x in 14..<31 {
                    let dx = Double(x - 20 - frame * 2)
                    let value = Int(210 * exp(-dx * dx / 1.65))
                    let offset = (y * width + x) * 4
                    for channel in 0..<3 { rgba[offset + channel] = UInt8(min(255, Int(rgba[offset + channel]) + value)) }
                }
            }
            for y in 119..<137 {
                for x in 353..<375 {
                    let dy = Double(y - 128 + frame)
                    let value = Int(210 * exp(-dy * dy / 1.65))
                    let offset = (y * width + x) * 4
                    for channel in 0..<3 { rgba[offset + channel] = UInt8(min(255, Int(rgba[offset + channel]) + value)) }
                }
            }
            let data = Data(rgba)
            let provider = CGDataProvider(data: data as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let url = folder.appendingPathComponent("Stack-Test-\(frame + 1).png")
            let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw AstroError.message("无法创建测试图像") }
            return url
        }
    }
}
#endif

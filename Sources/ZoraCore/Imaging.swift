import Foundation

public struct Recipe: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var temperature: Double
    public init(id: UUID = UUID(), name: String, exposure: Double = 0, contrast: Double = 1, saturation: Double = 1, temperature: Double = 6500) {
        self.id = id; self.name = name; self.exposure = exposure; self.contrast = contrast
        self.saturation = saturation; self.temperature = temperature
    }
    public func validated() throws -> Self {
        guard !name.isEmpty, name.count <= 80, exposure.isFinite, (-5...5).contains(exposure),
              contrast.isFinite, (0...2).contains(contrast), saturation.isFinite, (0...2).contains(saturation),
              temperature.isFinite, (2000...12000).contains(temperature) else {
            throw ZoraError.malformed("Recipe 参数超出范围")
        }
        return self
    }
    public static let presets: [Recipe] = [
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "原色"),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "琥珀日光", exposure: 0.2, contrast: 1.08, saturation: 0.88, temperature: 5800),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "银盐黑白", contrast: 1.18, saturation: 0)
    ]
}

public struct CubeLUT: Sendable {
    public let dimension: Int
    public let rgba: [Float]
    public init(text: String) throws {
        guard text.utf8.count <= 16 * 1024 * 1024 else { throw ZoraError.malformed("LUT exceeds 16 MiB") }
        var size: Int?, values: [Float] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let first = fields.first else { continue }
            switch first {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard size == nil, fields.count == 2, let n = Int(fields[1]), (2...64).contains(n) else { throw ZoraError.malformed("LUT_3D_SIZE must be 2...64") }
                size = n
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let required: Float = first == "DOMAIN_MIN" ? 0 : 1
                guard fields.count == 4, fields.dropFirst().allSatisfy({ Float($0) == required }) else { throw ZoraError.unsupported("LUT 仅支持 DOMAIN 0...1") }
            default:
                guard let n = size, fields.count == 3, values.count < n*n*n*4 else { throw ZoraError.malformed("LUT row or header") }
                let row = fields.compactMap(Float.init)
                guard row.count == 3, row.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ZoraError.malformed("LUT component") }
                values.append(contentsOf: row); values.append(1)
            }
        }
        guard let n = size, values.count == n*n*n*4 else { throw ZoraError.malformed("LUT row count") }
        dimension = n; rgba = values
    }
    public var data: Data { rgba.withUnsafeBytes { Data($0) } }
}

public struct FrameAnalysis: Sendable {
    public let histogram: [Int]
    public let clippedFraction: Double
    public let peaking: [UInt8]
    public let zebra: [UInt8]
    /// RGBA8 in display space. Diagnostics describe the preview, not sensor RAW exposure.
    public init(rgba: [UInt8], width: Int, height: Int, clipping: UInt8 = 245, edgeThreshold: Int = 28) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              rgba.count == width*height*4 else { throw ZoraError.malformed("monitor frame dimensions") }
        var histogram = [Int](repeating: 0, count: 256)
        var luma = [UInt8](repeating: 0, count: width*height)
        var peak = luma, zebra = luma
        var clipped = 0
        for i in luma.indices {
            let p = i*4
            let y = UInt8((54*Int(rgba[p]) + 183*Int(rgba[p+1]) + 19*Int(rgba[p+2])) >> 8)
            luma[i] = y; histogram[Int(y)] += 1
            if max(rgba[p], max(rgba[p+1], rgba[p+2])) >= clipping { zebra[i] = 255; clipped += 1 }
        }
        if width > 2 && height > 2 {
            for y in 1..<(height-1) { for x in 1..<(width-1) {
                let i = y*width+x
                let gradient = abs(Int(luma[i+1])-Int(luma[i-1])) + abs(Int(luma[i+width])-Int(luma[i-width]))
                if gradient >= edgeThreshold { peak[i] = 255 }
            } }
        }
        self.histogram = histogram; clippedFraction = Double(clipped)/Double(luma.count)
        peaking = peak; self.zebra = zebra
    }
}

import Foundation

enum StackMode: Int, Codable, CaseIterable, Identifiable, Sendable {
    case sky, landscape, trails
    var id: Int { rawValue }
    var title: String { ["星空对齐", "星野 · 地景", "星轨"][rawValue] }
    var subtitle: String { ["跟踪拍摄 / 纯天空", "固定机位 · 手动水平分界", "固定机位 · 亮度最大值"][rawValue] }
    var symbol: String { ["sparkles", "mountain.2", "moon.stars"][rawValue] }
}
struct StackConfiguration: Codable, Equatable, Sendable {
    var mode: StackMode = .sky
    var sigma: Double = 3
    var skyFraction: Double = 0.65
    var feather: Double = 0.04
}
struct HSLBand: Codable, Equatable, Sendable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
}
struct Adjustments: Codable, Equatable, Sendable {
    var exposure: Double = 0
    var contrast: Double = 1
    var warmth: Double = 0
    var tint: Double = 0
    var saturation: Double = 1
    var vibrance: Double = 0
    var shadows: Double = 0
    var highlights: Double = 1
    var noise: Double = 0
    var sharpness: Double = 0
    var black: Double = 0
    var curveLow: Double = 0.25
    var curveMid: Double = 0.5
    var curveHigh: Double = 0.75
    var hsl: [HSLBand] = Array(repeating: HSLBand(), count: 6)
    static let neutral = Adjustments()
}
struct FrameRecord: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var fileName: String
    var included = true
    var width = 0
    var height = 0
    var camera = ""
    var iso: Double?
    var exposure: Double?
    var quality: Double?
    var starCount: Int?
    var registrationRMS: Double?
    var rejection: String?
}
struct StackResult: Codable, Sendable {
    var fileName: String
    var width: Int
    var height: Int
    var acceptedFrames: Int
    var created = Date()
    var mode: StackMode
}
struct AstroProject: Identifiable, Codable, Sendable {
    var schema = 1
    var id = UUID()
    var name = "未命名星空"
    var created = Date()
    var updated = Date()
    var frames: [FrameRecord] = []
    var configuration = StackConfiguration()
    var adjustments = Adjustments()
    var undo: [Adjustments] = []
    var redo: [Adjustments] = []
    var result: StackResult?
    var jobInProgress = false
}
enum AstroError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
enum ExportKind: String, CaseIterable, Identifiable, Sendable {
    case tiff = "TIFF 16 位", jpeg = "JPEG", png = "PNG 16 位", heif = "HEIF"
    var id: String { rawValue }
    var ext: String { switch self { case .tiff: "tiff"; case .jpeg: "jpg"; case .png: "png"; case .heif: "heic" } }
}

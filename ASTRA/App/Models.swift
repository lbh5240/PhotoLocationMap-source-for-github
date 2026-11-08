import Foundation

enum StackMode: Int, Codable, CaseIterable, Identifiable, Sendable {
    case sky, landscape, trails
    var id: Int { rawValue }
    var title: String { ["星空对齐", "星野 · 地景", "星轨"][rawValue] }
    var subtitle: String { ["跟踪拍摄 / 纯天空", "固定机位 · 手动水平分界", "固定机位 · 亮度最大值"][rawValue] }
    var symbol: String { ["sparkles", "mountain.2", "moon.stars"][rawValue] }
}
struct StackRegion: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct StackConfiguration: Codable, Equatable, Sendable {
    var referenceFrameID: UUID?
    var region: StackRegion?
    var mode: StackMode = .sky
    var sigma: Double = 3
    var skyFraction: Double = 0.65
    var feather: Double = 0.04
    var halfResolution: Bool?
    var hdrFusion: Bool?
}
struct HSLBand: Codable, Equatable, Sendable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
}
enum GradeRange: Int, CaseIterable, Identifiable {
    case shadows, midtones, highlights
    var id: Int { rawValue }
    var title: String { ["阴影", "中间调", "高光"][rawValue] }
}
struct WheelGrade: Codable, Equatable, Sendable {
    var x = 0.0
    var y = 0.0
    var lightness = 0.0
}
struct ColorGrading: Codable, Equatable, Sendable {
    var shadows = WheelGrade()
    var midtones = WheelGrade()
    var highlights = WheelGrade()

    subscript(_ range: GradeRange) -> WheelGrade {
        get { switch range { case .shadows: shadows; case .midtones: midtones; case .highlights: highlights } }
        set { switch range { case .shadows: shadows = newValue; case .midtones: midtones = newValue; case .highlights: highlights = newValue } }
    }
}
enum DevelopMethod: Int, Codable, CaseIterable, Identifiable, Sendable {
    case natural, core, nebula
    var id: Int { rawValue }
    var title: String { switch self { case .natural: "自然"; case .core: "亮核"; case .nebula: "云气" } }
    var detail: String { switch self {
        case .natural: "Arcsinh 色彩保护与平滑肩部"
        case .core: "对数亮部压缩，适合 M42 高亮核心"
        case .nebula: "双曲线提升暗弱云气，注意噪声"
    } }
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
    // Optional for projects and undo histories saved before color grading.
    var colorGrading: ColorGrading?
    // Optional fields keep existing saved projects and undo history decodable.
    var autoSTF: Bool?
    var arcsinh: Double?
    var maskedStretch: Double?
    var gradientRemoval: Double?
    var nebulaContrast: Double?
    var starProtection: Double?
    var backgroundNeutralization: Double?
    var greenSuppression: Double?
    var starReduction: Double?
    var nebulaStructure: Double?
    var starSaturation: Double?
    // Image-measured stretch bounds for automatic development. Nil uses the live profile.
    var autoBlack: Double?
    var autoWhite: Double?
    var autoBlackRed: Double?
    var autoBlackGreen: Double?
    var autoBlackBlue: Double?
    var developMethod: DevelopMethod?
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
    var rawPreviewUnavailable: Bool?
}
struct StackResult: Codable, Sendable {
    var fileName: String
    var width: Int
    var height: Int
    var acceptedFrames: Int
    var created = Date()
    var mode: StackMode
    var bottomFirst: Bool?
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
    case tiff = "TIFF 16 位", jpeg = "JPEG", png = "PNG 16 位", heif = "HEIF", exr = "OpenEXR 32 位线性"
    var id: String { rawValue }
    var ext: String { switch self { case .tiff: "tiff"; case .jpeg: "jpg"; case .png: "png"; case .heif: "heic"; case .exr: "exr" } }
}

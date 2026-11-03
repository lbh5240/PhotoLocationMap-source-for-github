import Foundation

public struct CameraProperty: Identifiable, Sendable {
    public var id: UInt16 { code }
    public let code: UInt16, type: UInt16
    public let writable: Bool
    public let current: Int64
    public let allowed: [Int64]
    public let range: ClosedRange<Int64>?
    public let step: Int64?
    public init(data: Data) throws {
        var r = BinaryReader(data)
        code = try r.integer(UInt16.self); type = try r.integer(UInt16.self)
        writable = try r.integer(UInt8.self) == 1
        _ = try Self.read(type: type, from: &r); current = try Self.read(type: type, from: &r)
        let form = try r.integer(UInt8.self)
        switch form {
        case 0: allowed = []; range = nil; step = nil
        case 1:
            let low = try Self.read(type: type, from: &r), high = try Self.read(type: type, from: &r)
            let delta = try Self.read(type: type, from: &r)
            guard low <= high, delta > 0 else { throw ZoraError.malformed("property range") }
            range = low...high; step = delta; allowed = []
        case 2:
            let count = Int(try r.integer(UInt16.self))
            guard count <= 4096 else { throw ZoraError.malformed("property enum size") }
            let valueType = type
            allowed = try (0..<count).map { _ in try Self.read(type: valueType, from: &r) }; range = nil; step = nil
        default: throw ZoraError.unsupported("property form \(form)")
        }
    }
    private static func read(type: UInt16, from r: inout BinaryReader) throws -> Int64 {
        switch type {
        case 1: return Int64(Int8(bitPattern: try r.integer(UInt8.self)))
        case 2: return Int64(try r.integer(UInt8.self))
        case 3: return Int64(Int16(bitPattern: try r.integer(UInt16.self)))
        case 4: return Int64(try r.integer(UInt16.self))
        case 5: return Int64(Int32(bitPattern: try r.integer(UInt32.self)))
        case 6: return Int64(try r.integer(UInt32.self))
        default: throw ZoraError.unsupported("非标量或大于 32 位的相机属性")
        }
    }
    public func encode(_ value: Int64) throws -> Data {
        guard writable, allowed.isEmpty || allowed.contains(value), range == nil || range!.contains(value) else { throw ZoraError.unsupported("属性只读或参数不受支持") }
        if let range, let step { guard (value-range.lowerBound) % step == 0 else { throw ZoraError.malformed("property step") } }
        var data = Data()
        switch type {
        case 1: guard let n = Int8(exactly: value) else { throw ZoraError.malformed("Int8") }; data.appendLE(n)
        case 2: guard let n = UInt8(exactly: value) else { throw ZoraError.malformed("UInt8") }; data.appendLE(n)
        case 3: guard let n = Int16(exactly: value) else { throw ZoraError.malformed("Int16") }; data.appendLE(n)
        case 4: guard let n = UInt16(exactly: value) else { throw ZoraError.malformed("UInt16") }; data.appendLE(n)
        case 5: guard let n = Int32(exactly: value) else { throw ZoraError.malformed("Int32") }; data.appendLE(n)
        case 6: guard let n = UInt32(exactly: value) else { throw ZoraError.malformed("UInt32") }; data.appendLE(n)
        default: throw ZoraError.unsupported("property type")
        }
        return data
    }
    public var title: String {
        switch code {
        case 0x5007: "光圈"; case 0x500D, 0xD100: "快门"; case 0x500F: "ISO"; case 0x5010: "曝光补偿"
        case 0x5005: "白平衡"; case 0x500e: "曝光模式"; case 0x500a: "对焦模式"; case 0x500b: "测光模式"
        case 0x5004: "图像质量"; case 0x5013: "释放模式"; case 0x5001: "电量"; case 0x500C: "闪光模式"
        default: String(format: "属性 %04X", code)
        }
    }
    /// Selectable values: enumerations as declared, ranges expanded only when small enough for a menu.
    public var options: [Int64] {
        if !allowed.isEmpty { return allowed }
        guard let range, let step, (range.upperBound - range.lowerBound) / step < 400 else { return [] }
        return Array(stride(from: range.lowerBound, through: range.upperBound, by: Int(step)))
    }
    public var currentLabel: String { label(for: current) }
    public func label(for value: Int64) -> String { CameraPropertyFormat.describe(code: code, value: value) }
    /// Values `offsets` positions away from the current one in the declared order (sorted ascending).
    public func value(offset: Int) throws -> Int64 {
        let sorted = options.sorted()
        guard let index = sorted.firstIndex(of: current) else { throw ZoraError.unsupported("\(title) 当前值不在相机声明的可选列表中") }
        let target = index + offset
        guard sorted.indices.contains(target) else { throw ZoraError.unsupported("\(title) 包围范围超出相机允许值") }
        return sorted[target]
    }
}

/// Standard PTP value meanings plus Nikon vendor values cross-checked with public references.
/// Unknown values are shown numerically, never guessed.
public enum CameraPropertyFormat {
    static let shutterDenominators: [Double] = [8000,6400,5000,4000,3200,2500,2000,1600,1250,1000,800,640,500,400,320,250,200,160,125,100,80,60,50,40,30,25,20,15,13,10,8,6,5,4,3,2.5,2,1.6,1.3]
    public static func describe(code: UInt16, value: Int64) -> String {
        switch code {
        case 0x5007:
            return value % 100 == 0 ? "f/\(value / 100)" : String(format: "f/%.1f", Double(value) / 100)
        case 0x500D: return standardShutter(value)
        case 0xD100: return nikonShutter(value)
        case 0x500F: return "ISO \(value)"
        case 0x5010:
            if value == 0 { return "±0 EV" }
            return String(format: "%+.1f EV", Double(value) / 1000)
        case 0x5001: return "\(value)%"
        case 0x5005: return table(value, [1: "手动", 2: "自动", 3: "一键自动", 4: "晴天", 5: "荧光灯", 6: "白炽灯", 7: "闪光灯",
                                          0x8010: "阴天", 0x8011: "背阴", 0x8012: "色温", 0x8013: "手动预设", 0x8016: "自然光自动"])
        case 0x500e: return table(value, [1: "M 手动", 2: "P 程序", 3: "A 光圈优先", 4: "S 快门优先", 0x8010: "自动",
                                          0x8050: "U1", 0x8051: "U2", 0x8052: "U3"])
        case 0x500a: return table(value, [1: "MF 手动", 2: "自动", 3: "微距自动", 0x8010: "AF-S 单次", 0x8011: "AF-C 连续", 0x8012: "AF-A 自动切换"])
        case 0x500b: return table(value, [1: "平均", 2: "中央重点", 3: "矩阵", 4: "点测光", 0x8010: "亮部重点"])
        case 0x5013: return table(value, [1: "单张", 2: "连拍", 3: "定时", 0x8010: "低速连拍", 0x8011: "自拍"])
        case 0x500C: return table(value, [1: "自动", 2: "关闭", 3: "补光", 4: "防红眼", 5: "防红眼补光"])
        case 0x5004: return table(value, [0: "JPEG 基本", 1: "JPEG 标准", 2: "JPEG 精细", 4: "RAW",
                                          5: "RAW + JPEG 基本", 6: "RAW + JPEG 标准", 7: "RAW + JPEG 精细"])
        default: return "\(value)"
        }
    }
    private static func table(_ value: Int64, _ names: [Int64: String]) -> String {
        names[value].map { "\($0)" } ?? String(format: "0x%04llX", value)
    }
    /// 0x500D is 1/10000 s. Snap to nominal values: 1/8000 is reported as 1 or 1.25.
    static func standardShutter(_ value: Int64) -> String {
        if value == 0xFFFFFFFF { return "B 门" }
        if value == 0xFFFFFFFD { return "T 门" }
        guard value > 0 else { return "\(value)" }
        let seconds = Double(value) / 10000
        if seconds >= 0.95 { return abs(seconds.rounded() - seconds) < 0.05 ? "\(Int(seconds.rounded()))\"" : String(format: "%.1f\"", seconds) }
        let denominator = 1 / seconds
        let nominal = shutterDenominators.min { abs(log($0) - log(denominator)) < abs(log($1) - log(denominator)) } ?? denominator
        return nominal.rounded() == nominal ? "1/\(Int(nominal))" : String(format: "1/%.1f", nominal)
    }
    /// Nikon 0xD100 packs numerator (high 16 bits) / denominator (low 16 bits).
    static func nikonShutter(_ value: Int64) -> String {
        if value == 0xFFFFFFFF { return "B 门" }
        if value == 0xFFFFFFFE { return "T 门" }
        let numerator = (value >> 16) & 0xFFFF, denominator = value & 0xFFFF
        guard numerator > 0, denominator > 0 else { return String(format: "0x%08llX", value) }
        if numerator == 1 && denominator > 1 { return "1/\(denominator)" }
        if denominator == 1 { return "\(numerator)\"" }
        if numerator % denominator == 0 { return "\(numerator / denominator)\"" }
        return String(format: "%.1f\"", Double(numerator) / Double(denominator))
    }
}

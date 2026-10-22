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
        switch code { case 0x5007: "光圈 ×100"; case 0x500D: "快门 1/10000 秒"; case 0x500F: "ISO"; case 0x5010: "曝光补偿 ×1000"; case 0x5005: "白平衡代码"; default: String(format: "属性 %04X", code) }
    }
}

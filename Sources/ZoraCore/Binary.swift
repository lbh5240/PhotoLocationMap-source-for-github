import Foundation

public enum ZoraError: Error, Equatable, Sendable, LocalizedError {
    case malformed(String), unsupported(String), cameraResponse(UInt16), disconnected, busy, timeout, http(Int)
    public var errorDescription: String? {
        switch self {
        case .malformed(let s): return "数据格式错误：\(s)"
        case .unsupported(let s): return "当前不可用：\(s)"
        case .cameraResponse(let code): return String(format: "相机拒绝了本次操作（0x%04X），请检查拍摄模式与相机状态", code)
        case .disconnected: return "尚未连接相机"
        case .busy: return "相机通信正在进行，请稍后重试"
        case .timeout: return "操作超时，请检查相机连接与系统配对或网络提示"
        case .http(let n): return "服务器返回 HTTP \(n)"
        }
    }
}

public extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

public struct BinaryReader: Sendable {
    public let data: Data
    public private(set) var offset = 0
    public init(_ data: Data) { self.data = data }
    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw ZoraError.malformed("truncated binary field")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    public mutating func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let b = try bytes(MemoryLayout<T>.size)
        return b.enumerated().reduce(T.zero) { $0 | (T($1.element) << ($1.offset * 8)) }
    }
    public mutating func ptpString() throws -> String {
        let count = Int(try integer(UInt8.self))
        if count == 0 { return "" }
        let b = try bytes(count * 2)
        guard b.suffix(2) == Data([0, 0]), let s = String(data: b.dropLast(2), encoding: .utf16LittleEndian) else {
            throw ZoraError.malformed("PTP UTF-16 string")
        }
        return s
    }
    public mutating func array16() throws -> [UInt16] {
        let count = Int(try integer(UInt32.self))
        guard count <= (data.count - offset) / 2 else { throw ZoraError.malformed("PTP array") }
        return try (0..<count).map { _ in try integer(UInt16.self) }
    }
    public mutating func array32() throws -> [UInt32] {
        let count = Int(try integer(UInt32.self))
        guard count <= (data.count - offset) / 4 else { throw ZoraError.malformed("PTP array") }
        return try (0..<count).map { _ in try integer(UInt32.self) }
    }
}

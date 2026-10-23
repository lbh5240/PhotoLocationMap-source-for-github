import Foundation

public enum PTPOperation {
    public static let deviceInfo: UInt16 = 0x1001, openSession: UInt16 = 0x1002, closeSession: UInt16 = 0x1003
    public static let storageIDs: UInt16 = 0x1004, objectHandles: UInt16 = 0x1007, objectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009, capture: UInt16 = 0x100E
    public static let storageInfo: UInt16 = 0x1005, thumbnail: UInt16 = 0x100A, partialObject: UInt16 = 0x101B
    public static let manualFocus: UInt16 = 0x9204, captureToCard: UInt16 = 0x9207, vendorStorageIDs: UInt16 = 0x9209
    public static let startMovie: UInt16 = 0x920A, endMovie: UInt16 = 0x920B, terminateCapture: UInt16 = 0x920C
    public static let remoteControl: UInt16 = 0x90C2, deviceReady: UInt16 = 0x90C8
    public static let propertyDescription: UInt16 = 0x1014, propertyValue: UInt16 = 0x1015, setProperty: UInt16 = 0x1016
    public static let startLiveView: UInt16 = 0x9201, endLiveView: UInt16 = 0x9202, liveViewImage: UInt16 = 0x9203
    public static let autoFocus: UInt16 = 0x90C1
}

public struct PTPPacket: Equatable, Sendable {
    public var type: UInt32
    public var payload: Data
    public init(type: UInt32, payload: Data = Data()) { self.type = type; self.payload = payload }
    public var encoded: Data {
        var d = Data(); d.appendLE(UInt32(payload.count + 8)); d.appendLE(type); d.append(payload); return d
    }
    public static func operation(_ code: UInt16, transaction: UInt32, parameters: [UInt32] = [], sending: Bool = false) throws -> Self {
        guard parameters.count <= 5 else { throw ZoraError.malformed("too many operation parameters") }
        var p = Data(); p.appendLE(UInt32(sending ? 2 : 1)); p.appendLE(code); p.appendLE(transaction)
        for value in parameters { p.appendLE(value) }
        return Self(type: 6, payload: p)
    }
    public static func initialize(guid: UUID, name: String) -> Self {
        var uuid = guid.uuid
        var p = withUnsafeBytes(of: &uuid) { Data($0) }
        for u in name.prefix(80).utf16 { p.appendLE(u) }
        p.appendLE(UInt16(0)); p.appendLE(UInt32(0x00010000))
        return Self(type: 1, payload: p)
    }
}

/// TCP framing accepts fragments and coalesced frames. Bounded before allocating payloads.
public struct PTPFramer: Sendable {
    private var buffer = Data()
    public static let maximumPacket = 64 * 1024 * 1024
    public init() {}
    public mutating func feed(_ chunk: Data) throws -> [PTPPacket] {
        guard chunk.count <= Self.maximumPacket, buffer.count <= Self.maximumPacket - chunk.count else {
            throw ZoraError.malformed("PTP buffer limit")
        }
        buffer.append(chunk)
        var packets: [PTPPacket] = []
        while buffer.count >= 8 {
            var reader = BinaryReader(buffer)
            let length = Int(try reader.integer(UInt32.self))
            let type = try reader.integer(UInt32.self)
            guard length >= 8, length <= Self.maximumPacket else { throw ZoraError.malformed("PTP frame length") }
            guard buffer.count >= length else { break }
            packets.append(PTPPacket(type: type, payload: buffer.subdata(in: 8..<length)))
            buffer = Data(buffer.dropFirst(length))
        }
        return packets
    }
}

public struct CameraDeviceInfo: Sendable, Equatable {
    public let manufacturer: String, model: String, firmware: String, serial: String
    public let vendor: UInt32
    public let operations: Set<UInt16>, properties: Set<UInt16>
    public init(data: Data) throws {
        var r = BinaryReader(data)
        _ = try r.integer(UInt16.self); vendor = try r.integer(UInt32.self)
        _ = try r.integer(UInt16.self); _ = try r.ptpString(); _ = try r.integer(UInt16.self)
        operations = Set(try r.array16()); _ = try r.array16(); properties = Set(try r.array16())
        _ = try r.array16(); _ = try r.array16()
        manufacturer = try r.ptpString(); model = try r.ptpString(); firmware = try r.ptpString(); serial = try r.ptpString()
    }
    public var canLiveView: Bool {
        vendor == 0xA && [PTPOperation.startLiveView, PTPOperation.endLiveView, PTPOperation.liveViewImage].allSatisfy(operations.contains)
    }
    public var canCapture: Bool { operations.contains(PTPOperation.captureToCard) || operations.contains(PTPOperation.capture) }
    public var canRecordMovie: Bool { [PTPOperation.startMovie, PTPOperation.endMovie].allSatisfy(operations.contains) }
}

public struct CameraObject: Identifiable, Sendable {
    public let id: UInt32, filename: String, size: UInt32, format: UInt16
    public init(handle: UInt32, data: Data) throws {
        var r = BinaryReader(data)
        _ = try r.integer(UInt32.self); format = try r.integer(UInt16.self)
        _ = try r.integer(UInt16.self); size = try r.integer(UInt32.self)
        _ = try r.bytes(40)
        filename = try r.ptpString(); id = handle
    }
}

public struct PTPResult: Sendable { public let data: Data; public let parameters: [UInt32] }

/// Transaction assembly rejects cross-transaction data and mismatched transfer lengths.
public struct PTPTransaction: Sendable {
    public let id: UInt32
    private var expected: UInt64?
    private var ended = false
    private var data = Data()
    public init(id: UInt32) { self.id = id }
    public mutating func consume(_ packet: PTPPacket) throws -> PTPResult? {
        var r = BinaryReader(packet.payload)
        switch packet.type {
        case 9:
            guard expected == nil, try r.integer(UInt32.self) == id else { throw ZoraError.malformed("StartData transaction") }
            expected = try r.integer(UInt64.self)
            guard expected! <= UInt64(PTPFramer.maximumPacket) else { throw ZoraError.unsupported("��������ļ���������Ϊ 64 MiB") }
        case 10, 12:
            guard expected != nil, !ended, try r.integer(UInt32.self) == id else { throw ZoraError.malformed("Data transaction") }
            let bytes = try r.bytes(packet.payload.count - 4)
            guard UInt64(data.count + bytes.count) <= expected! else { throw ZoraError.malformed("data overflow") }
            data.append(bytes); ended = packet.type == 12
        case 7:
            let code = try r.integer(UInt16.self)
            guard try r.integer(UInt32.self) == id else { throw ZoraError.malformed("response transaction") }
            guard code == 0x2001 else { throw ZoraError.cameraResponse(code) }
            if let expected { guard ended && UInt64(data.count) == expected else { throw ZoraError.malformed("incomplete data phase") } }
            guard (packet.payload.count - 6) % 4 == 0 else { throw ZoraError.malformed("response parameters") }
            var params: [UInt32] = []
            while r.offset < packet.payload.count { params.append(try r.integer(UInt32.self)) }
            return PTPResult(data: data, parameters: params)
        default: throw ZoraError.malformed("unexpected transaction packet \(packet.type)")
        }
        return nil
    }
}

public enum LiveViewJPEG {
    /// Nikon headers vary by model/firmware; only accept a bounded, complete JPEG range.
    public static func extract(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw ZoraError.malformed("empty live view") }
        for i in 0..<min(bytes.count - 2, 4096) where bytes[i] == 0xff && bytes[i+1] == 0xd8 && bytes[i+2] == 0xff {
            for j in stride(from: bytes.count - 2, through: i + 2, by: -1) where bytes[j] == 0xff && bytes[j+1] == 0xd9 {
                return Data(bytes[i...j+1])
            }
        }
        throw ZoraError.malformed("no complete JPEG in live view payload")
    }
}

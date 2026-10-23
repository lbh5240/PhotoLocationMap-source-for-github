import Foundation

/// ImageCaptureCore owns the physical USB session. This command transport opens
/// that session through the OS; CameraSession must not forge OpenSession replies.
public protocol PTPDirectTransport: Sendable {
    func open() async throws
    func execute(code: UInt16, transaction: UInt32, parameters: [UInt32], sending: Data?) async throws -> PTPResult
    func eventStream() async -> AsyncStream<CameraTransportEvent>
    func close() async
}

public enum CameraTransportEvent: Sendable { case ptp(CameraEvent), disconnected }

public struct CameraEvent: Sendable, Equatable {
    public let code: UInt16
    public let transaction: UInt32
    public let parameters: [UInt32]
    public init(code: UInt16, transaction: UInt32, parameters: [UInt32]) {
        self.code = code; self.transaction = transaction; self.parameters = parameters
    }
    public init(ipPayload: Data) throws {
        guard ipPayload.count >= 6, ipPayload.count <= 18, (ipPayload.count-6).isMultiple(of: 4) else { throw ZoraError.malformed("PTP/IP event length") }
        var r = BinaryReader(ipPayload); code = try r.integer(); transaction = try r.integer()
        var values: [UInt32] = []; while r.offset < ipPayload.count { values.append(try r.integer()) }; parameters = values
    }
    public init(usbContainer: Data) throws {
        let header = try PTPUSBContainer.parse(usbContainer, type: 4, maximumParameters: 3)
        self.init(code: header.code, transaction: header.transaction, parameters: header.parameters)
    }
    public var changesStorage: Bool { [0x4002,0x4003,0x4004,0x4005,0x4007,0x4008,0x4009,0x400d].contains(code) }
}

public enum PTPUSBContainer {
    public static func command(code: UInt16, transaction: UInt32, parameters: [UInt32]) throws -> Data {
        guard parameters.count <= 5 else { throw ZoraError.malformed("USB PTP parameter count") }
        var result = Data(); result.appendLE(UInt32(12 + parameters.count * 4)); result.appendLE(UInt16(1))
        result.appendLE(code); result.appendLE(transaction); for p in parameters { result.appendLE(p) }; return result
    }
    static func parse(_ bytes: Data, type: UInt16, maximumParameters: Int) throws -> (code: UInt16, transaction: UInt32, parameters: [UInt32]) {
        guard bytes.count >= 12, bytes.count <= 12 + maximumParameters*4, (bytes.count-12).isMultiple(of: 4) else { throw ZoraError.malformed("USB PTP container length") }
        var r = BinaryReader(bytes)
        guard try r.integer(UInt32.self) == UInt32(bytes.count), try r.integer(UInt16.self) == type else { throw ZoraError.malformed("USB PTP container header") }
        let code = try r.integer(UInt16.self), transaction = try r.integer(UInt32.self)
        var params: [UInt32] = []; while r.offset < bytes.count { params.append(try r.integer()) }
        return (code,transaction,params)
    }
    /// Apple may substitute its own transaction ID. A nil expectedTransaction is
    /// only for a callback already correlated to a single OS request/token.
    public static func response(_ bytes: Data, payload: Data, expectedTransaction: UInt32? = nil) throws -> PTPResult {
        let header = try parse(bytes, type: 3, maximumParameters: 5)
        if let expectedTransaction, header.transaction != expectedTransaction { throw ZoraError.malformed("USB PTP response transaction") }
        guard payload.count <= PTPFramer.maximumPacket else { throw ZoraError.unsupported("USB ���δ��䳬���ڴ����ޣ���ʹ�÷ֿ�����") }
        guard header.code == 0x2001 else { throw ZoraError.cameraResponse(header.code) }
        return PTPResult(data: payload, parameters: header.parameters)
    }
}

public struct CameraStorage: Identifiable, Sendable {
    public let id: UInt32
    public let capacity: UInt64, freeBytes: UInt64
    public let freeImages: UInt32
    public let description: String, label: String
    public init(id: UInt32, data: Data) throws {
        var r = BinaryReader(data)
        _ = try r.integer(UInt16.self); _ = try r.integer(UInt16.self); _ = try r.integer(UInt16.self)
        capacity = try r.integer(); freeBytes = try r.integer(); freeImages = try r.integer()
        description = try r.ptpString(); label = try r.ptpString(); self.id = id
        guard freeBytes <= capacity || capacity == UInt64.max else { throw ZoraError.malformed("storage capacity") }
    }
}

public struct CameraObjectPage: Sendable {
    public let objects: [CameraObject]
    public let nextOffset: Int?
    public let total: Int
}

public enum FocusDriveResult: Sendable, Equatable { case completed, accepted, endOfTravel, stepTooSmall }

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
    public var changesStorage: Bool { [0x4002,0x4003,0x4004,0x4005,0x4007,0x4008,0x4009,0x400d,0xc101].contains(code) }
    /// ObjectAdded carries the new handle; Nikon SDRAM captures are not on a card and are not imported.
    public var addedObject: UInt32? { code == 0x4002 ? parameters.first : nil }
    public var changesProperty: Bool { code == 0x4006 }
    public var name: String {
        switch code {
        case 0x4002: "新增文件"; case 0x4003: "文件已删除"; case 0x4004: "插入存储卡"; case 0x4005: "移除存储卡"
        case 0x4006: "相机设置改变"; case 0x4007: "文件信息改变"; case 0x4008: "设备信息改变"; case 0x4009: "请求传输"
        case 0x400a: "存储卡已满"; case 0x400c: "存储卡信息改变"; case 0x400d: "拍摄完成"
        case 0xc101: "Nikon 内存图像"; case 0xc102: "Nikon 内存拍摄完成"; case 0xc105: "Nikon 预览图"
        default: String(format: "事件 %04X", code)
        }
    }
}

/// Nikon CheckEvent (0x90C7) payload: UInt16 count, then count × (UInt16 code, UInt32 parameter).
public enum NikonEventList {
    public static func parse(_ data: Data) throws -> [CameraEvent] {
        var r = BinaryReader(data)
        let count = Int(try r.integer(UInt16.self))
        guard count <= (data.count - 2) / 6 else { throw ZoraError.malformed("Nikon event list") }
        return try (0..<count).map { _ in
            let code = try r.integer(UInt16.self), parameter = try r.integer(UInt32.self)
            return CameraEvent(code: code, transaction: 0, parameters: [parameter])
        }
    }
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
        guard payload.count <= PTPFramer.maximumPacket else { throw ZoraError.unsupported("USB 单次传输超过内存上限，请使用分块下载") }
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

public struct DownloadProgress: Sendable, Equatable {
    public let received: UInt64, total: UInt64
    public let resumedFrom: UInt64
    public var fraction: Double { total == 0 ? 1 : Double(received) / Double(total) }
}

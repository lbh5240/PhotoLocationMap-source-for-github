import Foundation

public enum PTPOperation {
    public static let deviceInfo: UInt16 = 0x1001, openSession: UInt16 = 0x1002, closeSession: UInt16 = 0x1003
    public static let storageIDs: UInt16 = 0x1004, objectHandles: UInt16 = 0x1007, objectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009, capture: UInt16 = 0x100E, deleteObject: UInt16 = 0x100B
    public static let storageInfo: UInt16 = 0x1005, thumbnail: UInt16 = 0x100A, partialObject: UInt16 = 0x101B
    public static let manualFocus: UInt16 = 0x9204, captureToCard: UInt16 = 0x9207, vendorStorageIDs: UInt16 = 0x9209
    public static let startMovie: UInt16 = 0x920A, endMovie: UInt16 = 0x920B, terminateCapture: UInt16 = 0x920C
    public static let remoteControl: UInt16 = 0x90C2, deviceReady: UInt16 = 0x90C8, checkEvent: UInt16 = 0x90C7
    public static let propertyDescription: UInt16 = 0x1014, propertyValue: UInt16 = 0x1015, setProperty: UInt16 = 0x1016
    public static let startLiveView: UInt16 = 0x9201, endLiveView: UInt16 = 0x9202, liveViewImage: UInt16 = 0x9203
    public static let autoFocus: UInt16 = 0x90C1, changeAFArea: UInt16 = 0x9205, cancelAutoFocus: UInt16 = 0x9206

    /// Human-readable names for the capability list. Unknown codes stay hexadecimal.
    public static func name(_ code: UInt16) -> String {
        switch code {
        case deviceInfo: "设备信息"; case openSession: "打开会话"; case closeSession: "关闭会话"
        case storageIDs: "存储卡列表"; case storageInfo: "存储卡容量"; case objectHandles: "文件列表"; case objectInfo: "文件信息"
        case getObject: "下载文件"; case thumbnail: "缩略图"; case deleteObject: "删除文件"; case capture: "标准拍照"
        case partialObject: "分块下载"; case propertyDescription: "读取属性描述"; case propertyValue: "读取属性值"; case setProperty: "写入属性"
        case autoFocus: "自动对焦"; case remoteControl: "远程控制接管"; case checkEvent: "Nikon 事件轮询"; case deviceReady: "就绪查询"
        case startLiveView: "开始实时取景"; case endLiveView: "结束实时取景"; case liveViewImage: "取景帧"
        case manualFocus: "手动调焦"; case changeAFArea: "触摸对焦区域"; case cancelAutoFocus: "取消对焦"
        case captureToCard: "拍照写卡"; case vendorStorageIDs: "Nikon 存储卡列表"
        case startMovie: "开始录像"; case endMovie: "结束录像"; case terminateCapture: "终止连拍/长曝光"
        default: String(format: "操作 %04X", code)
        }
    }
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
    public let operations: Set<UInt16>, events: Set<UInt16>, properties: Set<UInt16>
    public init(data: Data) throws {
        var r = BinaryReader(data)
        _ = try r.integer(UInt16.self); vendor = try r.integer(UInt32.self)
        _ = try r.integer(UInt16.self); _ = try r.ptpString(); _ = try r.integer(UInt16.self)
        operations = Set(try r.array16()); events = Set(try r.array16()); properties = Set(try r.array16())
        _ = try r.array16(); _ = try r.array16()
        manufacturer = try r.ptpString(); model = try r.ptpString(); firmware = try r.ptpString(); serial = try r.ptpString()
    }
    public var canLiveView: Bool {
        vendor == 0xA && [PTPOperation.startLiveView, PTPOperation.endLiveView, PTPOperation.liveViewImage].allSatisfy(operations.contains)
    }
    public var canCapture: Bool { operations.contains(PTPOperation.captureToCard) || operations.contains(PTPOperation.capture) }
    public var canRecordMovie: Bool { [PTPOperation.startMovie, PTPOperation.endMovie].allSatisfy(operations.contains) }
    /// Touch AF also needs a validated live-view geometry; the opcode alone is not enough.
    public var canChangeAFArea: Bool { canLiveView && operations.contains(PTPOperation.changeAFArea) }
    public var canDelete: Bool { operations.contains(PTPOperation.deleteObject) }
    /// Serial is shown only as a suffix in the UI and diagnostics.
    public var maskedSerial: String { serial.count <= 4 ? serial : "…\(serial.suffix(4))" }
}

public struct CameraObject: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable { case jpeg, heif, raw, movie, folder, other }
    public let id: UInt32, filename: String, size: UInt32, format: UInt16
    public let storage: UInt32
    /// PTP DateTime string (YYYYMMDDThhmmss). Empty when the camera omits it.
    public let captureDate: String
    public init(handle: UInt32, data: Data) throws {
        var r = BinaryReader(data)
        storage = try r.integer(UInt32.self); format = try r.integer(UInt16.self)
        _ = try r.integer(UInt16.self); size = try r.integer(UInt32.self)
        _ = try r.bytes(40)
        filename = try r.ptpString(); id = handle
        // Older firmware and fixtures may end after the filename; dates are optional metadata.
        captureDate = (try? r.ptpString()) ?? ""
    }
    public var kind: Kind {
        if format == 0x3001 { return .folder }
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "hif", "heif", "heic": return .heif
        case "nef", "nrw": return .raw
        case "mov", "mp4": return .movie
        default: return format == 0x3801 ? .jpeg : .other
        }
    }
    /// Stable identity across sessions: object handles can be reassigned after reconnect.
    public var sourceKey: String { "\(storage)-\(filename)-\(size)-\(captureDate)" }
    public var displayDate: String? {
        guard captureDate.count >= 15 else { return nil }
        let c = Array(captureDate)
        return "\(String(c[0..<4]))-\(String(c[4..<6]))-\(String(c[6..<8])) \(String(c[9..<11])):\(String(c[11..<13]))"
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
            guard expected! <= UInt64(PTPFramer.maximumPacket) else { throw ZoraError.unsupported("单次相机文件下载上限为 64 MiB") }
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
        try locate(data).jpeg
    }
    static func locate(_ data: Data) throws -> (jpeg: Data, start: Int) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw ZoraError.malformed("empty live view") }
        for i in 0..<min(bytes.count - 2, 4096) where bytes[i] == 0xff && bytes[i+1] == 0xd8 && bytes[i+2] == 0xff {
            for j in stride(from: bytes.count - 2, through: i + 2, by: -1) where bytes[j] == 0xff && bytes[j+1] == 0xd9 {
                return (Data(bytes[i...j+1]), i)
            }
        }
        throw ZoraError.malformed("no complete JPEG in live view payload")
    }
    /// Width/height from the first SOF marker. Used only to validate vendor header fields.
    public static func dimensions(_ jpeg: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](jpeg)
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xff else { return nil }
            let marker = b[i+1]
            if marker == 0xd8 || marker == 0x01 || (0xd0...0xd7).contains(marker) { i += 2; continue }
            let length = Int(b[i+2]) << 8 | Int(b[i+3])
            guard length >= 2 else { return nil }
            if [0xc0, 0xc1, 0xc2, 0xc3].contains(marker) {
                let height = Int(b[i+5]) << 8 | Int(b[i+6]), width = Int(b[i+7]) << 8 | Int(b[i+8])
                return width > 0 && height > 0 ? (width, height) : nil
            }
            i += 2 + length
        }
        return nil
    }
}

public struct LiveFrame: Sendable {
    public let jpeg: Data
    public let geometry: LiveViewGeometry?
}

/// Whole-sensor coordinate space for Nikon ChangeAfArea. Only produced when a vendor
/// header field pair matches the decoded JPEG size and a plausible sensor size follows.
public struct LiveViewGeometry: Sendable, Equatable {
    public let jpegWidth: Int, jpegHeight: Int, wholeWidth: Int, wholeHeight: Int
    public init(jpegWidth: Int, jpegHeight: Int, wholeWidth: Int, wholeHeight: Int) {
        self.jpegWidth = jpegWidth; self.jpegHeight = jpegHeight; self.wholeWidth = wholeWidth; self.wholeHeight = wholeHeight
    }
    public static func parse(_ payload: Data) -> LiveViewGeometry? {
        guard let located = try? LiveViewJPEG.locate(payload), located.start >= 8,
              let size = LiveViewJPEG.dimensions(located.jpeg) else { return nil }
        let header = [UInt8](payload.prefix(min(located.start, 128)))
        func be(_ i: Int) -> Int { Int(header[i]) << 8 | Int(header[i+1]) }
        func le(_ i: Int) -> Int { Int(header[i+1]) << 8 | Int(header[i]) }
        for read in [be, le] {
            var i = 0
            while i + 8 <= header.count {
                if read(i) == size.width, read(i+2) == size.height {
                    let w = read(i+4), h = read(i+6)
                    let ratio = Double(w) / Double(max(h, 1)), expected = Double(size.width) / Double(size.height)
                    if w >= size.width, h >= size.height, w <= 16384, h <= 16384, abs(ratio - expected) / expected < 0.04 {
                        return LiveViewGeometry(jpegWidth: size.width, jpegHeight: size.height, wholeWidth: w, wholeHeight: h)
                    }
                }
                i += 2
            }
        }
        return nil
    }
    /// Normalized (0…1, top-left origin) display point to whole-size sensor coordinates.
    public func sensorPoint(x: Double, y: Double) throws -> (x: UInt32, y: UInt32) {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { throw ZoraError.malformed("对焦点超出取景范围") }
        let px = min(wholeWidth - 1, max(0, Int((x * Double(wholeWidth)).rounded())))
        let py = min(wholeHeight - 1, max(0, Int((y * Double(wholeHeight)).rounded())))
        return (UInt32(px), UInt32(py))
    }
}

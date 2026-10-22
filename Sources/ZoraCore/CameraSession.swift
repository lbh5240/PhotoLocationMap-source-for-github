import Foundation


public protocol PTPPacketTransport: Sendable {
    func open() async throws
    func send(_ packet: PTPPacket) async throws
    func read(timeout: Bool) async throws -> PTPPacket
    func close() async
}

public actor CameraSession {
    private var command: (any PTPPacketTransport)?
    private var events: (any PTPPacketTransport)?
    private var eventTask: Task<Void, Never>?
    private var transaction: UInt32 = 0
    private var locked = false
    public private(set) var device: CameraDeviceInfo?
    private var live = false
    private var generation = UUID()
    private let guid: UUID
    private let factory: @Sendable (String, UInt16) throws -> any PTPPacketTransport
    public init(guid: UUID, factory: @escaping @Sendable (String, UInt16) throws -> any PTPPacketTransport) {
        self.guid = guid; self.factory = factory
    }

    public func connect(host: String, port: UInt16 = 15740) async throws -> CameraDeviceInfo {
        guard !locked else { throw ZoraError.busy }
        locked = true; defer { locked = false }
        await shutdown()
        let cmd = try factory(host, port), evt = try factory(host, port)
        command = cmd; events = evt
        do {
            try await cmd.open(); try await cmd.send(.initialize(guid: guid, name: "ZORA Camera"))
            let ack = try await cmd.read(timeout: true)
            guard ack.type == 2, ack.payload.count >= 24 else { throw ZoraError.unsupported("PTP/IP 初始化被拒绝；可能需要 Nikon 配对或不同网络模式") }
            var r = BinaryReader(ack.payload); let connection = try r.integer(UInt32.self)
            try await evt.open()
            var p = Data(); p.appendLE(connection)
            try await evt.send(PTPPacket(type: 3, payload: p))
            guard try await evt.read(timeout: true).type == 4 else { throw ZoraError.malformed("event init ACK") }
            let currentGeneration = generation
            eventTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let packet = try await evt.read(timeout: false)
                        if packet.type == 13 { try await evt.send(PTPPacket(type: 14)) }
                        else if packet.type != 8 { throw ZoraError.malformed("event packet") }
                    }
                } catch { await self?.eventFailed(generation: currentGeneration) }
            }
            transaction = 0
            let info = try CameraDeviceInfo(data: await execute(PTPOperation.deviceInfo).data)
            guard info.vendor == 0xA, info.manufacturer.lowercased().contains("nikon") else { throw ZoraError.unsupported("此实验驱动仅用于 Nikon 相机") }
            transaction = 0 // OpenSession itself uses transaction ID zero; in-session requests start at one.
            _ = try await execute(PTPOperation.openSession, parameters: [1])
            device = info
            return info
        } catch { await shutdown(); throw error }
    }
    private func eventFailed(generation expected: UUID) async {
        if generation == expected { await shutdown() }
    }
    public func disconnect() async throws {
        guard !locked else { throw ZoraError.busy }
        locked = true; defer { locked = false }
        if live { _ = try? await execute(PTPOperation.endLiveView) }
        if device != nil { _ = try? await execute(PTPOperation.closeSession) }
        await shutdown()
    }
    private func shutdown() async {
        generation = UUID()
        eventTask?.cancel(); eventTask = nil
        await command?.close(); await events?.close()
        command = nil; events = nil; device = nil; live = false
    }
    private func run(_ code: UInt16, parameters: [UInt32] = [], sending: Data? = nil) async throws -> PTPResult {
        guard !locked else { throw ZoraError.busy }
        guard let device else { throw ZoraError.disconnected }
        guard device.operations.contains(code) else { throw ZoraError.unsupported(String(format: "相机未声明操作 %04X", code)) }
        locked = true; defer { locked = false }
        do { return try await execute(code, parameters: parameters, sending: sending) }
        catch {
            // Framing/transport failure invalidates the session. A camera response error preserves it.
            if case ZoraError.cameraResponse = error {} else { await shutdown() }
            throw error
        }
    }
    private func execute(_ code: UInt16, parameters: [UInt32] = [], sending: Data? = nil) async throws -> PTPResult {
        guard let command else { throw ZoraError.disconnected }
        let id = transaction; transaction &+= 1
        try await command.send(.operation(code, transaction: id, parameters: parameters, sending: sending != nil))
        if let sending {
            var start = Data(); start.appendLE(id); start.appendLE(UInt64(sending.count))
            try await command.send(PTPPacket(type: 9, payload: start))
            var end = Data(); end.appendLE(id); end.append(sending)
            try await command.send(PTPPacket(type: 12, payload: end))
        }
        var assembler = PTPTransaction(id: id)
        for _ in 0..<4096 {
            let packet = try await command.read(timeout: true)
            if packet.type == 13 { try await command.send(PTPPacket(type: 14)); continue }
            if let result = try assembler.consume(packet) { return result }
        }
        throw ZoraError.malformed("transaction packet limit")
    }
    public func capture() async throws { _ = try await run(PTPOperation.capture, parameters: [0, 0]) }
    public func autoFocus() async throws { _ = try await run(PTPOperation.autoFocus) }
    public func startLiveView() async throws { _ = try await run(PTPOperation.startLiveView); live = true }
    public func stopLiveView() async throws { _ = try await run(PTPOperation.endLiveView); live = false }
    public func frame() async throws -> Data {
        guard live else { throw ZoraError.unsupported("实时取景未开始") }
        return try LiveViewJPEG.extract(await run(PTPOperation.liveViewImage).data)
    }
    public func properties() async throws -> [CameraProperty] {
        guard let device else { throw ZoraError.disconnected }
        var result: [CameraProperty] = []
        for code: UInt16 in [0x5007, 0x500D, 0x500F, 0x5010, 0x5005] where device.properties.contains(code) {
            let data = try await run(PTPOperation.propertyDescription, parameters: [UInt32(code)]).data
            do { result.append(try CameraProperty(data: data)) }
            catch ZoraError.unsupported { continue }
        }
        return result
    }
    public func set(_ property: CameraProperty, value: Int64) async throws {
        _ = try await run(PTPOperation.setProperty, parameters: [UInt32(property.code)], sending: property.encode(value))
    }
    public func objects() async throws -> [CameraObject] {
        var storageReader = BinaryReader(try await run(PTPOperation.storageIDs).data)
        let stores = try storageReader.array32()
        var objects: [CameraObject] = []
        for store in stores {
            var handles = BinaryReader(try await run(PTPOperation.objectHandles, parameters: [store, 0, 0]).data)
            // Explicit cap prevents locking the UI for very large cards. Further paging is a hardware follow-up.
            for handle in try handles.array32().prefix(200) {
                objects.append(try CameraObject(handle: handle, data: await run(PTPOperation.objectInfo, parameters: [handle]).data))
            }
        }
        return objects
    }
    public func download(_ object: CameraObject, to target: URL) async throws {
        guard object.size <= 64*1024*1024 else { throw ZoraError.unsupported("此版本相机下载上限 64 MiB，可通过文件导入较大 NEF") }
        let data = try await run(PTPOperation.getObject, parameters: [object.id]).data
        guard data.count == Int(object.size) else { throw ZoraError.malformed("download size mismatch") }
        try data.write(to: target, options: .atomic)
    }
}

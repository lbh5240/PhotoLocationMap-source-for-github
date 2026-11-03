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
    private var direct: (any PTPDirectTransport)?
    private var eventTask: Task<Void, Never>?
    private var transaction: UInt32 = 0
    private var locked = false
    public private(set) var device: CameraDeviceInfo?
    private var live = false
    private var remoteOwned = false
    public private(set) var recentEvents: [CameraEvent] = []
    public private(set) var storageRevision: UInt64 = 0
    /// Monotonic across reconnects so consumers never re-handle an old event.
    public private(set) var eventSequence: UInt64 = 0
    private var eventLog: [(sequence: UInt64, event: CameraEvent)] = []
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
                        else if packet.type == 8 { await self?.receiveEvent(try CameraEvent(ipPayload: packet.payload), generation: currentGeneration) }
                        else { throw ZoraError.malformed("event packet") }
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
    public func connect(using transport: any PTPDirectTransport) async throws -> CameraDeviceInfo {
        guard !locked else { throw ZoraError.busy }; locked = true; defer { locked = false }
        await shutdown(); direct = transport
        do {
            try await transport.open() // Real OS-managed USB session; no fabricated PTP ACK.
            transaction = 1
            let info = try CameraDeviceInfo(data: await execute(PTPOperation.deviceInfo).data)
            guard info.vendor == 0xA, info.manufacturer.lowercased().contains("nikon") else { throw ZoraError.unsupported("此 USB 驱动仅用于 Nikon 相机") }
            device = info
            let expected = generation, stream = await transport.eventStream()
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .ptp(let value): await self?.receiveEvent(value, generation: expected)
                    case .disconnected: await self?.eventFailed(generation: expected); return
                    }
                }
            }
            return info
        } catch { await shutdown(); throw error }
    }
    private func receiveEvent(_ event: CameraEvent, generation expected: UUID) {
        guard generation == expected else { return }
        recentEvents.append(event); if recentEvents.count > 40 { recentEvents.removeFirst(recentEvents.count-40) }
        eventSequence &+= 1; eventLog.append((sequence: eventSequence, event: event))
        if eventLog.count > 200 { eventLog.removeFirst(eventLog.count-200) }
        if event.changesStorage { storageRevision &+= 1 }
    }
    /// Events newer than `sequence`. Older entries beyond the bounded log are dropped, not replayed.
    public func events(after sequence: UInt64) -> (events: [CameraEvent], latest: UInt64) {
        (eventLog.filter { $0.sequence > sequence }.map { $0.event }, eventSequence)
    }
    /// Nikon cameras may queue events for CheckEvent instead of the interrupt/event channel.
    /// Returns the number of events received; cameras without 0x90C7 return 0 without traffic.
    @discardableResult public func pollEvents() async throws -> Int {
        guard let device else { throw ZoraError.disconnected }
        guard device.operations.contains(PTPOperation.checkEvent) else { return 0 }
        let expected = generation
        let list = try NikonEventList.parse(await run(PTPOperation.checkEvent).data)
        for event in list { receiveEvent(event, generation: expected) }
        return list.count
    }
    private func eventFailed(generation expected: UUID) async {
        if generation == expected { await shutdown() }
    }
    public func disconnect() async throws {
        guard !locked else { throw ZoraError.busy }
        locked = true; defer { locked = false }
        if live { _ = try? await execute(PTPOperation.endLiveView) }
        if remoteOwned { _ = try? await execute(PTPOperation.remoteControl, parameters: [0]) }
        if device != nil, direct == nil { _ = try? await execute(PTPOperation.closeSession) }
        await shutdown()
    }
    private func shutdown() async {
        let oldDirect = direct, oldCommand = command, oldEvents = events
        generation = UUID()
        eventTask?.cancel(); eventTask = nil
        direct = nil; command = nil; events = nil; device = nil; live = false; remoteOwned = false; recentEvents = []; eventLog = []
        // Detach before awaiting OS close: a stale close must not clear a new session.
        await oldDirect?.close(); await oldCommand?.close(); await oldEvents?.close()
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
        let id = transaction; transaction &+= 1
        if let direct { return try await direct.execute(code: code, transaction: id, parameters: parameters, sending: sending) }
        guard let command else { throw ZoraError.disconnected }
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
    public func capture() async throws {
        if device?.operations.contains(PTPOperation.captureToCard) == true {
            _ = try await run(PTPOperation.captureToCard, parameters: [UInt32.max, 0])
        } else { _ = try await run(PTPOperation.capture, parameters: [0, 0]) }
    }
    public func setRemoteControl(_ enabled: Bool) async throws {
        _ = try await run(PTPOperation.remoteControl, parameters: [enabled ? 1 : 0]); remoteOwned = enabled
    }
    public func startMovie() async throws { _ = try await run(PTPOperation.startMovie) }
    public func stopMovie() async throws { _ = try await run(PTPOperation.endMovie) }
    public func terminateCapture() async throws { _ = try await run(PTPOperation.terminateCapture, parameters: [0,0]) }
    public func driveFocus(near: Bool, steps: UInt32) async throws -> FocusDriveResult {
        guard (1...32767).contains(steps) else { throw ZoraError.malformed("对焦步数需在 1–32767 之间") }
        do { _ = try await run(PTPOperation.manualFocus, parameters: [near ? 1 : 2, steps]) }
        catch ZoraError.cameraResponse(0xA00C) { return .endOfTravel }
        catch ZoraError.cameraResponse(0xA00E) { return .stepTooSmall }
        guard device?.operations.contains(PTPOperation.deviceReady) == true else { return .accepted }
        for _ in 0..<20 {
            do { _ = try await run(PTPOperation.deviceReady); return .completed }
            catch ZoraError.cameraResponse(0x2019) { try await Task.sleep(for: .milliseconds(100)) }
            catch ZoraError.cameraResponse(0xA00C) { return .endOfTravel }
            catch ZoraError.cameraResponse(0xA00E) { return .stepTooSmall }
        }
        throw ZoraError.timeout
    }
    public func autoFocus() async throws { _ = try await run(PTPOperation.autoFocus) }
    public func cancelAutoFocus() async throws { _ = try await run(PTPOperation.cancelAutoFocus) }
    /// Touch AF. Coordinates come from a validated live-view header, never from raw screen pixels.
    public func setAFArea(x: Double, y: Double, geometry: LiveViewGeometry) async throws {
        guard live else { throw ZoraError.unsupported("触摸对焦需要先开始实时取景") }
        let point = try geometry.sensorPoint(x: x, y: y)
        _ = try await run(PTPOperation.changeAFArea, parameters: [point.x, point.y])
    }
    /// Bounded DeviceReady wait used between sequence shots; cameras without 0x90C8 return at once.
    public func waitUntilReady(timeout: Duration = .seconds(10)) async throws {
        guard device?.operations.contains(PTPOperation.deviceReady) == true else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            do { _ = try await run(PTPOperation.deviceReady); return }
            catch ZoraError.cameraResponse(0x2019) {
                guard clock.now < deadline else { throw ZoraError.timeout }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    public func startLiveView() async throws {
        guard device != nil else { throw ZoraError.disconnected }
        guard !live else { return }
        _ = try await run(PTPOperation.startLiveView); live = true
    }
    public func stopLiveView() async throws { _ = try await run(PTPOperation.endLiveView); live = false }
    public var isLive: Bool { live }
    public func frame() async throws -> Data { try await liveFrame().jpeg }
    public func liveFrame() async throws -> LiveFrame {
        guard live else { throw ZoraError.unsupported("实时取景未开始") }
        let data = try await run(PTPOperation.liveViewImage).data
        return LiveFrame(jpeg: try LiveViewJPEG.extract(data), geometry: LiveViewGeometry.parse(data))
    }
    public static let propertyCodes: [UInt16] = [0x500e, 0x5007, 0x500D, 0xD100, 0x500F, 0x5010, 0x5005, 0x500a, 0x500b, 0x5004, 0x5013, 0x500C, 0x5001]
    public func properties() async throws -> [CameraProperty] {
        guard let device else { throw ZoraError.disconnected }
        var result: [CameraProperty] = []
        for code in Self.propertyCodes where device.properties.contains(code) {
            let data = try await run(PTPOperation.propertyDescription, parameters: [UInt32(code)]).data
            do { result.append(try CameraProperty(data: data)) }
            catch ZoraError.unsupported { continue }
        }
        return result
    }
    public func property(_ code: UInt16) async throws -> CameraProperty {
        guard device?.properties.contains(code) == true else { throw ZoraError.unsupported(String(format: "相机未声明属性 %04X", code)) }
        return try CameraProperty(data: await run(PTPOperation.propertyDescription, parameters: [UInt32(code)]).data)
    }
    public func set(_ property: CameraProperty, value: Int64) async throws {
        _ = try await run(PTPOperation.setProperty, parameters: [UInt32(property.code)], sending: property.encode(value))
    }
    public func objects() async throws -> [CameraObject] {
        let stores = try await storageIDs()
        var objects: [CameraObject] = []
        for store in stores {
            var handles = BinaryReader(try await run(PTPOperation.objectHandles, parameters: [store, 0, 0]).data)
            // Explicit cap prevents locking the UI for very large cards. Use objectPage for paging.
            for handle in try handles.array32().prefix(200) {
                objects.append(try CameraObject(handle: handle, data: await run(PTPOperation.objectInfo, parameters: [handle]).data))
            }
        }
        return objects
    }
    public func objectInfo(_ handle: UInt32) async throws -> CameraObject {
        try CameraObject(handle: handle, data: await run(PTPOperation.objectInfo, parameters: [handle]).data)
    }
    /// Deletes one object on the card. Callers must confirm with the user first; no batch or format command exists here.
    public func deleteObject(_ handle: UInt32) async throws {
        _ = try await run(PTPOperation.deleteObject, parameters: [handle, 0]); storageRevision &+= 1
    }
    public func download(_ object: CameraObject, to target: URL, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        if device?.operations.contains(PTPOperation.partialObject) == true { try await downloadChunks(object, to: target, progress: progress); return }
        guard object.size <= 64*1024*1024 else { throw ZoraError.unsupported("相机未声明分块下载，超过 64 MiB 的文件请用 Files 导入") }
        let data = try await run(PTPOperation.getObject, parameters: [object.id]).data
        guard data.count == Int(object.size) else { throw ZoraError.malformed("download size mismatch") }
        try data.write(to: target, options: .atomic)
        progress?(DownloadProgress(received: UInt64(data.count), total: UInt64(object.size), resumedFrom: 0))
    }
    public func storageIDs() async throws -> [UInt32] {
        let op = device?.operations.contains(PTPOperation.vendorStorageIDs) == true ? PTPOperation.vendorStorageIDs : PTPOperation.storageIDs
        var r = BinaryReader(try await run(op).data); return try r.array32()
    }
    public func storageInfo(_ id: UInt32) async throws -> CameraStorage {
        try CameraStorage(id: id, data: await run(PTPOperation.storageInfo, parameters: [id]).data)
    }
    public func objectPage(storage: UInt32, offset: Int = 0, limit: Int = 100) async throws -> CameraObjectPage {
        guard offset >= 0, (1...200).contains(limit) else { throw ZoraError.malformed("文件分页参数") }
        var r = BinaryReader(try await run(PTPOperation.objectHandles, parameters: [storage,0,0]).data)
        let all = try r.array32(); guard offset <= all.count else { throw ZoraError.malformed("存储卡目录发生变化，请刷新") }
        let end = min(offset + limit, all.count)
        var objects: [CameraObject] = []
        for handle in all[offset..<end] {
            try Task.checkCancellation()
            objects.append(try CameraObject(handle: handle, data: await run(PTPOperation.objectInfo, parameters: [handle]).data))
        }
        return CameraObjectPage(objects: objects, nextOffset: end < all.count ? end : nil, total: all.count)
    }
    public func thumbnail(_ handle: UInt32) async throws -> Data {
        try LiveViewJPEG.extract(await run(PTPOperation.thumbnail, parameters: [handle]).data)
    }
    /// Partial files are named from the object's stable identity so an interrupted transfer
    /// (disconnect, cancel, timeout) resumes after reconnect. Invalid data always discards them.
    public static func partialName(for object: CameraObject) -> String {
        let digest = SHA256Digest.hex(SHA256Digest.hash(Data(object.sourceKey.utf8)))
        return ".zora-\(digest.prefix(24)).partial"
    }
    static func resumable(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let value = error as? ZoraError else { return true } // Transport-level failures.
        switch value { case .disconnected, .timeout, .busy: return true; default: return false }
    }
    private func chunk(_ handle: UInt32, offset: UInt32, count: UInt32) async throws -> PTPResult {
        for attempt in 0..<3 {
            do { return try await run(PTPOperation.partialObject, parameters: [handle, offset, count]) }
            catch ZoraError.cameraResponse(0x2019) where attempt < 2 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw ZoraError.busy
    }
    private func downloadChunks(_ object: CameraObject, to target: URL, progress: (@Sendable (DownloadProgress) -> Void)?) async throws {
        guard object.size != UInt32.max, object.format != 0x3001 else { throw ZoraError.unsupported("目录或需要 64 位对象扩展的文件不能在此下载") }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ZoraError.unsupported("目标文件已存在") }
        let staging = target.deletingLastPathComponent().appendingPathComponent(Self.partialName(for: object))
        let existing = (try? FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.uint64Value ?? 0
        var offset: UInt32 = 0
        if existing > 0, existing < UInt64(object.size) { offset = UInt32(existing) }
        else {
            try? FileManager.default.removeItem(at: staging)
            guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw ZoraError.unsupported("无法创建下载临时文件") }
        }
        let resumedFrom = UInt64(offset)
        let file = try FileHandle(forWritingTo: staging)
        var closed = false
        defer { if !closed { try? file.close() } }
        let expected = generation
        do {
            try file.truncate(atOffset: UInt64(offset)); try file.seek(toOffset: UInt64(offset))
            while offset < object.size {
                try Task.checkCancellation(); guard generation == expected else { throw ZoraError.disconnected }
                let count = min(UInt32(4*1024*1024), object.size-offset)
                let result = try await chunk(object.id, offset: offset, count: count)
                guard !result.data.isEmpty, result.data.count <= Int(count),
                      result.parameters.first == UInt32(result.data.count) else { throw ZoraError.malformed("分块下载长度或响应字节数不一致") }
                try file.write(contentsOf: result.data); offset += UInt32(result.data.count)
                progress?(DownloadProgress(received: UInt64(offset), total: UInt64(object.size), resumedFrom: resumedFrom))
            }
            try file.synchronize(); try file.close(); closed = true
            try Task.checkCancellation(); guard generation == expected else { throw ZoraError.disconnected }
            try FileManager.default.moveItem(at: staging, to: target)
        } catch {
            if !closed { try? file.close(); closed = true }
            if !(Self.resumable(error) && offset > 0) { try? FileManager.default.removeItem(at: staging) }
            throw error
        }
    }
}
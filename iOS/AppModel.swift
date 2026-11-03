import Foundation
import Observation
import NetworkExtension
import ZoraCore

struct CameraWiFiProfile: Codable {
    let peripheralID: UUID
    let ssid: String
    let password: String
    let host: String
    let cameraSerial: String?
    init(peripheralID: UUID, ssid: String, password: String, host: String, cameraSerial: String? = nil) {
        self.peripheralID = peripheralID; self.ssid = ssid; self.password = password; self.host = host; self.cameraSerial = cameraSerial
    }
    func matches(_ identity: NikonBLEIdentity?) -> Bool {
        guard let identity else { return false }
        if let cameraSerial { return cameraSerial == identity.serial }
        return peripheralID == identity.peripheralID
    }
}

@MainActor @Observable final class AppModel {
    var error: String?
    var notice: String?
    var busy = false
    var device: CameraDeviceInfo?
    var properties: [CameraProperty] = []
    var cameraObjects: [CameraObject] = []
    var preview: ProcessedPreview?
    var liveGeometry: LiveViewGeometry?
    var streaming = false
    var assets: [LibraryAsset] = []
    var importedKeys: Set<String> = []
    var jobs: [UploadJob] = []
    var recipes = Recipe.presets
    var cube: CubeLUT?
    var cubeName: String?
    var luts: [String] = []
    var destination: NASDestination?
    var connectionProgress: String?
    var sequenceStatus: String?
    var transferName: String?
    var transferFraction: Double?
    var autoImportedCount = 0
    var autoWake = UserDefaults.standard.object(forKey: "bleAutoWake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoWake, forKey: "bleAutoWake") }
    }
    /// SnapBridge-style automatic transfer of new shots, driven by real camera ObjectAdded events.
    var autoImport = UserDefaults.standard.bool(forKey: "autoImport") {
        didSet { UserDefaults.standard.set(autoImport, forKey: "autoImport"); if !autoImport { pendingImports = [] } }
    }
    var autoImportRAW = UserDefaults.standard.bool(forKey: "autoImportRAW") {
        didSet { UserDefaults.standard.set(autoImportRAW, forKey: "autoImportRAW") }
    }
    var autoUpload = UserDefaults.standard.bool(forKey: "autoUpload") {
        didSet { UserDefaults.standard.set(autoUpload, forKey: "autoUpload") }
    }
    let connectivity = Connectivity()
    let usb = USBCamera()
    let location = LocationTagger()
    var connectionType: String?
    var cardStorageIDs: [UInt32] = []
    var storages: [CameraStorage] = []
    var selectedStorage: UInt32?
    var nextObjectOffset: Int?
    var objectTotal = 0
    var cameraThumbnail: Data?
    var protocolEvents: [CameraEvent] = []
    var cameraFilesChanged = false
    private var directoryRevision: UInt64 = 0
    var remoteControl = false
    var recordingRequested = false
    private var usbSelected = false
    let camera: CameraSession
    let library: AssetLibrary
    let uploadQueue: UploadQueue
    let processor = ImageProcessor()
    private let root: URL
    private var liveTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var eventWorker: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var foreground = true
    private var eventCursor: UInt64 = 0
    private var pendingImports: [UInt32] = []
    private var importAttempts: [UInt32: Int] = [:]
    /// Background event polling/import holds the camera; user operations wait for it to finish.
    private var backgroundWork = false
    private var lutDirectory: URL { root.appendingPathComponent("LUTs", isDirectory: true) }
    init() throws {
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ZORA", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = try AssetLibrary(root: root.appendingPathComponent("Originals"))
        uploadQueue = try UploadQueue(store: root.appendingPathComponent("uploads.json"))
        let defaults = UserDefaults.standard
        let guid = defaults.string(forKey: "cameraGUID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(guid.uuidString, forKey: "cameraGUID"); camera = CameraSession(guid: guid) { host, port in try PacketChannel(host: host, port: port) }
        if let data = defaults.data(forKey: "nasDestination") { destination = try JSONDecoder().decode(NASDestination.self, from: data).validated() }
        let recipeURL = root.appendingPathComponent("recipes.json")
        if FileManager.default.fileExists(atPath: recipeURL.path) {
            recipes += try JSONDecoder().decode([Recipe].self, from: Data(contentsOf: recipeURL)).map { try $0.validated() }.filter { !$0.isPreset }
        }
        try FileManager.default.createDirectory(at: lutDirectory, withIntermediateDirectories: true)
        loadLUTs()
    }
    func start() async {
        await refresh()
        connectivity.bluetooth.onAuthenticated = { [weak self] in self?.autoWakeIfReady() }
        usb.onRemoval = { [weak self] in
            guard let self, connectionType == "USB" else { return }
            device = nil; connectionType = nil; properties = []; recordingRequested = false; remoteControl = false; liveGeometry = nil; pendingImports = []
            notice = "USB 控制已中断，拍摄状态请以相机为准"
            Task { await self.stopStream() }
        }
        connectivity.bluetooth.resume(foreground: foreground)
        location.start()
        worker?.cancel()
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        eventWorker?.cancel()
        eventWorker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.backgroundTick()
            }
        }
    }
    func sceneActive(_ active: Bool) {
        foreground = active; connectivity.bluetooth.resume(foreground: active)
        if active { location.start(); autoWakeIfReady() } else { location.stop() }
    }
    private func autoWakeIfReady() {
        guard autoWake, !usbSelected, foreground, !busy, device == nil, connectivity.bluetooth.authenticated,
              let profile = try? Keychain.loadValue(CameraWiFiProfile.self, id: "nikon.wifi"),
              profile.matches(connectivity.bluetooth.identity) else { return }
        perform { try await self.wakeAndConnect() }
    }
    func saveCameraWiFi(ssid: String, password: String, host: String) throws {
        guard connectivity.bluetooth.authenticated, let identity = connectivity.bluetooth.identity else { throw ZoraError.unsupported("请先完成相机配对注册，再保存 Wi-Fi") }
        guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !host.isEmpty,
              password.isEmpty || (8...63).contains(password.utf8.count) else { throw ZoraError.malformed("请输入有效 SSID、地址及 8–63 字节的 Wi-Fi 密码") }
        try Keychain.saveValue(CameraWiFiProfile(peripheralID: identity.peripheralID, ssid: ssid, password: password, host: host, cameraSerial: identity.serial), id: "nikon.wifi")
        notice = "相机 Wi-Fi 已保存到本机钥匙串，后续唤醒可自动衔接连接"
    }
    func wakeAndConnect() async throws {
        guard foreground else { throw ZoraError.unsupported("请回到前台完成相机 Wi-Fi 连接") }
        let profile = try Keychain.loadValue(CameraWiFiProfile.self, id: "nikon.wifi")
        let generation = connectivity.bluetooth.automationGeneration
        func checkConnectionIntent() throws {
            try Task.checkCancellation()
            guard foreground, generation == connectivity.bluetooth.automationGeneration,
                  profile.matches(connectivity.bluetooth.identity) else {
                throw ZoraError.unsupported("自动连接已停止，请在前台重新选择相机")
            }
        }
        guard profile.matches(connectivity.bluetooth.identity) else { throw ZoraError.unsupported("Wi-Fi 资料属于另一台相机，请重新保存") }
        if profile.cameraSerial == nil, let id = connectivity.bluetooth.identity {
            try Keychain.saveValue(CameraWiFiProfile(peripheralID: id.peripheralID, ssid: profile.ssid, password: profile.password, host: profile.host, cameraSerial: id.serial), id: "nikon.wifi")
        }
        connectionProgress = "1/3 · 发送蓝牙唤醒请求"
        defer { connectionProgress = nil }
        try await connectivity.bluetooth.wakeWiFi()
        connectionProgress = "2/3 · 等待相机热点 · 请允许 iOS 加入网络"
        var joinError: Error?
        for delay in [2, 3, 5] {
            try await Task.sleep(for: .seconds(delay)); try checkConnectionIntent()
            do { try await connectivity.join(ssid: profile.ssid, password: profile.password); joinError = nil; break }
            catch {
                joinError = error
                // Do not repeatedly present a system prompt after explicit denial.
                let value = error as NSError
                if value.domain == NEHotspotConfigurationErrorDomain,
                   value.code == NEHotspotConfigurationError.userDenied.rawValue { throw error }
            }
        }
        if let joinError { throw joinError }
        connectionProgress = "3/3 · 验证真实 PTP 相机会话"
        var lastError: Error = ZoraError.disconnected
        for _ in 0..<4 {
            try checkConnectionIntent()
            do {
                try await connect(host: profile.host)
                do { try checkConnectionIntent() }
                catch { try? await disconnect(); throw error }
                return
            } catch { lastError = error }
            try await Task.sleep(for: .seconds(2))
        }
        throw lastError
    }
    func refresh() async {
        assets = await library.assets(); jobs = await uploadQueue.snapshot()
        importedKeys = await library.importedSourceKeys
        protocolEvents = await camera.recentEvents
        let revision = await camera.storageRevision
        cameraFilesChanged = !cameraObjects.isEmpty && directoryRevision != revision
        if device != nil, await camera.device == nil { clearCameraState() }
    }
    private func clearCameraState() {
        device = nil; connectionType = nil; properties = []; remoteControl = false; recordingRequested = false
        liveGeometry = nil; pendingImports = []; importAttempts = [:]
    }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        operationTask = Task {
            defer { busy = false }
            // A background poll/import already owns the camera transaction; never interleave.
            while backgroundWork { try? await Task.sleep(for: .milliseconds(50)) }
            do { try await operation(); await refresh() }
            catch {
                if error is CancellationError { notice = "后续操作已取消，已发出的相机指令请以机身状态为准" }
                else { self.error = error.localizedDescription }
                device = await camera.device
                if device == nil { await stopStream(); clearCameraState() }
            }
        }
    }
    func cancelOperation() { operationTask?.cancel() }
    func connect(host: String) async throws {
        usbSelected = false
        await stopStream()
        device = nil; connectionType = nil; properties = []; cameraObjects = []
        device = try await camera.connect(host: host)
        connectionType = "Wi-Fi"; remoteControl = false; recordingRequested = false
        eventCursor = await camera.eventSequence
        // Connection success comes only from real handshake + GetDeviceInfo + OpenSession.
        notice = "真实 PTP 会话已建立；设备能力已读取，具体操作仍需逐项验证"
        do { properties = try await camera.properties() } catch { self.error = error.localizedDescription }
    }
    func connectUSB(_ id: String) async throws {
        usbSelected = true
        await stopStream(); try await camera.disconnect()
        device = nil; properties = []; cameraObjects = []; connectionType = nil
        try usb.select(id)
        device = try await camera.connect(using: usb)
        connectionType = "USB"; remoteControl = false; recordingRequested = false
        eventCursor = await camera.eventSequence
        notice = "系统 USB 会话与 Nikon 设备信息已验证；具体功能仍需真机验收"
        do { properties = try await camera.properties() } catch { self.error = error.localizedDescription }
    }
    func disconnect() async throws { await stopStream(); try await camera.disconnect(); clearCameraState(); cameraObjects = [] }
    func setRemoteControl(_ enabled: Bool) async throws {
        await stopStream(); try await camera.setRemoteControl(enabled); remoteControl = enabled
        notice = enabled ? "相机接受远程接管；部分机身按键可能暂时锁定，完成后请释放控制" : "相机接受释放远程控制"
    }
    func setMovieRecording(_ enabled: Bool) async throws {
        try await withLiveControl(ensureLive: enabled) {
            if enabled { try await self.camera.startMovie() } else { try await self.camera.stopMovie() }
            self.recordingRequested = enabled
        }
        notice = enabled ? "相机已接受开始录像指令，请以机身录制指示/完成事件确认" : "相机已接受停止录像指令，请确认文件写入完成"
    }
    func driveFocus(near: Bool, steps: UInt32) async throws {
        let result = try await withLiveControl(ensureLive: true) { try await self.camera.driveFocus(near: near, steps: steps) }
        switch result {
        case .completed: notice = "相机已返回对焦驱动就绪"
        case .accepted: notice = "相机已接受对焦驱动；未提供完成状态查询"
        case .endOfTravel: notice = "镜头已到调焦行程边界"
        case .stepTooSmall: notice = "对焦步长过小，请增大后重试"
        }
    }
    var canTouchFocus: Bool { device?.canChangeAFArea == true && liveGeometry != nil && streaming }
    /// Touch AF: move the AF area to the tapped point (validated sensor coordinates), then focus if supported.
    func touchFocus(x: Double, y: Double) async throws {
        guard device?.canChangeAFArea == true else { throw ZoraError.unsupported("相机未声明触摸对焦区域指令") }
        guard let geometry = liveGeometry else { throw ZoraError.unsupported("取景帧未能校验对焦坐标系，触摸对焦保持关闭") }
        try await withLiveControl(ensureLive: true) {
            try await self.camera.setAFArea(x: x, y: y, geometry: geometry)
            if self.device?.operations.contains(PTPOperation.autoFocus) == true { try await self.camera.autoFocus() }
        }
    }
    /// Pause polling without EndLiveView: Nikon MF/movie commands require the
    /// camera's live-view state. Re-entering the UI polling loop must not restart it.
    private func withLiveControl<T: Sendable>(ensureLive: Bool, operation: @MainActor () async throws -> T) async throws -> T {
        let resume = streaming || ensureLive
        streaming = false; await liveTask?.value; liveTask = nil
        let result: T
        do {
            if ensureLive { try await camera.startLiveView() }
            result = try await operation()
        } catch {
            if resume, foreground { try? await startStream() }
            throw error
        }
        if resume, foreground {
            do { try await startStream() }
            catch { self.error = "相机指令已被接受，但监看恢复失败；请勿因此重复发送拍摄指令。\(error.localizedDescription)" }
        }
        return result
    }
    func startStream() async throws {
        guard !streaming else { return }
        guard device?.canLiveView == true else { throw ZoraError.unsupported("相机没有声明完整 Nikon Live View 能力") }
        try await camera.startLiveView(); streaming = true
        liveTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0
            do {
                while streaming && !Task.isCancelled {
                    let frame = try await camera.liveFrame()
                    liveGeometry = frame.geometry
                    preview = try await processor.preview(jpeg: frame.jpeg)
                    tick += 1
                    // Events and auto-import share the same serialized command loop as frames.
                    if tick % 8 == 0 { await serviceEvents(importLimit: 1) }
                    try await Task.sleep(for: .milliseconds(120))
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if streaming { try? await camera.stopLiveView() }
            device = await camera.device
            streaming = false
        }
    }
    func stopStream() async {
        let hadTask = liveTask != nil
        streaming = false; await liveTask?.value; liveTask = nil
        if hadTask { try? await camera.stopLiveView() }
        streaming = false; preview = nil; liveGeometry = nil
    }
    func capture() async throws {
        await stopStream(); try await camera.capture()
        notice = autoImport ? "相机已接受快门指令。新照片写卡后会自动导入。" : "相机已接受快门指令。请刷新相机文件确认照片落盘。"
    }
    func set(_ property: CameraProperty, value: Int64) async throws {
        await stopStream(); try await camera.set(property, value: value); properties = try await camera.properties()
    }

    // MARK: Events and automatic transfer
    private func backgroundTick() async {
        guard device != nil, !busy, !streaming, foreground, !backgroundWork else { return }
        backgroundWork = true; defer { backgroundWork = false }
        await serviceEvents(importLimit: 3)
    }
    /// Poll Nikon CheckEvent when declared, then react to events from any channel.
    private func serviceEvents(importLimit: Int) async {
        guard device != nil else { return }
        _ = try? await camera.pollEvents()
        let batch = await camera.events(after: eventCursor); eventCursor = batch.latest
        protocolEvents = await camera.recentEvents
        var propertiesChanged = false
        for event in batch.events {
            if autoImport, let handle = event.addedObject, !pendingImports.contains(handle) { pendingImports.append(handle) }
            if event.changesProperty { propertiesChanged = true }
        }
        if propertiesChanged, let next = try? await camera.properties() { properties = next }
        if autoImport, !pendingImports.isEmpty { await importPending(limit: importLimit) }
        let revision = await camera.storageRevision
        cameraFilesChanged = !cameraObjects.isEmpty && directoryRevision != revision
    }
    private func importPending(limit: Int) async {
        var handled = 0
        while handled < limit, !pendingImports.isEmpty, device != nil {
            let handle = pendingImports.removeFirst()
            do {
                let object = try await camera.objectInfo(handle)
                handled += 1
                let wanted: [CameraObject.Kind] = autoImportRAW ? [.jpeg, .heif, .raw] : [.jpeg, .heif]
                guard wanted.contains(object.kind) else { continue }
                if try await importObject(object, upload: autoUpload) { autoImportedCount += 1 }
                importAttempts[handle] = nil
            } catch ZoraError.cameraResponse(let code) where streaming || code == 0x2019 {
                // Camera still writing, or refuses transfers during live view: retry later, bounded.
                let attempts = (importAttempts[handle] ?? 0) + 1; importAttempts[handle] = attempts
                if attempts < 6 { pendingImports.append(handle) }
                return
            } catch {
                importAttempts[handle] = nil
                self.error = "自动导入未完成：\(error.localizedDescription)"
                return
            }
        }
    }
    /// Downloads one camera object into the library. Returns false when it was imported before.
    @discardableResult private func importObject(_ object: CameraObject, upload: Bool) async throws -> Bool {
        guard !importedKeys.contains(object.sourceKey) else { return false }
        let ext = URL(fileURLWithPath: object.filename).pathExtension.lowercased()
        let staging = root.appendingPathComponent("\(UUID()).\(ext)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let name = object.filename
        transferName = name; transferFraction = 0
        defer { transferName = nil; transferFraction = nil }
        try await camera.download(object, to: staging) { progress in
            Task { @MainActor [weak self] in
                guard let self, self.transferName == name else { return }
                self.transferFraction = progress.fraction
            }
        }
        let asset = try await library.importFile(staging, originalName: object.filename, sourceKey: object.sourceKey, location: location.current)
        importedKeys.insert(object.sourceKey)
        if upload, destination != nil { try await enqueue(asset, drain: false) }
        assets = await library.assets()
        return true
    }

    // MARK: Sequences (run inside perform; cancel with cancelOperation)
    func runInterval(_ plan: IntervalPlan) async throws {
        let plan = try plan.validated()
        guard device?.canCapture == true else { throw ZoraError.unsupported("相机未声明拍照指令") }
        await stopStream()
        defer { sequenceStatus = nil }
        let clock = ContinuousClock()
        let start = clock.now
        var index: Int? = 0, taken = 0, skipped = 0
        while let current = index {
            let due = start + .milliseconds(Int64(plan.offset(of: current) * 1000))
            while clock.now < due {
                try Task.checkCancellation()
                let remaining = due - clock.now
                sequenceStatus = plan.shots == 1 ? "自拍倒计时 \(Int(seconds(remaining).rounded(.up))) 秒"
                    : "间隔拍摄 \(current + 1)/\(plan.shots) · \(Int(seconds(remaining).rounded(.up))) 秒后拍摄"
                try await Task.sleep(for: min(remaining, .seconds(1)))
            }
            sequenceStatus = plan.shots == 1 ? "正在释放快门" : "间隔拍摄 \(current + 1)/\(plan.shots) · 拍摄中"
            try await camera.capture(); taken += 1
            try await camera.waitUntilReady()
            await serviceEvents(importLimit: 2)
            index = plan.nextIndex(after: current, elapsed: seconds(clock.now - start))
            if let next = index { skipped += next - current - 1 } else { skipped += plan.shots - current - 1 }
        }
        notice = plan.shots == 1 ? "相机已接受延时快门指令。"
            : "间隔拍摄结束：相机接受 \(taken) 次快门" + (skipped > 0 ? "，因拍摄耗时超过间隔跳过 \(skipped) 个时间点。" : "。")
    }
    func runBracket(code: UInt16, frames: Int, spacing: Int) async throws {
        guard device?.canCapture == true else { throw ZoraError.unsupported("相机未声明拍照指令") }
        await stopStream()
        defer { sequenceStatus = nil }
        let property = try await camera.property(code)
        let plan = try BracketPlan(property: property, frames: frames, spacing: spacing)
        do {
            for (i, value) in plan.values.enumerated() {
                try Task.checkCancellation()
                sequenceStatus = "包围曝光 \(i + 1)/\(plan.values.count) · \(property.label(for: value))"
                if i > 0 { try await camera.set(property, value: value) }
                try await camera.capture(); try await camera.waitUntilReady()
            }
        } catch {
            // Always try to put the camera back where the user left it.
            try? await camera.set(property, value: plan.original)
            properties = (try? await camera.properties()) ?? properties
            throw error
        }
        try await camera.set(property, value: plan.original)
        properties = try await camera.properties()
        notice = "包围曝光完成：\(plan.values.count) 张，\(property.title) 已恢复为 \(property.label(for: plan.original))"
    }
    var canFocusStack: Bool {
        guard let device else { return false }
        return device.canCapture && device.canLiveView && device.operations.contains(PTPOperation.manualFocus)
    }
    func runFocusStack(_ plan: FocusStackPlan) async throws {
        let plan = try plan.validated()
        guard canFocusStack else { throw ZoraError.unsupported("相机未同时声明拍照、实时取景与手动调焦指令") }
        await stopStream()
        defer { sequenceStatus = nil }
        var taken = 0, reachedEnd = false
        do {
            for i in 0..<plan.shots {
                try Task.checkCancellation()
                sequenceStatus = "焦点包围 \(i + 1)/\(plan.shots)"
                if await camera.isLive { try await camera.stopLiveView() }
                try await camera.capture(); taken += 1
                try await camera.waitUntilReady()
                guard i < plan.shots - 1 else { break }
                try await camera.startLiveView()
                let result = try await camera.driveFocus(near: plan.towardNear, steps: plan.steps)
                if result == .endOfTravel { reachedEnd = true; break }
                if result == .stepTooSmall { throw ZoraError.unsupported("对焦步长过小，请增大后重试") }
            }
        } catch {
            if await camera.isLive { try? await camera.stopLiveView() }
            throw error
        }
        if await camera.isLive { try? await camera.stopLiveView() }
        notice = reachedEnd ? "镜头到达调焦行程边界，焦点包围在第 \(taken) 张结束" : "焦点包围完成：相机接受 \(taken) 次快门"
    }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: Camera files
    func listCameraFiles() async throws {
        await stopStream(); cardStorageIDs = try await camera.storageIDs(); storages = []
        if device?.operations.contains(PTPOperation.storageInfo) == true {
            for id in cardStorageIDs { do { storages.append(try await camera.storageInfo(id)) } catch { notice = "部分存储卡信息不可读取：\(error.localizedDescription)" } }
        }
        if selectedStorage == nil || !cardStorageIDs.contains(selectedStorage!) { selectedStorage = cardStorageIDs.first }
        try await loadCameraPage(reset: true)
    }
    func loadCameraPage(reset: Bool) async throws {
        if !reset, directoryRevision != (await camera.storageRevision) { throw ZoraError.unsupported("相机文件已变化，请先刷新目录再继续分页") }
        guard let id = selectedStorage else { cameraObjects = []; nextObjectOffset = nil; objectTotal = 0; return }
        let page = try await camera.objectPage(storage: id, offset: reset ? 0 : nextObjectOffset ?? 0)
        if reset { cameraObjects = page.objects } else {
            let known = Set(cameraObjects.map(\.id)); cameraObjects += page.objects.filter { !known.contains($0.id) }
        }
        nextObjectOffset = page.nextOffset; objectTotal = page.total
        directoryRevision = await camera.storageRevision; cameraFilesChanged = false
    }
    func loadThumbnail(_ object: CameraObject) async throws { await stopStream(); cameraThumbnail = try await camera.thumbnail(object.id) }
    func download(_ object: CameraObject) async throws {
        await stopStream()
        guard object.kind != .movie else { throw ZoraError.unsupported("视频文件请用“文件”App 或电脑导入；照片库仅保存静态照片") }
        if try await importObject(object, upload: false) { notice = "\(object.filename) 已保存到照片库" }
        else { notice = "\(object.filename) 已在照片库中" }
    }
    /// Downloads every listed, not-yet-imported photo of the chosen kinds. Cancellable between files.
    func downloadAll(kinds: Set<CameraObject.Kind>) async throws {
        await stopStream()
        let targets = cameraObjects.filter { kinds.contains($0.kind) && !importedKeys.contains($0.sourceKey) }
        guard !targets.isEmpty else { notice = "当前列表中没有需要导入的照片"; return }
        defer { sequenceStatus = nil }
        var done = 0
        for object in targets {
            try Task.checkCancellation()
            sequenceStatus = "批量导入 \(done + 1)/\(targets.count)"
            if try await importObject(object, upload: autoUpload) { done += 1 }
        }
        notice = "已导入 \(done) 个文件"
    }
    func deleteCameraObject(_ object: CameraObject) async throws {
        await stopStream(); try await camera.deleteObject(object.id)
        cameraObjects.removeAll { $0.id == object.id }; objectTotal = max(0, objectTotal - 1)
        if let offset = nextObjectOffset { nextObjectOffset = max(0, offset - 1) }
        directoryRevision = await camera.storageRevision
        notice = "相机已删除 \(object.filename)"
    }

    // MARK: Library
    func importFiles(_ urls: [URL]) async throws {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            _ = try await library.importFile(url)
        }
        await refresh()
    }
    func setFavorite(_ asset: LibraryAsset, _ favorite: Bool) async throws { try await library.setFavorite(favorite, for: asset.id); await refresh() }
    func setRating(_ asset: LibraryAsset, _ rating: Int) async throws { try await library.setRating(rating, for: asset.id); await refresh() }
    func deleteAsset(_ asset: LibraryAsset) async throws {
        guard !jobs.contains(where: { $0.file.lastPathComponent == asset.storedName && $0.state == .uploading }) else { throw ZoraError.busy }
        try await library.delete(asset.id); await refresh()
    }
    func enqueue(_ asset: LibraryAsset, drain: Bool = true) async throws {
        guard let destination else { throw ZoraError.unsupported("请先配置 NAS") }
        let file = try await library.url(for: asset)
        // Stable unique key: reattempts never create a second remote object.
        let key = destination.kind == .webDAV ? "\(asset.id.uuidString)-\(asset.originalName)" : "\(asset.id.uuidString)/\(asset.originalName)"
        try await uploadQueue.enqueue(file: file, key: key, destination: destination)
        jobs = await uploadQueue.snapshot()
        if drain { await refresh(); await sync() }
    }
    func sync() async {
        do { try await uploadQueue.drain(using: HTTPUploadTransport { id in try Keychain.load(id: id) }, online: connectivity.online) }
        catch { self.error = error.localizedDescription }
        jobs = await uploadQueue.snapshot()
        if !busy, !backgroundWork, device != nil {
            device = await camera.device
            if device == nil { clearCameraState(); cameraObjects = [] }
        }
    }
    func saveDestination(_ next: NASDestination, username: String, secret: String, token: String) throws {
        var valid = try next.validated()
        if let current = destination, current.kind == valid.kind, current.endpoint == valid.endpoint,
           current.bucket == valid.bucket, current.region == valid.region, current.prefix == valid.prefix {
            valid.credentialID = current.credentialID // Updating a password must repair pending jobs for this destination.
        } else { valid.credentialID = "nas-\(UUID().uuidString)" }
        guard !username.isEmpty, !secret.isEmpty else { throw ZoraError.malformed("请输入用户名/Access Key 与密码/Secret Key") }
        try Keychain.save(NASCredential(username: username, secret: secret, token: token.isEmpty ? nil : token), id: valid.credentialID)
        UserDefaults.standard.set(try JSONEncoder().encode(valid), forKey: "nasDestination"); destination = valid
        notice = "NAS 配置已保存。WebDAV 缺少目录时会尝试自动创建；实际上传结果见任务队列。"
    }

    // MARK: Looks
    func importLook(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "cube" {
            let text = try String(contentsOf: url, encoding: .utf8)
            _ = try CubeLUT(text: text) // Validate before keeping a copy.
            var name = url.lastPathComponent, n = 2
            while FileManager.default.fileExists(atPath: lutDirectory.appendingPathComponent(name).path) {
                name = "\(url.deletingPathExtension().lastPathComponent) \(n).cube"; n += 1
            }
            try Data(text.utf8).write(to: lutDirectory.appendingPathComponent(name), options: .atomic)
            loadLUTs(); try selectLUT(name)
        } else {
            var recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: url)).validated()
            recipe.id = UUID(); recipes.append(recipe); try persistRecipes()
        }
    }
    private func loadLUTs() {
        luts = ((try? FileManager.default.contentsOfDirectory(atPath: lutDirectory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".cube") }.sorted()
        if cubeName == nil, let active = UserDefaults.standard.string(forKey: "activeLUT"), luts.contains(active) { try? selectLUT(active) }
    }
    func selectLUT(_ name: String?) throws {
        guard let name else { cube = nil; cubeName = nil; UserDefaults.standard.removeObject(forKey: "activeLUT"); return }
        guard luts.contains(name) else { throw ZoraError.malformed("LUT 不存在") }
        cube = try CubeLUT(text: String(contentsOf: lutDirectory.appendingPathComponent(name), encoding: .utf8)); cubeName = name
        UserDefaults.standard.set(name, forKey: "activeLUT")
    }
    func deleteLUT(_ name: String) throws {
        guard luts.contains(name) else { return }
        try FileManager.default.removeItem(at: lutDirectory.appendingPathComponent(name))
        if cubeName == name { try selectLUT(nil) }
        loadLUTs()
    }
    func saveRecipe(_ recipe: Recipe, name: String) throws {
        var next = recipe; next.id = UUID(); next.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        recipes.append(try next.validated()); try persistRecipes()
        notice = "已保存风格「\(next.name)」"
    }
    func deleteRecipe(_ recipe: Recipe) throws {
        guard !recipe.isPreset else { throw ZoraError.unsupported("内置风格不能删除") }
        recipes.removeAll { $0.id == recipe.id }; try persistRecipes()
    }
    func exportRecipe(_ recipe: Recipe) throws -> URL {
        let directory = root.appendingPathComponent("Exports"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = recipe.name.map { "/\\:".contains($0) ? "_" : $0 }
        let target = directory.appendingPathComponent("\(String(safe)).recipe.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: target, options: .atomic); return target
    }
    private func persistRecipes() throws {
        try JSONEncoder().encode(recipes.filter { !$0.isPreset }).write(to: root.appendingPathComponent("recipes.json"), options: .atomic)
    }
    func export(_ asset: LibraryAsset, recipe: Recipe) async throws -> URL {
        let directory = root.appendingPathComponent("Exports"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: asset.originalName).deletingPathExtension().lastPathComponent
        let target = directory.appendingPathComponent("\(base)-ZORA-\(UUID().uuidString.prefix(6)).jpg")
        let source = try await library.url(for: asset)
        try await processor.export(url: source, recipe: recipe, cube: cube, location: asset.location, to: target)
        try await library.apply(recipe, to: asset.id); await refresh(); return target
    }
}

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
    var streaming = false
    var assets: [LibraryAsset] = []
    var jobs: [UploadJob] = []
    var recipes = Recipe.presets
    var cube: CubeLUT?
    var cubeName: String?
    var destination: NASDestination?
    var connectionProgress: String?
    var autoWake = UserDefaults.standard.object(forKey: "bleAutoWake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoWake, forKey: "bleAutoWake") }
    }
    let connectivity = Connectivity()
    let usb = USBCamera()
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
    private var operationTask: Task<Void, Never>?
    private var foreground = true
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
            recipes += try JSONDecoder().decode([Recipe].self, from: Data(contentsOf: recipeURL)).map { try $0.validated() }
        }
    }
    func start() async {
        await refresh()
        connectivity.bluetooth.onAuthenticated = { [weak self] in self?.autoWakeIfReady() }
        usb.onRemoval = { [weak self] in
            guard let self, connectionType == "USB" else { return }
            device = nil; connectionType = nil; properties = []; recordingRequested = false; remoteControl = false; notice = "USB 控制已中断，拍摄状态请以相机为准"
            Task { await self.stopStream() }
        }
        connectivity.bluetooth.resume(foreground: foreground)
        worker?.cancel()
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    func sceneActive(_ active: Bool) {
        foreground = active; connectivity.bluetooth.resume(foreground: active)
        if active { autoWakeIfReady() }
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
        protocolEvents = await camera.recentEvents
        let revision = await camera.storageRevision
        cameraFilesChanged = !cameraObjects.isEmpty && directoryRevision != revision
        if device != nil, await camera.device == nil { device = nil; connectionType = nil; properties = []; remoteControl = false; recordingRequested = false }
    }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        operationTask = Task {
            defer { busy = false }
            do { try await operation(); await refresh() }
            catch {
                if error is CancellationError { notice = "后续操作已取消，已发出的相机指令请以机身状态为准" }
                else { self.error = error.localizedDescription }
                device = await camera.device
                if device == nil { await stopStream(); connectionType = nil; properties = []; remoteControl = false; recordingRequested = false }
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
        notice = "系统 USB 会话与 Nikon 设备信息已验证；具体功能仍需真机验收"
        do { properties = try await camera.properties() } catch { self.error = error.localizedDescription }
    }
    func disconnect() async throws { await stopStream(); try await camera.disconnect(); device = nil; connectionType = nil; properties = []; cameraObjects = []; remoteControl = false; recordingRequested = false }
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
            do {
                while streaming && !Task.isCancelled {
                    let jpeg = try await camera.frame()
                    preview = try await processor.preview(jpeg: jpeg)
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
        streaming = false; preview = nil
    }
    func capture() async throws {
        await stopStream(); try await camera.capture()
        notice = "相机已接受快门指令。请刷新相机文件确认照片落盘。"
    }
    func set(_ property: CameraProperty, value: Int64) async throws {
        await stopStream(); try await camera.set(property, value: value); properties = try await camera.properties()
    }
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
        let staging = root.appendingPathComponent("\(UUID()).\(URL(fileURLWithPath: object.filename).pathExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await camera.download(object, to: staging); _ = try await library.importFile(staging); await refresh()
    }
    func importFiles(_ urls: [URL]) async throws {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            _ = try await library.importFile(url)
        }
        await refresh()
    }
    func enqueue(_ asset: LibraryAsset) async throws {
        guard let destination else { throw ZoraError.unsupported("请先配置 NAS") }
        let file = try await library.url(for: asset)
        // Stable unique key: reattempts never create a second remote object.
        let key = destination.kind == .webDAV ? "\(asset.id.uuidString)-\(asset.originalName)" : "\(asset.id.uuidString)/\(asset.originalName)"
        try await uploadQueue.enqueue(file: file, key: key, destination: destination)
        await refresh(); await sync()
    }
    func sync() async {
        do { try await uploadQueue.drain(using: HTTPUploadTransport { id in try Keychain.load(id: id) }, online: connectivity.online) }
        catch { self.error = error.localizedDescription }
        jobs = await uploadQueue.snapshot()
        if !busy, device != nil {
            device = await camera.device
            if device == nil { properties = []; cameraObjects = [] }
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
        notice = "NAS 配置已保存。WebDAV 目标目录需预先创建；实际上传结果见任务队列。"
    }
    func importLook(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "cube" { cube = try CubeLUT(text: String(contentsOf: url, encoding: .utf8)); cubeName = url.lastPathComponent }
        else {
            var recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: url)).validated()
            recipe.id = UUID(); recipes.append(recipe)
            try JSONEncoder().encode(Array(recipes.dropFirst(Recipe.presets.count))).write(to: root.appendingPathComponent("recipes.json"), options: .atomic)
        }
    }
    func export(_ asset: LibraryAsset, recipe: Recipe) async throws -> URL {
        let directory = root.appendingPathComponent("Exports"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("\(asset.id)-\(UUID()).jpg")
        let source = try await library.url(for: asset)
        try await processor.export(url: source, recipe: recipe, cube: cube, to: target)
        try await library.apply(recipe, to: asset.id); await refresh(); return target
    }
}

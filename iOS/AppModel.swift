import Foundation
import Observation
import NetworkExtension
import ZoraCore

struct CameraWiFiProfile: Codable {
    let peripheralID: UUID
    let ssid: String
    let password: String
    let host: String
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
            device = nil; properties = []; recordingRequested = false; remoteControl = false; notice = "USB �ѶϿ�������״̬�������Ϊ׼"
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
              profile.peripheralID == connectivity.bluetooth.identity?.peripheralID else { return }
        perform { try await self.wakeAndConnect() }
    }
    func saveCameraWiFi(ssid: String, password: String, host: String) throws {
        guard let id = connectivity.bluetooth.identity?.peripheralID else { throw ZoraError.unsupported("�������������֤���ٰ󶨴������ Wi-Fi") }
        guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !host.isEmpty,
              password.isEmpty || (8...63).contains(password.utf8.count) else { throw ZoraError.malformed("��������Ч SSID����ַ�� 8�C63 �ֽڵ� Wi-Fi ����") }
        try Keychain.saveValue(CameraWiFiProfile(peripheralID: id, ssid: ssid, password: password, host: host), id: "nikon.wifi")
        notice = "��� Wi-Fi �ѱ��浽����Կ�״����������ѿ��Զ��ν�����"
    }
    func wakeAndConnect() async throws {
        guard foreground else { throw ZoraError.unsupported("��ص�ǰ̨������ Wi-Fi ����") }
        let profile = try Keychain.loadValue(CameraWiFiProfile.self, id: "nikon.wifi")
        let generation = connectivity.bluetooth.automationGeneration
        func checkConnectionIntent() throws {
            try Task.checkCancellation()
            guard foreground, generation == connectivity.bluetooth.automationGeneration,
                  profile.peripheralID == connectivity.bluetooth.identity?.peripheralID else {
                throw ZoraError.unsupported("�Զ�������ֹͣ������ǰ̨����ѡ�����")
            }
        }
        guard profile.peripheralID == connectivity.bluetooth.identity?.peripheralID else { throw ZoraError.unsupported("Wi-Fi ����������һ̨����������±���") }
        connectionProgress = "1/3 �� ����������������"
        defer { connectionProgress = nil }
        try await connectivity.bluetooth.wakeWiFi()
        connectionProgress = "2/3 �� �ȴ�����ȵ� �� ������ iOS ��������"
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
        connectionProgress = "3/3 �� ��֤��ʵ PTP ����Ự"
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
        Task {
            defer { busy = false }
            do { try await operation(); await refresh() }
            catch {
                self.error = error.localizedDescription
                device = await camera.device
                if device == nil { await stopStream(); properties = [] }
            }
        }
    }
    func connect(host: String) async throws {
        usbSelected = false
        await stopStream()
        device = nil; connectionType = nil; properties = []; cameraObjects = []
        device = try await camera.connect(host: host)
        connectionType = "Wi-Fi"; remoteControl = false; recordingRequested = false
        // Connection success comes only from real handshake + GetDeviceInfo + OpenSession.
        notice = "��ʵ PTP �Ự�ѽ������豸�����Ѷ�ȡ�������������������֤"
        do { properties = try await camera.properties() } catch { self.error = error.localizedDescription }
    }
    func connectUSB(_ id: String) async throws {
        usbSelected = true
        await stopStream(); try await camera.disconnect()
        device = nil; properties = []; cameraObjects = []; connectionType = nil
        try usb.select(id)
        device = try await camera.connect(using: usb)
        connectionType = "USB"; remoteControl = false; recordingRequested = false
        notice = "ϵͳ USB �Ự�� Nikon �豸��Ϣ����֤�����幦�������������"
        do { properties = try await camera.properties() } catch { self.error = error.localizedDescription }
    }
    func disconnect() async throws { await stopStream(); try await camera.disconnect(); device = nil; connectionType = nil; properties = []; cameraObjects = []; remoteControl = false; recordingRequested = false }
    func setRemoteControl(_ enabled: Bool) async throws {
        await stopStream(); try await camera.setRemoteControl(enabled); remoteControl = enabled
        notice = enabled ? "�������Զ�̽ӹܣ����ֻ�������������ʱ��������ɺ����ͷſ���" : "��������ͷ�Զ�̿���"
    }
    func setMovieRecording(_ enabled: Bool) async throws {
        try await withLiveControl(ensureLive: enabled) {
            if enabled { try await self.camera.startMovie() } else { try await self.camera.stopMovie() }
        }
        recordingRequested = enabled
        notice = enabled ? "����ѽ��ܿ�ʼ¼��ָ����Ի���¼��ָʾ/����¼�ȷ��" : "����ѽ���ֹͣ¼��ָ���ȷ���ļ�д�����"
    }
    func driveFocus(near: Bool, steps: UInt32) async throws {
        let result = try await withLiveControl(ensureLive: true) { try await self.camera.driveFocus(near: near, steps: steps) }
        switch result {
        case .completed: notice = "����ѷ��ضԽ���������"
        case .accepted: notice = "����ѽ��ܶԽ�������δ�ṩ���״̬��ѯ"
        case .endOfTravel: notice = "��ͷ�ѵ������г̱߽�"
        case .stepTooSmall: notice = "�Խ�������С�������������"
        }
    }
    /// Pause polling without EndLiveView: Nikon MF/movie commands require the
    /// camera's live-view state. Re-entering the UI polling loop must not restart it.
    private func withLiveControl<T: Sendable>(ensureLive: Bool, operation: @MainActor () async throws -> T) async throws -> T {
        let resume = streaming || ensureLive
        streaming = false; await liveTask?.value; liveTask = nil
        do {
            if ensureLive { try await camera.startLiveView() }
            let result = try await operation()
            if resume, foreground { try await startStream() }
            return result
        } catch {
            if resume, foreground { try? await startStream() }
            throw error
        }
    }
    func startStream() async throws {
        guard !streaming else { return }
        guard device?.canLiveView == true else { throw ZoraError.unsupported("���û���������� Nikon Live View ����") }
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
        notice = "����ѽ��ܿ���ָ���ˢ������ļ�ȷ����Ƭ���̡�"
    }
    func set(_ property: CameraProperty, value: Int64) async throws {
        await stopStream(); try await camera.set(property, value: value); properties = try await camera.properties()
    }
    func listCameraFiles() async throws {
        await stopStream(); cardStorageIDs = try await camera.storageIDs(); storages = []
        if device?.operations.contains(PTPOperation.storageInfo) == true {
            for id in cardStorageIDs { do { storages.append(try await camera.storageInfo(id)) } catch { notice = "���ִ洢����Ϣ���ɶ�ȡ��\(error.localizedDescription)" } }
        }
        if selectedStorage == nil || !cardStorageIDs.contains(selectedStorage!) { selectedStorage = cardStorageIDs.first }
        try await loadCameraPage(reset: true)
    }
    func loadCameraPage(reset: Bool) async throws {
        if !reset, directoryRevision != (await camera.storageRevision) { throw ZoraError.unsupported("����ļ��ѱ仯������ˢ��Ŀ¼�ټ�����ҳ") }
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
        guard let destination else { throw ZoraError.unsupported("�������� NAS") }
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
        guard !username.isEmpty, !secret.isEmpty else { throw ZoraError.malformed("�������û���/Access Key ������/Secret Key") }
        try Keychain.save(NASCredential(username: username, secret: secret, token: token.isEmpty ? nil : token), id: valid.credentialID)
        UserDefaults.standard.set(try JSONEncoder().encode(valid), forKey: "nasDestination"); destination = valid
        notice = "NAS �����ѱ��档WebDAV Ŀ��Ŀ¼��Ԥ�ȴ�����ʵ���ϴ������������С�"
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

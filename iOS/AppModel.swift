import Foundation
import Observation
import ZoraCore

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
    let connectivity = Connectivity()
    let camera: CameraSession
    let library: AssetLibrary
    let uploadQueue: UploadQueue
    let processor = ImageProcessor()
    private let root: URL
    private var liveTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
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
        worker?.cancel()
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    func refresh() async { assets = await library.assets(); jobs = await uploadQueue.snapshot() }
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
        await stopStream()
        device = nil; properties = []; cameraObjects = []
        device = try await camera.connect(host: host)
        // Connection success comes only from real handshake + GetDeviceInfo + OpenSession.
        notice = "真实 PTP 会话已建立；设备能力已读取，具体操作仍需逐项验证"
        do { properties = try await camera.properties() } catch { self.error = error.localizedDescription }
    }
    func disconnect() async throws { await stopStream(); try await camera.disconnect(); device = nil; properties = []; cameraObjects = [] }
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
    func listCameraFiles() async throws { await stopStream(); cameraObjects = try await camera.objects() }
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

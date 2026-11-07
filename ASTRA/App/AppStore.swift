import SwiftUI
import UIKit
import CoreImage

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var projects: [AstroProject] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var preview: UIImage?
    @Published private(set) var beforePreview: UIImage?
    @Published private(set) var histogram: [Double] = []
    @Published private(set) var busy = false
    @Published private(set) var canCancel = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published var message: String?
    @Published var sharedURL: URL?
    private var repository: ProjectRepository?
    private var cancelToken: ASCancelToken?
    private var saveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    var project: AstroProject? { projects.first { $0.id == selectedID } }
    init() {
        do { let repo = try ProjectRepository(); repository = repo; projects = try repo.list() }
        catch { message = error.localizedDescription }
    }
    func select(_ id: UUID?) {
        flushSave(); selectedID = id; preview = nil; beforePreview = nil; requestPreview()
    }
    func create() {
        guard !busy, let repo = repository else { return }
        var p = AstroProject(); p.name = "星空 \(Date.now.formatted(date: .numeric, time: .shortened))"
        do { try repo.save(p); projects.insert(p, at: 0); select(p.id) } catch { message = error.localizedDescription }
    }
    func delete(_ p: AstroProject) {
        guard !busy, let repo = repository else { return }
        do { try repo.remove(p); projects.removeAll { $0.id == p.id }; if selectedID == p.id { select(nil) } } catch { message = error.localizedDescription }
    }
    func update(_ change: (inout AstroProject) -> Void, render: Bool = false) {
        guard !busy, let i = projects.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&projects[i]); projects[i].updated = .now
        saveTask?.cancel(); saveTask = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { flushSave() } }
        if render { requestPreview() }
    }
    func checkpoint() { update { p in p.undo.append(p.adjustments); if p.undo.count > 50 { p.undo.removeFirst() }; p.redo = [] } }
    func undo() { update({ p in guard let prev = p.undo.popLast() else { return }; p.redo.append(p.adjustments); p.adjustments = prev }, render: true) }
    func redo() { update({ p in guard let next = p.redo.popLast() else { return }; p.undo.append(p.adjustments); p.adjustments = next }, render: true) }
    func reset() { checkpoint(); update({ $0.adjustments = .neutral }, render: true) }
    func preset(_ index: Int) {
        checkpoint(); update({ p in
            var a = Adjustments()
            switch index {
            case 0: a.exposure = 0.5; a.vibrance = 0.2; a.curveLow = 0.19; a.curveHigh = 0.82
            case 1: a.exposure = 0.3; a.warmth = -20; a.saturation = 0.9; a.curveLow = 0.18
            case 2: a.exposure = 1.0; a.shadows = 0.25; a.vibrance = 0.3; a.noise = 0.2
            default: break
            }; p.adjustments = a
        }, render: true)
    }
    func flushSave() {
        saveTask?.cancel()
        guard let repo = repository, let p = project else { return }
        do { try repo.save(p) } catch { message = "工程保存失败：\(error.localizedDescription)" }
    }
    func thumbnail(_ frame: FrameRecord) -> URL? {
        guard let repo = repository, let p = project else { return nil }
        return repo.url(p, "Thumbs/\(frame.id.uuidString).jpg")
    }
    func sourceImage(_ p: AstroProject, _ repo: ProjectRepository, _ pipeline: ImagePipeline) throws -> CIImage {
        if let result = p.result { return try pipeline.master(result, repository: repo, project: p) }
        guard let frame = p.frames.first else { throw AstroError.message("请先导入照片") }
        return try pipeline.decode(repo.url(p, frame.fileName))
    }
    func requestPreview() {
        previewTask?.cancel(); previewGeneration += 1
        guard let p = project, !p.frames.isEmpty, let repo = repository else { return }
        let generation = previewGeneration
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(140)); if Task.isCancelled { return }
            do {
                let rendered = try await Task.detached(priority: .userInitiated) { () -> (CGImage, CGImage, [Double]) in
                    let pipeline = ImagePipeline()
                    let source: CIImage
                    if let result = p.result { source = try pipeline.master(result, repository: repo, project: p) }
                    else { source = try pipeline.decode(repo.url(p, p.frames[0].fileName)) }
                    let after = try pipeline.preview(image: source, adjustments: p.adjustments)
                    let before = try pipeline.preview(image: source, adjustments: .neutral)
                    return (after, before, Self.makeHistogram(after))
                }.value
                guard !Task.isCancelled, generation == previewGeneration, selectedID == p.id else { return }
                preview = UIImage(cgImage: rendered.0); beforePreview = UIImage(cgImage: rendered.1); histogram = rendered.2
            } catch { if generation == previewGeneration { message = error.localizedDescription } }
        }
    }
    nonisolated private static func makeHistogram(_ image: CGImage) -> [Double] {
        let w = 256, h = 128; var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var bins = [Double](repeating: 0, count: 64)
        bytes.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for i in 0..<(w*h) { let l = (Int(bytes[i*4]) + Int(bytes[i*4+1])*2 + Int(bytes[i*4+2])) / 4; bins[min(63,l/4)] += 1 }
        let top = max(1, bins.max() ?? 1); return bins.map { log(1+$0) / log(1+top) }
    }
    func importFiles(_ urls: [URL]) {
        guard !busy, let p = project, let repo = repository else { return }
        flushSave(); busy = true; status = "导入照片"; progress = 0
        let permissions = urls.map { $0.startAccessingSecurityScopedResource() }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([FrameRecord], [String]) in
                defer { for (i, url) in urls.enumerated() where permissions[i] { url.stopAccessingSecurityScopedResource() } }
                let pipeline = ImagePipeline(); var frames: [FrameRecord] = [], errors: [String] = []
                for (i, url) in urls.enumerated() {
                    do {
                        let f = try autoreleasepool { () throws -> FrameRecord in
                            let name = "Originals/\(UUID().uuidString).\(url.pathExtension.lowercased())", dest = repo.url(p, name)
                            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try FileManager.default.copyItem(at: url, to: dest)
                            do {
                                let frame = try pipeline.metadata(dest, name: url.lastPathComponent, stored: name)
                                let image = try pipeline.preview(image: pipeline.decode(dest), adjustments: .neutral, maxSide: 256)
                                let thumb = repo.url(p, "Thumbs/\(frame.id.uuidString).jpg")
                                try FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
                                guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else { throw AstroError.message("无法生成缩略图") }
                                try data.write(to: thumb); return frame
                            } catch { try? FileManager.default.removeItem(at: dest); throw error }
                        }; frames.append(f)
                    } catch { errors.append(error.localizedDescription) }
                    Task { @MainActor in self.progress = Double(i+1) / Double(urls.count) }
                }; return (frames, errors)
            }.value
            busy = false
            update { $0.frames.append(contentsOf: result.0) }; flushSave(); requestPreview()
            if !result.1.isEmpty { message = "已导入 \(result.0.count) 张。\n" + result.1.joined(separator: "\n") }
        }
    }
    func startStack() {
        guard !busy, var p = project, let repo = repository else { return }
        flushSave(); p.jobInProgress = true
        do { try repo.save(p) } catch { message = error.localizedDescription; return }
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p }
        busy = true; canCancel = true; progress = 0; status = "准备合成"; let token = ASCancelToken(); cancelToken = token
        let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "ASTRA Stack") { token.cancel() }
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                let work = try await Task.detached(priority: .userInitiated) {
                    var last = Date.distantPast
                    return try StackWorker.run(project: p, repository: repo, token: token) { value, label in
                        if Date.now.timeIntervalSince(last) < 0.12 && value < 1 { return }; last = .now
                        Task { @MainActor in self.progress = value; self.status = label }
                    }
                }.value
                guard let index = projects.firstIndex(where: { $0.id == p.id }) else { throw AstroError.message("工程已不可用") }
                let old = projects[index].result?.fileName
                var committed = projects[index]
                committed.frames = work.frames; committed.result = work.result; committed.jobInProgress = false; committed.updated = .now
                // Persist the new reference before removing the old master.
                try repo.save(committed)
                projects[index] = committed; busy = false
                if let old, old != work.result.fileName { try? FileManager.default.removeItem(at: repo.url(p, old)) }
                requestPreview()
                let rejected = work.frames.filter { $0.included && $0.rejection != nil }.count
                if rejected > 0 { message = "已合成 \(work.result.acceptedFrames) 张，\(rejected) 张配准失败已跳过，可在帧列表查看原因。" }
            } catch {
                busy = false; update { $0.jobInProgress = false }; flushSave()
                message = token.isCancelled() ? "合成已取消。原片、解码缓存和上次结果已保留，可重新开始。" : error.localizedDescription
            }
            cancelToken = nil; canCancel = false; UIApplication.shared.isIdleTimerDisabled = false
            if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
        }
    }
    func cancel() { cancelToken?.cancel(); status = "正在安全停止…" }
    func clearCache() {
        guard !busy, let repo = repository, let p = project else { return }
        do { try repo.clearCache(p); message = "解码缓存已清理。" } catch { message = error.localizedDescription }
    }
    func export(_ kind: ExportKind) {
        guard !busy, let p = project, !p.frames.isEmpty, let repo = repository else { return }
        flushSave(); busy = true; status = "导出全分辨率 \(kind.rawValue)"; progress = 0
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let pipeline = ImagePipeline(), source: CIImage
                    if let result = p.result { source = try pipeline.master(result, repository: repo, project: p) }
                    else { source = try pipeline.decode(repo.url(p, p.frames[0].fileName)) }
                    let output = repo.url(p, "Exports/ASTRA-\(UUID().uuidString.prefix(8)).\(kind.ext)")
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try pipeline.export(image: source, adjustments: p.adjustments, kind: kind, url: output)
                    return output
                }.value
                sharedURL = url
            } catch { message = "导出失败：\(error.localizedDescription)" }
            busy = false
        }
    }
}

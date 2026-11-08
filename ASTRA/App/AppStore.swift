import SwiftUI
import UIKit
import CoreImage
import PhotosUI
import Photos

enum ExportDestination: Equatable { case share, photos }

struct StackNotice {
    let projectID: UUID
    let title: String
    let detail: String
    let failed: Bool
}

enum PhotoFormatRequest {
    case importing([PhotoImportSource], available: [Set<PhotoFormat>], title: String)
    case stacking

    var title: String {
        switch self {
        case .importing: "选择本次导入的格式"
        case .stacking: "选择本次堆栈的格式"
        }
    }
}

private actor PreviewWorker {
    private var pipeline: ImagePipeline?
    private var key: URL?
    private var proxy: CIImage?
    private var before: CGImage?
    private var astroProfile: AstroProfile?
    private var beforeSTF: Bool?

    func render(project: AstroProject, repository: ProjectRepository) throws -> (CGImage, CGImage) {
        try Task.checkCancellation()
        return try autoreleasepool {
            let url = repository.url(project, project.result?.fileName ?? project.frames.first(where: { $0.id == project.configuration.referenceFrameID })?.fileName ?? project.frames[0].fileName)
            let pipeline = self.pipeline ?? ImagePipeline()
            self.pipeline = pipeline
            if key != url || proxy == nil || before == nil {
                let source: CIImage
                if let result = project.result {
                    source = try pipeline.master(result, repository: repository, project: project)
                } else if StackSelection.rawExtensions.contains(url.pathExtension.lowercased()) {
                    let frame = project.frames.first { $0.fileName == url.lastPathComponent || repository.url(project, $0.fileName) == url }
                    let thumbnail = frame.map { repository.url(project, "Thumbs/\($0.id.uuidString).preview.jpg") }
                    if let thumbnail, let image = CIImage(contentsOf: thumbnail, options: [.applyOrientationProperty: true]) {
                        source = image
                    } else {
                        let cg: CGImage
                        if let embedded = pipeline.embeddedRAWPreview(url) { cg = embedded }
                        else { cg = try pipeline.rawPreviewPlaceholder() }
                        source = CIImage(cgImage: cg, options: [.colorSpace: pipeline.display])
                    }
                } else {
                    source = try pipeline.decode(url)
                }
                let image = try pipeline.previewSource(source)
                astroProfile = project.result == nil ? nil : pipeline.astroProfile(image)
                proxy = image
                key = url
            }
            try Task.checkCancellation()
            guard let proxy else { throw AstroError.message("预览渲染失败") }
            let stf = project.result != nil && (project.adjustments.autoSTF ?? true)
            if before == nil || beforeSTF != stf {
                before = try pipeline.preview(image: proxy, adjustments: .neutral,
                                              profile: astroProfile, autoSTF: stf)
                beforeSTF = stf
            }
            guard let before else { throw AstroError.message("预览渲染失败") }
            let after = try pipeline.preview(image: proxy, adjustments: project.adjustments,
                                             profile: astroProfile, autoSTF: stf)
            return (after, before)
        }
    }

    func reset() {
        key = nil
        proxy = nil
        before = nil
        astroProfile = nil
        beforeSTF = nil
        pipeline = nil
    }
}

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
    @Published private(set) var stackNotice: StackNotice?
    @Published var message: String?
    @Published var sharedURL: URL?
    @Published var formatRequest: PhotoFormatRequest?
    private var repository: ProjectRepository?
    private var cancelToken: ASCancelToken?
    private var importWorker: Task<(Int, [String]), Never>?
    private var activeImportID: UUID?
    private var saveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private let previewWorker = PreviewWorker()
    var project: AstroProject? { projects.first { $0.id == selectedID } }
    init() {
        do { let repo = try ProjectRepository(); repository = repo; projects = try repo.list() }
        catch { message = error.localizedDescription }
    }
    func select(_ id: UUID?) {
        flushSave(); selectedID = id; preview = nil; beforePreview = nil; histogram = []; requestPreview()
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
    func enhanceNebula() {
        checkpoint()
        update({ p in
            p.adjustments.arcsinh = 18
            p.adjustments.maskedStretch = 0.55
            p.adjustments.gradientRemoval = 0.4
            p.adjustments.nebulaContrast = 0.55
            p.adjustments.starProtection = 0.85
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
    func requestPreview() {
        previewTask?.cancel(); previewGeneration += 1
        guard let p = project, !p.frames.isEmpty, let repo = repository else { return }
        let generation = previewGeneration
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(140)); if Task.isCancelled { return }
            do {
                let rendered = try await previewWorker.render(project: p, repository: repo)
                guard !Task.isCancelled, generation == previewGeneration, selectedID == p.id else { return }
                preview = UIImage(cgImage: rendered.0)
                beforePreview = UIImage(cgImage: rendered.1)
                histogram = Self.makeHistogram(rendered.0)
            } catch { if !Task.isCancelled, generation == previewGeneration { message = error.localizedDescription } }
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
        prepareImport(urls.map(PhotoImportSource.file), title: "导入文件")
    }
    func importPhotos(_ items: [PhotosPickerItem]) {
        prepareImport(items.map(PhotoImportSource.library), title: "从相册导入")
    }
    private func prepareImport(_ sources: [PhotoImportSource], title: String) {
        guard !sources.isEmpty, !busy, project != nil else { return }
        busy = true; status = "检查相册原件"; progress = 0
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            var available: [Set<PhotoFormat>] = []
            for (index, source) in sources.enumerated() {
                status = "检查相册原件 \(index + 1) / \(sources.count)"
                available.append(await source.availableFormats())
                progress = Double(index + 1) / Double(sources.count)
            }
            let formats = Set(available.flatMap { $0 })
            UIApplication.shared.isIdleTimerDisabled = false
            busy = false
            if formats.count > 1 { formatRequest = .importing(sources, available: available, title: title) }
            else { importImages(sources, title: title, format: formats.first) }
        }
    }
    func applyFormat(_ format: PhotoFormat, to request: PhotoFormatRequest) {
        formatRequest = nil
        switch request {
        case .importing(let sources, let available, let title):
            importImages(zip(sources, available).compactMap { $0.1.contains(format) ? $0.0 : nil }, title: title, format: format)
        case .stacking:
            startStack(format: format)
        }
    }
    private func importImages(_ sources: [PhotoImportSource], title: String, format: PhotoFormat?) {
        guard !sources.isEmpty, !busy, let project, let repo = repository else { return }
        flushSave()
        previewTask?.cancel()
        busy = true
        canCancel = true; status = "\(title) · 请保持屏幕解锁"; progress = 0
        UIApplication.shared.isIdleTimerDisabled = true
        let importID = UUID(); activeImportID = importID
        let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "ASTRA Import") { [weak self] in
            Task { @MainActor in
                self?.importWorker?.cancel()
                self?.status = "系统后台时间已结束，已保存完成的照片。请解锁并重新导入剩余照片。"
            }
        }
        Task {
            await previewWorker.reset()
            let worker = Task.detached(priority: .userInitiated) { () -> (Int, [String]) in
                let pipeline = ImagePipeline()
                var imported = 0
                var errors: [String] = []
                for (index, source) in sources.enumerated() {
                    if Task.isCancelled { break }
                    let update: @Sendable (Double, String) -> Void = { fraction, stage in
                        Task { @MainActor in
                            guard self.activeImportID == importID else { return }
                            self.progress = max(self.progress, (Double(index) + min(1, max(0, fraction))) / Double(sources.count))
                            self.status = "第 \(index + 1) / \(sources.count) 张 · \(stage) · 请保持屏幕解锁"
                        }
                    }
                    do {
                        let frame = try await source.withFile(format: format, progress: { fraction, stage in
                            update(fraction * 0.82, stage)
                        }) { url, move in
                            try autoreleasepool { try Self.copyFrame(from: url, move: move, to: project,
                                                                      repository: repo, pipeline: pipeline,
                                                                      progress: { fraction, stage in update(0.82 + fraction * 0.18, stage) }) }
                        }
                        do {
                            try await MainActor.run {
                                guard let i = self.projects.firstIndex(where: { $0.id == project.id }) else {
                                    throw AstroError.message("工程已不可用")
                                }
                                var committed = self.projects[i]
                                committed.frames.append(frame); committed.updated = .now
                                try repo.save(committed)
                                self.projects[i] = committed
                            }
                            imported += 1
                        } catch {
                            try? FileManager.default.removeItem(at: repo.url(project, frame.fileName))
                            try? FileManager.default.removeItem(at: repo.url(project, "Thumbs/\(frame.id.uuidString).jpg"))
                            try? FileManager.default.removeItem(at: repo.url(project, "Thumbs/\(frame.id.uuidString).preview.jpg"))
                            throw error
                        }
                    } catch {
                        errors.append("\(source.displayName(at: index))：\(error.localizedDescription)")
                    }
                    await MainActor.run { self.progress = Double(index + 1) / Double(sources.count) }
                }
                return (imported, errors)
            }
            importWorker = worker
            let result = await worker.value
            activeImportID = nil; importWorker = nil; canCancel = false; busy = false
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
            if selectedID == project.id && result.0 > 0 { requestPreview() }
            let remaining = max(0, sources.count - result.0 - result.1.count)
            status = "已导入 \(result.0) 张" + (remaining > 0 ? "，剩余 \(remaining) 张未处理" : "")
            if !result.1.isEmpty || remaining > 0 {
                let details = result.1.prefix(4).joined(separator: "\n")
                message = "已保存 \(result.0) 张，失败 \(result.1.count) 张，未处理 \(remaining) 张。" +
                          (details.isEmpty ? "" : "\n\(details)")
            }
        }
    }
    nonisolated private static func copyFrame(from url: URL, move: Bool, to project: AstroProject,
                                              repository: ProjectRepository, pipeline: ImagePipeline,
                                              progress: @escaping @Sendable (Double, String) -> Void) throws -> FrameRecord {
        let suffix = url.pathExtension.lowercased()
        let fileName = UUID().uuidString + (suffix.isEmpty ? "" : ".\(suffix)")
        let name = "Originals/\(fileName)"
        let destination = repository.url(project, name)
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var thumbnail: URL?
        var largePreview: URL?
        do {
            progress(0.83, "保存照片原件")
            if move { try files.moveItem(at: url, to: destination) }
            else { try files.copyItem(at: url, to: destination) }
            let isRaw = StackSelection.rawExtensions.contains(suffix)
            progress(0.89, isRaw ? "读取 NEF 元数据" : "读取照片元数据")
            var frame: FrameRecord
            let image: CGImage
            if isRaw {
                frame = try pipeline.rawMetadata(destination, name: url.lastPathComponent, stored: name)
                progress(0.94, "提取 NEF 内嵌预览（不解码全尺寸 RAW）")
                let embedded = pipeline.embeddedRAWPreview(destination)
                frame.rawPreviewUnavailable = embedded == nil
                if let embedded { image = embedded }
                else { image = try pipeline.rawPreviewPlaceholder() }
                let preview = repository.url(project, "Thumbs/\(frame.id.uuidString).preview.jpg")
                largePreview = preview
                try files.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.78) else {
                    throw AstroError.message("无法保存 NEF 内嵌预览")
                }
                try data.write(to: preview, options: .atomic)
            } else {
                let decoded = try pipeline.decode(destination)
                frame = pipeline.metadata(destination, image: decoded, name: url.lastPathComponent, stored: name)
                image = try pipeline.preview(image: decoded, adjustments: .neutral, maxSide: 256)
            }
            let thumb = repository.url(project, "Thumbs/\(frame.id.uuidString).jpg")
            thumbnail = thumb
            try files.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
            let small: CGImage
            if isRaw {
                small = try pipeline.preview(image: CIImage(cgImage: image, options: [.colorSpace: pipeline.display]),
                                             adjustments: .neutral, maxSide: 256)
            } else {
                small = image
            }
            guard let data = UIImage(cgImage: small).jpegData(compressionQuality: 0.8) else {
                throw AstroError.message("无法生成缩略图")
            }
            try data.write(to: thumb, options: .atomic)
            progress(1, "照片已导入")
            return frame
        } catch {
            try? files.removeItem(at: destination)
            if let thumbnail { try? files.removeItem(at: thumbnail) }
            if let largePreview { try? files.removeItem(at: largePreview) }
            throw error
        }
    }
    func prepareStack() {
        guard let project, !busy else { return }
        if StackSelection.formats(in: project).count > 1 {
            formatRequest = .stacking
        } else {
            startStack(format: nil)
        }
    }
    private func startStack(format: PhotoFormat?) {
        guard !busy, var p = project, let repo = repository else { return }
        stackNotice = nil
        do {
            try StackWorker.validateSelection(p, format: format)
            saveTask?.cancel()
            p.jobInProgress = true
            try repo.save(p)
        } catch {
            stackNotice = StackNotice(projectID: p.id, title: "无法开始合成", detail: error.localizedDescription, failed: true)
            return
        }
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p }
        previewTask?.cancel()
        busy = true; canCancel = true; progress = 0; status = "准备合成"; let token = ASCancelToken(); cancelToken = token
        let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "ASTRA Stack") { token.cancel() }
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                await previewWorker.reset()
                let work = try await Task.detached(priority: .userInitiated) {
                    var last = Date.distantPast
                    return try StackWorker.run(project: p, repository: repo, format: format, token: token) { value, label in
                        if Date.now.timeIntervalSince(last) < 0.12 && value < 1 { return }; last = .now
                        Task { @MainActor in
                            guard self.cancelToken === token, !token.isCancelled() else { return }
                            self.progress = value
                            self.status = label
                        }
                    }
                }.value
                guard let index = projects.firstIndex(where: { $0.id == p.id }) else { throw AstroError.message("工程已不可用") }
                let old = projects[index].result?.fileName
                var committed = projects[index]
                committed.frames = work.frames; committed.result = work.result; committed.jobInProgress = false; committed.updated = .now
                // Persist the new reference before removing the old master.
                do { try repo.save(committed) }
                catch {
                    try? FileManager.default.removeItem(at: repo.url(p, work.result.fileName))
                    throw error
                }
                projects[index] = committed
                if let old, old != work.result.fileName { try? FileManager.default.removeItem(at: repo.url(p, old)) }
                requestPreview()
                let rejected = work.frames.filter { $0.included && $0.rejection != nil }.count
                let size = "\(work.result.width) × \(work.result.height) 像素"
                let rejectedText = rejected > 0 ? "，\(rejected) 张未参与（原因见照片列表）" : ""
                let note = work.formatNote.map { $0 + "\n" } ?? ""
                stackNotice = StackNotice(projectID: p.id, title: "合成完成", detail: "\(note)\(work.result.acceptedFrames) 张 · \(size)\(rejectedText)。可继续调色或导出。", failed: false)
            } catch {
                if let index = projects.firstIndex(where: { $0.id == p.id }) {
                    projects[index].jobInProgress = false
                    try? repo.save(projects[index])
                }
                let cancelled = token.isCancelled()
                stackNotice = StackNotice(projectID: p.id, title: cancelled ? "合成已取消" : "合成失败",
                    detail: cancelled ? "可以重新开始。" : error.localizedDescription, failed: !cancelled)
            }
            cancelToken = nil; canCancel = false; busy = false; UIApplication.shared.isIdleTimerDisabled = false
            if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
        }
    }
    func cancel() { cancelToken?.cancel(); importWorker?.cancel(); status = "正在安全停止…" }
    func clearCache() {
        guard !busy, let repo = repository, let p = project else { return }
        do { try repo.clearCache(p); message = "解码缓存已清理。" } catch { message = error.localizedDescription }
    }
    func export(_ kind: ExportKind, to destination: ExportDestination = .share) {
        guard !busy, let p = project, !p.frames.isEmpty, let repo = repository else { return }
        if destination == .photos && kind == .tiff {
            message = "保存到相册请选择 JPEG、HEIF 或 PNG；16 位 TIFF 请导出并分享到「文件」。"
            return
        }
        flushSave(); busy = true; status = "导出全分辨率 \(kind.rawValue)"; progress = 0
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let pipeline = ImagePipeline(), source: CIImage
                    if let result = p.result { source = try pipeline.master(result, repository: repo, project: p) }
                    else { source = try pipeline.decode(repo.url(p, (p.frames.first(where: { $0.id == p.configuration.referenceFrameID }) ?? p.frames[0]).fileName)) }
                    let output = repo.url(p, "Exports/ASTRA-\(UUID().uuidString.prefix(8)).\(kind.ext)")
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try pipeline.export(image: source, adjustments: p.adjustments, kind: kind, url: output)
                    return output
                }.value
                if destination == .photos {
                    status = "正在保存到系统相册"
                    let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard permission == .authorized || permission == .limited else {
                        throw AstroError.message("没有保存到相册的权限，请在系统设置中允许 ASTRA 添加照片。")
                    }
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, fileURL: url, options: nil)
                    }
                    message = "成片已保存到系统相册。"
                } else { sharedURL = url }
            } catch { message = "导出失败：\(error.localizedDescription)" }
            busy = false
        }
    }
}

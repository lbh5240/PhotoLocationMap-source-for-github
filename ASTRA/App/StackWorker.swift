import Foundation

struct StackWorkResult {
    var frames: [FrameRecord]
    var result: StackResult
}
enum StackWorker {
    static func validateSelection(_ project: AstroProject) throws {
        let selected = project.frames.filter(\.included)
        guard selected.count >= 2 else { throw AstroError.message("请至少选择两张照片。") }
        guard selected.count <= 512 else { throw AstroError.message("单次最多合成 512 张照片。") }
        let first = selected[0]
        if let other = selected.first(where: { $0.width != first.width || $0.height != first.height }) {
            throw AstroError.message("所选照片尺寸不同（\(first.width)×\(first.height) 与 \(other.width)×\(other.height)）。请在照片列表排除裁切或方向不同的照片。")
        }
    }

    static func run(project: AstroProject, repository: ProjectRepository, token: ASCancelToken, progress: @escaping (Double, String) -> Void) throws -> StackWorkResult {
        try validateSelection(project)
        let pipeline = ImagePipeline(), cfg = project.configuration
        var frames = project.frames
        let selected = frames.indices.filter { frames[$0].included }
        let w = frames[selected[0]].width, h = frames[selected[0]].height
        let cache = repository.url(project, "Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        func cacheURL(_ i: Int) -> URL { cache.appendingPathComponent(frames[i].id.uuidString + ".rgba") }
        let byteCount = Int64(w) * Int64(h) * 16
        let missing = selected.filter { (try? cacheURL($0).resourceValues(forKeys: [.fileSizeKey]).fileSize) != Int(byteCount) }.count
        let capacities = try? repository.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = capacities?.volumeAvailableCapacityForImportantUsage ?? capacities?.volumeAvailableCapacity.map(Int64.init)
        let needed = Int64(missing + 1) * byteCount + 64 * 1024 * 1024
        if let available, available < needed {
            throw AstroError.message("当前可用 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))，本次需要约 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))。请清理空间或减少选帧。")
        }
        var analyses: [Int: [AnyHashable: Any]] = [:]
        var proxyScales: [Int: Double] = [:]
        for (step, i) in selected.enumerated() {
            if token.isCancelled() { throw CancellationError() }
            try autoreleasepool {
                progress(Double(step) / Double(selected.count) * 0.45, "解码与星点分析 \(step + 1) / \(selected.count)")
                let image = try pipeline.decode(repository.url(project, frames[i].fileName))
                let proxy = pipeline.proxy(image)
                let analysis = AstroBridge.analyze(pixels: proxy.data, width: proxy.width, height: proxy.height, skyFraction: cfg.mode == .landscape ? cfg.skyFraction : 1)
                analyses[i] = analysis; proxyScales[i] = proxy.scale
                frames[i].starCount = (analysis["stars"] as? [Any])?.count ?? 0
                frames[i].quality = (analysis["quality"] as? NSNumber)?.doubleValue ?? 0
                frames[i].rejection = nil; frames[i].registrationRMS = nil
                if (try? cacheURL(i).resourceValues(forKeys: [.fileSizeKey]).fileSize) != Int(byteCount) {
                    try pipeline.cache(image, at: cacheURL(i), token: token)
                }
            }
        }
        let eligible = selected.filter { cfg.mode == .trails || (frames[$0].starCount ?? 0) >= 8 }
        guard eligible.count >= 2, let reference = eligible.max(by: { (frames[$0].quality ?? 0) < (frames[$1].quality ?? 0) }) else {
            throw AstroError.message("只有 \(eligible.count) 张照片识别到至少 8 个星点。请选择同一片天空的清晰照片，或检查星野模式的天空分界。")
        }
        var accepted: [[String: Any]] = []
        for (step, i) in selected.enumerated() {
            if token.isCancelled() { throw CancellationError() }
            progress(0.45 + Double(step) / Double(selected.count) * 0.08, "自动对齐 \(step + 1) / \(selected.count)")
            var t: [AnyHashable: Any] = ["a": 1.0, "b": 0.0, "tx": 0.0, "ty": 0.0, "rms": 0.0]
            if cfg.mode != .trails && i != reference {
                if (frames[i].starCount ?? 0) < 8 {
                    frames[i].rejection = "可识别星点少于 8 个"
                    continue
                }
                t = AstroBridge.align(reference: analyses[reference]!, source: analyses[i]!, scale: proxyScales[i]!)
                if let error = t["error"] as? String { frames[i].rejection = error; continue }
            }
            let a = (t["a"] as? NSNumber)?.doubleValue ?? 1, b = (t["b"] as? NSNumber)?.doubleValue ?? 0
            let tx = ((t["tx"] as? NSNumber)?.doubleValue ?? 0)
            let ty = ((t["ty"] as? NSNumber)?.doubleValue ?? 0)
            frames[i].registrationRMS = ((t["rms"] as? NSNumber)?.doubleValue ?? 0)
            // Geometry uses pixel-center coordinates at each scale.
            accepted.append(["path": cacheURL(i).path, "a": a, "b": b, "tx": tx, "ty": ty, "weight": max(0.01, min(100, frames[i].quality ?? 1))])
        }
        guard accepted.count >= 2 else { throw AstroError.message("选中的 \(selected.count) 张照片中只有 \(accepted.count) 张对齐成功。请使用同一片天空的照片，排除云层、拖尾或构图差异过大的帧。") }
        let fileName = "Master-\(UUID().uuidString).rgba"
        let out = repository.url(project, fileName)
        if let error = AstroBridge.stack(frames: accepted, width: w, height: h, mode: cfg.mode.rawValue, sigma: cfg.sigma, skyFraction: cfg.skyFraction, feather: cfg.feather, destination: out.path, token: token, progress: { p in progress(0.53 + p * 0.47, "合成真实像素 \(Int(p * 100))%") }) {
            if token.isCancelled() { throw CancellationError() }
            throw AstroError.message(error)
        }
        return StackWorkResult(frames: frames, result: StackResult(fileName: fileName, width: w, height: h, acceptedFrames: accepted.count, mode: cfg.mode))
    }
}

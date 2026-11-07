import Foundation

struct StackWorkResult {
    var frames: [FrameRecord]
    var result: StackResult
}
enum StackWorker {
    static func run(project: AstroProject, repository: ProjectRepository, token: ASCancelToken, progress: @escaping (Double, String) -> Void) throws -> StackWorkResult {
        let pipeline = ImagePipeline(), cfg = project.configuration
        var frames = project.frames
        let selected = frames.indices.filter { frames[$0].included }
        guard selected.count >= 2 else { throw AstroError.message("请至少选择两张照片") }
        guard selected.count <= 512 else { throw AstroError.message("单工程最多合成 512 张照片") }
        let w = frames[selected[0]].width, h = frames[selected[0]].height
        guard selected.allSatisfy({ frames[$0].width == w && frames[$0].height == h }) else { throw AstroError.message("堆栈照片必须具有相同尺寸和方向") }
        let cache = repository.url(project, "Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        func cacheURL(_ i: Int) -> URL { cache.appendingPathComponent(frames[i].id.uuidString + ".rgba") }
        let byteCount = Int64(w) * Int64(h) * 16
        let missing = selected.filter { (try? cacheURL($0).resourceValues(forKeys: [.fileSizeKey]).fileSize) != Int(byteCount) }.count
        let space = try repository.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        let needed = Int64(missing + 1) * byteCount + 1_073_741_824
        guard space > needed else { throw AstroError.message(String(format: "解码缓存与合成至少需要 %.1f GB 可用空间。可先清理缓存。", Double(needed) / 1_000_000_000)) }
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
        guard let reference = selected.max(by: { (frames[$0].quality ?? 0) < (frames[$1].quality ?? 0) }) else { throw AstroError.message("没有可用参考帧") }
        if cfg.mode != .trails && (frames[reference].starCount ?? 0) < 8 { throw AstroError.message("未检测到足够星点。请检查曝光，或调节天空分界。星轨模式无需星点对齐。") }
        var accepted: [[String: Any]] = []
        for (step, i) in selected.enumerated() {
            if token.isCancelled() { throw CancellationError() }
            progress(0.45 + Double(step) / Double(selected.count) * 0.08, "自动对齐 \(step + 1) / \(selected.count)")
            var t: [AnyHashable: Any] = ["a": 1.0, "b": 0.0, "tx": 0.0, "ty": 0.0, "rms": 0.0]
            if cfg.mode != .trails && i != reference {
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
        guard accepted.count >= 2 else { throw AstroError.message("成功配准不足两张，无法堆栈。请排除云层、拖尾和构图差异过大的照片。") }
        let fileName = "Master-\(UUID().uuidString).rgba"
        let out = repository.url(project, fileName)
        if let error = AstroBridge.stack(frames: accepted, width: w, height: h, mode: cfg.mode.rawValue, sigma: cfg.sigma, skyFraction: cfg.skyFraction, feather: cfg.feather, destination: out.path, token: token, progress: { p in progress(0.53 + p * 0.47, "合成真实像素 \(Int(p * 100))%") }) {
            if token.isCancelled() { throw CancellationError() }
            throw AstroError.message(error)
        }
        return StackWorkResult(frames: frames, result: StackResult(fileName: fileName, width: w, height: h, acceptedFrames: accepted.count, mode: cfg.mode))
    }
}

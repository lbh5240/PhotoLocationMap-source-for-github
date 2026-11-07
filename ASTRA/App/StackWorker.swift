import Foundation
import CoreImage

struct StackWorkResult {
    var frames: [FrameRecord]
    var result: StackResult
    var formatNote: String?
}
enum StackWorker {
    static func validateSelection(_ project: AstroProject, format: PhotoFormat? = nil) throws {
        let selected = try StackSelection.indices(in: project, format: format).map { project.frames[$0] }
        guard selected.count >= 2 else { throw AstroError.message("请至少选择两张照片。") }
        guard selected.count <= 512 else { throw AstroError.message("单次最多合成 512 张照片。") }
        if let id = project.configuration.referenceFrameID, !selected.contains(where: { $0.id == id }) {
            throw AstroError.message("主图未参与合成，请在照片列表中重新选择主图。")
        }
    }

    static func run(project: AstroProject, repository: ProjectRepository, format: PhotoFormat?, token: ASCancelToken, progress: @escaping (Double, String) -> Void) throws -> StackWorkResult {
        try validateSelection(project, format: format)
        let pipeline = ImagePipeline(), cfg = project.configuration
        var frames = project.frames
        let selected = try StackSelection.indices(in: project, format: format)
        let selectedSet = Set(selected)
        let grouped = frames.indices.filter { frames[$0].included && !selectedSet.contains($0) }
        let formatNote = grouped.isEmpty ? nil : "本次只使用所选格式，另有 \(grouped.count) 张未参与。"
        for index in grouped { frames[index].rejection = formatNote }
        let divisor = cfg.halfResolution == true ? 2 : 1
        let w = selected.map { frames[$0].width }.max()! / divisor
        let h = selected.map { frames[$0].height }.max()! / divisor
        try repository.clearCache(project)
        let cache = repository.url(project, "Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? repository.clearCache(project) }
        func cacheURL(_ i: Int) -> URL { cache.appendingPathComponent(frames[i].id.uuidString + ".rgba16") }
        let pixels = Int64(w) * Int64(h)
        let capacities = try? repository.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = capacities?.volumeAvailableCapacityForImportantUsage ?? capacities?.volumeAvailableCapacity.map(Int64.init)
        let needed = pixels * (Int64(selected.count) * 8 + 16) + 64 * 1024 * 1024
        if let available, available < needed {
            throw AstroError.message("当前可用 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))，本次需要约 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))。请清理空间、减少选帧或选择省空间模式。")
        }
        var analyses: [Int: [AnyHashable: Any]] = [:]
        var proxyScales: [Int: Double] = [:]
        for (step, i) in selected.enumerated() {
            if token.isCancelled() { throw CancellationError() }
            try autoreleasepool {
                progress(Double(step) / Double(selected.count) * 0.45, "解码与星点分析 \(step + 1) / \(selected.count)")
                let original = try pipeline.decode(repository.url(project, frames[i].fileName))
                let image = pipeline.registrationCanvas(original, width: w, height: h, divisor: divisor)
                let proxy = pipeline.proxy(image)
                let analysis = AstroBridge.analyze(pixels: proxy.data, width: proxy.width, height: proxy.height, skyFraction: cfg.mode == .landscape ? cfg.skyFraction : 1)
                analyses[i] = analysis; proxyScales[i] = proxy.scale
                frames[i].starCount = (analysis["stars"] as? [Any])?.count ?? 0
                frames[i].quality = (analysis["quality"] as? NSNumber)?.doubleValue ?? 0
                frames[i].rejection = nil; frames[i].registrationRMS = nil
                if cfg.mode == .trails || (frames[i].starCount ?? 0) >= 8 {
                    try pipeline.cache(image, at: cacheURL(i), token: token)
                }
            }
        }
        let requestedReference = cfg.referenceFrameID.flatMap { id in selected.first { frames[$0].id == id } }
        let eligible = selected.filter { cfg.mode == .trails || (frames[$0].starCount ?? 0) >= 8 }
        guard eligible.count >= 2 else {
            throw AstroError.message("只有 \(eligible.count) 张照片识别到至少 8 个星点，请扩大主体框或排除模糊照片。")
        }
        let reference = requestedReference ?? eligible.max(by: { (frames[$0].quality ?? 0) < (frames[$1].quality ?? 0) })!
        guard eligible.contains(reference) else {
            throw AstroError.message("主图的星点不足 8 个，请扩大主体框或选择另一张主图。")
        }
        if let region = cfg.region, cfg.mode != .trails {
            let ref = frames[reference]
            let offsetX = (Double(w * divisor - ref.width) / 2) / Double(divisor) * proxyScales[reference]!
            let offsetY = (Double(h * divisor - ref.height) / 2) / Double(divisor) * proxyScales[reference]!
            let x0 = offsetX + region.x * Double(ref.width) / Double(divisor) * proxyScales[reference]!
            let y0 = offsetY + region.y * Double(ref.height) / Double(divisor) * proxyScales[reference]!
            let x1 = x0 + region.width * Double(ref.width) / Double(divisor) * proxyScales[reference]!
            let y1 = y0 + region.height * Double(ref.height) / Double(divisor) * proxyScales[reference]!
            var referenceAnalysis = analyses[reference]!
            let stars = (referenceAnalysis["stars"] as? [[NSNumber]] ?? []).filter { star in
                star.count >= 2 && star[0].doubleValue >= x0 && star[0].doubleValue <= x1 &&
                star[1].doubleValue >= y0 && star[1].doubleValue <= y1
            }
            referenceAnalysis["stars"] = stars
            analyses[reference] = referenceAnalysis
            let count = stars.count
            guard count >= 8 else {
                throw AstroError.message("主体框内只有 \(count) 个可识别星点，请把框扩大到至少包含 8 颗清晰星星。")
            }
        }
        var accepted: [[String: Any]] = []
        for (step, i) in selected.enumerated() {
            if token.isCancelled() { throw CancellationError() }
            progress(0.45 + Double(step) / Double(selected.count) * 0.08, "全尺寸星点对齐 \(step + 1) / \(selected.count)")
            var t: [AnyHashable: Any] = ["a": 1.0, "b": 0.0, "tx": 0.0, "ty": 0.0, "rms": 0.0]
            if cfg.mode != .trails && i != reference {
                if (frames[i].starCount ?? 0) < 8 {
                    frames[i].rejection = "可识别星点少于 8 个"
                    continue
                }
                t = AstroBridge.align(reference: analyses[reference]!, source: analyses[i]!, scale: proxyScales[i]!,
                                      referencePath: cacheURL(reference).path, sourcePath: cacheURL(i).path, width: w, height: h)
                if let error = t["error"] as? String {
                    frames[i].rejection = error
                    try? FileManager.default.removeItem(at: cacheURL(i))
                    continue
                }
            }
            let a = (t["a"] as? NSNumber)?.doubleValue ?? 1, b = (t["b"] as? NSNumber)?.doubleValue ?? 0
            let tx = ((t["tx"] as? NSNumber)?.doubleValue ?? 0)
            let ty = ((t["ty"] as? NSNumber)?.doubleValue ?? 0)
            let gain = ((t["gain"] as? NSNumber)?.doubleValue ?? 1)
            let offset = ((t["offset"] as? NSNumber)?.doubleValue ?? 0)
            frames[i].registrationRMS = ((t["rms"] as? NSNumber)?.doubleValue ?? 0)
            // Geometry uses pixel-center coordinates at each scale.
            accepted.append(["path": cacheURL(i).path, "half": true, "a": a, "b": b, "tx": tx, "ty": ty, "weight": max(0.01, min(100, frames[i].quality ?? 1)), "gain": gain, "offset": offset])
        }
        guard accepted.count >= 2 else {
            let reasons = selected.compactMap { frames[$0].rejection }.prefix(2).joined(separator: "；")
            let detail = reasons.isEmpty ? "" : "\n\(reasons)"
            throw AstroError.message("选中的 \(selected.count) 张照片中只有 \(accepted.count) 张对齐成功。请使用同一片天空的清晰照片。\(detail)")
        }
        let fileName = "Master-\(UUID().uuidString).rgba"
        let out = repository.url(project, fileName)
        if let error = AstroBridge.stack(frames: accepted, width: w, height: h, mode: cfg.mode.rawValue, sigma: cfg.sigma, skyFraction: cfg.skyFraction, feather: cfg.feather, destination: out.path, token: token, progress: { p in progress(0.53 + p * 0.47, "合成真实像素 \(Int(p * 100))%") }) {
            if token.isCancelled() { throw CancellationError() }
            throw AstroError.message(error)
        }
        return StackWorkResult(frames: frames, result: StackResult(fileName: fileName, width: w, height: h, acceptedFrames: accepted.count, mode: cfg.mode, bottomFirst: true), formatNote: formatNote)
    }
}

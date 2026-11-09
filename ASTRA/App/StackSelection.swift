import Foundation

enum PhotoFormat: String, CaseIterable, Hashable, Sendable {
    case raw = "RAW / NEF"
    case processed = "JPEG / 普通照片"
}

enum StackSelection {
    static let rawExtensions: Set<String> = ["nef", "nrw", "dng", "arw", "cr2", "cr3", "raf", "orf", "rw2"]

    static func isRaw(_ frame: FrameRecord) -> Bool {
        rawExtensions.contains((frame.fileName as NSString).pathExtension.lowercased())
    }

    static func formats(in project: AstroProject) -> Set<PhotoFormat> {
        Set(project.frames.filter(\.included).map { isRaw($0) ? .raw : .processed })
    }

    static func indices(in project: AstroProject, format: PhotoFormat? = nil) throws -> [Int] {
        let selected = project.frames.indices.filter { project.frames[$0].included }
        guard selected.count >= 2 else { throw AstroError.message("请至少选择两次拍摄的照片。") }
        let raw = selected.filter { isRaw(project.frames[$0]) }
        let processed = selected.filter { !isRaw(project.frames[$0]) }
        if let format {
            let matches = format == .raw ? raw : processed
            guard matches.count >= 2 else { throw AstroError.message("所选格式不足两张，请再导入至少一张同格式照片。") }
            return matches
        }
        if raw.isEmpty || processed.isEmpty { return selected }
        if raw.count >= 2 { return raw }
        if processed.count >= 2 { return processed }
        let names = selected.map { ((project.frames[$0].name as NSString).deletingPathExtension).lowercased() }
        if names[0] == names[1] {
            throw AstroError.message("这组 JPEG+NEF 只有同一次曝光的两个格式，无法增加堆栈信噪比。请再选择至少一次拍摄的 NEF 或 JPEG。")
        }
        throw AstroError.message("目前 RAW 和 JPEG 各只有一张。请再导入同一组的至少一张 NEF 或 JPEG，软件会按格式分组堆栈。")
    }
}

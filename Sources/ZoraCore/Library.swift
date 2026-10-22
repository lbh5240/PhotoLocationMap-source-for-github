import Foundation

public struct LibraryAsset: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var originalName: String
    public var storedName: String
    public var importedAt: Date
    public var bytes: Int64
    public var recipe: Recipe?
    public var isRAW: Bool { ["nef", "nrw", "dng"].contains(URL(fileURLWithPath: originalName).pathExtension.lowercased()) }
}

public actor AssetLibrary {
    private let root: URL
    private var items: [LibraryAsset]
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("library.json")
        items = FileManager.default.fileExists(atPath: index.path)
            ? try JSONDecoder().decode([LibraryAsset].self, from: Data(contentsOf: index)) : []
    }
    public func assets() -> [LibraryAsset] { items.sorted { $0.importedAt > $1.importedAt } }
    public func url(for asset: LibraryAsset) throws -> URL {
        guard asset.storedName == URL(fileURLWithPath: asset.storedName).lastPathComponent,
              !asset.storedName.contains("\\"), !asset.storedName.contains("..") else { throw ZoraError.malformed("asset path") }
        return root.appendingPathComponent(asset.storedName)
    }
    @discardableResult public func importFile(_ source: URL) throws -> LibraryAsset {
        let ext = source.pathExtension.lowercased()
        guard ["nef", "nrw", "dng", "jpg", "jpeg", "heic", "png", "tif", "tiff"].contains(ext) else { throw ZoraError.unsupported("此文件类型无法导入") }
        let id = UUID(), name = "\(UUID().uuidString).\(ext)"
        let target = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        do {
            let bytes = (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let asset = LibraryAsset(id: id, originalName: source.lastPathComponent, storedName: name, importedAt: Date(), bytes: Int64(bytes))
            var next = items; next.append(asset); try persist(next); items = next
            return asset
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
    public func apply(_ recipe: Recipe, to id: UUID) throws {
        let valid = try recipe.validated()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw ZoraError.malformed("unknown asset") }
        var next = items; next[index].recipe = valid; try persist(next); items = next
    }
    private func persist(_ next: [LibraryAsset]) throws {
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
}

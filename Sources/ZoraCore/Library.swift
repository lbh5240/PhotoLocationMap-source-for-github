import Foundation

/// Phone-side location captured when a photo is imported (SnapBridge-style geotagging,
/// done in the app: camera originals are never rewritten).
public struct GeoTag: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var accuracy: Double?
    public var timestamp: Date
    public init(latitude: Double, longitude: Double, altitude: Double? = nil, accuracy: Double? = nil, timestamp: Date = Date()) {
        self.latitude = latitude; self.longitude = longitude; self.altitude = altitude; self.accuracy = accuracy; self.timestamp = timestamp
    }
    public func validated() throws -> Self {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              altitude?.isFinite ?? true, (accuracy ?? 0) >= 0 else { throw ZoraError.malformed("位置坐标无效") }
        return self
    }
    /// Locations older than `maximumAge` are not attached to a new photo.
    public func isFresh(at date: Date = Date(), maximumAge: TimeInterval = 600) -> Bool {
        abs(date.timeIntervalSince(timestamp)) <= maximumAge
    }
    /// ImageIO GPS dictionary. Keys equal the kCGImagePropertyGPS* constant values.
    public func exifGPS() -> [String: Any] {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"; let day = formatter.string(from: timestamp)
        formatter.dateFormat = "HH:mm:ss.SS"; let time = formatter.string(from: timestamp)
        var result: [String: Any] = [
            "Latitude": abs(latitude), "LatitudeRef": latitude >= 0 ? "N" : "S",
            "Longitude": abs(longitude), "LongitudeRef": longitude >= 0 ? "E" : "W",
            "DateStamp": day, "TimeStamp": time
        ]
        if let altitude { result["Altitude"] = abs(altitude); result["AltitudeRef"] = altitude >= 0 ? 0 : 1 }
        if let accuracy { result["HPositioningError"] = accuracy }
        return result
    }
    public var display: String { String(format: "%.5f, %.5f", latitude, longitude) }
}

public struct LibraryAsset: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var originalName: String
    public var storedName: String
    public var importedAt: Date
    public var bytes: Int64
    public var recipe: Recipe?
    // Added in 0.5. Optional so 0.4 library.json files decode unchanged.
    public var favorite: Bool?
    public var rating: Int?
    public var location: GeoTag?
    public var sourceKey: String?
    public var isRAW: Bool { ["nef", "nrw", "dng"].contains(URL(fileURLWithPath: originalName).pathExtension.lowercased()) }
    public var isFavorite: Bool { favorite ?? false }
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
    /// Camera imports pass the object's stable key so repeat downloads are recognised.
    public func contains(sourceKey: String) -> Bool { items.contains { $0.sourceKey == sourceKey } }
    public var importedSourceKeys: Set<String> { Set(items.compactMap(\.sourceKey)) }
    @discardableResult public func importFile(_ source: URL, originalName: String? = nil, sourceKey: String? = nil, location: GeoTag? = nil) throws -> LibraryAsset {
        let ext = source.pathExtension.lowercased()
        guard ["nef", "nrw", "dng", "jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff"].contains(ext) else { throw ZoraError.unsupported("此文件类型无法导入") }
        if let sourceKey, contains(sourceKey: sourceKey) { throw ZoraError.unsupported("这张照片已在照片库中") }
        let id = UUID(), name = "\(UUID().uuidString).\(ext)"
        let target = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        do {
            let bytes = (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let asset = LibraryAsset(id: id, originalName: originalName ?? source.lastPathComponent, storedName: name, importedAt: Date(), bytes: Int64(bytes),
                                     location: try location?.validated(), sourceKey: sourceKey)
            var next = items; next.append(asset); try persist(next); items = next
            return asset
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
    public func apply(_ recipe: Recipe, to id: UUID) throws {
        let valid = try recipe.validated()
        try update(id) { $0.recipe = valid }
    }
    public func setFavorite(_ favorite: Bool, for id: UUID) throws { try update(id) { $0.favorite = favorite } }
    public func setRating(_ rating: Int, for id: UUID) throws {
        guard (0...5).contains(rating) else { throw ZoraError.malformed("评分需在 0–5 之间") }
        try update(id) { $0.rating = rating == 0 ? nil : rating }
    }
    /// Removes the index entry first, then the file: a crash never leaves an entry pointing at nothing.
    public func delete(_ id: UUID) throws {
        guard let asset = items.first(where: { $0.id == id }) else { throw ZoraError.malformed("unknown asset") }
        let file = try url(for: asset)
        let next = items.filter { $0.id != id }; try persist(next); items = next
        try? FileManager.default.removeItem(at: file)
    }
    private func update(_ id: UUID, _ change: (inout LibraryAsset) -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw ZoraError.malformed("unknown asset") }
        var next = items; change(&next[index]); try persist(next); items = next
    }
    private func persist(_ next: [LibraryAsset]) throws {
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
}

import Foundation

struct ProjectRepository: Sendable {
    let root: URL
    init() throws {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        root = docs.appendingPathComponent("ASTRA", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func url(_ project: AstroProject, _ name: String) -> URL { folder(project.id).appendingPathComponent(name) }
    func save(_ project: AstroProject) throws {
        let dir = folder(project.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
    }
    func list() throws -> [AstroProject] {
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var projects: [AstroProject] = []
        for dir in dirs {
            guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let manifest = dir.appendingPathComponent("project.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            // A corrupt project is an explicit error; never silently hide a user's work.
            var p = try decoder.decode(AstroProject.self, from: Data(contentsOf: manifest))
            guard p.schema == 1 else { throw AstroError.message("工程版本不兼容：\(p.name)") }
            if p.jobInProgress {
                for location in [dir, dir.appendingPathComponent("Cache", isDirectory: true)] {
                    let files = (try? FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)) ?? []
                    for f in files where f.lastPathComponent.hasSuffix(".rgba.partial") { try? FileManager.default.removeItem(at: f) }
                }
                p.jobInProgress = false; try save(p)
            }
            projects.append(p)
        }
        return projects.sorted { $0.updated > $1.updated }
    }
    func remove(_ project: AstroProject) throws { try FileManager.default.removeItem(at: folder(project.id)) }
    func clearCache(_ p: AstroProject) throws {
        let dir = url(p, "Cache")
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }
}

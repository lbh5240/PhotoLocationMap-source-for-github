import CoreTransferable
import Foundation
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

enum PhotoImportSource: Sendable {
    case file(URL)
    case library(PhotosPickerItem)

    func displayName(at index: Int) -> String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .library: "相册第 \(index + 1) 张"
        }
    }

    func withFile<Result>(_ operation: (URL) throws -> Result) async throws -> Result {
        switch self {
        case .file(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try operation(url)
        case .library(let item):
            guard let photo = try await item.loadTransferable(type: SelectedPhotoFile.self) else {
                throw AstroError.message("相册未能提供图像文件。若照片存于 iCloud，请下载后重试。")
            }
            defer { try? FileManager.default.removeItem(at: photo.directory) }
            return try operation(photo.url)
        }
    }
}

private struct SelectedPhotoFile: Transferable, Sendable {
    let directory: URL
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let files = FileManager.default
            let directory = files.temporaryDirectory.appendingPathComponent("ASTRA-Photo-\(UUID())", isDirectory: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                let source = received.file
                var name = source.lastPathComponent
                let suffix = UTType(filenameExtension: source.pathExtension)
                if suffix?.conforms(to: .image) != true,
                   let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                   let identifier = CGImageSourceGetType(imageSource),
                   let detectedSuffix = UTType(identifier as String)?.preferredFilenameExtension {
                    name = source.deletingPathExtension().lastPathComponent + "." + detectedSuffix
                }
                let copy = directory.appendingPathComponent(name)
                // The system's source URL may expire as soon as this callback returns.
                try files.copyItem(at: source, to: copy)
                return SelectedPhotoFile(directory: directory, url: copy)
            } catch {
                try? files.removeItem(at: directory)
                throw error
            }
        }
    }
}

import CoreTransferable
import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum PhotoImportSource: Sendable {
    case file(URL)
    case library(PhotosPickerItem)

    var formats: Set<PhotoFormat> {
        switch self {
        case .file(let url):
            let suffix = url.pathExtension.lowercased()
            let raw = StackSelection.rawExtensions.contains(suffix) || UTType(filenameExtension: suffix)?.conforms(to: .rawImage) == true
            return [raw ? .raw : .processed]
        case .library(let item):
            let types = item.supportedContentTypes
            let raw = types.contains { $0.conforms(to: .rawImage) }
            let processed = types.contains { $0.conforms(to: .image) && $0 != .image && !$0.conforms(to: .rawImage) }
            if raw { return processed ? [.raw, .processed] : [.raw] }
            return [.processed]
        }
    }

    func availableFormats() async -> Set<PhotoFormat> {
        guard case .library(let item) = self, item.itemIdentifier != nil else { return formats }
        if let resources = await OriginalPhotoResource.resources(for: item) {
            let available = Set(resources.map { OriginalPhotoResource.isRAW($0) ? PhotoFormat.raw : .processed })
            if !available.isEmpty { return available }
        }
        return formats
    }

    func displayName(at index: Int) -> String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .library: "相册第 \(index + 1) 张"
        }
    }

    func withFile<Result>(format: PhotoFormat?, _ operation: (URL, Bool) throws -> Result) async throws -> Result {
        switch self {
        case .file(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try operation(url, false)
        case .library(let item):
            let photo: SelectedPhotoFile?
            let requested = format ?? (formats == [.raw] ? .raw : .processed)
            if requested == .raw {
                if let resource = await OriginalPhotoResource.resources(for: item)?.first(where: OriginalPhotoResource.isRAW) {
                    photo = try await OriginalPhotoResource.stage(resource)
                } else {
                    photo = try await item.loadTransferable(type: RAWPhotoFile.self)?.file
                }
            } else if item.supportedContentTypes.contains(where: { $0.conforms(to: .jpeg) }) {
                photo = try await item.loadTransferable(type: JPEGPhotoFile.self)?.file
            } else {
                photo = try await item.loadTransferable(type: SelectedPhotoFile.self)
            }
            guard let photo else {
                throw AstroError.message("相册未提供所选格式。若照片存于 iCloud，请下载后重试，也可从「文件」导入原件。")
            }
            defer { try? FileManager.default.removeItem(at: photo.directory) }
            guard photo.format == requested else {
                throw AstroError.message("相册提供的格式与所选格式不同，请从「文件」导入需要的原件。")
            }
            return try operation(photo.url, true)
        }
    }
}

private struct SelectedPhotoFile: Transferable, Sendable {
    let directory: URL
    let url: URL
    let format: PhotoFormat

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { try stage($0.file) }
    }

    static func stage(_ source: URL) throws -> Self {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("ASTRA-Photo-\(UUID())", isDirectory: true)
        let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil)
        let detected = imageSource.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        let suffix = UTType(filenameExtension: source.pathExtension)
        let format: PhotoFormat = detected?.conforms(to: .rawImage) == true ||
            StackSelection.rawExtensions.contains(source.pathExtension.lowercased()) ? .raw : .processed
        let name: String
        if let detected, let ext = detected.preferredFilenameExtension,
           suffix?.identifier != detected.identifier {
            name = source.deletingPathExtension().lastPathComponent + "." + ext
        } else {
            name = source.lastPathComponent
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let copy = directory.appendingPathComponent(name)
            // Keep a link to the system file where possible; its provider URL can expire.
            do { try files.linkItem(at: source, to: copy) }
            catch { try files.copyItem(at: source, to: copy) }
            return SelectedPhotoFile(directory: directory, url: copy, format: format)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }
}

private enum OriginalPhotoResource {
    static func isRAW(_ resource: PHAssetResource) -> Bool {
        let type = UTType(resource.uniformTypeIdentifier)
        return type?.conforms(to: .rawImage) == true ||
            StackSelection.rawExtensions.contains((resource.originalFilename as NSString).pathExtension.lowercased())
    }

    static func resources(for item: PhotosPickerItem) async -> [PHAssetResource]? {
        guard let identifier = item.itemIdentifier else { return nil }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        return PHAssetResource.assetResources(for: asset).filter { $0.type == .photo || $0.type == .alternatePhoto }
    }

    static func stage(_ resource: PHAssetResource) async throws -> SelectedPhotoFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ASTRA-Photo-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let filename = (resource.originalFilename as NSString).lastPathComponent
        let url = folder.appendingPathComponent(filename.isEmpty ? "Original.nef" : filename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            guard isRAW(resource) else { throw AstroError.message("相册返回的原件并非 RAW。") }
            return SelectedPhotoFile(directory: folder, url: url, format: .raw)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

private struct RAWPhotoFile: Transferable, Sendable {
    let file: SelectedPhotoFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { Self(file: try SelectedPhotoFile.stage($0.file)) }
    }
}

private struct JPEGPhotoFile: Transferable, Sendable {
    let file: SelectedPhotoFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .jpeg) { Self(file: try SelectedPhotoFile.stage($0.file)) }
    }
}

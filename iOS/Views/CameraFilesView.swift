import SwiftUI
import ZoraCore

struct CameraFilesView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", photos = "照片", raw = "RAW", movies = "视频", new = "未导入"
        var id: Self { self }
    }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter = Filter.all
    @State private var pendingDelete: CameraObject?
    private var visible: [CameraObject] {
        model.cameraObjects.filter { object in
            switch filter {
            case .all: true
            case .photos: object.kind == .jpeg || object.kind == .heif
            case .raw: object.kind == .raw
            case .movies: object.kind == .movie
            case .new: object.kind != .folder && object.kind != .movie && !model.importedKeys.contains(object.sourceKey)
            }
        }
    }
    var body: some View {
        @Bindable var settings = model
        NavigationStack {
            List {
                Section {
                    Text("按存储卡分页读取。分块下载中断后，重新连接再下载会从已收到的位置续传。大于等于 4 GiB 的扩展对象仍需用“文件”导入。") .font(.caption).foregroundStyle(.secondary)
                    Button("刷新相机文件", systemImage: "arrow.clockwise") { model.perform { try await model.listCameraFiles() } }.disabled(model.busy)
                    if model.cameraFilesChanged { Label("相机目录有变化，请刷新后继续浏览", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(Color.zoraAmber) }
                    if !model.cardStorageIDs.isEmpty {
                        Picker("存储卡", selection: $settings.selectedStorage) {
                            ForEach(model.cardStorageIDs, id: \.self) { id in Text(model.storages.first(where: { $0.id == id })?.description ?? String(format: "存储卡 %08X", id)).tag(Optional(id)) }
                        }.onChange(of: model.selectedStorage) { _, _ in model.perform { try await model.loadCameraPage(reset: true) } }.disabled(model.busy)
                    }
                    ForEach(model.storages) { storage in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(storage.description.isEmpty ? storage.label : storage.description)
                            if storage.capacity > 0, storage.capacity != UInt64.max {
                                ProgressView(value: Double(storage.capacity - storage.freeBytes), total: Double(storage.capacity))
                            }
                            Text(usage(storage)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.cameraObjects.isEmpty {
                    Section {
                        Picker("筛选", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        HStack {
                            Button("导入列表中全部新照片", systemImage: "square.and.arrow.down.on.square") {
                                model.perform { try await model.downloadAll(kinds: model.autoImportRAW ? [.jpeg, .heif, .raw] : [.jpeg, .heif]) }
                            }.disabled(model.busy)
                            Spacer()
                            if model.busy { Button("停止") { model.cancelOperation() } }
                        }
                        Text(model.autoImportRAW ? "批量导入包含 JPEG/HEIF 与 RAW" : "批量导入仅 JPEG/HEIF；可在设置中加入 RAW") .font(.caption2).foregroundStyle(.secondary)
                        if let status = model.sequenceStatus { Text(status).font(.caption.monospacedDigit()) }
                        if let name = model.transferName {
                            VStack(alignment: .leading) { Text(name).font(.caption); ProgressView(value: model.transferFraction ?? 0) }
                        }
                    }
                }
                if let data = model.cameraThumbnail, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240) }
                ForEach(visible) { object in
                    HStack {
                        Image(systemName: icon(object.kind)).foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(object.filename)
                                if model.importedKeys.contains(object.sourceKey) { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).accessibilityLabel("已导入") }
                            }
                            Text([ByteCountFormatter.string(fromByteCount: Int64(object.size), countStyle: .file), object.displayDate].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.device?.operations.contains(PTPOperation.thumbnail) == true, object.kind != .folder {
                            Button("预览") { model.perform { try await model.loadThumbnail(object) } }.disabled(model.busy)
                        }
                        Button("下载") { model.perform { try await model.download(object) } }
                            .disabled(model.busy || object.kind == .folder || object.kind == .movie)
                    }
                    .buttonStyle(.borderless)
                    .swipeActions {
                        if model.device?.canDelete == true, object.kind != .folder {
                            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = object }
                        }
                    }
                }
                Text("已显示 \(model.cameraObjects.count) / \(model.objectTotal) 项" + (model.device?.canDelete == true ? " · 向左滑动可删除相机上的单个文件" : "")).font(.caption).foregroundStyle(.secondary)
                if model.nextObjectOffset != nil { Button("加载下一页") { model.perform { try await model.loadCameraPage(reset: false) } }.disabled(model.busy) }
            }.navigationTitle("相机文件").toolbar { Button("完成") { dismiss() } }
                .confirmationDialog("从相机存储卡删除？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { object in
                    Button("删除 \(object.filename)", role: .destructive) { model.perform { try await model.deleteCameraObject(object) } }
                } message: { _ in Text("文件将从相机存储卡上永久删除，无法恢复。受保护的文件会被相机拒绝。") }
        }
    }
    private func usage(_ storage: CameraStorage) -> String {
        let free = ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.freeBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.capacity), countStyle: .file)
        let shots = storage.freeImages != UInt32.max && storage.freeImages > 0 ? " · 约可拍 \(storage.freeImages) 张" : ""
        return "可用 \(free) / \(total)\(shots)"
    }
    private func icon(_ kind: CameraObject.Kind) -> String {
        switch kind {
        case .jpeg, .heif: "photo"
        case .raw: "camera.aperture"
        case .movie: "film"
        case .folder: "folder"
        case .other: "doc"
        }
    }
}

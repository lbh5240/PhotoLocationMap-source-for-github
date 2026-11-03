import SwiftUI
import UniformTypeIdentifiers
import ZoraCore

struct GalleryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", favorite = "收藏", raw = "RAW", jpeg = "JPEG/HEIF", located = "有位置"
        var id: Self { self }
    }
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var query = ""
    @State private var filter = Filter.all
    private var filtered: [LibraryAsset] {
        model.assets.filter { asset in
            guard query.isEmpty || asset.originalName.localizedCaseInsensitiveContains(query) else { return false }
            switch filter {
            case .all: return true
            case .favorite: return asset.isFavorite
            case .raw: return asset.isRAW
            case .jpeg: return !asset.isRAW
            case .located: return asset.location != nil
            }
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    SectionLabel(title: "光影档案", subtitle: "保留原片，为每一次快门留底。")
                    Picker("筛选", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    if filtered.isEmpty {
                        ContentUnavailableView("照片将出现在这里", systemImage: "photo.stack", description: Text("导入 JPEG、HEIC 或 NEF 原片，或在设置中开启拍摄后自动导入。"))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 18) {
                        ForEach(filtered) { asset in
                            NavigationLink { AssetDetailView(asset: asset) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    AssetThumbnail(asset: asset).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
                                        .overlay(alignment: .topTrailing) {
                                            if asset.isFavorite { Image(systemName: "heart.fill").foregroundStyle(Color.zoraAmber).padding(8) }
                                        }
                                    Text(asset.originalName).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                    HStack(spacing: 4) {
                                        Text(asset.isRAW ? "RAW · 原片保留" : "\(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))")
                                        if let rating = asset.rating { Text(String(repeating: "★", count: rating)).foregroundStyle(Color.zoraAmber) }
                                        if asset.location != nil { Image(systemName: "location.fill") }
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button(asset.isFavorite ? "取消收藏" : "收藏", systemImage: asset.isFavorite ? "heart.slash" : "heart") { model.perform { try await model.setFavorite(asset, !asset.isFavorite) } }
                            }
                        }
                    }
                }.padding(20)
            }.background(Color.zoraBackground).navigationTitle("照片")
                .searchable(text: $query, prompt: "搜索文件名")
                .toolbar { Button("导入", systemImage: "plus") { importing = true }.accessibilityIdentifier("importPhotos") }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true) { result in
                    switch result { case .success(let urls): model.perform { try await model.importFiles(urls) }; case .failure(let error): model.error = error.localizedDescription }
                }
        }
    }
}

private struct AssetThumbnail: View {
    @Environment(AppModel.self) private var model
    let asset: LibraryAsset
    @State private var jpeg: Data?
    var body: some View {
        ZStack {
            Color.white.opacity(0.04)
            if let jpeg, let image = UIImage(data: jpeg) { Image(uiImage: image).resizable().scaledToFill().clipped() }
            else { Image(systemName: asset.isRAW ? "doc.richtext" : "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }.clipped().task(id: asset.id) {
            do { let url = try await model.library.url(for: asset); jpeg = try await model.processor.preview(url: url, recipe: asset.recipe ?? Recipe.presets[0]).jpeg }
            catch { jpeg = nil }
        }
    }
}

struct AssetDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let asset: LibraryAsset
    @State private var recipe = Recipe.presets[0]
    @State private var preview: ProcessedPreview?
    @State private var previewError: String?
    @State private var exported: URL?
    @State private var original: URL?
    @State private var confirmDelete = false
    @State private var naming = false
    @State private var newName = ""
    /// The library snapshot is refreshed after each change; read the live entry, not the navigation copy.
    private var current: LibraryAsset { model.assets.first { $0.id == asset.id } ?? asset }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let preview, let image = UIImage(data: preview.jpeg) { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20)) }
                else { ContentUnavailableView("预览", systemImage: "photo", description: Text(previewError ?? "正在处理照片…")) }
                HStack {
                    Label(current.isRAW ? "RAW 原片" : "原始文件", systemImage: "checkmark.shield")
                    Spacer(); Text(ByteCountFormatter.string(fromByteCount: current.bytes, countStyle: .file))
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button { model.perform { try await model.setFavorite(current, !current.isFavorite) } } label: {
                        Image(systemName: current.isFavorite ? "heart.fill" : "heart").foregroundStyle(Color.zoraAmber)
                    }.accessibilityLabel(current.isFavorite ? "取消收藏" : "收藏")
                    ForEach(1...5, id: \.self) { star in
                        Button { model.perform { try await model.setRating(current, current.rating == star ? 0 : star) } } label: {
                            Image(systemName: star <= (current.rating ?? 0) ? "star.fill" : "star").foregroundStyle(Color.zoraAmber)
                        }.accessibilityLabel("评 \(star) 星")
                    }
                    Spacer()
                    if let location = current.location { Label(location.display, systemImage: "location").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }.buttonStyle(.borderless).disabled(model.busy)
                Picker("风格", selection: $recipe) { ForEach(model.recipes) { item in Text(item.name).tag(item) } }.pickerStyle(.menu)
                VStack(spacing: 16) {
                    editSlider("曝光", value: $recipe.exposure, range: -3...3)
                    editSlider("对比", value: $recipe.contrast, range: 0...2)
                    editSlider("饱和", value: $recipe.saturation, range: 0...2)
                    editSlider("自然饱和", value: $recipe.vibrance, range: -1...1)
                    editSlider("色温", value: $recipe.temperature, range: 2000...12000, digits: 0)
                    editSlider("色调", value: $recipe.tint, range: -100...100, digits: 0)
                    editSlider("高光恢复", value: $recipe.highlightRecovery, range: 0...1)
                    editSlider("阴影", value: $recipe.shadows, range: -1...1)
                    editSlider("暗角", value: $recipe.vignette, range: 0...1)
                    editSlider("颗粒", value: $recipe.grain, range: 0...1)
                    if let name = model.cubeName { Label("LUT · \(name)", systemImage: "cube.transparent").font(.caption) }
                    Button("保存为新风格", systemImage: "plus.square.on.square") { newName = recipe.name + " 副本"; naming = true }.font(.caption)
                }.zoraPanel()
                HStack {
                    Button("导出 JPEG", systemImage: "square.and.arrow.up") {
                        model.perform { exported = try await model.export(current, recipe: recipe) }
                    }.buttonStyle(.borderedProminent).disabled(model.busy || preview == nil)
                    Button("上传原片", systemImage: "externaldrive.badge.icloud") { model.perform { try await model.enqueue(current) } }.disabled(model.busy)
                }
                if let exported {
                    HStack {
                        ShareLink("分享导出", item: exported)
                        Button("将导出加入照片库") { model.perform { _ = try await model.library.importFile(exported); await model.refresh() } }
                    }
                }
                if let original { ShareLink("分享原始文件", item: original) }
                Text("调整在 App 中处理，导出为 sRGB JPEG，保留原片 EXIF" + (current.location != nil ? "并写入导入时的手机定位" : "") + "。原片不会被改写；RAW 解码取决于 iOS 的机型与格式支持。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("从 ZORA 照片库删除", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(model.busy)
            }.padding(20)
        }.background(Color.zoraBackground).navigationTitle(current.originalName).navigationBarTitleDisplayMode(.inline)
            .onAppear { recipe = asset.recipe ?? Recipe.presets[0] }
            .task(id: recipe) {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let url = try await model.library.url(for: asset); original = url
                    let rendered = try await model.processor.preview(url: url, recipe: recipe, cube: model.cube)
                    try Task.checkCancellation(); preview = rendered; previewError = nil
                } catch is CancellationError {} catch { preview = nil; previewError = error.localizedDescription }
            }
            .confirmationDialog("删除这张照片？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除原片与编辑记录", role: .destructive) { model.perform { try await model.deleteAsset(current); dismiss() } }
            } message: { Text("只删除 ZORA 内的副本；相机存储卡与已上传到 NAS 的文件不受影响。") }
            .alert("保存为新风格", isPresented: $naming) {
                TextField("风格名称", text: $newName)
                Button("保存") { model.perform { try model.saveRecipe(recipe, name: newName) } }
                Button("取消", role: .cancel) {}
            }
    }
    private func editSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, digits: Int = 2) -> some View {
        VStack(spacing: 5) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(digits))).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value: value, in: range)
        }
    }
}

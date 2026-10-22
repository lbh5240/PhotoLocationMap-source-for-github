import SwiftUI
import UniformTypeIdentifiers
import ZoraCore

struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var query = ""
    private var filtered: [LibraryAsset] { model.assets.filter { query.isEmpty || $0.originalName.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    SectionLabel(title: "光影档案", subtitle: "保留原片，为每一次快门留底。")
                    if filtered.isEmpty {
                        ContentUnavailableView("照片将出现在这里", systemImage: "photo.stack", description: Text("导入 JPEG、HEIC 或 NEF 原片，开始编辑与备份。"))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 18) {
                        ForEach(filtered) { asset in
                            NavigationLink { AssetDetailView(asset: asset) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    AssetThumbnail(asset: asset).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
                                    Text(asset.originalName).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                    Text(asset.isRAW ? "RAW · 原片保留" : "\(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
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
    let asset: LibraryAsset
    @State private var recipe = Recipe.presets[0]
    @State private var preview: ProcessedPreview?
    @State private var previewError: String?
    @State private var exported: URL?
    @State private var original: URL?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let preview, let image = UIImage(data: preview.jpeg) { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20)) }
                else { ContentUnavailableView("预览", systemImage: "photo", description: Text(previewError ?? "正在处理照片…")) }
                HStack {
                    Label(asset.isRAW ? "RAW 原片" : "原始文件", systemImage: "checkmark.shield")
                    Spacer(); Text(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))
                }.font(.caption).foregroundStyle(.secondary)
                Picker("风格", selection: $recipe) { ForEach(model.recipes) { item in Text(item.name).tag(item) } }.pickerStyle(.menu)
                VStack(spacing: 16) {
                    editSlider("曝光", value: $recipe.exposure, range: -3...3)
                    editSlider("对比", value: $recipe.contrast, range: 0...2)
                    editSlider("饱和", value: $recipe.saturation, range: 0...2)
                    editSlider("色温", value: $recipe.temperature, range: 2000...12000)
                    if let name = model.cubeName { Label("LUT · \(name)", systemImage: "cube.transparent").font(.caption) }
                }.zoraPanel()
                HStack {
                    Button("导出 JPEG", systemImage: "square.and.arrow.up") {
                        model.perform { exported = try await model.export(asset, recipe: recipe) }
                    }.buttonStyle(.borderedProminent).disabled(model.busy || preview == nil)
                    Button("上传原片", systemImage: "externaldrive.badge.icloud") { model.perform { try await model.enqueue(asset) } }.disabled(model.busy)
                }
                if let exported {
                    HStack {
                        ShareLink("分享导出", item: exported)
                        Button("将导出加入照片库") { model.perform { _ = try await model.library.importFile(exported) } }
                    }
                }
                if let original { ShareLink("分享原始文件", item: original) }
                Text("调整在 App 中处理，导出为 sRGB JPEG。原片不会被改写；RAW 解码取决于 iOS 的机型与格式支持。上传按钮备份原片，导出图可加入照片库后上传。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color.zoraBackground).navigationTitle(asset.originalName).navigationBarTitleDisplayMode(.inline)
            .onAppear { recipe = asset.recipe ?? Recipe.presets[0] }
            .task(id: recipe) {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let url = try await model.library.url(for: asset); original = url
                    let rendered = try await model.processor.preview(url: url, recipe: recipe, cube: model.cube)
                    try Task.checkCancellation(); preview = rendered; previewError = nil
                } catch is CancellationError {} catch { preview = nil; previewError = error.localizedDescription }
            }
    }
    private func editSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 5) { HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(title == "色温" ? 0 : 2))).monospacedDigit().foregroundStyle(.secondary) }.font(.caption); Slider(value: value, in: range) }
    }
}

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
                VStack(alignment: .leading, spacing: 16) {
                    SectionLabel(title: "光影档案", subtitle: summary)
                    FilterChips(options: Filter.allCases, selection: $filter) { $0.rawValue }
                    if filtered.isEmpty {
                        ContentUnavailableView("照片将出现在这里", systemImage: "photo.stack", description: Text(model.assets.isEmpty ? "点右上角 + 导入 JPEG、HEIC 或 NEF，或在设置中开启拍摄后自动导入。" : "没有符合当前筛选的照片。"))
                            .padding(.top, 30)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 6)], spacing: 6) {
                        ForEach(filtered) { asset in
                            NavigationLink { AssetDetailView(asset: asset) } label: { AssetCell(asset: asset) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(asset.isFavorite ? "取消收藏" : "收藏", systemImage: asset.isFavorite ? "heart.slash" : "heart") { model.perform { try await model.setFavorite(asset, !asset.isFavorite) } }
                                }
                        }
                    }
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }.zoraPage().navigationTitle("照片").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "搜索文件名")
                .toolbar { Button("导入", systemImage: "plus") { importing = true }.accessibilityIdentifier("importPhotos") }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true) { result in
                    switch result { case .success(let urls): model.perform { try await model.importFiles(urls) }; case .failure(let error): model.error = error.localizedDescription }
                }
        }
    }
    private var summary: String {
        let raw = model.assets.filter(\.isRAW).count, favorites = model.assets.filter(\.isFavorite).count
        return model.assets.isEmpty ? "保留原片，为每一次快门留底。" : "\(model.assets.count) 张 · RAW \(raw) · 收藏 \(favorites)"
    }
}

private struct AssetCell: View {
    let asset: LibraryAsset
    var body: some View {
        AssetThumbnail(asset: asset)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if asset.isRAW {
                    Text("RAW").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if asset.isFavorite { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Color.zoraAmber).shadow(radius: 2).padding(6) }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if let rating = asset.rating { Text(String(repeating: "★", count: rating)).font(.system(size: 9)).foregroundStyle(Color.zoraAmber) }
                    if asset.location != nil { Image(systemName: "location.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.85)) }
                }.shadow(radius: 2).padding(6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(asset.originalName + (asset.isFavorite ? "，已收藏" : ""))
    }
}

private struct AssetThumbnail: View {
    @Environment(AppModel.self) private var model
    let asset: LibraryAsset
    @State private var jpeg: Data?
    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let jpeg, let image = UIImage(data: jpeg) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: asset.isRAW ? "camera.aperture" : "photo").font(.title2).foregroundStyle(.tertiary) }
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
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    Color.black
                    if let preview, let image = UIImage(data: preview.jpeg) { Image(uiImage: image).resizable().scaledToFit() }
                    else { ContentUnavailableView("预览", systemImage: "photo", description: Text(previewError ?? "正在处理照片…")) }
                }
                .frame(minHeight: 240).clipShape(RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 8) {
                    StatusPill(text: current.isRAW ? "RAW 原片" : "原始文件", systemImage: "checkmark.shield", color: .zoraOK)
                    StatusPill(text: ByteCountFormatter.string(fromByteCount: current.bytes, countStyle: .file), systemImage: "doc", color: .secondary)
                    if let location = current.location { StatusPill(text: location.display, systemImage: "location", color: .secondary) }
                }
                HStack(spacing: 14) {
                    Button { model.perform { try await model.setFavorite(current, !current.isFavorite) } } label: {
                        Image(systemName: current.isFavorite ? "heart.fill" : "heart").font(.title3).foregroundStyle(Color.zoraAmber)
                    }.accessibilityLabel(current.isFavorite ? "取消收藏" : "收藏")
                    Divider().frame(height: 22)
                    ForEach(1...5, id: \.self) { star in
                        Button { model.perform { try await model.setRating(current, current.rating == star ? 0 : star) } } label: {
                            Image(systemName: star <= (current.rating ?? 0) ? "star.fill" : "star").foregroundStyle(Color.zoraAmber)
                        }.accessibilityLabel("评 \(star) 星")
                    }
                    Spacer()
                }.buttonStyle(.borderless).disabled(model.busy)
                VStack(alignment: .leading, spacing: 10) {
                    Text("风格").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.recipes) { item in
                                let selected = item.id == recipe.id
                                Button { recipe = item } label: {
                                    VStack(spacing: 6) {
                                        RecipeSwatch(recipe: item).frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.zoraAmber : .clear, lineWidth: 2))
                                        Text(item.name).font(.caption2).lineLimit(1).foregroundStyle(selected ? Color.zoraAmber : .secondary)
                                    }.frame(width: 70)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(spacing: 0) {
                    adjustGroup("基础", icon: "sun.max", expanded: true) {
                        editSlider("曝光", value: $recipe.exposure, range: -3...3)
                        editSlider("对比", value: $recipe.contrast, range: 0...2)
                        editSlider("饱和", value: $recipe.saturation, range: 0...2)
                        editSlider("自然饱和", value: $recipe.vibrance, range: -1...1)
                    }
                    Divider().padding(.vertical, 6)
                    adjustGroup("白平衡", icon: "thermometer.medium") {
                        editSlider("色温", value: $recipe.temperature, range: 2000...12000, digits: 0)
                        editSlider("色调", value: $recipe.tint, range: -100...100, digits: 0)
                    }
                    Divider().padding(.vertical, 6)
                    adjustGroup("光影与质感", icon: "circle.lefthalf.filled") {
                        editSlider("高光恢复", value: $recipe.highlightRecovery, range: 0...1)
                        editSlider("阴影", value: $recipe.shadows, range: -1...1)
                        editSlider("暗角", value: $recipe.vignette, range: 0...1)
                        editSlider("颗粒", value: $recipe.grain, range: 0...1)
                    }
                    if let name = model.cubeName { Label("叠加 LUT · \(name)", systemImage: "cube.transparent").font(.caption).foregroundStyle(.secondary).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        Button("还原", systemImage: "arrow.uturn.backward") { recipe = model.recipes.first { $0.id == recipe.id } ?? Recipe.presets[0] }
                        Spacer()
                        Button("保存为新风格", systemImage: "plus.square.on.square") { newName = recipe.name + " 副本"; naming = true }
                    }.font(.caption.weight(.medium)).padding(.top, 12)
                }.zoraPanel()
                HStack(spacing: 10) {
                    Button { model.perform { exported = try await model.export(current, recipe: recipe) } } label: {
                        Label("导出 JPEG", systemImage: "square.and.arrow.up").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(LinearGradient.zoraAccent, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).disabled(model.busy || preview == nil)
                    Button { model.perform { try await model.enqueue(current) } } label: {
                        Label("备份原片", systemImage: "externaldrive.badge.icloud").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).disabled(model.busy)
                }
                if let exported {
                    HStack {
                        ShareLink("分享导出", item: exported)
                        Spacer()
                        Button("加入照片库") { model.perform { _ = try await model.library.importFile(exported); await model.refresh() } }
                    }.font(.subheadline).zoraPanel()
                }
                if let original { ShareLink("分享原始文件", item: original).font(.subheadline) }
                Text("导出为 sRGB JPEG，保留原片 EXIF" + (current.location != nil ? "并写入导入时的手机定位" : "") + "。原片不会被改写。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("从 ZORA 照片库删除", systemImage: "trash", role: .destructive) { confirmDelete = true }.font(.subheadline).disabled(model.busy)
            }.padding(18)
        }.zoraPage().navigationTitle(current.originalName).navigationBarTitleDisplayMode(.inline)
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
    private func adjustGroup<Content: View>(_ title: String, icon: String, expanded: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        AdjustGroup(title: title, icon: icon, initiallyExpanded: expanded, content: content())
    }
    private func editSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, digits: Int = 2) -> some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(digits))).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value: value, in: range).tint(Color.zoraAmber)
        }
    }
}

private struct AdjustGroup<Content: View>: View {
    let title: String, icon: String
    @State private var expanded: Bool
    let content: Content
    init(title: String, icon: String, initiallyExpanded: Bool, content: Content) {
        self.title = title; self.icon = icon; _expanded = State(initialValue: initiallyExpanded); self.content = content
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 12) { content }.padding(.top, 10)
        } label: {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
        }.tint(.secondary)
    }
}

/// Approximate preview of a recipe on a few reference colours (sky, skin, foliage, shadow, highlight).
struct RecipeSwatch: View {
    let recipe: Recipe
    private static let samples: [(Double, Double, Double)] = [(0.42, 0.62, 0.86), (0.86, 0.66, 0.54), (0.36, 0.55, 0.30), (0.18, 0.17, 0.20), (0.92, 0.90, 0.86)]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.samples.count, id: \.self) { i in Rectangle().fill(color(Self.samples[i])) }
        }
    }
    private func color(_ rgb: (Double, Double, Double)) -> Color {
        var (r, g, b) = rgb
        let gain = pow(2, recipe.exposure); r *= gain; g *= gain; b *= gain
        let warm = (6500 - recipe.temperature) / 9000, tint = recipe.tint / 300
        r += warm; b -= warm; g -= tint
        let luma = 0.3 * r + 0.59 * g + 0.11 * b
        let sat = recipe.saturation * (1 + recipe.vibrance * 0.5)
        r = luma + (r - luma) * sat; g = luma + (g - luma) * sat; b = luma + (b - luma) * sat
        func tone(_ v: Double) -> Double {
            var x = 0.5 + (v - 0.5) * recipe.contrast
            if x < 0.5 { x += recipe.shadows * 0.15 * (0.5 - x) * 2 } else { x -= recipe.highlightRecovery * 0.12 * (x - 0.5) * 2 }
            return min(1, max(0, x))
        }
        return Color(red: tone(r), green: tone(g), blue: tone(b))
    }
}

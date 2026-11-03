import SwiftUI
import ZoraCore

struct LooksView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var shared: URL?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel(title: "让色彩有自己的语气", subtitle: "ZORA Recipes · 独立的手机端影像风格")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(model.recipes) { recipe in
                            RecipeCard(recipe: recipe)
                                .contextMenu {
                                    Button("导出 Recipe JSON", systemImage: "square.and.arrow.up") {
                                        do { shared = try model.exportRecipe(recipe) } catch { model.error = error.localizedDescription }
                                    }
                                    if !recipe.isPreset {
                                        Button("删除", systemImage: "trash", role: .destructive) {
                                            do { try model.deleteRecipe(recipe) } catch { model.error = error.localizedDescription }
                                        }
                                    }
                                }
                        }
                    }
                    if let shared {
                        HStack { ShareLink("分享 \(shared.lastPathComponent)", item: shared); Spacer(); Button("关闭") { self.shared = nil } }.font(.subheadline).zoraPanel()
                    }
                    ZoraCard(title: "LUT 库", systemImage: "cube.transparent") {
                        Button { importing = true } label: { Image(systemName: "plus").font(.subheadline.weight(.semibold)) }.accessibilityLabel("导入 LUT 或 Recipe")
                    } content: {
                        if model.luts.isEmpty {
                            Text("导入 .cube（2–64 阶，DOMAIN 0…1）后保存在本机，可随时切换。也可在这里导入 Recipe JSON。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.luts, id: \.self) { name in
                            HStack(spacing: 10) {
                                Button {
                                    do { try model.selectLUT(model.cubeName == name ? nil : name) } catch { model.error = error.localizedDescription }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: model.cubeName == name ? "checkmark.circle.fill" : "circle").foregroundStyle(model.cubeName == name ? Color.zoraAmber : .secondary)
                                        Text(name).lineLimit(1).foregroundStyle(.primary)
                                        Spacer(minLength: 0)
                                    }
                                }
                                Button(role: .destructive) {
                                    do { try model.deleteLUT(name) } catch { model.error = error.localizedDescription }
                                } label: { Image(systemName: "trash").font(.caption) }.accessibilityLabel("删除 \(name)")
                            }.buttonStyle(.borderless).font(.subheadline).padding(.vertical, 2)
                        }
                        Button("导入 LUT / Recipe JSON", systemImage: "square.and.arrow.down") { importing = true }.font(.subheadline)
                    }
                    Text("长按风格卡片可导出或删除自定义风格。ZORA 不是 Nikon Imaging Cloud 客户端，不下载云创配方，也不向相机写入 Picture Control；风格在手机端处理照片。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }.zoraPage().navigationTitle("风格").navigationBarTitleDisplayMode(.inline)
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                    switch result { case .success(let urls): if let url = urls.first { model.perform { try model.importLook(url) } }; case .failure(let error): model.error = error.localizedDescription }
                }
        }
    }
}

private struct RecipeCard: View {
    let recipe: Recipe
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecipeSwatch(recipe: recipe).frame(height: 58).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if !recipe.isPreset {
                        Text("自定义").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(Color.zoraAmber, in: Capsule()).padding(6)
                    }
                }
            Text(recipe.name).font(.headline).lineLimit(1)
            Text(details).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }
    private var details: String {
        var parts = [String(format: "EV %+.1f", recipe.exposure), String(format: "%.0fK", recipe.temperature)]
        if recipe.saturation == 0 { parts.append("黑白") } else if recipe.saturation != 1 { parts.append(String(format: "饱和 %.2f", recipe.saturation)) }
        if recipe.contrast != 1 { parts.append(String(format: "对比 %.2f", recipe.contrast)) }
        if recipe.grain > 0 { parts.append("颗粒") }
        if recipe.vignette > 0 { parts.append("暗角") }
        return parts.joined(separator: " · ")
    }
}

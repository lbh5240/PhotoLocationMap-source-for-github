import SwiftUI
import ZoraCore

struct LooksView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var shared: URL?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    SectionLabel(title: "让色彩有自己的语气", subtitle: "ZORA Recipes · 独立的手机端影像风格")
                    ForEach(Array(model.recipes.enumerated()), id: \.element.id) { index, recipe in
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text(String(format: "%02d", index+1)).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.zoraAmber)
                                if !recipe.isPreset { Text("自定义").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.zoraAmber.opacity(0.2), in: Capsule()) }
                                Spacer()
                                Image(systemName: recipe.saturation == 0 ? "circle.lefthalf.filled" : "sun.haze")
                            }
                            Text(recipe.name).font(.title2.weight(.medium))
                            HStack { Text("EV \(recipe.exposure, specifier: "%.1f")"); Text("对比 \(recipe.contrast, specifier: "%.2f")"); Text("色温 \(recipe.temperature, specifier: "%.0f")") }
                                .font(.caption).foregroundStyle(.secondary)
                            if recipe.grain > 0 || recipe.vignette > 0 || recipe.highlightRecovery > 0 || recipe.shadows != 0 {
                                HStack {
                                    if recipe.highlightRecovery > 0 { Text("高光 -\(recipe.highlightRecovery, specifier: "%.2f")") }
                                    if recipe.shadows != 0 { Text("阴影 \(recipe.shadows, specifier: "%+.2f")") }
                                    if recipe.vignette > 0 { Text("暗角 \(recipe.vignette, specifier: "%.2f")") }
                                    if recipe.grain > 0 { Text("颗粒 \(recipe.grain, specifier: "%.2f")") }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                        }.zoraPanel()
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
                    if let shared {
                        HStack { ShareLink("分享 \(shared.lastPathComponent)", item: shared); Spacer(); Button("关闭") { self.shared = nil } }.zoraPanel()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("LUT 库", systemImage: "cube.transparent").font(.headline)
                        Text("支持 2–64 阶 3D LUT、标准 0…1 DOMAIN。导入后保存在本机，重启后仍可使用；选中的 LUT 在编辑预览和导出中叠加于风格之后。") .font(.caption).foregroundStyle(.secondary)
                        if model.luts.isEmpty { Text("尚未导入 LUT").font(.caption).foregroundStyle(.secondary) }
                        ForEach(model.luts, id: \.self) { name in
                            HStack {
                                Button {
                                    do { try model.selectLUT(model.cubeName == name ? nil : name) } catch { model.error = error.localizedDescription }
                                } label: {
                                    Label(name, systemImage: model.cubeName == name ? "checkmark.circle.fill" : "circle")
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    do { try model.deleteLUT(name) } catch { model.error = error.localizedDescription }
                                } label: { Image(systemName: "trash") }.accessibilityLabel("删除 \(name)")
                            }.buttonStyle(.borderless).font(.subheadline)
                        }
                        Button("导入 LUT / Recipe JSON", systemImage: "square.and.arrow.down") { importing = true }
                    }.zoraPanel()
                    Text("长按风格卡片可导出或删除。这不是 Nikon Imaging Cloud 客户端。Z7 II 不在已查证的官方兼容列表中；ZORA 不下载受保护的云创配方，也不向相机写入云创或 Picture Control。这里的原创 Recipes 在手机端处理照片。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color.zoraBackground).navigationTitle("风格")
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                    switch result { case .success(let urls): if let url = urls.first { model.perform { try model.importLook(url) } }; case .failure(let error): model.error = error.localizedDescription }
                }
        }
    }
}

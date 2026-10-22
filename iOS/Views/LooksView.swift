import SwiftUI
import ZoraCore

struct LooksView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    SectionLabel(title: "让色彩有自己的语气", subtitle: "ZORA Recipes · 独立的手机端影像风格")
                    ForEach(Array(model.recipes.enumerated()), id: \.element.id) { index, recipe in
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { Text(String(format: "%02d", index+1)).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.zoraAmber); Spacer(); Image(systemName: recipe.saturation == 0 ? "circle.lefthalf.filled" : "sun.haze") }
                            Text(recipe.name).font(.title2.weight(.medium))
                            HStack { Text("EV \(recipe.exposure, specifier: "%.1f")"); Text("对比 \(recipe.contrast, specifier: "%.2f")"); Text("色温 \(recipe.temperature, specifier: "%.0f")") }
                                .font(.caption).foregroundStyle(.secondary)
                        }.zoraPanel()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.cubeName ?? "导入你有权使用的 .cube LUT", systemImage: "cube.transparent").font(.headline)
                        Text("支持 2–64 阶 3D LUT、标准 0…1 DOMAIN。当前 LUT 在照片编辑预览和导出中应用，仅本次会话有效。") .font(.caption).foregroundStyle(.secondary)
                        if model.cube != nil { Button("移除当前 LUT") { model.cube = nil; model.cubeName = nil } }
                        Button("导入 LUT / Recipe JSON", systemImage: "square.and.arrow.down") { importing = true }
                    }.zoraPanel()
                    Text("这不是 Nikon Imaging Cloud 客户端。Z7 II 不在已查证的官方兼容列表中；ZORA 不下载受保护的云创配方，也不向相机写入云创或 Picture Control。这里的原创 Recipes 在手机端处理照片。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color.zoraBackground).navigationTitle("风格")
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                    switch result { case .success(let urls): if let url = urls.first { model.perform { try model.importLook(url) } }; case .failure(let error): model.error = error.localizedDescription }
                }
        }
    }
}

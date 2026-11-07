import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum ToolPanel: String, CaseIterable {
    case stack = "堆栈", light = "光影", color = "色彩", curves = "曲线", hsl = "HSL", detail = "细节"
    var symbol: String { switch self { case .stack: "square.3.layers.3d"; case .light: "sun.max"; case .color: "circle.lefthalf.filled"; case .curves: "point.topleft.down.to.point.bottomright.curvepath"; case .hsl: "slider.horizontal.3"; case .detail: "circle.dotted" } }
}
struct WorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var panel = ToolPanel.stack
    @State private var importing = false
    @State private var pickingPhotos = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showFrames = false
    @State private var showExport = false
    @State private var showHelp = false
    @State private var showRename = false
    @State private var name = ""
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.028, blue: 0.04).ignoresSafeArea()
            if let p = store.project {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Badge(text: p.result == nil ? "原片预览" : "\(p.result!.acceptedFrames) 帧合成", color: .mint)
                        Text(info(p)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if !p.frames.isEmpty { Button { showFrames = true } label: { Image(systemName: "rectangle.stack").padding(8) }.accessibilityLabel("管理照片") }
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                    PhotoCanvas(image: store.preview, original: store.beforePreview, skyFraction: panel == .stack && p.configuration.mode == .landscape ? p.configuration.skyFraction : nil)
                        .frame(minHeight: 160).overlay(alignment: .bottomTrailing) {
                            if store.preview != nil { Text("长按比较 · 双指缩放").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).padding(8).allowsHitTesting(false) }
                        }
                    if store.busy { progressView }
                    VStack(spacing: 12) {
                        if panel != .stack { HistogramView(values: store.histogram).padding(.horizontal, 8) }
                        ScrollView { controls(p).padding(.horizontal, 4).padding(.bottom, 8) }.frame(height: panel == .stack ? 214 : 198)
                        toolBar
                    }.padding(16).background(Color(red: 0.045, green: 0.05, blue: 0.07))
                }
            }
        }
        .navigationTitle(store.project?.name ?? "ASTRA").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(store.busy)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: store.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(store.busy || store.project?.undo.isEmpty != false).accessibilityLabel("撤销")
                Menu {
                    importActions
                    Button("管理照片", systemImage: "rectangle.stack") { showFrames = true }
                    Button("重命名工程", systemImage: "pencil") { name = store.project?.name ?? ""; showRename = true }
                    Button("重置调整", systemImage: "arrow.counterclockwise", action: store.reset)
                    Button("重做", systemImage: "arrow.uturn.forward", action: store.redo).disabled(store.project?.redo.isEmpty != false)
                    Button("清理解码缓存", systemImage: "externaldrive", action: store.clearCache)
                    Button("使用说明", systemImage: "questionmark.circle") { showHelp = true }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(store.busy)
                Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }.disabled(store.busy || store.preview == nil).accessibilityLabel("导出照片")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): store.importFiles(urls); case .failure(let error): store.message = error.localizedDescription }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $selectedPhotos, maxSelectionCount: 512,
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            store.importPhotos(items)
        }
        .sheet(isPresented: $showFrames) { FramesView() }
        .sheet(isPresented: $showExport) { ExportView() }
        .sheet(isPresented: $showHelp) { HelpView() }
        .sheet(isPresented: Binding(get: { store.sharedURL != nil }, set: { if !$0 { store.sharedURL = nil } })) { if let url = store.sharedURL { ShareSheet(url: url) } }
        .alert("重命名工程", isPresented: $showRename) {
            TextField("工程名称", text: $name)
            Button("保存") { let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines); if !trimmed.isEmpty { store.update { $0.name = trimmed }; store.flushSave() } }
            Button("取消", role: .cancel) {}
        }
    }
    @ViewBuilder private var importActions: some View {
        Button("从相册导入", systemImage: "photo.on.rectangle.angled") { pickingPhotos = true }
        Button("从文件导入", systemImage: "folder") { importing = true }
    }
    private func info(_ p: AstroProject) -> String {
        if let r = p.result { return "\(r.width) × \(r.height) · Float32" }
        guard let f = p.frames.first else { return "等待导入" }
        return "\(f.camera) · \(String(format: "%.1f", Double(f.width*f.height)/1_000_000)) MP"
    }
    private var progressView: some View {
        VStack(spacing: 8) {
            HStack { Text(store.status).font(.caption); Spacer(); if store.canCancel { Button("取消", action: store.cancel).font(.caption) } }
            if store.progress == 0 { ProgressView().frame(maxWidth: .infinity) } else { ProgressView(value: store.progress).tint(.mint) }
        }.padding(14).background(.white.opacity(0.05))
    }
    private var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(ToolPanel.allCases, id: \.self) { item in
                        Button { withAnimation(.snappy) { panel = item } } label: {
                            VStack(spacing: 5) { Image(systemName: item.symbol).font(.system(size: 17)); Text(item.rawValue).font(.system(size: 10, weight: .medium)) }
                                .frame(width: 54, height: 48).foregroundStyle(panel == item ? Color.white : Color.secondary)
                                .background(panel == item ? Color.indigo.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }.padding(5).astroGlass()
            }
        }.disabled(store.busy)
    }
    @ViewBuilder private func controls(_ p: AstroProject) -> some View {
        switch panel {
        case .stack: stackControls(p)
        case .light:
            VStack(spacing: 13) {
                slider("曝光 / EV", \.exposure, -5...5)
                slider("对比度", \.contrast, 0.5...1.8)
                slider("高光", \.highlights, 0...1)
                slider("阴影", \.shadows, -1...1)
                slider("黑场抬升", \.black, 0...0.15)
            }
        case .color:
            VStack(spacing: 13) {
                HStack { ForEach(Array(["自然银河", "冷调暗夜", "暗部提亮"].enumerated()), id: \.offset) { i, title in Button(title) { store.preset(i) }.font(.caption).buttonStyle(.bordered) } }
                slider("冷暖 · 相对原片", \.warmth, -100...100)
                slider("色调", \.tint, -100...100)
                slider("饱和度", \.saturation, 0...2)
                slider("自然饱和度", \.vibrance, -1...1)
            }
        case .curves: CurveControls()
        case .hsl: HSLControls()
        case .detail:
            VStack(alignment: .leading, spacing: 14) {
                slider("亮度 / 彩色降噪", \.noise, 0...1)
                slider("亮度锐化", \.sharpness, 0...1.5)
                Text("堆栈先通过多帧平均改善信噪比，这里的空间降噪用于微调。较强降噪可能损失暗星，请配合调整前后比较。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func slider(_ title: String, _ key: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double>) -> some View {
        AdjustmentSlider(title: title, value: Binding(get: { store.project?.adjustments[keyPath: key] ?? 0 }, set: { v in store.update({ $0.adjustments[keyPath: key] = v }, render: true) }), range: range, checkpoint: store.checkpoint).disabled(store.busy)
    }
    private func stackControls(_ p: AstroProject) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("合成模式", selection: Binding(get: { p.configuration.mode }, set: { v in store.update { $0.configuration.mode = v } })) {
                ForEach(StackMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented)
            HStack {
                Text(p.configuration.mode.subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("\(p.frames.filter(\.included).count) 张已选") { showFrames = true }.font(.caption)
            }
            if p.configuration.mode == .landscape {
                AdjustmentSlider(title: "天空占画面高度", value: Binding(get: { p.configuration.skyFraction }, set: { v in store.update { $0.configuration.skyFraction = v } }), range: 0.15...1, format: "%.2f")
                Text("水平分界适用于平坦地景。山峰、树木等复杂边缘暂不支持精细蒙版。").font(.caption2).foregroundStyle(.secondary)
            } else if p.configuration.mode != .trails {
                AdjustmentSlider(title: "异常值剔除 / Sigma", value: Binding(get: { p.configuration.sigma }, set: { v in store.update { $0.configuration.sigma = v } }), range: 1.5...5, format: "%.1f")
                Text("至少 5 帧启用稳健剔除；2–4 帧使用加权平均。").font(.caption2).foregroundStyle(.secondary)
            } else { Text("最大值混合会保留飞机与卫星光带，请在帧列表排除不需要的照片。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
            HStack(spacing: 10) {
                Menu { importActions } label: {
                    Label("导入照片", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 4)
                }.buttonStyle(.bordered)
                Button(action: store.startStack) { Label("开始合成", systemImage: "sparkles").frame(maxWidth: .infinity).padding(.vertical, 4) }.buttonStyle(.borderedProminent).disabled(p.frames.filter(\.included).count < 2)
            }
        }.disabled(store.busy)
    }
}
private struct CurveControls: View {
    @EnvironmentObject private var store: AppStore
    private func binding(_ key: WritableKeyPath<Adjustments, Double>) -> Binding<Double> { Binding(get: { store.project?.adjustments[keyPath: key] ?? 0 }, set: { v in store.update({ $0.adjustments[keyPath: key] = v }, render: true) }) }
    var body: some View {
        VStack(spacing: 14) {
            Canvas { ctx, size in
                guard let a = store.project?.adjustments else { return }
                let points = [a.black, a.curveLow, a.curveMid, a.curveHigh, 1]
                for i in 0...4 { let v = CGFloat(i)/4; let p = Path { p in p.move(to: CGPoint(x: v*size.width, y: 0)); p.addLine(to: CGPoint(x: v*size.width, y: size.height)) }; ctx.stroke(p, with: .color(.white.opacity(0.08))) }
                var line = Path()
                for (i,y) in points.enumerated() { let point = CGPoint(x: CGFloat(i)/4*size.width, y: (1-y)*size.height); if i==0 { line.move(to: point) } else { line.addLine(to: point) }; ctx.fill(Path(ellipseIn: CGRect(x: point.x-3,y: point.y-3,width: 6,height: 6)), with: .color(.mint)) }
                ctx.stroke(line, with: .color(.mint), lineWidth: 1.5)
            }.frame(height: 65).accessibilityLabel("曲线控制点位置示意")
            AdjustmentSlider(title: "暗调 · 输入 25%", value: binding(\.curveLow), range: 0...0.5, checkpoint: store.checkpoint)
            AdjustmentSlider(title: "中间调 · 输入 50%", value: binding(\.curveMid), range: 0.2...0.8, checkpoint: store.checkpoint)
            AdjustmentSlider(title: "亮调 · 输入 75%", value: binding(\.curveHigh), range: 0.5...1, checkpoint: store.checkpoint)
        }.disabled(store.busy)
    }
}
private struct HSLControls: View {
    @EnvironmentObject private var store: AppStore
    @State private var band = 0
    private let colors: [Color] = [.red, .yellow, .green, .cyan, .blue, .purple]
    private let names = ["红", "黄", "绿", "青", "蓝", "洋红"]
    private func binding(_ key: WritableKeyPath<HSLBand, Double>) -> Binding<Double> { Binding(get: { store.project?.adjustments.hsl[band][keyPath: key] ?? 0 }, set: { v in store.update({ $0.adjustments.hsl[band][keyPath: key] = v }, render: true) }) }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 20) { ForEach(0..<6) { i in Button { band = i } label: { Circle().fill(colors[i]).frame(width: 24,height: 24).padding(4).overlay(Circle().stroke(band == i ? .white : .clear,lineWidth: 1.5)) }.accessibilityLabel(names[i]) } }.frame(maxWidth: .infinity)
            AdjustmentSlider(title: "\(names[band]) · 色相 / °", value: binding(\.hue), range: -40...40, format: "%.0f", checkpoint: store.checkpoint)
            AdjustmentSlider(title: "饱和度", value: binding(\.saturation), range: -1...1, checkpoint: store.checkpoint)
            AdjustmentSlider(title: "明度", value: binding(\.luminance), range: -1...1, checkpoint: store.checkpoint)
        }.disabled(store.busy)
    }
}
struct FramesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { Text("点击开关决定是否参与合成。修改选帧后需要重新合成，已有结果会保留到新合成成功。").font(.caption).foregroundStyle(.secondary) }
                ForEach(store.project?.frames ?? []) { f in
                    HStack(spacing: 12) {
                        if let url = store.thumbnail(f), let im = UIImage(contentsOfFile: url.path) { Image(uiImage: im).resizable().scaledToFill().frame(width: 58,height: 58).clipped().clipShape(RoundedRectangle(cornerRadius: 8)) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(f.name).font(.subheadline).lineLimit(1)
                            Text("\(f.width) × \(f.height) · \(f.camera)").font(.caption2).foregroundStyle(.secondary)
                            if let stars = f.starCount { Text("\(stars) 星点" + (f.registrationRMS.map { String(format: " · RMS %.2f px", $0) } ?? "")).font(.caption2.monospacedDigit()).foregroundStyle(.mint) }
                            if let rejection = f.rejection { Text(rejection).font(.caption2).foregroundStyle(.orange) }
                        }
                        Toggle("参与合成", isOn: Binding(get: { store.project?.frames.first { $0.id == f.id }?.included ?? false }, set: { v in store.update { p in if let i = p.frames.firstIndex(where: { $0.id == f.id }) { p.frames[i].included = v } } })).labelsHidden().disabled(store.busy)
                    }.padding(.vertical, 4)
                }
            }.navigationTitle("合成照片").toolbar {
                ToolbarItem(placement: .topBarLeading) { Menu("选择") { Button("全选") { store.update { p in for i in p.frames.indices { p.frames[i].included = true } } }; Button("排除配准失败帧") { store.update { p in for i in p.frames.indices where p.frames[i].rejection != nil { p.frames[i].included = false } } } }.disabled(store.busy) }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { store.flushSave(); dismiss() } }
            }
        }
    }
}
struct ExportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ExportKind.tiff
    var body: some View {
        NavigationStack {
            Form {
                Section("格式") { Picker("文件格式", selection: $kind) { ForEach(ExportKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline) }
                Section("全分辨率 · sRGB") {
                    if let p = store.project { Text(p.result.map { "\($0.width) × \($0.height)" } ?? p.frames.first.map { "\($0.width) × \($0.height)" } ?? "") }
                    Text("导出会读取完整尺寸数据并应用当前全部调整。16 位 TIFF 适合继续后期，JPEG 适合分享。").font(.caption).foregroundStyle(.secondary)
                    if store.project?.result == nil { Text("当前尚未堆栈，将导出第一张原片的编辑结果。").font(.caption).foregroundStyle(.orange) }
                    Text("合成边缘覆盖不足时保留透明；JPEG 边缘为黑色。建议导出后裁切。").font(.caption).foregroundStyle(.secondary)
                }
                Section { Button("导出并分享") { dismiss(); Task { try? await Task.sleep(for: .milliseconds(400)); store.export(kind) } }.frame(maxWidth: .infinity).disabled(store.busy) }
            }.navigationTitle("导出成片").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.presentationDetents([.large])
    }
}

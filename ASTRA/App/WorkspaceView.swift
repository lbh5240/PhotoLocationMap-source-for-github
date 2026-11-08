import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum ToolPanel: String, CaseIterable {
    case stack = "堆栈", light = "光影", color = "色彩", wheels = "色轮", curves = "曲线", hsl = "HSL", detail = "细节", astro = "星云"
    var symbol: String { switch self { case .stack: "square.3.layers.3d"; case .light: "sun.max"; case .color: "circle.lefthalf.filled"; case .wheels: "circle.hexagongrid.fill"; case .curves: "point.topleft.down.to.point.bottomright.curvepath"; case .hsl: "slider.horizontal.3"; case .detail: "circle.dotted"; case .astro: "sparkles.rectangle.stack" } }
}
struct WorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var panel = ToolPanel.stack
    @State private var comparing = false
    @State private var canvasOnly = false
    @State private var importing = false
    @State private var pickingPhotos = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showFrames = false
    @State private var showRegion = false
    @State private var showExport = false
    @State private var showHelp = false
    @State private var showRename = false
    @State private var name = ""
    var body: some View {
        GeometryReader { geometry in
            if let project = store.project {
                let panelHeight = min(300, max(200, geometry.size.height * 0.42))
                VStack(spacing: 9) {
                    canvasHeader(project)
                    PhotoCanvas(image: store.preview, original: store.beforePreview,
                                skyFraction: !canvasOnly && panel == .stack && project.configuration.mode == .landscape ? project.configuration.skyFraction : nil,
                                showOriginal: comparing)
                        .frame(minHeight: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(EditorStyle.line).allowsHitTesting(false))
                        .layoutPriority(1)
                    if store.busy { progressView }
                    if !canvasOnly || store.busy {
                        if !store.busy, panel == .stack, let notice = store.stackNotice, notice.projectID == project.id {
                            resultNotice(notice)
                        }
                        inspector(project).frame(height: panelHeight + (panel == .wheels ? 18 : 0))
                        toolBar
                    }
                }
                .padding(.horizontal, 12).padding(.top, 3).padding(.bottom, 5)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(EditorStyle.backdrop.ignoresSafeArea())
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
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current,
                      photoLibrary: .shared())
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            store.importPhotos(items)
        }
        .confirmationDialog(store.formatRequest?.title ?? "选择照片格式",
                            isPresented: Binding(get: { store.formatRequest != nil }, set: { if !$0 { store.formatRequest = nil } }),
                            titleVisibility: .visible, presenting: store.formatRequest) { request in
            ForEach(PhotoFormat.allCases, id: \.self) { format in
                Button(format.rawValue) { store.applyFormat(format, to: request) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("仅使用所选格式。使用 JPEG 可节省空间，使用 RAW 可保留更多调色余量。")
        }
        .sheet(isPresented: $showFrames) { FramesView() }
        .sheet(isPresented: $showRegion) { ReferenceRegionView() }
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
        if let r = p.result {
            let raw = p.frames.filter(\.included).allSatisfy { StackSelection.rawExtensions.contains(URL(fileURLWithPath: $0.fileName).pathExtension.lowercased()) }
            return "\(r.outputWidth) × \(r.outputHeight) · \(raw ? "RAW 来源 · " : "")线性 Float32"
        }
        guard let f = p.frames.first else { return "等待导入" }
        let resolution = String(format: "%.1f MP", Double(f.width*f.height)/1_000_000)
        return f.camera.isEmpty ? resolution : "\(f.camera) · \(resolution)"
    }
    private var progressView: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(EditorStyle.accent)
                Text(store.status).font(.caption.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                if store.progress > 0 { Text("\(Int(store.progress * 100))%")
                        .font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(EditorStyle.accent) }
                if store.canCancel { Button("取消", action: store.cancel).font(.caption2.weight(.medium)) }
            }
            GeometryReader { geometry in
                Capsule().fill(EditorStyle.line)
                    .overlay(alignment: .leading) {
                        Capsule().fill(EditorStyle.accent.gradient)
                            .frame(width: max(3, geometry.size.width * min(1, max(0, store.progress))))
                    }
            }.frame(height: 4).accessibilityLabel("处理进度")
                .accessibilityValue("\(Int(store.progress * 100))%")
            if store.status.contains("请保持屏幕解锁") {
                Text("保持屏幕解锁 · 完成一张即保存一张")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(EditorStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(EditorStyle.line).allowsHitTesting(false))
    }
    private func canvasHeader(_ project: AstroProject) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.result.map { "合成 · \($0.acceptedFrames) 帧" } ?? (project.frames.isEmpty ? "工作台" : "原片"))
                    .font(.caption.weight(.semibold)).foregroundStyle(EditorStyle.accent)
                Text(info(project)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if project.result == nil && project.frames.contains(where: { $0.rawPreviewUnavailable == true }) {
                    Text("NEF 原件已保存；无内嵌预览的照片将在堆栈时完整解码。")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !project.frames.isEmpty {
                canvasButton("rectangle.stack", label: "管理照片") { showFrames = true }
            }
            if store.preview != nil {
                canvasButton("square.split.2x1", label: comparing ? "查看调整后" : "对比原图", selected: comparing) { comparing.toggle() }
                canvasButton(canvasOnly ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             label: canvasOnly ? "显示编辑面板" : "只看画面", selected: canvasOnly) { canvasOnly.toggle() }
            }
        }.padding(.horizontal, 4)
    }

    private func canvasButton(_ symbol: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .foregroundStyle(selected ? EditorStyle.accent : Color.secondary)
                .background(selected ? EditorStyle.accent.opacity(0.12) : EditorStyle.surface, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private func resultNotice(_ notice: StackNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(notice.title, systemImage: notice.failed ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption.weight(.semibold)).accessibilityIdentifier("stack-result-title")
            Text(notice.detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(notice.failed ? Color.orange : EditorStyle.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(EditorStyle.surface, in: RoundedRectangle(cornerRadius: 13))
    }

    private func inspector(_ project: AstroProject) -> some View {
        VStack(spacing: 7) {
            HStack {
                Label(panel.rawValue, systemImage: panel.symbol).font(.subheadline.weight(.semibold))
                Spacer()
                if panel == .stack {
                    Button("\(project.frames.filter(\.included).count) 张已选") { showFrames = true }
                        .font(.caption2.monospacedDigit()).foregroundStyle(EditorStyle.accent).disabled(store.busy)
                } else if !store.histogram.isEmpty && panel != .curves {
                    HistogramView(values: store.histogram, height: 22).frame(width: 80)
                }
                if panel != .stack {
                    Button("恢复默认", action: store.reset).font(.caption2.weight(.medium))
                        .foregroundStyle(EditorStyle.accent).disabled(store.busy)
                        .accessibilityIdentifier("reset-adjustments")
                }
            }.padding(.horizontal, 3).frame(minHeight: 24)
            ScrollView {
                controls(project).padding(.horizontal, 2).padding(.vertical, 1).disabled(store.busy)
            }.id(panel).accessibilityIdentifier("editor-inspector")
            if panel == .stack { stackActions(project) }
        }
        .padding(10)
        .background(EditorStyle.surface.opacity(0.42), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(EditorStyle.line).allowsHitTesting(false))
    }

    private var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(ToolPanel.allCases, id: \.self) { item in
                    Button { panel = item; comparing = false } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.symbol).font(.system(size: 16, weight: .medium))
                            Text(item.rawValue).font(.caption2.weight(.medium)).lineLimit(1)
                        }
                        .frame(width: 76, height: 48)
                        .contentShape(Rectangle())
                        .foregroundStyle(panel == item ? EditorStyle.accent : Color.secondary)
                        .background(panel == item ? EditorStyle.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityAddTraits(panel == item ? .isSelected : [])
                        .accessibilityIdentifier("editor-tool-\(item)")
                }
            }.padding(6)
        }
        .astroGlass()
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-dock")
        .disabled(store.busy)
    }

    @ViewBuilder private func controls(_ p: AstroProject) -> some View {
        switch panel {
        case .stack: stackControls(p)
        case .light:
            ParameterInspector(parameters: [
                parameter("曝光", "sun.max", \.exposure, -5...5, step: 0.05, unit: "EV"),
                parameter("对比度", "circle.lefthalf.filled", \.contrast, 0.5...1.8),
                parameter("高光", "sun.horizon", \.highlights, 0...1),
                parameter("阴影", "moon", \.shadows, -1...1),
                parameter("黑场", "circle.fill", \.black, 0...0.15, step: 0.005, precision: 3)
            ], checkpoint: store.checkpoint).id(ToolPanel.light)
        case .color:
            VStack(spacing: 8) {
                Button { store.autoDevelop() } label: {
                    Label("智能显影 · 分析当前照片", systemImage: "sparkles.rectangle.stack")
                        .font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.borderedProminent).tint(EditorStyle.accent)
                    .accessibilityIdentifier("auto-develop")
                ParameterInspector(parameters: [
                    parameter("冷暖", "thermometer.medium", \.warmth, -100...100, step: 1, precision: 0),
                    parameter("色调", "drop", \.tint, -100...100, step: 1, precision: 0),
                    parameter("饱和度", "circle.hexagongrid", \.saturation, 0...2),
                    parameter("自然饱和", "sparkle", \.vibrance, -1...1)
                ], checkpoint: store.checkpoint).id(ToolPanel.color)
            }
        case .curves: CurveControls()
        case .wheels: ColorWheelsPanel()
        case .hsl: HSLControls()
        case .detail:
            VStack(alignment: .leading, spacing: 8) {
                ParameterInspector(parameters: [
                    parameter("降噪", "circle.dotted", \.noise, 0...1),
                    parameter("锐化", "triangle", \.sharpness, 0...1.5)
                ], checkpoint: store.checkpoint).id(ToolPanel.detail)
                Text("加强降噪可能损失暗星。用对比按钮检查调整前后。").font(.caption2).foregroundStyle(.secondary)
            }
        case .astro:
            VStack(alignment: .leading, spacing: 8) {
                Button { store.autoDevelop() } label: {
                    Label("智能显影 · 自适应去灰", systemImage: "sparkles")
                        .font(.caption.weight(.semibold)).foregroundStyle(EditorStyle.accent)
                        .frame(maxWidth: .infinity, minHeight: 35)
                        .background(EditorStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).accessibilityIdentifier("auto-develop")
                ParameterInspector(parameters: [
                    percentParameter("去灰强度", "moon.stars", key: \.dehazeStrength, range: 0...200, initial: 100,
                                     enabled: p.usesScreenStretch && p.adjustments.adaptiveShadowKnee != nil),
                    percentParameter("云气色彩", "drop.halffull", key: \.nebulaColorRecovery, range: 0...100, initial: 0,
                                     enabled: p.usesScreenStretch)
                ], checkpoint: store.checkpoint)
                if p.adjustments.adaptiveShadowKnee == nil {
                    Text("先点智能显影分析灰底，再调去灰强度。").font(.caption2).foregroundStyle(.secondary)
                }
                starSpikeControls(p)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(DevelopMethod.allCases) { method in
                        Button(method.title) { store.chooseDevelopMethod(method) }
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background((p.adjustments.developMethod ?? .natural) == method ? EditorStyle.accent.opacity(0.22) : EditorStyle.surface,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityIdentifier("develop-method-\(method.rawValue)")
                    }
                }
                Text((p.adjustments.developMethod ?? .natural).detail).font(.caption2).foregroundStyle(.secondary)
                if p.result != nil {
                    Text("堆栈后保留线性 Float32 主文件；预览是缩小的工作图，导出成片会从主文件重新计算。原始 NEF 不会被覆盖。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("自动 STF 预览与成片", isOn: Binding(get: { p.usesScreenStretch }, set: { value in
                    store.update({ $0.adjustments.autoSTF = value }, render: true)
                })).font(.caption.weight(.semibold)).tint(EditorStyle.accent)
                    .accessibilityIdentifier("auto-stf-toggle")
                Text("STF 默认也用于所见即所得导出；原始线性数据可另存 OpenEXR。")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("云气与背景").font(.caption2.weight(.semibold)).foregroundStyle(EditorStyle.accent)
                ParameterInspector(parameters: [
                    astroParameter("Arcsinh 拉伸", "sparkles", \.arcsinh, 0...60, step: 2, precision: 1),
                    astroParameter("Masked Stretch · 核心保护", "circle.dotted.circle", \.maskedStretch, 0...1),
                    astroParameter("背景梯度消除", "moon.stars", \.gradientRemoval, 0...1),
                    astroParameter("星云对比", "cloud", \.nebulaContrast, 0...1),
                    astroParameter("云气结构", "waveform.path", \.nebulaStructure, 0...1)
                ], checkpoint: store.checkpoint).id("astro-nebula")
                Text("天空色彩与星点").font(.caption2.weight(.semibold)).foregroundStyle(EditorStyle.accent)
                ParameterInspector(parameters: [
                    astroParameter("背景中和", "circle.lefthalf.filled", \.backgroundNeutralization, 0...1),
                    astroParameter("绿色偏色抑制", "leaf", \.greenSuppression, 0...1),
                    astroParameter("星点保护", "sparkle", \.starProtection, 0...1, neutral: 1),
                    astroParameter("星点缩小", "sparkle.magnifyingglass", \.starReduction, 0...1),
                    astroParameter("星点色彩", "circle.hexagongrid", \.starSaturation, 0...1)
                ], checkpoint: store.checkpoint).id("astro-stars")
                Text("背景中和与绿色抑制会改变真实色彩，请从低强度开始；星点缩小不做 AI 去星。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func percentParameter(_ title: String, _ symbol: String, key: WritableKeyPath<Adjustments, Double?>,
                                  range: ClosedRange<Double>, initial: Double, enabled: Bool = true) -> EditorParameter {
        let value = Binding(get: { (store.project?.adjustments[keyPath: key] ?? initial / 100) * 100 }, set: { value in
            store.update({ $0.adjustments[keyPath: key] = value / 100 }, render: true)
        })
        return EditorParameter(title: title, symbol: symbol, value: value, range: range, neutral: initial,
                               step: 5, precision: 0, unit: "%", enabled: enabled)
    }

    private func starSpikeControls(_ project: AstroProject) -> some View {
        let style = project.adjustments.starSpikeStyle ?? .off
        let density = project.adjustments.starSpikeDensity ?? .sparse
        return VStack(alignment: .leading, spacing: 7) {
            Text("星芒").font(.caption2.weight(.semibold)).foregroundStyle(EditorStyle.accent)
            starChoices(StarSpikeStyle.allCases, selected: style, id: "spike-style", title: { $0.title }) { value in
                store.checkpoint()
                store.update({ $0.adjustments.starSpikeStyle = value }, render: true)
            }
            if style != .off {
                Text("星芒密度").font(.caption2.weight(.semibold)).foregroundStyle(EditorStyle.accent)
                starChoices(StarSpikeDensity.allCases, selected: density, id: "spike-density", title: { $0.title }) { value in
                    store.checkpoint()
                    store.update({ $0.adjustments.starSpikeDensity = value }, render: true)
                }
                let strength = percentParameter("星芒强度", "sparkle", key: \.starSpikeStrength, range: 0...100, initial: 38)
                PrecisionRuler(title: strength.title, value: strength.value, range: strength.range,
                               neutral: strength.neutral, step: strength.step, precision: strength.precision,
                               unit: strength.unit, checkpoint: store.checkpoint)
            }
        }
    }

    private func starChoices<Option: RawRepresentable & Hashable>(_ options: [Option], selected: Option,
                       id: String, title: (Option) -> String, change: @escaping (Option) -> Void) -> some View
                       where Option.RawValue == String {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button { change(option) } label: {
                    Text(title(option)).font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 39)
                        .editorCard(selected: option == selected)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selected ? .isSelected : [])
                .accessibilityIdentifier("\(id)-\(option.rawValue)")
            }
        }
    }

    private func astroParameter(_ title: String, _ symbol: String, _ key: WritableKeyPath<Adjustments, Double?>,
                                _ range: ClosedRange<Double>, neutral: Double = 0,
                                step: Double = 0.01, precision: Int = 2) -> EditorParameter {
        let binding = Binding(get: { store.project?.adjustments[keyPath: key] ?? neutral }, set: { value in
            store.update({ $0.adjustments[keyPath: key] = value }, render: true)
        })
        return EditorParameter(title: title, symbol: symbol, value: binding, range: range, neutral: neutral,
                               step: step, precision: precision, unit: "")
    }

    private func parameter(_ title: String, _ symbol: String, _ key: WritableKeyPath<Adjustments, Double>,
                           _ range: ClosedRange<Double>, step: Double = 0.01, precision: Int = 2, unit: String = "") -> EditorParameter {
        let neutral = Adjustments.neutral[keyPath: key]
        let binding = Binding(get: { store.project?.adjustments[keyPath: key] ?? neutral }, set: { value in
            store.update({ $0.adjustments[keyPath: key] = value }, render: true)
        })
        return EditorParameter(title: title, symbol: symbol, value: binding, range: range, neutral: neutral,
                               step: step, precision: precision, unit: unit)
    }

    private func stackControls(_ project: AstroProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(StackMode.allCases) { mode in
                    let selected = project.configuration.mode == mode
                    Button { store.update { $0.configuration.mode = mode } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: mode.symbol).font(.system(size: 14, weight: .medium))
                            Text(mode.title).font(.caption2.weight(.medium)).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 49)
                            .foregroundStyle(selected ? EditorStyle.accent : Color.secondary)
                            .background(selected ? EditorStyle.accent.opacity(0.13) : EditorStyle.surface, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? EditorStyle.accent.opacity(0.28) : EditorStyle.line))
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(project.configuration.mode.subtitle).font(.caption2).foregroundStyle(.secondary)
            if project.configuration.mode != .trails && !project.frames.isEmpty {
                Button { showRegion = true } label: {
                    Label(project.configuration.region == nil ? "选择主图 · 框选主体" : "修改主图和主体框",
                          systemImage: "viewfinder").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered).accessibilityIdentifier("select-reference-region")
            }
            if project.configuration.mode == .sky {
                Toggle("HDR 多曝光融合", isOn: Binding(get: { project.configuration.hdrFusion == true }, set: { value in
                    store.update { $0.configuration.hdrFusion = value }
                })).font(.caption.weight(.semibold)).tint(EditorStyle.accent)
                Text("对齐后用短曝光恢复饱和核心，用长曝光保留暗部信号；需要同一目标的不同曝光。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Menu {
                Button { store.update { $0.configuration.halfResolution = false } } label: {
                    Label("原尺寸", systemImage: project.configuration.halfResolution == true ? "photo" : "checkmark")
                }
                Button { store.update { $0.configuration.halfResolution = true } } label: {
                    Label("省空间 · 宽高减半", systemImage: project.configuration.halfResolution == true ? "checkmark" : "photo")
                }
            } label: {
                Label(project.configuration.halfResolution == true ? "省空间 · 宽高减半" : "堆栈分辨率 · 原尺寸",
                      systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered)
            if project.configuration.mode == .landscape {
                PrecisionRuler(title: "天空占比", value: Binding(get: { project.configuration.skyFraction }, set: { value in
                    store.update { $0.configuration.skyFraction = value }
                }), range: 0.15...1, neutral: StackConfiguration().skyFraction)
                Text("按画面里的水平线划分天空和地景。").font(.caption2).foregroundStyle(.secondary)
            } else if project.configuration.mode == .sky {
                PrecisionRuler(title: "异常值剔除", value: Binding(get: { project.configuration.sigma }, set: { value in
                    store.update { $0.configuration.sigma = value }
                }), range: 1.5...5, neutral: StackConfiguration().sigma, step: 0.1, precision: 1, unit: "σ")
                Text("至少 5 帧启用稳健剔除，2–4 帧使用加权平均。").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("星轨模式保留星星移动的轨迹。叠加星云请选「星空对齐」。").font(.caption2).foregroundStyle(.secondary)
            }
        }.disabled(store.busy)
    }

    private func stackActions(_ project: AstroProject) -> some View {
        HStack(spacing: 8) {
            Menu { importActions } label: {
                Label("导入照片", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 27)
            }.buttonStyle(.bordered)
            Button(action: store.prepareStack) {
                Label("开始合成", systemImage: "sparkles").frame(maxWidth: .infinity, minHeight: 27)
            }.buttonStyle(.borderedProminent).tint(EditorStyle.accent).foregroundStyle(.black)
                .disabled(project.frames.filter(\.included).count < 2)
                .accessibilityIdentifier("start-stack")
        }.font(.subheadline.weight(.semibold)).disabled(store.busy)
    }

}
private struct CurveControls: View {
    private enum Point: Int, CaseIterable {
        case shadows, midtones, highlights
        var key: WritableKeyPath<Adjustments, Double> {
            switch self { case .shadows: \.curveLow; case .midtones: \.curveMid; case .highlights: \.curveHigh }
        }
        var title: String { ["暗调", "中间调", "亮调"][rawValue] }
        var input: Double { Double(rawValue + 1) / 4 }
        var range: ClosedRange<Double> { [0...0.5, 0.2...0.8, 0.5...1][rawValue] }
    }
    @EnvironmentObject private var store: AppStore
    @State private var point = Point.midtones
    @State private var draggingPoint: Point?
    @GestureState private var dragging = false

    private var adjustments: Adjustments { store.project?.adjustments ?? .neutral }
    private var binding: Binding<Double> {
        Binding(get: { adjustments[keyPath: point.key] }, set: { set(point, $0) })
    }

    var body: some View {
        VStack(spacing: 7) {
            graph.frame(height: 112)
            HStack(spacing: 6) {
                ForEach(Point.allCases, id: \.self) { item in
                    Button { point = item } label: {
                        Text(item.title).font(.caption2.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(point == item ? EditorStyle.accent : Color.secondary)
                            .background(point == item ? EditorStyle.accent.opacity(0.12) : EditorStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(point == item ? .isSelected : [])
                }
            }
            PrecisionRuler(title: point.title, value: binding, range: point.range, neutral: point.input,
                           checkpoint: store.checkpoint).id(point)
        }.disabled(store.busy)
    }

    private var graph: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 11
            let width = max(geometry.size.width - inset * 2, 1)
            let height = max(geometry.size.height - inset * 2, 1)
            Canvas { context, _ in
                func location(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: inset + x * width, y: inset + (1 - y) * height)
                }
                let histogram = store.histogram
                if histogram.count > 1 {
                    var distribution = Path()
                    distribution.move(to: location(0, 0))
                    for (i, level) in histogram.enumerated() {
                        distribution.addLine(to: location(Double(i) / Double(histogram.count - 1), level * 0.88))
                    }
                    distribution.addLine(to: location(1, 0)); distribution.closeSubpath()
                    context.fill(distribution, with: .color(EditorStyle.accent.opacity(0.11)))
                }
                var grid = Path()
                for i in 0...4 {
                    let position = Double(i) / 4
                    grid.move(to: location(position, 0)); grid.addLine(to: location(position, 1))
                    grid.move(to: location(0, position)); grid.addLine(to: location(1, position))
                }
                context.stroke(grid, with: .color(EditorStyle.line))
                let baseline = Path { path in path.move(to: location(0, 0)); path.addLine(to: location(1, 1)) }
                context.stroke(baseline, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                var curve = Path()
                curve.move(to: location(0, adjustments.black))
                for item in Point.allCases { curve.addLine(to: location(item.input, adjustments[keyPath: item.key])) }
                curve.addLine(to: location(1, 1))
                context.stroke(curve, with: .color(EditorStyle.accent), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                for item in Point.allCases {
                    let center = location(item.input, adjustments[keyPath: item.key])
                    let radius: CGFloat = item == point ? 5 : 3.5
                    let dot = Path(ellipseIn: CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
                    context.fill(dot, with: .color(item == point ? EditorStyle.accent : EditorStyle.surface))
                    context.stroke(dot, with: .color(EditorStyle.accent), lineWidth: 1.2)
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        if draggingPoint == nil {
                            let start = (gesture.startLocation.x - inset) / width
                            let nearest = Point.allCases.min { abs($0.input - start) < abs($1.input - start) } ?? .midtones
                            point = nearest
                            draggingPoint = nearest
                            store.checkpoint()
                        }
                        if let draggingPoint { set(draggingPoint, 1 - (gesture.location.y - inset) / height) }
                    })
                .onChange(of: dragging) { _, active in if !active { draggingPoint = nil } }
                .accessibilityLabel("曲线图，拖动控制点调整对应亮度")
                .accessibilityIdentifier("tone-curve-graph")
        }.background(EditorStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func set(_ point: Point, _ value: Double) {
        let clamped = min(point.range.upperBound, max(point.range.lowerBound, value))
        store.update({ $0.adjustments[keyPath: point.key] = clamped }, render: true)
    }
}

private struct HSLControls: View {
    @EnvironmentObject private var store: AppStore
    @State private var band = 0
    private let colors: [Color] = [.red, .yellow, .green, .cyan, .blue, .purple]
    private let names = ["红", "黄", "绿", "青", "蓝", "洋红"]

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                ForEach(0..<colors.count, id: \.self) { index in
                    Button { band = index } label: {
                        Circle().fill(colors[index].gradient).frame(width: 21, height: 21)
                            .padding(4)
                            .overlay(Circle().strokeBorder(band == index ? .white : .clear, lineWidth: 1.5))
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(names[index])
                        .accessibilityAddTraits(band == index ? .isSelected : [])
                }
            }
            ParameterInspector(parameters: [
                adjustment("色相", "circle.lefthalf.filled", \.hue, -40...40, step: 1, precision: 0, unit: "°"),
                adjustment("饱和度", "drop", \.saturation, -1...1),
                adjustment("明度", "sun.max", \.luminance, -1...1)
            ], tint: colors[band].opacity(0.85), checkpoint: store.checkpoint).id(band)
        }.disabled(store.busy)
    }

    private func adjustment(_ title: String, _ symbol: String, _ key: WritableKeyPath<HSLBand, Double>,
                            _ range: ClosedRange<Double>, step: Double = 0.01, precision: Int = 2, unit: String = "") -> EditorParameter {
        let index = band
        let value = Binding(get: { store.project?.adjustments.hsl[index][keyPath: key] ?? 0 }, set: { newValue in
            store.update({ $0.adjustments.hsl[index][keyPath: key] = newValue }, render: true)
        })
        return EditorParameter(title: title, symbol: symbol, value: value, range: range, neutral: 0,
                               step: step, precision: precision, unit: unit)
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
                            if f.rawPreviewUnavailable == true {
                                Text("RAW 原件已保存 · 无内嵌预览").font(.caption2).foregroundStyle(.orange)
                            }
                            if let stars = f.starCount { Text("\(stars) 星点" + (f.registrationRMS.map { String(format: " · RMS %.2f px", $0) } ?? "")).font(.caption2.monospacedDigit()).foregroundStyle(.mint) }
                            if let rejection = f.rejection { Text(rejection).font(.caption2).foregroundStyle(.orange) }
                        }
                        if f.id == store.project?.configuration.referenceFrameID {
                            Text("主图").font(.caption2.weight(.semibold)).foregroundStyle(EditorStyle.accent)
                        }
                        Toggle("参与合成", isOn: Binding(get: { store.project?.frames.first { $0.id == f.id }?.included ?? false }, set: { v in store.update { p in if let i = p.frames.firstIndex(where: { $0.id == f.id }) { p.frames[i].included = v } } })).labelsHidden().disabled(store.busy)
                    }.padding(.vertical, 4)
                        .swipeActions(edge: .leading) {
                            Button("设为主图") {
                                store.update { $0.configuration.referenceFrameID = f.id; $0.configuration.region = nil }
                            }.tint(.blue)
                        }
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
    @State private var kind = ExportKind.jpeg
    @State private var matchPreview = true
    var body: some View {
        NavigationStack {
            Form {
                Section("格式") { Picker("文件格式", selection: $kind) { ForEach(ExportKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline) }
                Section(kind == .exr ? "Float32 线性" : "全分辨率 · sRGB") {
                    if let p = store.project { Text(p.result.map { "\($0.outputWidth) × \($0.outputHeight)" } ?? p.frames.first.map { "\($0.width) × \($0.height)" } ?? "") }
                    Toggle("与屏幕预览一致（包含自动 STF）", isOn: $matchPreview)
                        .disabled(kind == .exr || store.project?.usesScreenStretch != true)
                        .accessibilityIdentifier("export-match-preview")
                    Text(kind == .exr ? "OpenEXR 保存未调色的 Float32 线性堆栈，可在电脑上继续后期。原始 NEF 保存在工程中。" :
                         "默认沿用预览的拉伸、星云和调色效果。关闭上面的开关只会跳过 STF，其它调节仍会导出。")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.project?.result == nil { Text("当前尚未堆栈，将导出第一张原片的编辑结果。").font(.caption).foregroundStyle(.orange) }
                    Text(store.project?.result?.crop != nil ? "所有导出格式沿用合成时的主体框与比例，工程仍保留完整线性主文件。" : "成片可能自动修剪对齐边缘。未框选的 OpenEXR 保留完整线性画幅。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("保存成片") {
                    Button("保存到手机相册", systemImage: "photo.badge.plus") {
                        dismiss(); Task { try? await Task.sleep(for: .milliseconds(400)); store.export(kind, to: .photos, matchPreview: matchPreview) }
                    }.disabled(store.busy || kind == .tiff || kind == .exr)
                        .accessibilityIdentifier("export-to-photos")
                    Button("导出并分享", systemImage: "square.and.arrow.up") {
                        dismiss(); Task { try? await Task.sleep(for: .milliseconds(400)); store.export(kind, matchPreview: matchPreview) }
                    }.disabled(store.busy || (kind == .exr && store.project?.result == nil))
                    if kind == .tiff || kind == .exr { Text("TIFF 和 OpenEXR 可分享到「文件」；保存到相册请选择 JPEG、HEIF 或 PNG。")
                            .font(.caption).foregroundStyle(.secondary) }
                }
            }.navigationTitle("导出成片").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.presentationDetents([.large])
    }
}

private struct ReferenceRegionView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = false
    @State private var aspect: RegionAspect = .free
    @State private var draft: StackRegion?
    @State private var gestureBase: StackRegion?
    @State private var gestureStarted = false
    @State private var moving = false
    @State private var pinchBase: StackRegion?

    private enum RegionAspect: String, CaseIterable, Identifiable {
        case free = "自由", square = "1:1", landscape43 = "4:3", landscape32 = "3:2"
        case wide = "16:9", portrait32 = "2:3", portrait916 = "9:16"
        var id: String { rawValue }
        var ratio: CGFloat? {
            switch self {
            case .free: nil
            case .square: 1
            case .landscape43: 4.0 / 3
            case .landscape32: 3.0 / 2
            case .wide: 16.0 / 9
            case .portrait32: 2.0 / 3
            case .portrait916: 9.0 / 16
            }
        }
    }

    private var selected: FrameRecord? {
        guard let project = store.project else { return nil }
        return project.frames.first { $0.id == project.configuration.referenceFrameID && $0.included }
            ?? project.frames.first(where: \.included)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let project = store.project {
                    Menu {
                        ForEach(project.frames.filter(\.included)) { frame in
                            Button(frame.name) {
                                store.update {
                                    $0.configuration.referenceFrameID = frame.id
                                    $0.configuration.region = nil
                                }
                                draft = nil
                                image = nil
                                load(frame)
                            }
                        }
                    } label: {
                        Label("主图 · \(selected?.name ?? "选择照片")", systemImage: "photo")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        if let image {
                            let ratio = min(geometry.size.width / image.size.width,
                                            geometry.size.height / image.size.height)
                            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                            let origin = CGPoint(x: (geometry.size.width - size.width) / 2,
                                                 y: (geometry.size.height - size.height) / 2)
                            Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            let selectedRegion = displayedRegion(origin: origin, size: size)
                            if let selectedRegion {
                                Rectangle().fill(.black.opacity(0.4))
                                    .mask(Rectangle().overlay(
                                        Rectangle().frame(width: selectedRegion.width, height: selectedRegion.height)
                                            .position(x: selectedRegion.midX, y: selectedRegion.midY)
                                            .blendMode(.destinationOut)))
                                Rectangle().strokeBorder(EditorStyle.accent, lineWidth: 2)
                                    .frame(width: selectedRegion.width, height: selectedRegion.height)
                                    .position(x: selectedRegion.midX, y: selectedRegion.midY)
                                    .accessibilityIdentifier("reference-region")
                            }
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .frame(width: size.width, height: size.height)
                                .accessibilityLabel("主图主体框选区域")
                                .accessibilityIdentifier("reference-selector-canvas")
                                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                .gesture(DragGesture(minimumDistance: 4)
                                    .onChanged { value in
                                        if !gestureStarted {
                                            gestureStarted = true
                                            gestureBase = store.project?.configuration.region
                                            let point = value.startLocation
                                            moving = displayedRegion(origin: .zero, size: size, region: gestureBase)?.insetBy(dx: -8, dy: -8).contains(point) == true
                                        }
                                        if moving, let base = gestureBase {
                                            draft = move(base, dx: value.translation.width / size.width,
                                                         dy: -value.translation.height / size.height)
                                        } else {
                                            draft = selection(from: value.startLocation, to: value.location, size: size)
                                        }
                                    }
                                    .onEnded { value in
                                        defer { gestureBase = nil; gestureStarted = false; moving = false; draft = nil }
                                        if let result = draft, result.width >= 0.08, result.height >= 0.08 {
                                            store.update { $0.configuration.region = result }
                                        }
                                    })
                                .simultaneousGesture(MagnifyGesture()
                                    .onChanged { value in
                                        if pinchBase == nil { pinchBase = draft ?? store.project?.configuration.region }
                                        if let base = pinchBase { draft = resized(base, width: CGFloat(base.width) * value.magnification, size: size) }
                                    }
                                    .onEnded { _ in
                                        if let draft { store.update { $0.configuration.region = draft } }
                                        pinchBase = nil; draft = nil
                                    })
                        } else if loading {
                            ProgressView("正在载入主图…")
                        } else {
                            Text("请选择一张主图").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                if let image {
                    let bounds = CGSize(width: image.size.width, height: image.size.height)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(RegionAspect.allCases) { option in
                                Button(option.rawValue) {
                                    aspect = option
                                    let current = store.project?.configuration.region ?? StackRegion(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
                                    store.update {
                                        $0.configuration.regionAspect = option.rawValue
                                        $0.configuration.region = resized(current, width: CGFloat(current.width), size: bounds)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(option == aspect ? EditorStyle.accent : .secondary)
                                .accessibilityIdentifier("region-aspect-\(option.rawValue)")
                            }
                        }.padding(.horizontal)
                    }
                    .accessibilityIdentifier("region-ratios")
                    HStack {
                        Text("框选大小")
                        Slider(value: Binding(get: {
                            store.project?.configuration.region?.width ?? 0.6
                        }, set: { value in
                            let current = store.project?.configuration.region ?? StackRegion(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
                            store.update { $0.configuration.region = resized(current, width: CGFloat(value), size: bounds) }
                        }), in: 0.1...0.95)
                        .accessibilityIdentifier("region-size-slider")
                    }.padding(.horizontal)
                }
                Text("主体框决定下次合成的预览和导出画幅。拖框内移动，双指或滑杆等比缩放。请留至少 8 颗清晰星星。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                HStack {
                    Button("使用整张主图") { draft = nil; store.update { $0.configuration.region = nil } }
                    Spacer()
                    Button("完成") {
                        if store.project?.configuration.region != nil, let selected {
                            store.update { $0.configuration.referenceFrameID = selected.id }
                        }
                        store.flushSave()
                        dismiss()
                    }.buttonStyle(.borderedProminent)
                }.padding()
            }
            .background(EditorStyle.backdrop)
            .navigationTitle("选择主图与主体")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                aspect = RegionAspect(rawValue: store.project?.configuration.regionAspect ?? "") ?? .free
                if let selected { load(selected) }
            }
        }
    }

    private func displayedRegion(origin: CGPoint, size: CGSize) -> CGRect? {
        displayedRegion(origin: origin, size: size, region: draft ?? store.project?.configuration.region)
    }

    private func displayedRegion(origin: CGPoint, size: CGSize, region: StackRegion?) -> CGRect? {
        guard let region else { return nil }
        return CGRect(x: origin.x + CGFloat(region.x) * size.width,
                      y: origin.y + CGFloat(1 - region.y - region.height) * size.height,
                      width: CGFloat(region.width) * size.width, height: CGFloat(region.height) * size.height)
    }

    private func move(_ region: StackRegion, dx: CGFloat, dy: CGFloat) -> StackRegion {
        StackRegion(x: min(1-region.width, max(0, region.x+Double(dx))),
                    y: min(1-region.height, max(0, region.y+Double(dy))),
                    width: region.width, height: region.height)
    }

    private func resized(_ region: StackRegion, width: CGFloat, size: CGSize) -> StackRegion {
        let ratio = aspect.ratio ?? CGFloat(region.width) * size.width / max(0.001, CGFloat(region.height) * size.height)
        let w = min(min(0.98, max(0.08, width)), 0.98 * ratio * size.height / size.width)
        let h = w * size.width / size.height / ratio
        let cx = CGFloat(region.x + region.width/2), cy = CGFloat(region.y + region.height/2)
        return StackRegion(x: Double(min(1-w, max(0,cx-w/2))), y: Double(min(1-h,max(0,cy-h/2))),
                           width: Double(w), height: Double(h))
    }

    private func selection(from start: CGPoint, to end: CGPoint, size: CGSize) -> StackRegion? {
        let x = min(max(0,start.x),size.width), y = min(max(0,start.y),size.height)
        let ex = min(max(0,end.x),size.width), ey = min(max(0,end.y),size.height)
        var w = abs(ex-x), h = abs(ey-y)
        if let ratio = aspect.ratio {
            w = min(w, h*ratio)
            h = w/ratio
        }
        guard w >= size.width*0.08, h >= size.height*0.08 else { return nil }
        let left = min(max(0, (ex >= x ? x : x-w)), size.width-w)
        let top = min(max(0, (ey >= y ? y : y-h)), size.height-h)
        return StackRegion(x: Double(left/size.width), y: Double(1-(top+h)/size.height),
                           width: Double(w/size.width), height: Double(h/size.height))
    }

    private func load(_ frame: FrameRecord) {
        guard let project = store.project else { return }
        loading = true
        Task {
            do {
                let source = try await Task.detached {
                    let repository = try ProjectRepository()
                    let pipeline = ImagePipeline()
                    let decoded = try pipeline.decode(repository.url(project, frame.fileName))
                    let rendered = try pipeline.preview(image: decoded, adjustments: .neutral, maxSide: 1600)
                    return UIImage(cgImage: rendered)
                }.value
                guard selected?.id == frame.id else { return }
                image = source
            } catch { store.message = "主图预览失败：\(error.localizedDescription)" }
            loading = false
        }
    }
}

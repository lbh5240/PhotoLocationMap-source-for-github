import SwiftUI
import ZoraCore

struct CameraView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var showFiles = false
    @State private var showTools = false
    @AppStorage("monitorGrid") private var grid = true
    @AppStorage("monitorPeaking") private var peaking = false
    @AppStorage("monitorZebra") private var zebra = false
    @State private var zoom: CGFloat = 1
    @State private var focusPoint: CGPoint?
    @State private var focusSteps = 100
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if model.device != nil { statusRow }
                    viewfinder
                    if let preview = model.preview, model.streaming {
                        HistogramView(bins: preview.histogram).frame(height: 44)
                            .overlay(alignment: .topTrailing) {
                                Text("高亮 \(preview.clippedFraction * 100, specifier: "%.1f")%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).padding(6)
                            }
                            .padding(10).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                    }
                    controlDeck
                    if let status = model.sequenceStatus {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(status).font(.subheadline.monospacedDigit()).lineLimit(2)
                            Spacer()
                            Button("停止", role: .destructive) { model.cancelOperation() }.buttonStyle(.bordered)
                        }.zoraPanel()
                    }
                    if let name = model.transferName {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("正在导入 \(name)", systemImage: "arrow.down.circle").font(.caption)
                            ProgressView(value: model.transferFraction ?? 0).tint(Color.zoraAmber)
                        }.zoraPanel()
                    }
                    HStack(spacing: 12) {
                        ActionTile(title: "拍摄工具", systemImage: "timer", subtitle: "延时 · 间隔 · 包围") { showTools = true }
                            .disabled(model.device?.canCapture != true || model.busy).opacity(model.device?.canCapture == true ? 1 : 0.45)
                        ActionTile(title: "存储卡", systemImage: "sdcard", subtitle: model.autoImport ? "自动导入已开启" : "浏览与导入") { showFiles = true }
                            .disabled(model.device == nil || model.busy).opacity(model.device == nil ? 0.45 : 1)
                    }
                    if model.device == nil { onboarding } else {
                        if !model.properties.isEmpty { exposureCard }
                        lensCard
                    }
                    Text("功能随相机声明的能力开放；Z7 II 真机兼容性仍在验证。")
                        .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }.zoraPage().toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $connecting) { ConnectionView() }
                .sheet(isPresented: $showFiles) { CameraFilesView() }
                .sheet(isPresented: $showTools) { ShootingToolsView().presentationDetents([.medium, .large]) }
                .onChange(of: model.streaming) { _, live in if !live { zoom = 1; focusPoint = nil } }
        }
    }

    // MARK: Sections
    private var header: some View {
        HStack(spacing: 12) {
            ZoraMark(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("ZORA").font(.system(size: 24, weight: .black, design: .rounded)).tracking(4)
                Text("把目光，留给此刻。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { connecting = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(model.device == nil ? Color.secondary : Color.zoraOK).frame(width: 8, height: 8)
                    Text(model.device?.model ?? "连接相机").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10).glassEffect(.regular.interactive(), in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("connectCamera")
        }
    }
    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusPill(text: model.connectionType ?? "相机", systemImage: model.connectionType == "USB" ? "cable.connector" : "wifi", color: .zoraOK)
                if let battery = model.properties.first(where: { $0.code == 0x5001 })?.current ?? model.connectivity.bluetooth.battery.map({ Int64($0) }) {
                    StatusPill(text: "\(battery)%", systemImage: battery <= 20 ? "battery.25percent" : "battery.75percent", color: battery <= 20 ? .zoraLive : .secondary)
                }
                if let storage = model.storages.first {
                    StatusPill(text: "剩余 " + ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.freeBytes), countStyle: .file), systemImage: "sdcard", color: .secondary)
                }
                if model.autoImport { StatusPill(text: "自动导入 \(model.autoImportedCount)", systemImage: "arrow.down.circle", color: .zoraAmber) }
                if model.remoteControl { StatusPill(text: "已接管", systemImage: "hand.raised", color: .zoraAmber) }
                if model.recordingRequested { StatusPill(text: "录像中", color: .zoraLive) }
            }
        }
    }
    private var viewfinder: some View {
        ZStack {
            Color.black
            if let preview = model.preview, model.streaming, let image = UIImage(data: preview.jpeg) {
                LiveViewSurface(image: image, preview: preview, peaking: peaking, zebra: zebra, grid: grid, zoom: zoom, focusPoint: $focusPoint)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "viewfinder").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(LinearGradient.zoraAccent)
                    Text(model.device == nil ? "等待你的 Nikon Z7 II" : "准备开始实时取景").font(.headline)
                    Text(model.device == nil ? "连接后，这里显示相机返回的真实画面" : "点下方 ▶ 开始取景").font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
        }
        .aspectRatio(3/2, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if model.streaming {
                HStack(spacing: 6) { Circle().fill(Color.zoraLive).frame(width: 7, height: 7); Text("LIVE").font(.caption2.weight(.bold)) }
                    .padding(.horizontal, 9).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule()).padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.streaming {
                VStack(spacing: 8) {
                    overlayToggle("grid", label: "网格", isOn: grid) { grid.toggle() }
                    overlayToggle("waveform.path", label: "峰值对焦", isOn: peaking) { peaking.toggle() }
                    overlayToggle("line.3.horizontal", label: "斑马纹", isOn: zebra) { zebra.toggle() }
                    overlayToggle(zoom >= 4 ? "minus.magnifyingglass" : "plus.magnifyingglass", label: "放大检查对焦", isOn: zoom > 1) { zoom = zoom >= 4 ? 1 : zoom * 2 }
                }.padding(10)
            }
        }
        .overlay(alignment: .bottom) { ExposureStrip() }
        .overlay(alignment: .bottomLeading) {
            if model.streaming, model.device?.canChangeAFArea == true {
                Text(model.canTouchFocus ? "轻点对焦" : "对焦坐标未校验").font(.caption2).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.45), in: Capsule()).padding(.leading, 10).padding(.bottom, 44)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.08)))
    }
    private func overlayToggle(_ icon: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                .foregroundStyle(isOn ? Color.black : Color.white)
                .background(isOn ? AnyShapeStyle(LinearGradient.zoraAccent) : AnyShapeStyle(Color.black.opacity(0.5)), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(isOn ? .isSelected : [])
    }
    private var controlDeck: some View {
        HStack {
            deckButton(icon: "scope", label: "自动对焦", enabled: model.device?.operations.contains(PTPOperation.autoFocus) == true) {
                model.perform { await model.stopStream(); try await model.camera.autoFocus() }
            }
            Spacer()
            Button { model.perform { try await model.capture() } } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.75), lineWidth: 3).frame(width: 82, height: 82)
                    Circle().fill(LinearGradient.zoraAccent).frame(width: 66, height: 66)
                        .shadow(color: .zoraAmber.opacity(0.45), radius: 14)
                }
            }.buttonStyle(.plain).disabled(model.device?.canCapture != true || model.busy)
                .opacity(model.device?.canCapture == true ? 1 : 0.4).accessibilityLabel("释放快门")
            Spacer()
            deckButton(icon: model.streaming ? "stop.fill" : "play.fill", label: model.streaming ? "停止取景" : "开始取景", enabled: model.device?.canLiveView == true) {
                model.perform { if model.streaming { await model.stopStream() } else { try await model.startStream() } }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
    }
    private func deckButton(icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.title3.weight(.semibold)).frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.08), in: Circle())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).disabled(!enabled || model.busy).opacity(enabled ? 1 : 0.4).accessibilityLabel(label)
    }
    private var onboarding: some View {
        ZoraCard(title: "开始连接", systemImage: "link") {
            VStack(alignment: .leading, spacing: 12) {
                step(1, "在相机菜单开启“连接至智能设备”，并关闭 SnapBridge")
                step(2, "点右上角“连接相机”，用蓝牙配对或 USB 数据线连接")
                step(3, "首次保存相机热点，之后可一键唤醒并连接")
                Button { connecting = true } label: {
                    Text("连接我的相机").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(LinearGradient.zoraAccent, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).padding(.top, 4)
            }
        }
    }
    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.black).frame(width: 22, height: 22).background(Color.zoraAmber, in: Circle())
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var exposureCard: some View {
        ZoraCard(title: "曝光与色彩", systemImage: "camera.aperture") {
            Button { model.perform { await model.stopStream(); model.properties = try await model.camera.properties() } } label: {
                Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold))
            }.disabled(model.busy).accessibilityLabel("刷新相机设置")
        } content: {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(model.properties) { property in PropertyTile(property: property) }
            }
            Text("带锁的项由当前拍摄模式决定，例如 A 档下快门由相机计算。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var lensCard: some View {
        if let device = model.device, device.operations.contains(PTPOperation.remoteControl) || device.canRecordMovie
            || device.operations.contains(PTPOperation.manualFocus) || device.operations.contains(PTPOperation.terminateCapture) {
            ZoraCard(title: "对焦 · 录像 · 控制", systemImage: "slider.horizontal.below.rectangle") {
                VStack(alignment: .leading, spacing: 14) {
                    if device.operations.contains(PTPOperation.manualFocus) {
                        VStack(alignment: .leading, spacing: 8) {
                            Stepper("手动调焦步长 \(focusSteps)", value: $focusSteps, in: 1...1000, step: 10).font(.subheadline)
                            HStack(spacing: 10) {
                                Button { model.perform { try await model.driveFocus(near: true, steps: UInt32(focusSteps)) } } label: {
                                    Label("向近", systemImage: "chevron.left.2").frame(maxWidth: .infinity)
                                }
                                Button { model.perform { try await model.driveFocus(near: false, steps: UInt32(focusSteps)) } } label: {
                                    Label("向远", systemImage: "chevron.right.2").frame(maxWidth: .infinity)
                                }
                            }.buttonStyle(.bordered).disabled(model.busy)
                        }
                    }
                    if device.canRecordMovie {
                        HStack(spacing: 10) {
                            Button { model.perform { try await model.setMovieRecording(true) } } label: { Label("开始录像", systemImage: "record.circle").frame(maxWidth: .infinity) }
                                .tint(.zoraLive)
                            Button { model.perform { try await model.setMovieRecording(false) } } label: { Label("结束录像", systemImage: "stop.circle").frame(maxWidth: .infinity) }
                        }.buttonStyle(.bordered).disabled(model.busy)
                        Text(model.recordingRequested ? "相机已接受开始录像，请以机身指示为准" : "先在相机上切换到视频模式").font(.caption2).foregroundStyle(.secondary)
                    }
                    if device.operations.contains(PTPOperation.remoteControl) {
                        Toggle(isOn: Binding(get: { model.remoteControl }, set: { value in model.perform { try await model.setRemoteControl(value) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("接管相机控制").font(.subheadline)
                                Text("取景被拒时可开启；结束后关闭以恢复机身操作").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.disabled(model.busy)
                    }
                    if device.operations.contains(PTPOperation.terminateCapture) {
                        Button(role: .destructive) { model.perform { await model.stopStream(); try await model.camera.terminateCapture() } } label: {
                            Label("终止连拍 / 长曝光", systemImage: "stop.hand").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(model.busy)
                    }
                }
            }
        }
    }
}

/// Live image with overlays, local magnification and tap-to-focus. Tap coordinates are
/// normalized to the displayed JPEG; the model maps them to validated sensor coordinates.
private struct LiveViewSurface: View {
    @Environment(AppModel.self) private var model
    let image: UIImage
    let preview: ProcessedPreview
    let peaking: Bool, zebra: Bool, grid: Bool
    let zoom: CGFloat
    @Binding var focusPoint: CGPoint?
    var body: some View {
        GeometryReader { proxy in
            let rect = fitted(image.size, in: proxy.size)
            let anchor = CGPoint(x: rect.minX + (focusPoint?.x ?? 0.5) * rect.width, y: rect.minY + (focusPoint?.y ?? 0.5) * rect.height)
            ZStack {
                ZStack {
                    Image(uiImage: image).resizable()
                    if peaking, let data = preview.peakingPNG, let overlay = UIImage(data: data) { Image(uiImage: overlay).resizable() }
                    if zebra, let data = preview.zebraPNG, let overlay = UIImage(data: data) { Image(uiImage: overlay).resizable() }
                    if grid { GridOverlay() }
                }
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                .scaleEffect(zoom, anchor: UnitPoint(x: anchor.x / max(proxy.size.width, 1), y: anchor.y / max(proxy.size.height, 1)))
                if let point = focusPoint, zoom == 1 {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.zoraAmber, lineWidth: 1.5).frame(width: 56, height: 56)
                        .position(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                // Undo the magnification about `anchor` to find the tapped image point.
                let x = anchor.x + (location.x - anchor.x) / zoom, y = anchor.y + (location.y - anchor.y) / zoom
                guard rect.contains(CGPoint(x: x, y: y)) else { return }
                let point = CGPoint(x: (x - rect.minX) / rect.width, y: (y - rect.minY) / rect.height)
                focusPoint = point
                if model.canTouchFocus, !model.busy { model.perform { try await model.touchFocus(x: Double(point.x), y: Double(point.y)) } }
            }
        }.clipped()
    }
    private func fitted(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

/// Viewfinder-style summary of the values the camera actually reported, overlaid on the image.
private struct ExposureStrip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let shutterCode: UInt16 = model.properties.contains(where: { $0.code == 0xD100 }) ? 0xD100 : 0x500D
        let codes: [UInt16] = [0x500e, shutterCode, 0x5007, 0x500F, 0x5010]
        let items = codes.compactMap { code in model.properties.first { $0.code == code } }
        if !items.isEmpty {
            HStack(spacing: 0) {
                ForEach(items) { property in
                    Text(property.currentLabel).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(property.code == 0x500e ? Color.zoraAmber : .white)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 6)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .accessibilityElement(children: .combine).accessibilityLabel("相机当前曝光参数")
        }
    }
}

private struct GridOverlay: View {
    var body: some View { Canvas { context, size in
        var p = Path()
        for n in 1...2 {
            let x = size.width*CGFloat(n)/3, y = size.height*CGFloat(n)/3
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
    }.allowsHitTesting(false) }
}

struct HistogramView: View {
    let bins: [Int]
    var body: some View { Canvas { context, size in
        let maximum = max(1, bins.max() ?? 1)
        var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
        for (i, count) in bins.enumerated() {
            path.addLine(to: CGPoint(x: CGFloat(i)*size.width/255, y: size.height*(1-CGFloat(count)/CGFloat(maximum))))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
        context.fill(path, with: .linearGradient(Gradient(colors: [.zoraAmber.opacity(0.9), .zoraAmberDeep.opacity(0.35)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }.accessibilityLabel("图像亮度直方图") }
}

/// One camera setting as a tile: title, current value, and a menu of camera-declared values.
private struct PropertyTile: View {
    @Environment(AppModel.self) private var model
    let property: CameraProperty
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(property.title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !property.writable { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary) }
            }
            if property.writable && !property.options.isEmpty {
                Menu {
                    ForEach(property.options, id: \.self) { value in
                        Button { model.perform { try await model.set(property, value: value) } } label: {
                            if value == property.current { Label(property.label(for: value), systemImage: "checkmark") } else { Text(property.label(for: value)) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(property.currentLabel).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }.tint(.primary).disabled(model.busy)
            } else if property.writable {
                HStack(spacing: 6) {
                    TextField(property.currentLabel, text: $text).keyboardType(.numbersAndPunctuation).font(.callout.monospacedDigit())
                    Button("设置") {
                        guard let value = Int64(text) else { model.error = "请输入相机原始整数参数"; return }
                        model.perform { try await model.set(property, value: value) }
                    }.font(.caption.weight(.semibold)).disabled(model.busy)
                }
            } else {
                Text(property.currentLabel).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }
}

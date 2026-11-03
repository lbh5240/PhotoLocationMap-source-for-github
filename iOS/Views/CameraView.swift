import SwiftUI
import ZoraCore

struct CameraView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var showFiles = false
    @State private var showTools = false
    @State private var grid = true
    @State private var peaking = false
    @State private var zebra = false
    @State private var zoom: CGFloat = 1
    @State private var focusPoint: CGPoint?
    @State private var focusSteps = 100
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ZORA").font(.system(size: 28, weight: .black, design: .rounded)).tracking(5)
                            Text("把目光，留给此刻。").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { connecting = true } label: {
                            Label(model.device == nil ? "连接相机" : model.device!.model, systemImage: model.device == nil ? "wifi.slash" : (model.connectionType == "USB" ? "cable.connector" : "wifi"))
                                .font(.caption.weight(.medium)).padding(12).zoraGlass()
                        }.accessibilityIdentifier("connectCamera")
                    }
                    VStack(spacing: 0) {
                        ZStack {
                            Color.black
                            if let preview = model.preview, model.streaming, let image = UIImage(data: preview.jpeg) {
                                LiveViewSurface(image: image, preview: preview, peaking: peaking, zebra: zebra, grid: grid, zoom: zoom, focusPoint: $focusPoint)
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "viewfinder").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(Color.zoraAmber)
                                    Text(model.device == nil ? "等待你的 Nikon Z7 II" : "准备开始实时取景").font(.headline)
                                    Text("画面仅在相机返回真实图像后显示").font(.caption).foregroundStyle(.secondary)
                                }.padding()
                            }
                        }.aspectRatio(3/2, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 22))
                        HStack {
                            Label(model.streaming ? "LIVE · 相机画面" : "STANDBY", systemImage: model.streaming ? "circle.fill" : "circle")
                                .foregroundStyle(model.streaming ? Color.zoraAmber : .secondary)
                            Spacer()
                            if model.streaming {
                                Text(model.canTouchFocus ? "轻点画面对焦" : (model.device?.canChangeAFArea == true ? "对焦坐标未校验" : "")).foregroundStyle(.secondary)
                            }
                            Text("\((model.device?.model ?? "NIKON Z7 II").uppercased()) · 实验驱动").foregroundStyle(.secondary)
                        }.font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.top, 10)
                    }
                    ExposureStrip()
                    HStack(spacing: 10) {
                        monitorButton("网格", icon: "grid", enabled: $grid)
                        monitorButton("峰值", icon: "waveform.path", enabled: $peaking)
                        monitorButton("斑马纹", icon: "line.3.horizontal", enabled: $zebra)
                        Button { zoom = zoom >= 4 ? 1 : zoom * 2 } label: {
                            Label(zoom == 1 ? "放大" : "\(Int(zoom))×", systemImage: "plus.magnifyingglass").font(.caption)
                                .foregroundStyle(zoom > 1 ? Color.zoraAmber : .secondary).padding(12).frame(maxWidth: .infinity)
                        }.zoraGlass().disabled(!model.streaming).accessibilityLabel("放大检查对焦")
                    }
                    if let preview = model.preview, model.streaming {
                        VStack(alignment: .leading, spacing: 8) {
                            HistogramView(bins: preview.histogram).frame(height: 52)
                            Text("预览直方图 · 高亮像素 \(preview.clippedFraction*100, specifier: "%.1f")% · 监看基于显示图像")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.zoraPanel()
                    }
                    HStack(spacing: 32) {
                        Button { model.perform { await model.stopStream(); try await model.camera.autoFocus() } } label: { Image(systemName: "scope").font(.title2) }
                            .disabled(model.device?.operations.contains(PTPOperation.autoFocus) != true || model.busy).accessibilityLabel("自动对焦")
                        Button { model.perform { try await model.capture() } } label: {
                            Circle().fill(Color.zoraAmber).frame(width: 68, height: 68)
                                .padding(6).overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 2))
                        }.disabled(model.device?.canCapture != true || model.busy).accessibilityLabel("释放快门")
                        Button { model.perform { if model.streaming { await model.stopStream() } else { try await model.startStream() } } } label: {
                            Image(systemName: model.streaming ? "stop.circle" : "play.circle").font(.title)
                        }.disabled(model.device?.canLiveView != true || model.busy).accessibilityLabel(model.streaming ? "停止取景" : "开始取景")
                    }.padding(14).frame(maxWidth: .infinity).zoraGlass()
                    if let status = model.sequenceStatus {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(status).font(.caption.monospacedDigit())
                            Spacer()
                            Button("停止", role: .destructive) { model.cancelOperation() }
                        }.zoraPanel()
                    }
                    if let name = model.transferName {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("正在导入 \(name)").font(.caption)
                            ProgressView(value: model.transferFraction ?? 0)
                        }.zoraPanel()
                    }
                    HStack(spacing: 12) {
                        Button("拍摄工具", systemImage: "timer") { showTools = true }
                            .disabled(model.device?.canCapture != true || model.busy)
                        Spacer()
                        Button("相机存储卡", systemImage: "sdcard") { showFiles = true }
                            .disabled(model.device == nil || model.busy)
                    }
                    if let device = model.device {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("\(model.connectionType ?? "相机") · 扩展控制", systemImage: model.connectionType == "USB" ? "cable.connector" : "wifi").font(.headline)
                            if device.operations.contains(PTPOperation.remoteControl) {
                                Button(model.remoteControl ? "释放相机控制" : "接管相机控制") { model.perform { try await model.setRemoteControl(!model.remoteControl) } }.disabled(model.busy)
                                Text("USB 取景若被相机拒绝，可先接管控制；结束后释放，恢复机身操作。") .font(.caption).foregroundStyle(.secondary)
                            }
                            if device.canRecordMovie {
                                HStack {
                                    Button("开始录像", systemImage: "record.circle") { model.perform { try await model.setMovieRecording(true) } }
                                    Spacer()
                                    Button("结束录像", systemImage: "stop.circle") { model.perform { try await model.setMovieRecording(false) } }
                                }.disabled(model.busy)
                                Text(model.recordingRequested ? "开始录像指令已被接受，请以相机指示确认录制" : "请先在相机上选择视频模式，再发送录像指令") .font(.caption).foregroundStyle(.secondary)
                            }
                            if device.operations.contains(PTPOperation.manualFocus) {
                                Stepper("调焦步长 \(focusSteps)", value: $focusSteps, in: 1...1000, step: 10)
                                HStack {
                                    Button("焦点向近", systemImage: "arrow.down.right.and.arrow.up.left") { model.perform { try await model.driveFocus(near: true, steps: UInt32(focusSteps)) } }
                                    Spacer()
                                    Button("焦点向远", systemImage: "arrow.up.left.and.arrow.down.right") { model.perform { try await model.driveFocus(near: false, steps: UInt32(focusSteps)) } }
                                }.disabled(model.busy)
                                Text("相对镜头驱动；步长与距离关系取决于镜头。操作期间会暂停图传。") .font(.caption).foregroundStyle(.secondary)
                            }
                            if device.operations.contains(PTPOperation.terminateCapture) {
                                Button("终止连拍 / 长曝光", systemImage: "stop.hand") { model.perform { await model.stopStream(); try await model.camera.terminateCapture() } }.disabled(model.busy)
                            }
                        }.zoraPanel()
                    }
                    if !model.properties.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("曝光与色彩").font(.headline)
                                Spacer()
                                Button("刷新", systemImage: "arrow.clockwise") { model.perform { await model.stopStream(); model.properties = try await model.camera.properties() } }
                                    .font(.caption).disabled(model.busy)
                            }
                            ForEach(model.properties) { property in PropertyRow(property: property) }
                            Text("只读项多由当前拍摄模式决定，例如 A 档下快门由相机计算。") .font(.caption2).foregroundStyle(.secondary)
                        }.zoraPanel()
                    }
                    if let progress = model.connectionProgress { Label(progress, systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(Color.zoraAmber) }
                    if model.connectivity.bluetooth.authenticated {
                        HStack {
                            Label("蓝牙已认证", systemImage: "checkmark.shield")
                            Spacer()
                            if let battery = model.connectivity.bluetooth.battery { Label("\(battery)%", systemImage: "battery.100percent") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if model.autoImport && model.device != nil {
                        Label("自动导入已开启 · 本次连接已导入 \(model.autoImportedCount) 张", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("连接、曝光、对焦与取景的可用性取决于固件和相机能力。蓝牙认证与 Wi-Fi 唤醒已接入真实协议，Z7 II 真机兼容性待验证。")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(20)
            }.background(Color.zoraBackground).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $connecting) { ConnectionView() }
                .sheet(isPresented: $showFiles) { CameraFilesView() }
                .sheet(isPresented: $showTools) { ShootingToolsView() }
                .onChange(of: model.streaming) { _, live in if !live { zoom = 1; focusPoint = nil } }
        }
    }
    private func monitorButton(_ title: String, icon: String, enabled: Binding<Bool>) -> some View {
        Button { enabled.wrappedValue.toggle() } label: {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(enabled.wrappedValue ? Color.zoraAmber : .secondary).padding(12).frame(maxWidth: .infinity)
        }.zoraGlass().accessibilityAddTraits(enabled.wrappedValue ? .isSelected : [])
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
                    RoundedRectangle(cornerRadius: 4).stroke(Color.zoraAmber, lineWidth: 1.5).frame(width: 54, height: 54)
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

/// Viewfinder-style summary of the values the camera actually reported.
private struct ExposureStrip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let codes: [UInt16] = [0x500e, model.properties.contains(where: { $0.code == 0xD100 }) ? 0xD100 : 0x500D, 0x5007, 0x500F, 0x5010, 0x5001]
        let items = codes.compactMap { code in model.properties.first { $0.code == code } }
        if !items.isEmpty {
            HStack(spacing: 0) {
                ForEach(items) { property in
                    Text(property.currentLabel).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(property.code == 0x5001 && property.current <= 20 ? Color.red : .primary)
                        .frame(maxWidth: .infinity)
                }
            }.padding(.vertical, 10).zoraGlass().accessibilityElement(children: .combine).accessibilityLabel("相机当前曝光参数")
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
        context.fill(path, with: .color(.zoraAmber.opacity(0.8)))
    }.accessibilityLabel("图像亮度直方图") }
}

private struct PropertyRow: View {
    @Environment(AppModel.self) private var model
    let property: CameraProperty
    @State private var text = ""
    var body: some View {
        HStack {
            Text(property.title).font(.caption)
            Spacer()
            if property.writable && !property.options.isEmpty {
                Menu {
                    ForEach(property.options, id: \.self) { value in
                        Button { model.perform { try await model.set(property, value: value) } } label: {
                            if value == property.current { Label(property.label(for: value), systemImage: "checkmark") } else { Text(property.label(for: value)) }
                        }
                    }
                } label: { Text(property.currentLabel).monospacedDigit() }.disabled(model.busy)
            } else if property.writable {
                TextField(property.currentLabel, text: $text).multilineTextAlignment(.trailing).frame(width: 90).keyboardType(.numbersAndPunctuation)
                Button("设置") {
                    guard let value = Int64(text) else { model.error = "请输入相机原始整数参数"; return }
                    model.perform { try await model.set(property, value: value) }
                }.disabled(model.busy)
            } else {
                Label(property.currentLabel, systemImage: "lock").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

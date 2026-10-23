import SwiftUI
import ZoraCore

struct CameraView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var showFiles = false
    @State private var grid = true
    @State private var peaking = false
    @State private var zebra = false
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
                            Label(model.device == nil ? "连接相机" : model.device!.model, systemImage: model.device == nil ? "wifi.slash" : "wifi")
                                .font(.caption.weight(.medium)).padding(12).zoraGlass()
                        }.accessibilityIdentifier("connectCamera")
                    }
                    VStack(spacing: 0) {
                        ZStack {
                            Color.black
                            if let preview = model.preview, model.streaming, let image = UIImage(data: preview.jpeg) {
                                Image(uiImage: image).resizable().scaledToFit()
                                if peaking, let data = preview.peakingPNG, let overlay = UIImage(data: data) { Image(uiImage: overlay).resizable().scaledToFit() }
                                if zebra, let data = preview.zebraPNG, let overlay = UIImage(data: data) { Image(uiImage: overlay).resizable().scaledToFit() }
                                if grid { GridOverlay() }
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
                            Text("NIKON Z7 II · 实验驱动").foregroundStyle(.secondary)
                        }.font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.top, 10)
                    }
                    HStack(spacing: 14) {
                        monitorButton("网格", icon: "grid", enabled: $grid)
                        monitorButton("峰值", icon: "waveform.path", enabled: $peaking)
                        monitorButton("斑马纹", icon: "line.3.horizontal", enabled: $zebra)
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
                        }.disabled(model.device?.operations.contains(PTPOperation.capture) != true || model.busy).accessibilityLabel("释放快门")
                        Button { model.perform { if model.streaming { await model.stopStream() } else { try await model.startStream() } } } label: {
                            Image(systemName: model.streaming ? "stop.circle" : "play.circle").font(.title)
                        }.disabled(model.device?.canLiveView != true || model.busy).accessibilityLabel(model.streaming ? "停止取景" : "开始取景")
                    }.padding(14).frame(maxWidth: .infinity).zoraGlass()
                    if !model.properties.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("曝光与色彩").font(.headline)
                            ForEach(model.properties) { property in PropertyRow(property: property) }
                        }.zoraPanel()
                    }
                    Button("浏览相机存储卡", systemImage: "sdcard") { showFiles = true }
                        .disabled(model.device == nil || model.busy)
                    if let progress = model.connectionProgress { Label(progress, systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(Color.zoraAmber) }
                    if model.connectivity.bluetooth.authenticated {
                        HStack {
                            Label("蓝牙已认证", systemImage: "checkmark.shield")
                            Spacer()
                            if let battery = model.connectivity.bluetooth.battery { Label("\(battery)%", systemImage: "battery.100percent") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Text("连接、曝光、对焦与取景的可用性取决于固件和相机能力。蓝牙认证与 Wi-Fi 唤醒已接入真实协议，Z7 II 真机兼容性待验证。")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(20)
            }.background(Color.zoraBackground).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $connecting) { ConnectionView() }
                .sheet(isPresented: $showFiles) { CameraFilesView() }
        }
    }
    private func monitorButton(_ title: String, icon: String, enabled: Binding<Bool>) -> some View {
        Button { enabled.wrappedValue.toggle() } label: {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(enabled.wrappedValue ? Color.zoraAmber : .secondary).padding(12).frame(maxWidth: .infinity)
        }.zoraGlass().accessibilityAddTraits(enabled.wrappedValue ? .isSelected : [])
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
            if !property.allowed.isEmpty && property.writable {
                Menu("\(property.current)") {
                    ForEach(property.allowed, id: \.self) { value in Button("\(value)") { model.perform { try await model.set(property, value: value) } } }
                }
            } else {
                TextField("\(property.current)", text: $text).multilineTextAlignment(.trailing).frame(width: 90).keyboardType(.numbersAndPunctuation)
                Button("设置") {
                    guard let value = Int64(text) else { model.error = "请输入整数参数"; return }
                    model.perform { try await model.set(property, value: value) }
                }.disabled(!property.writable || model.busy)
            }
        }
    }
}

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cameraHost") private var host = "192.168.1.1"
    @State private var ssid = ""
    @State private var password = ""
    var body: some View {
        @Bindable var bluetooth = model.connectivity.bluetooth
        @Bindable var settings = model
        NavigationStack {
            Form {
                Section("1 · 蓝牙配对与唤醒") {
                    Text("首次连接：在 Z7 II 中开启“连接至智能设备 → 配对（蓝牙）”，再扫描并选择相机。按系统和相机提示确认配对码。")
                    Label(bluetooth.status, systemImage: bluetooth.authenticated ? "checkmark.shield" : "antenna.radiowaves.left.and.right").font(.caption)
                    Button("搜索 Nikon 相机", systemImage: "dot.radiowaves.left.and.right") { bluetooth.scan() }.disabled(bluetooth.working)
                    ForEach(bluetooth.nearby.sorted(by: { $0.rssi > $1.rssi })) { item in
                        Button { bluetooth.connect(item.id) } label: {
                            HStack { Text(item.name); Spacer(); Text("\(item.rssi) dBm").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(bluetooth.working)
                    }
                    if bluetooth.identity != nil {
                        Button("重连已保存相机") { bluetooth.retrySaved() }.disabled(bluetooth.working || bluetooth.authenticated)
                        Toggle("自动重连已配对相机", isOn: $bluetooth.autoReconnect)
                        Toggle("前台连接后自动唤醒并连接 Wi-Fi", isOn: $settings.autoWake)
                        Button("唤醒并连接相机", systemImage: "bolt.horizontal.circle") { model.perform { try await model.wakeAndConnect(); dismiss() } }
                            .disabled(!bluetooth.authenticated || model.busy)
                        Button("同步相机时间与电量") { Task { await bluetooth.refreshTelemetry() } }.disabled(!bluetooth.authenticated)
                        if let battery = bluetooth.battery { Label("相机电量 \(battery)%", systemImage: "battery.100percent") }
                        Button("断开蓝牙") { bluetooth.disconnect() }
                        Button("忘记本机相机资料", role: .destructive) { bluetooth.disconnect(forget: true) }
                    }
                    DisclosureGroup("首次系统绑定与兼容性说明") {
                        Text("Nikon 认证完成不等于系统绑定完成。如相机仍要求配对，可打开系统配件选择器，或到 iPhone 蓝牙设置中确认相机，再返回重连。部分 iOS/相机组合可能不显示系统选择器。")
                        Button("打开系统配件选择器") { bluetooth.showSystemPairing() }
                        Text("自动唤醒需要相机蓝牙保持开启；关机连接还受相机“关机时发送”设置影响。飞行模式、取出电池、强制退出 App 或系统后台限制时无法保证唤醒。后台恢复只重连保存的相机，Wi-Fi 切换在前台完成。")
                    }.font(.caption)
                }
                Section("2 · 保存相机 Wi-Fi") {
                    Text("在相机菜单中开启连接至智能设备/Wi-Fi。可先在 iPhone 设置中加入相机热点，也可在下方输入相机显示的 SSID。")
                    TextField("相机 SSID", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Wi-Fi 密码", text: $password)
                    Button("保存至此相机的钥匙串") { model.perform { try model.saveCameraWiFi(ssid: ssid, password: password, host: host); password = "" } }
                        .disabled(model.busy || !bluetooth.authenticated || ssid.isEmpty)
                    Text("首次保存一次热点信息，后续可由蓝牙唤醒衔接连接。iOS 可能仍要求确认加入网络。密码不会进入诊断日志。") .font(.caption).foregroundStyle(.secondary)
                    Button("加入此 Wi-Fi") { model.perform { try await model.connectivity.join(ssid: ssid, password: password); password = "" } }.disabled(model.busy || ssid.isEmpty)
                }
                Section("3 · 手动 PTP/IP 连接 / 网络地址") {
                    TextField("相机 IP / 主机名", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("默认地址只是可编辑的起点。请按相机当前网络实际地址填写；15740 端口或配对要求可能因固件而异。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("建立真实连接") { model.perform { try await model.connect(host: host); dismiss() } }.disabled(model.busy)
                    if model.device != nil { Button("断开连接", role: .destructive) { model.perform { try await model.disconnect() } } }
                }
                if let progress = model.connectionProgress { Section { ProgressView(progress) } }
                Section("连接诊断") {
                    Text("阶段：\(bluetooth.state.rawValue) · PTP：\(model.device == nil ? "未建立" : "已验证")").font(.caption)
                    ShareLink(item: bluetooth.diagnostics.joined(separator: "\n")) { Label("分享不含密码的蓝牙诊断", systemImage: "square.and.arrow.up") }
                    DisclosureGroup("最近事件") {
                        ForEach(Array(bluetooth.diagnostics.suffix(12).enumerated()), id: \.offset) { _, line in Text(line).font(.caption2).textSelection(.enabled) }
                    }
                }
            }.navigationTitle("相机连接").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct CameraFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("每个存储区显示最多 200 项。相机下载限 64 MiB；较大 RAW 可从“照片 → 导入”加入。") .font(.caption).foregroundStyle(.secondary)
                Button("刷新相机文件") { model.perform { try await model.listCameraFiles() } }.disabled(model.busy)
                ForEach(model.cameraObjects) { object in
                    HStack { VStack(alignment: .leading) { Text(object.filename); Text(ByteCountFormatter.string(fromByteCount: Int64(object.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Button("下载") { model.perform { try await model.download(object) } }.disabled(model.busy) }
                }
            }.navigationTitle("相机文件").toolbar { Button("完成") { dismiss() } }
        }
    }
}

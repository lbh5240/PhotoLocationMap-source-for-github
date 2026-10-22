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
                    Text("连接、曝光、对焦与取景的可用性取决于固件、网络模式及相机声明的操作。蓝牙目前仅支持设备发现。")
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
        NavigationStack {
            Form {
                Section("1 · 连接相机 Wi-Fi") {
                    Text("在相机菜单中开启连接至智能设备/Wi-Fi。可先在 iPhone 设置中加入相机热点，也可在下方输入相机显示的 SSID。")
                    TextField("相机 SSID", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Wi-Fi 密码", text: $password)
                    Button("加入此 Wi-Fi") { model.perform { try await model.connectivity.join(ssid: ssid, password: password); password = "" } }.disabled(model.busy || ssid.isEmpty)
                }
                Section("2 · 实验性 PTP/IP 会话") {
                    TextField("相机 IP / 主机名", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("默认地址只是可编辑的起点。请按相机当前网络实际地址填写；15740 端口或配对要求可能因固件而异。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("建立真实连接") { model.perform { try await model.connect(host: host); dismiss() } }.disabled(model.busy)
                    if model.device != nil { Button("断开连接", role: .destructive) { model.perform { try await model.disconnect() } } }
                }
                Section("蓝牙设备发现") {
                    Button("扫描附近设备") { model.connectivity.scan() }
                    Text(model.connectivity.bluetoothStatus).font(.caption)
                    ForEach(model.connectivity.peripherals.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in Text(model.connectivity.peripherals[id] ?? "未知设备") }
                    Text("扫描结果不代表已配对。Nikon 私有 GATT 认证与蓝牙唤醒尚未实现。") .font(.caption).foregroundStyle(.secondary)
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

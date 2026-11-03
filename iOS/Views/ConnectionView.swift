import SwiftUI
import ZoraCore

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cameraHost") private var host = "192.168.1.1"
    @State private var ssid = ""
    @State private var password = ""
    @State private var connectionMode = 0
    var body: some View {
        @Bindable var bluetooth = model.connectivity.bluetooth
        @Bindable var settings = model
        NavigationStack {
            Form {
                Section {
                    Picker("连接方式", selection: $connectionMode) { Text("无线").tag(0); Text("USB 有线").tag(1) }.pickerStyle(.segmented).accessibilityIdentifier("connectionMode")
                }
                if connectionMode == 1 {
                    Section("USB 数据线连接") {
                        Text("使用支持数据传输的 USB-C 线连接 iPhone/iPad 与 Z7 II，开启相机。Lightning 设备需相机 USB 转接器，供电不足时使用带供电转接器。")
                        Button("搜索 USB 相机", systemImage: "cable.connector") { Task { await model.usb.search() } }.accessibilityIdentifier("searchUSBCamera")
                        Text(model.usb.status).font(.caption).accessibilityIdentifier("usbConnectionStatus")
                        ForEach(model.usb.cameras) { camera in
                            Button(camera.name) { model.perform { try await model.connectUSB(camera.id); dismiss() } }.disabled(model.busy)
                        }
                        if model.connectionType == "USB" { Button("断开 USB 会话") { model.perform { try await model.disconnect() } }.disabled(model.busy) }
                        Text("首次需允许相机媒体与控制权限。USB 连接不需要相机 Wi-Fi；连接成功后共用拍摄、取景、文件与调色功能。真实兼容性需按相机和固件验收。") .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                Section("1 · 蓝牙配对与唤醒") {
                    Text("首次连接：在 Z7 II 中开启“连接至智能设备 → 配对（蓝牙）”，再扫描并选择相机。按系统和相机提示确认配对码。")
                    Label(bluetooth.status, systemImage: bluetooth.authenticated ? "checkmark.shield" : "antenna.radiowaves.left.and.right").font(.caption)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(["建立蓝牙链路", "Nikon 身份握手", "两端确认系统配对码", "相机注册与校时", "验证完成，允许 Wi-Fi 连接"].enumerated()), id: \.offset) { index, title in
                            let complete = index == 2 ? bluetooth.systemPairingConfirmed : bluetooth.authenticated || bluetooth.step > index+1
                            Label(title, systemImage: complete ? "checkmark.circle.fill" : bluetooth.step == index+1 ? "circle.inset.filled" : "circle")
                                .font(.caption).foregroundStyle(bluetooth.step == index+1 ? Color.zoraAmber : .secondary)
                        }
                    }.accessibilityIdentifier("pairingSteps")
                    Text("确认配对码后，还需等待相机完成注册。注册通过前不会自动开启 Wi-Fi；六位码只在系统/相机窗口确认。") .font(.caption).foregroundStyle(.secondary)
                    if bluetooth.working {
                        ProgressView("正在等待相机 / 系统响应")
                        Button("取消当前配对") { bluetooth.disconnect() }
                    }
                    Button("搜索 Nikon 相机", systemImage: "dot.radiowaves.left.and.right") { bluetooth.scan() }.disabled(bluetooth.working || bluetooth.authenticated)
                    ForEach(bluetooth.nearby.sorted(by: { $0.rssi > $1.rssi })) { item in
                        Button { bluetooth.connect(item.id) } label: {
                            HStack { Text(item.name); Spacer(); Text("\(item.rssi) dBm").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(bluetooth.working || bluetooth.authenticated)
                    }
                    if bluetooth.identity != nil {
                        Button(bluetooth.identity?.registrationVerified == true ? "重连已保存相机" : "继续验证未完成的相机配对") { bluetooth.retrySaved() }.disabled(bluetooth.working || bluetooth.authenticated)
                        if !bluetooth.authenticated { Button("继续系统配对并重新验证") { bluetooth.showSystemPairing() }.disabled(bluetooth.working) }
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
                        Text("如果确认配对码后相机仍在等待，点“继续验证未完成的相机配对”；仍未完成时再点“继续系统配对并重新验证”。App 会先释放旧链路，再打开系统选择器，保留原身份重连并验证相机注册。旧系统绑定冲突时，可在 iPhone 蓝牙设置中忽略该相机，再从相机菜单开始新配对。")
                        Button("打开系统配件选择器并验证") { bluetooth.showSystemPairing() }.disabled(bluetooth.working)
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
                }
                if let progress = model.connectionProgress { Section { ProgressView(progress) } }
                if model.busy { Section { Button("取消后续连接操作") { model.cancelOperation() } } }
                Section("连接诊断") {
                    Text("阶段：\(bluetooth.state.rawValue) · PTP：\(model.device == nil ? "未建立" : "已验证")").font(.caption)
                    ShareLink(item: bluetooth.diagnostics.joined(separator: "\n")) { Label("分享不含密码的蓝牙诊断", systemImage: "square.and.arrow.up") }
                    DisclosureGroup("最近事件") {
                        ForEach(Array(bluetooth.diagnostics.suffix(12).enumerated()), id: \.offset) { _, line in Text(line).font(.caption2).textSelection(.enabled) }
                    }
                    DisclosureGroup("相机事件") {
                        ForEach(Array(model.protocolEvents.suffix(12).enumerated()), id: \.offset) { _, event in
                            Text(event.name + String(format: " · 0x%04X · ", event.code) + event.parameters.map(String.init).joined(separator: ", ")).font(.caption2)
                        }
                    }
                }
            }.navigationTitle("相机连接").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

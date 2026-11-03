import SwiftUI
import ZoraCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model
        @Bindable var location = model.location
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZoraMark(size: 54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ZORA Camera").font(.title3.weight(.semibold))
                            Text("版本 \(appVersion) · 实验版").font(.caption).foregroundStyle(.secondary)
                            Text(model.device.map { "\($0.model) · 固件 \($0.firmware)" } ?? "未连接相机").font(.caption).foregroundStyle(model.device == nil ? .secondary : Color.zoraOK)
                        }
                    }.padding(.vertical, 4)
                }
                Section {
                    Toggle(isOn: $settings.autoImport) { Label("拍摄后自动导入", systemImage: "arrow.down.circle") }
                    Toggle(isOn: $settings.autoImportRAW) { Label("包含 RAW (NEF)", systemImage: "camera.aperture") }.disabled(!model.autoImport)
                    Toggle(isOn: $settings.autoUpload) { Label("导入后自动备份到 NAS", systemImage: "externaldrive.badge.icloud") }.disabled(!model.autoImport || model.destination == nil)
                } header: { Text("自动传输") } footer: { Text("连接期间依据相机“新增文件”事件下载新拍摄的照片，不重复导入。相机写卡未完成时稍后重试。App 需保持在前台。") }
                Section {
                    Toggle(isOn: $location.enabled) { Label("记录手机位置", systemImage: "location") }
                    if model.location.enabled { Text(model.location.status).font(.caption).foregroundStyle(.secondary) }
                } header: { Text("位置信息") } footer: { Text("导入时记录 10 分钟内的 iPhone 定位，导出 JPEG 时写入 GPS。不改写相机原片，也不写入相机。") }
                Section("备份") {
                    NavigationLink { NASSettingsView() } label: {
                        LabeledContent {
                            Text(model.destination.map { $0.kind == .webDAV ? "WebDAV" : "S3" } ?? "未配置").foregroundStyle(.secondary)
                        } label: { Label("NAS 目的地", systemImage: "externaldrive.connected.to.line.below") }
                    }
                }
                Section("相机") {
                    LabeledContent { Text(model.connectionType.map { $0 == "USB" ? "USB · 实验性" : "Wi-Fi PTP/IP · 实验性" } ?? "未连接") } label: { Label("驱动", systemImage: "cpu") }
                    if let device = model.device {
                        LabeledContent { Text(device.maskedSerial) } label: { Label("序列号", systemImage: "number") }
                        DisclosureGroup {
                            ForEach(device.operations.sorted(), id: \.self) { code in
                                LabeledContent(PTPOperation.name(code), value: String(format: "0x%04X", code)).font(.caption)
                            }
                        } label: { Label("相机声明的能力 · \(device.operations.count) 项", systemImage: "list.bullet.rectangle") }
                        ShareLink(item: capabilityReport(device)) { Label("分享能力清单（不含序列号）", systemImage: "square.and.arrow.up") }
                    }
                    Text("功能随相机声明的能力开放；Z7 II 与 NAS 仍需实机验证。设备发现不等于 Nikon 配对。").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Label("原生 SwiftUI · Swift 6 · iOS 27 · Liquid Glass", systemImage: "swift")
                    Label("无分析 SDK，不上传遥测；原片与风格保存在设备内", systemImage: "lock.shield")
                } header: { Text("关于") }
            }.scrollContentBackground(.hidden).zoraPage().navigationTitle("设置")
        }
    }
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
    private func capabilityReport(_ device: CameraDeviceInfo) -> String {
        var lines = ["ZORA \(appVersion) 相机能力清单", "\(device.manufacturer) \(device.model) · 固件 \(device.firmware) · \(model.connectionType ?? "")"]
        lines.append("操作：" + device.operations.sorted().map { String(format: "%04X", $0) }.joined(separator: " "))
        lines.append("事件：" + device.events.sorted().map { String(format: "%04X", $0) }.joined(separator: " "))
        lines.append("属性：" + device.properties.sorted().map { String(format: "%04X", $0) }.joined(separator: " "))
        return lines.joined(separator: "\n")
    }
}

private struct NASSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var kind: DestinationKind = .webDAV
    @State private var endpoint = ""
    @State private var bucket = ""
    @State private var region = "us-east-1"
    @State private var prefix = "ZORA"
    @State private var username = ""
    @State private var secret = ""
    @State private var token = ""
    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $kind) { ForEach(DestinationKind.allCases, id: \.self) { Text($0 == .webDAV ? "WebDAV" : "S3 兼容").tag($0) } }.pickerStyle(.segmented)
            }
            Section("服务器") {
                TextField("HTTPS 服务地址", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("远端目录 / 前缀", text: $prefix).textInputAutocapitalization(.never).autocorrectionDisabled()
                if kind == .s3 {
                    TextField("Bucket", text: $bucket).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Region", text: $region).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            Section {
                TextField(kind == .s3 ? "Access Key" : "用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(kind == .s3 ? "Secret Key" : "密码 / 应用密码", text: $secret)
                if kind == .s3 { SecureField("Session Token（可选）", text: $token) }
            } header: { Text("凭据") } footer: { Text("密码只存入本机钥匙串。") }
            Section {
                Button {
                    model.perform {
                        guard let url = URL(string: endpoint) else { throw ZoraError.malformed("NAS 地址") }
                        try model.saveDestination(.init(kind: kind, endpoint: url, bucket: bucket, region: region, prefix: prefix), username: username, secret: secret, token: token)
                        secret = ""; token = ""
                    }
                } label: { Text("保存 NAS 绑定").frame(maxWidth: .infinity).fontWeight(.semibold) }.disabled(model.busy || endpoint.isEmpty)
            } footer: { Text("仅支持有效证书的 HTTPS，不绕过证书校验。WebDAV 使用 Basic Auth，缺少目录时自动创建；S3 使用 SigV4 path-style。上传后用 HEAD 核对服务器保存的文件大小。修改配置后已有任务继续发往原目的地。") }
        }.scrollContentBackground(.hidden).zoraPage().navigationTitle("NAS 目的地").navigationBarTitleDisplayMode(.inline).onAppear {
            if let d = model.destination { kind = d.kind; endpoint = d.endpoint.absoluteString; bucket = d.bucket; region = d.region; prefix = d.prefix }
        }
    }
}

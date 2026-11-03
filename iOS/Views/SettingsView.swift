import SwiftUI
import ZoraCore

struct SettingsView: View {
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
        @Bindable var settings = model
        @Bindable var location = model.location
        NavigationStack {
            Form {
                Section {
                    Toggle("拍摄后自动导入新照片", isOn: $settings.autoImport)
                    Toggle("自动导入包含 RAW (NEF)", isOn: $settings.autoImportRAW).disabled(!model.autoImport)
                    Toggle("导入后加入 NAS 备份队列", isOn: $settings.autoUpload).disabled(!model.autoImport || model.destination == nil)
                } header: { Text("自动传输") } footer: { Text("连接期间，ZORA 依据相机的“新增文件”事件（声明 Nikon 事件轮询时每 2 秒查询一次）下载新拍摄的文件，不会重复导入已有照片。相机写卡未完成时会稍后重试。App 需保持在前台。") }
                Section {
                    Toggle("为导入的照片记录手机位置", isOn: $location.enabled)
                    Text(model.location.status).font(.caption).foregroundStyle(.secondary)
                } header: { Text("位置信息") } footer: { Text("类似 SnapBridge 位置同步，但在手机端完成：导入时记录 iPhone 定位（10 分钟内的有效定位），导出 JPEG 时写入 GPS EXIF。不会改写相机原片，也不会把位置写入相机。") }
                Section {
                    Picker("连接方式", selection: $kind) { ForEach(DestinationKind.allCases, id: \.self) { Text($0 == .webDAV ? "WebDAV" : "S3 兼容").tag($0) } }
                    TextField("HTTPS 服务地址", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("远端目录 / 前缀", text: $prefix).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if kind == .s3 {
                        TextField("Bucket", text: $bucket).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Region", text: $region).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    TextField(kind == .s3 ? "Access Key" : "用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(kind == .s3 ? "Secret Key" : "密码 / 应用密码", text: $secret)
                    if kind == .s3 { SecureField("Session Token（可选）", text: $token) }
                    Button("保存 NAS 绑定") {
                        model.perform {
                            guard let url = URL(string: endpoint) else { throw ZoraError.malformed("NAS 地址") }
                            try model.saveDestination(.init(kind: kind, endpoint: url, bucket: bucket, region: region, prefix: prefix), username: username, secret: secret, token: token)
                            secret = ""; token = ""
                        }
                    }.disabled(model.busy)
                } header: { Text("NAS 目的地") } footer: { Text("仅支持有效证书的 HTTPS，不绕过证书校验。WebDAV 使用 Basic Auth，缺少目录时自动 MKCOL 创建；S3 使用 SigV4 path-style。上传后用 HEAD 核对服务器保存的文件大小。密码存入本机钥匙串；修改配置后已有任务继续使用原目的地。") }
                Section("设备与验证") {
                    LabeledContent("相机", value: model.device?.model ?? "未连接")
                    LabeledContent("固件", value: model.device?.firmware ?? "未读取")
                    if let device = model.device { LabeledContent("序列号", value: device.maskedSerial) }
                    LabeledContent("驱动状态", value: model.connectionType.map { $0 == "USB" ? "USB · ImageCaptureCore · 实验性" : "PTP/IP · 实验性" } ?? "未连接")
                    if let device = model.device {
                        DisclosureGroup("相机声明的能力（\(device.operations.count) 项操作 · \(device.properties.count) 项属性）") {
                            ForEach(device.operations.sorted(), id: \.self) { code in
                                LabeledContent(PTPOperation.name(code), value: String(format: "0x%04X", code)).font(.caption)
                            }
                        }
                        ShareLink(item: capabilityReport(device)) { Label("分享能力清单（不含序列号）", systemImage: "square.and.arrow.up") }
                    }
                    Text("此实验版本仍需 Z7 II 与 NAS 实机验证。设备发现不等于 Nikon 配对，功能随相机能力开放。") .font(.caption).foregroundStyle(.secondary)
                }
                Section("ZORA Camera") {
                    Text("ZORA Camera 0.5 · 原生 SwiftUI · Swift 6 · iOS 27 · Liquid Glass")
                    Text("无分析 SDK，不上传遥测。原片与独立 Recipes 保存在设备内。") .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("连接与偏好").onAppear {
                if let d = model.destination { kind = d.kind; endpoint = d.endpoint.absoluteString; bucket = d.bucket; region = d.region; prefix = d.prefix }
            }
        }
    }
    private func capabilityReport(_ device: CameraDeviceInfo) -> String {
        var lines = ["ZORA 0.5 相机能力清单", "\(device.manufacturer) \(device.model) · 固件 \(device.firmware) · \(model.connectionType ?? "")"]
        lines.append("操作：" + device.operations.sorted().map { String(format: "%04X", $0) }.joined(separator: " "))
        lines.append("事件：" + device.events.sorted().map { String(format: "%04X", $0) }.joined(separator: " "))
        lines.append("属性：" + device.properties.sorted().map { String(format: "%04X", $0) }.joined(separator: " "))
        return lines.joined(separator: "\n")
    }
}

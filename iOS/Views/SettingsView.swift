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
        NavigationStack {
            Form {
                Section("NAS 目的地") {
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
                } footer: { Text("仅支持有效证书的 HTTPS，不绕过证书校验。WebDAV 使用 Basic Auth，S3 使用 SigV4 path-style。WebDAV 目录需预先建立。密码存入本机钥匙串；修改配置后已有任务继续使用原目的地。") }
                Section("设备与验证") {
                    LabeledContent("相机", value: model.device?.model ?? "未连接")
                    LabeledContent("固件", value: model.device?.firmware ?? "未读取")
                    LabeledContent("驱动状态", value: "PTP/IP · 实验性")
                    Text("此实验版本仍需 Z7 II 与 NAS 实机验证。设备发现不等于 Nikon 配对，功能随相机能力开放。") .font(.caption).foregroundStyle(.secondary)
                }
                Section("ZORA Camera") {
                    Text("原生 SwiftUI · Swift 6 · iOS 27 · Liquid Glass")
                    Text("无分析 SDK，不上传遥测。原片与独立 Recipes 保存在设备内。") .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("连接与偏好").onAppear {
                if let d = model.destination { kind = d.kind; endpoint = d.endpoint.absoluteString; bucket = d.bucket; region = d.region; prefix = d.prefix }
            }
        }
    }
}

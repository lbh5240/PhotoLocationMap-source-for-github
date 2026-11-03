import SwiftUI
import ZoraCore

struct TransfersView: View {
    @Environment(AppModel.self) private var model
    private var done: Int { model.jobs.filter { $0.state == .complete }.count }
    private var blocked: Int { model.jobs.filter { $0.state == .blocked }.count }
    private var pending: Int { model.jobs.count - done - blocked }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            StatusPill(text: model.connectivity.online ? "网络可用" : "离线 · 队列已保留", systemImage: model.connectivity.online ? "wifi" : "wifi.slash",
                                       color: model.connectivity.online ? .zoraOK : .secondary)
                            Spacer()
                            if model.destination == nil { StatusPill(text: "未配置 NAS", systemImage: "exclamationmark.triangle", color: .zoraAmber) }
                        }
                        HStack(spacing: 0) {
                            stat(done, "已确认", .zoraOK)
                            stat(pending, "待上传", .zoraAmber)
                            stat(blocked, "需处理", blocked > 0 ? .zoraLive : .secondary)
                        }
                        if !model.jobs.isEmpty {
                            ProgressView(value: Double(done), total: Double(max(model.jobs.count, 1))).tint(Color.zoraOK)
                        }
                        HStack(spacing: 10) {
                            Button { model.perform { await model.sync() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).tint(Color.zoraAmber).foregroundStyle(.black)
                            Button { model.perform { try await model.uploadQueue.retryBlocked(); await model.sync() } } label: { Label("重试", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).disabled(blocked == 0 && pending == 0)
                        }.disabled(model.busy)
                    }.padding(.vertical, 6)
                } footer: { Text("App 在前台时自动上传。上传后会请求服务器回报文件大小核对。切换到相机热点时 NAS 可能不可达，回到 NAS 网络后自动重试。左滑可移除单个任务。") }
                if model.jobs.isEmpty {
                    ContentUnavailableView("备份队列为空", systemImage: "externaldrive", description: Text("在照片详情中点“备份原片”，或在设置中开启导入后自动备份。"))
                } else {
                    Section {
                        ForEach(model.jobs) { job in
                            HStack(spacing: 12) {
                                Image(systemName: icon(job.state)).font(.title3).foregroundStyle(color(job.state)).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.assets.first { $0.storedName == job.file.lastPathComponent }?.originalName ?? job.file.lastPathComponent).font(.subheadline).lineLimit(1)
                                    Text(detail(job)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                if job.state == .uploading { ProgressView().controlSize(.small) }
                            }
                            .swipeActions {
                                if job.state != .uploading {
                                    Button("移除", systemImage: "xmark", role: .destructive) { model.perform { try await model.uploadQueue.remove(job.id); await model.refresh() } }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("任务")
                            Spacer()
                            if done > 0 { Button("清除已完成") { model.perform { try await model.uploadQueue.clearCompleted(); await model.refresh() } }.font(.caption).disabled(model.busy) }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).zoraPage().navigationTitle("安全抵达").refreshable { await model.refresh() }
        }
    }
    private func stat(_ value: Int, _ title: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(.title, design: .rounded).weight(.bold)).foregroundStyle(color).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    private func icon(_ state: UploadState) -> String {
        switch state { case .queued: "clock"; case .uploading: "arrow.up.circle"; case .retry: "arrow.clockwise.circle"; case .blocked: "exclamationmark.triangle.fill"; case .complete: "checkmark.circle.fill" }
    }
    private func color(_ state: UploadState) -> Color {
        switch state { case .complete: .zoraOK; case .blocked: .zoraLive; case .uploading: .zoraAmber; default: .secondary }
    }
    private func detail(_ job: UploadJob) -> String {
        let state: String
        switch job.state { case .queued: state = "等待上传"; case .uploading: state = "正在上传"; case .retry: state = "等待重试"; case .blocked: state = "需要处理"
        case .complete: state = job.remoteVerified == true ? "服务器已确认 · 大小一致" : "服务器已确认 · 未回报大小" }
        var parts = [state]
        if job.attempts > 1 { parts.append("尝试 \(job.attempts) 次") }
        if let error = job.lastError, job.state != .complete { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}

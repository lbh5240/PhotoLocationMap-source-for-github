import SwiftUI
import ZoraCore

struct TransfersView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(model.connectivity.online ? "网络可用 · 等待目标响应" : "当前离线 · 队列已保留", systemImage: model.connectivity.online ? "wifi" : "wifi.slash")
                    Text("\(model.jobs.filter { $0.state == .complete }.count) 已完成 · \(model.jobs.filter { $0.state != .complete }.count) 待处理").font(.subheadline).foregroundStyle(.secondary)
                    Button("立即同步") { model.perform { await model.sync() } }.disabled(model.busy)
                    Button("重试受阻任务") { model.perform { try await model.uploadQueue.retryBlocked(); await model.sync() } }.disabled(model.busy)
                    Button("清除已完成记录") { model.perform { try await model.uploadQueue.clearCompleted(); await model.refresh() } }.disabled(model.busy || !model.jobs.contains(where: { $0.state == .complete }))
                } footer: { Text("队列在 App 开启时自动工作。切换相机热点后 NAS 可能暂不可达；回到 NAS 网络后会重试。上传成功后会请求服务器回报文件大小核对。iOS 后台持续传输与 S3 分片上传尚未接入。向左滑动可移除单个任务。") }
                if model.jobs.isEmpty { ContentUnavailableView("备份队列为空", systemImage: "externaldrive", description: Text("在照片详情中选择上传原片。")) }
                ForEach(model.jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.assets.first { $0.storedName == job.file.lastPathComponent }?.originalName ?? job.file.lastPathComponent).font(.caption).lineLimit(1)
                        HStack { Text(label(job.state)); Spacer(); Text("尝试 \(job.attempts) 次") }.font(.caption).foregroundStyle(job.state == .complete ? Color.green : Color.zoraAmber)
                        if job.state == .complete { Text(job.remoteVerified == true ? "服务器回报的文件大小与原片一致" : "服务器未回报文件大小，未做大小核对").font(.caption2).foregroundStyle(.secondary) }
                        if let error = job.lastError { Text(error).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.vertical, 5)
                    .swipeActions {
                        if job.state != .uploading {
                            Button("移除", systemImage: "xmark", role: .destructive) { model.perform { try await model.uploadQueue.remove(job.id); await model.refresh() } }
                        }
                    }
                }
            }.navigationTitle("安全抵达").refreshable { await model.refresh() }
        }
    }
    private func label(_ state: UploadState) -> String {
        switch state { case .queued: "等待上传"; case .uploading: "正在上传"; case .retry: "等待重试"; case .blocked: "需要处理"; case .complete: "服务器已确认" }
    }
}

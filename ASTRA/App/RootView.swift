import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("astra.hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var deleting: AstroProject?
    @State private var showHelp = false
    @State private var showOnboarding = false
    var body: some View {
        NavigationStack {
            ZStack {
                StarBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 9) { Image(systemName: "sparkle").foregroundStyle(.indigo); Text("ASTRA").tracking(7).font(.system(size: 14, weight: .semibold, design: .rounded)) }
                            Text("把星光，\n留得更清楚。").font(.system(size: 38, weight: .light, design: .rounded)).lineSpacing(5)
                            Text("星空堆栈 · RAW 调整 · 色彩创作").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.top, 14)
                        Button(action: store.create) {
                            HStack(spacing: 16) {
                                Image(systemName: "plus").font(.title2).frame(width: 45, height: 45).background(.indigo.opacity(0.2), in: Circle())
                                VStack(alignment: .leading, spacing: 5) { Text("创建星空工程").font(.headline); Text("支持尼康 NEF · 原片保留").font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: "arrow.up.right")
                            }.padding(20).frame(maxWidth: .infinity).astroGlass()
                        }.buttonStyle(.plain).disabled(store.busy)
                        HStack { Text("你的星空").font(.title3.weight(.semibold)); Spacer(); Text("\(store.projects.count) 个工程").font(.caption).foregroundStyle(.secondary) }
                        if store.projects.isEmpty {
                            VStack(spacing: 12) { Image(systemName: "moon.stars").font(.largeTitle).foregroundStyle(.secondary); Text("从第一组星空照片开始"); Text("所有图像处理均在本机完成").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 30)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                            ForEach(store.projects) { project in
                                Button { store.select(project.id) } label: { ProjectCard(project: project) }
                                    .buttonStyle(.plain).contextMenu { Button("删除工程及原片副本", systemImage: "trash", role: .destructive) { deleting = project } }.disabled(store.busy)
                            }
                        }
                    }.padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("使用说明", systemImage: "questionmark.circle") { showHelp = true }.labelStyle(.iconOnly) } }
            .navigationDestination(isPresented: Binding(get: { store.selectedID != nil }, set: { if !$0 { store.select(nil) } })) { WorkspaceView() }
            .sheet(isPresented: $showHelp) { HelpView() }
            .sheet(isPresented: $showOnboarding, onDismiss: { hasSeenOnboarding = true }) {
                NavigationStack { OnboardingView(firstLaunch: true) }
            }
            .task {
                if !hasSeenOnboarding && store.message == nil { showOnboarding = true }
            }
            .alert("ASTRA", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("好", role: .cancel) { store.message = nil } } message: { Text(store.message ?? "") }
            .confirmationDialog("删除工程会移除导入副本、调色参数和结果，外部原文件不受影响。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除工程", role: .destructive) { if let deleting { store.delete(deleting) }; deleting = nil }
            }
        }
    }
}
private struct ProjectCard: View {
    let project: AstroProject
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.indigo.opacity(0.18), .black], startPoint: .topTrailing, endPoint: .bottomLeading)
                if let repo = try? ProjectRepository() {
                    let cover = repo.url(project, "cover.jpg")
                    if let image = UIImage(contentsOfFile: cover.path) { Image(uiImage: image).resizable().scaledToFill() }
                    else if let frame = project.frames.first, let image = UIImage(contentsOfFile: repo.url(project, "Thumbs/\(frame.id.uuidString).jpg").path) { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "sparkles").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                HStack { Badge(text: project.result == nil ? "待合成" : "已合成", color: project.result == nil ? .white : .mint); Spacer(); if let r = project.result { Badge(text: "\(r.acceptedFrames) 帧", color: .white) } }.padding(12)
            }.frame(height: 150).clipped().clipShape(RoundedRectangle(cornerRadius: 18))
            Text(project.name).font(.headline).lineLimit(1)
            HStack { Text("\(project.frames.count) 张照片"); Spacer(); Text(project.updated.formatted(date: .abbreviated, time: .omitted)) }.font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("快速上手") {
                    NavigationLink { OnboardingView(firstLaunch: false) } label: {
                        Label("新手引导", systemImage: "sparkles")
                    }
                    Text("在工程中点「导入照片」，可从相册多选图片，也可从文件导入尼康 NEF 原片。建议用同一机位、焦距和曝光拍摄的一组照片堆栈。")
                }
                Section("三种模式") { Text("星空对齐：星点相似变换配准，适合跟踪拍摄和纯天空。\n星野：水平分界线上方对齐星空，下方固定地景平均；适合平坦地平线。\n星轨：固定机位最大值合成，不做星点对齐。") }
                Section("NEF 与精度") { Text("使用系统 RAW 解码器，RAW 无法解码时直接报错，不使用内嵌 JPEG 替代。先去马赛克，再在线性扩展 sRGB 浮点空间堆栈。此版本不包含 CFA 暗场、平场或偏置场校准。支持范围取决于系统、机型与 RAW 压缩方式。") }
                Section("画面与导出") { Text("画布是最长边 1600 像素的预览，放大仅用于查看预览。所有导出重新读取全尺寸数据。TIFF 与 PNG 为 16 位 sRGB，JPEG 与 HEIF 为 8 位 sRGB。合成覆盖不足的边缘保留透明；JPEG 不保留透明通道，边缘会变黑。") }
                Section("处理任务") { Text("大尺寸 RAW 需要较多磁盘空间。请保持应用前台，系统限制后台执行时会取消任务。解码缓存可复用，上次已完成合成会保留；重新开始会从合成阶段重算。所有工程、原片副本和参数保存在设备本地。删除 App 会移除这些数据，请通过文件 App 备份 ASTRA 文件夹。") }
                Section("当前实现范围") { Text("已接入：相册与文件导入、系统 RAW 解码、星点配准、分块堆栈、稳健异常值剔除、星轨、手动水平天空分界、基础修图、曲线、六色 HSL、撤销重做与导出。\n不包含：自动地景分割、画笔蒙版、光污染背景建模、星点缩小、镜头畸变配准、CFA 校准、AI 模型降噪及合成阶段断点续算。") }
            }.navigationTitle("使用说明").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

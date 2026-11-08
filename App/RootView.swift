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
                #if DEBUG && targetEnvironment(simulator)
                if let variant = ProcessInfo.processInfo.environment["ASTRA_UI_STACK_FIXTURE"], store.project == nil {
                    do {
                        let files = try SimulatorStackFixture.make(variant: variant)
                        store.create()
                        store.importFiles(files)
                    } catch { store.message = error.localizedDescription }
                    return
                }
                #endif
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
                    Text("从相册选择 RAW+JPEG 时会读取资产中的原始 NEF 资源并提示选择格式。若未授权原件读取，可从文件导入 NEF。不同曝光照片可开启 HDR 多曝光融合。")
                }
                Section("三种模式") { Text("星空对齐：星点相似变换配准，适合跟踪拍摄和纯天空。\n星野：水平分界线上方对齐星空，下方固定地景平均；适合平坦地平线。\n星轨：固定机位最大值合成，不做星点对齐。") }
                Section("NEF 与精度") { Text("使用系统 RAW 解码器，RAW 无法解码时直接报错，不使用内嵌 JPEG 替代。先去马赛克，再在线性扩展 sRGB 浮点空间堆栈。此版本不包含 CFA 暗场、平场或偏置场校准。支持范围取决于系统、机型与 RAW 压缩方式。") }
                Section("画面与导出") { Text("合成结果默认开启自动 STF 屏幕预览，不改动 Float32 主文件，也不会写入导出。星云工具中的 Arcsinh、核心保护、梯度消除与星云对比会应用到导出。全尺寸导出支持 16 位 TIFF/PNG 与 8 位 JPEG/HEIF。") }
                Section("处理任务") { Text("相册 NEF 导入会显示 iCloud 下载和逐张保存进度。导入时避免手动锁屏：系统可能暂停锁屏后的任务，后台时间也有限；已完成的照片会保存在工程里。导入只提取内嵌预览，全尺寸 RAW 在堆栈或导出时才解码。删除 App 会移除本地数据，请先通过文件 App 备份 ASTRA 文件夹。") }
                Section("当前实现范围") { Text("背景消除使用低频网格估计；星点保护使用高频亮度掩膜，均可调强度。HDR 在星点对齐后以未饱和短曝光填补长曝光核心。没有画笔蒙版、完整 PixInsight 式迭代 Masked Stretch、镜头畸变配准、CFA 校准和 AI 模型降噪。") }
            }.navigationTitle("使用说明").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

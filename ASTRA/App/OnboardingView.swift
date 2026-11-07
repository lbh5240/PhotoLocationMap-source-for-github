import SwiftUI

struct OnboardingView: View {
    let firstLaunch: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Step {
        let symbol: String
        let title: String
        let summary: String
        let tips: [String]
    }

    private static let steps = [
        Step(symbol: "photo.on.rectangle.angled", title: "导入第一组照片",
             summary: "创建星空工程，在底部点「导入照片」。",
             tips: ["从相册导入时，可以按顺序多选同一组照片。", "尼康 Z7 II 的 NEF 原片可通过「从文件导入」选择。", "单张可直接调色。堆栈至少选两张，尽量使用同一机位、焦距和曝光。"]),
        Step(symbol: "square.3.layers.3d", title: "按题材选择堆栈",
             summary: "在「堆栈」里选模式，然后点「开始合成」。",
             tips: ["星空对齐适合纯天空和跟踪拍摄，软件会用星点自动配准。", "有平坦地平线时选「星野 · 地景」，拖动「天空占画面高度」对准分界。", "星轨模式按固定机位合成。可在照片列表取消勾选有飞机光带或严重拖尾的帧。"]),
        Step(symbol: "slider.horizontal.3", title: "调出暗部和星色",
             summary: "先调光影，再用色轮、曲线和 HSL 微调。",
             tips: ["先轻调曝光和阴影，再看直方图，避免亮星失去细节。", "在「细节」里微调降噪和锐化。", "长按画面对比调整前后，双指放大预览。顶部箭头可以撤销。"]),
        Step(symbol: "square.and.arrow.up", title: "导出全分辨率成片",
             summary: "点右上角的导出按钮，选择格式后分享。",
             tips: ["需要继续精修时，选 16 位 TIFF。日常分享可选 JPEG。", "原片副本和调色参数保存在工程里，可以返回接着改。", "首页和工程的「使用说明」里都可以重看这份引导。"])
    ]

    var body: some View {
        ZStack {
            StarBackdrop()
            VStack(spacing: 12) {
                TabView(selection: $page) {
                    ForEach(Self.steps.indices, id: \.self) { index in
                        stepPage(Self.steps[index]).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                Text("第 \(page + 1) 步 · 共 \(Self.steps.count) 步")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if page > 0 {
                        Button("上一步") { withAnimation(.snappy) { page -= 1 } }
                            .buttonStyle(.bordered)
                    }
                    Button {
                        if page == Self.steps.count - 1 { dismiss() }
                        else { withAnimation(.snappy) { page += 1 } }
                    } label: {
                        Text(page == Self.steps.count - 1 ? (firstLaunch ? "开始使用" : "完成") : "下一步")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
        .navigationTitle("新手引导")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if firstLaunch {
                ToolbarItem(placement: .topBarTrailing) { Button("跳过") { dismiss() } }
            }
        }
    }

    private func stepPage(_ step: Step) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: step.symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.mint)
                    .frame(width: 60, height: 60)
                    .astroGlass()
                    .accessibilityHidden(true)
                Text(step.title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(step.summary).font(.body).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(step.tips, id: \.self) { tip in
                        Label(tip, systemImage: "smallcircle.filled.circle")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .astroGlass()
            }
            .padding(24)
            .frame(maxWidth: 570, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

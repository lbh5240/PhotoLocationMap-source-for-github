import SwiftUI

extension Color {
    static let zoraAmber = Color(red: 0.97, green: 0.73, blue: 0.34)
    static let zoraBackground = Color(red: 0.045, green: 0.055, blue: 0.065)
}
extension View {
    func zoraPanel() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.07)))
    }
    func zoraGlass() -> some View { glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22)) }
}
struct SectionLabel: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TabView {
            Tab("拍摄", systemImage: "camera.aperture") { CameraView() }
            Tab("照片", systemImage: "square.grid.2x2") { GalleryView() }
            Tab("风格", systemImage: "camera.filters") { LooksView() }
            Tab("传输", systemImage: "arrow.up.right.circle") { TransfersView() }
            Tab("设置", systemImage: "slider.horizontal.3") { SettingsView() }
        }
        .alert(model.error != nil ? "操作未完成" : "ZORA", isPresented: Binding(get: { model.error != nil || model.notice != nil }, set: { if !$0 { model.error = nil; model.notice = nil } })) {
            Button("好") { model.error = nil; model.notice = nil }
        } message: { Text(model.error ?? model.notice ?? "") }
        .overlay(alignment: .top) { if model.busy { ProgressView().padding(12).zoraGlass().padding(.top, 8).allowsHitTesting(false) } }
    }
}

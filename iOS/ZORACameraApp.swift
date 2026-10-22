import SwiftUI

@main struct ZORACameraApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            Group {
                if let model { RootView().environment(model) }
                else if let startupError { ContentUnavailableView("无法打开本地资料库", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError)) }
                else { ProgressView("正在打开 ZORA") }
            }
            .preferredColorScheme(.dark)
            .tint(Color.zoraAmber)
            .task {
                guard model == nil else { return }
                do { let created = try AppModel(); model = created; await created.start() }
                catch { startupError = error.localizedDescription }
            }
            .onChange(of: phase) { _, next in
                if next == .background { Task { await model?.stopStream() } }
                if next == .active { Task { await model?.sync() } }
            }
        }
    }
}

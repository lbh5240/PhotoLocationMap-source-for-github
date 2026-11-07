import SwiftUI

@main
struct ASTRAApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).preferredColorScheme(.dark)
                .tint(.init(red: 0.63, green: 0.68, blue: 1))
                .onChange(of: phase) { _, phase in if phase != .active { store.flushSave() } }
        }
    }
}

import SwiftUI

extension Color {
    static let zoraAmber = Color(red: 0.97, green: 0.73, blue: 0.34)
    static let zoraAmberDeep = Color(red: 0.89, green: 0.55, blue: 0.18)
    static let zoraBackground = Color(red: 0.045, green: 0.055, blue: 0.065)
    static let zoraLive = Color(red: 0.96, green: 0.36, blue: 0.32)
    static let zoraOK = Color(red: 0.42, green: 0.82, blue: 0.56)
}
extension LinearGradient {
    static let zoraAccent = LinearGradient(colors: [.zoraAmber, .zoraAmberDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Subtle top-to-bottom wash used behind every tab.
    static let zoraPage = LinearGradient(colors: [Color(red: 0.07, green: 0.085, blue: 0.11), .zoraBackground], startPoint: .top, endPoint: .center)
}
extension View {
    func zoraPanel() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.07)))
    }
    func zoraGlass() -> some View { glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22)) }
    func zoraPage() -> some View { background(LinearGradient.zoraPage.ignoresSafeArea()) }
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

/// Titled card with an icon; the standard container for grouped controls.
struct ZoraCard<Content: View, Trailing: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(Color.zoraAmber)
                    .frame(width: 30, height: 30).background(Color.zoraAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                Text(title).font(.headline)
                Spacer(minLength: 0)
                trailing
            }
            content
        }.zoraPanel()
    }
}
extension ZoraCard where Trailing == EmptyView {
    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.systemImage = systemImage; trailing = EmptyView(); self.content = content()
    }
}

/// Compact status capsule: a coloured dot or icon and a short label.
struct StatusPill: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.caption2.weight(.semibold)) }
            else { Circle().frame(width: 7, height: 7) }
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Horizontally scrolling single-choice chips; replaces cramped segmented controls.
struct FilterChips<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button { withAnimation(.snappy) { selection = option } } label: {
                        Text(label(option)).font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(selected ? Color.black : Color.primary)
                            .background {
                                if selected { Capsule().fill(LinearGradient.zoraAccent) }
                                else { Capsule().fill(Color.white.opacity(0.07)) }
                            }
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.vertical, 2)
        }
    }
}

/// Large tappable tile with an icon and label, used for primary secondary-actions.
struct ActionTile: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title3).foregroundStyle(Color.zoraAmber).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }
}

/// App mark drawn in code (the home-screen icon lives in the asset catalog).
struct ZoraMark: View {
    var size: CGFloat = 34
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26)
            .fill(LinearGradient(colors: [Color(red: 0.1, green: 0.12, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.05)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay { Image(systemName: "camera.aperture").font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(LinearGradient.zoraAccent) }
            .overlay(RoundedRectangle(cornerRadius: size * 0.26).stroke(.white.opacity(0.1)))
            .accessibilityHidden(true)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TabView {
            Tab("拍摄", systemImage: "camera.aperture") { CameraView() }
            Tab("照片", systemImage: "photo.on.rectangle.angled") { GalleryView() }
            Tab("风格", systemImage: "camera.filters") { LooksView() }
            Tab("传输", systemImage: "arrow.up.circle") { TransfersView() }
            Tab("设置", systemImage: "gearshape") { SettingsView() }
        }
        .alert(model.error != nil ? "操作未完成" : "ZORA", isPresented: Binding(get: { model.error != nil || model.notice != nil }, set: { if !$0 { model.error = nil; model.notice = nil } })) {
            Button("好") { model.error = nil; model.notice = nil }
        } message: { Text(model.error ?? model.notice ?? "") }
        .overlay(alignment: .top) {
            if model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.sequenceStatus ?? "处理中").font(.caption.weight(.medium)).lineLimit(1) }
                    .padding(.horizontal, 14).padding(.vertical, 8).glassEffect(.regular, in: Capsule())
                    .padding(.top, 6).allowsHitTesting(false).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.busy)
    }
}

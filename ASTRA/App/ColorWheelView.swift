import SwiftUI

struct ColorWheelsPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var range = GradeRange.shadows
    @State private var started = false
    @GestureState private var touchingWheel = false

    private var grade: WheelGrade { store.project?.adjustments.colorGrading?[range] ?? WheelGrade() }
    private var strength: Double { min(1, hypot(grade.x, grade.y)) }
    private var hue: Double { (atan2(grade.y, grade.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                ForEach(GradeRange.allCases) { item in
                    Button { range = item } label: {
                        Text(item.title).font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(range == item ? EditorStyle.accent : Color.secondary)
                            .background(range == item ? EditorStyle.accent.opacity(0.12) : EditorStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(range == item ? .isSelected : [])
                }
            }
            HStack(spacing: 21) {
                wheel.frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 8) {
                    readout("色相", strength < 0.005 ? "—" : "\(Int(hue))°")
                    readout("强度", "\(Int((strength * 100).rounded()))%")
                    Button {
                        store.checkpoint()
                        change { $0 = WheelGrade() }
                    } label: {
                        Label("复位", systemImage: "arrow.counterclockwise")
                            .font(.caption2.weight(.medium)).frame(minHeight: 36)
                    }.buttonStyle(.plain).foregroundStyle(EditorStyle.accent).disabled(grade == WheelGrade())
                }
            }.frame(maxWidth: .infinity)
            PrecisionRuler(title: "\(range.title)亮度", value: Binding(get: { grade.lightness }, set: { value in
                change { $0.lightness = value }
            }), range: -1...1, neutral: 0, checkpoint: store.checkpoint).id(range)
        }.disabled(store.busy)
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced).weight(.medium)).foregroundStyle(.primary)
        }
    }

    private var wheel: some View {
        GeometryReader { geometry in
            let radius = geometry.size.width / 2
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.38), .clear], center: .center, startRadius: 4, endRadius: radius))
                Circle().strokeBorder(.white.opacity(0.33), lineWidth: 1)
                Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1).padding(radius * 0.47)
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    var axes = Path()
                    axes.move(to: CGPoint(x: center.x - 7, y: center.y)); axes.addLine(to: CGPoint(x: center.x + 7, y: center.y))
                    axes.move(to: CGPoint(x: center.x, y: center.y - 7)); axes.addLine(to: CGPoint(x: center.x, y: center.y + 7))
                    context.stroke(axes, with: .color(.white.opacity(0.46)))
                }
                Circle().fill(.black.opacity(0.34)).overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 15, height: 15).shadow(radius: 2)
                    .offset(x: grade.x * radius * 0.9, y: grade.y * radius * 0.9)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touchingWheel) { _, state, _ in state = true }
                .onChanged { drag in
                    if !started { store.checkpoint(); started = true }
                    let x = (drag.location.x - radius) / (radius * 0.9)
                    let y = (drag.location.y - radius) / (radius * 0.9)
                    let magnitude = max(1, hypot(x, y))
                    change { $0.x = x / magnitude; $0.y = y / magnitude }
                })
            .onChange(of: touchingWheel) { _, active in if !active { started = false } }
            .accessibilityLabel("\(range.title)色轮，拖动方向选色，距离中心决定强度")
        }
    }

    private func change(_ update: (inout WheelGrade) -> Void) {
        store.update({ project in
            var grading = project.adjustments.colorGrading ?? ColorGrading()
            var wheel = grading[range]
            update(&wheel)
            grading[range] = wheel
            project.adjustments.colorGrading = grading
        }, render: true)
    }
}

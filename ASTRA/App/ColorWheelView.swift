import SwiftUI

struct ColorWheelsPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var range = GradeRange.shadows
    @State private var dragging = false

    private var grade: WheelGrade { store.project?.adjustments.colorGrading?[range] ?? WheelGrade() }

    var body: some View {
        VStack(spacing: 12) {
            Picker("色轮范围", selection: $range) {
                ForEach(GradeRange.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            wheel.frame(width: 124, height: 124)
            AdjustmentSlider(title: "\(range.title)亮度", value: Binding(get: { grade.lightness }, set: { value in
                change { $0.lightness = value }
            }), range: -1...1, checkpoint: store.checkpoint)
            Button("重置\(range.title)色轮") {
                store.checkpoint()
                change { $0 = WheelGrade() }
            }.font(.caption).disabled(grade == WheelGrade())
        }.disabled(store.busy)
    }

    private var wheel: some View {
        GeometryReader { geometry in
            let radius = geometry.size.width / 2
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.45), .clear], center: .center, startRadius: 1, endRadius: radius))
                Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1)
                Circle().strokeBorder(.white, lineWidth: 2).frame(width: 13, height: 13)
                    .shadow(radius: 2).offset(x: grade.x * radius * 0.9, y: grade.y * radius * 0.9)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if !dragging { store.checkpoint(); dragging = true }
                let x = (drag.location.x - radius) / (radius * 0.9)
                let y = (drag.location.y - radius) / (radius * 0.9)
                let magnitude = max(1, hypot(x, y))
                change { $0.x = x / magnitude; $0.y = y / magnitude }
            }.onEnded { _ in dragging = false })
            .accessibilityLabel("\(range.title)色轮")
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

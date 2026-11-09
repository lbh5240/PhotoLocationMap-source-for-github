import SwiftUI

// The photo stays neutral. Accent color is reserved for controls and readings.
enum EditorStyle {
    static let backdrop = Color(red: 0.038, green: 0.043, blue: 0.059)
    static let surface = Color(red: 0.076, green: 0.086, blue: 0.112)
    static let line = Color.white.opacity(0.085)
    static let accent = Color(red: 0.64, green: 0.78, blue: 1)

    static func number(_ value: Double, precision: Int) -> String {
        let threshold = pow(10.0, -Double(precision)) / 2
        return String(format: "%.*f", precision, abs(value) < threshold ? 0 : value)
    }
}

extension View {
    func editorCard(selected: Bool, tint: Color = EditorStyle.accent) -> some View {
        foregroundStyle(selected ? tint : .secondary)
            .background(selected ? tint.opacity(0.12) : EditorStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? tint.opacity(0.32) : EditorStyle.line))
    }
}

struct PrecisionRuler: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    var step: Double = 0.01
    var precision = 2
    var unit = ""
    var tint = EditorStyle.accent
    var checkpoint: () -> Void = {}
    @State private var anchor: Double?
    @GestureState private var adjusting = false

    private var span: Double { range.upperBound - range.lowerBound }
    private var reading: String { EditorStyle.number(value, precision: precision) + (unit.isEmpty ? "" : " \(unit)") }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(reading)
                    .font(.system(.headline, design: .monospaced).weight(.semibold))
                    .contentTransition(.numericText())
                    .foregroundStyle(tint)
                    .accessibilityIdentifier("ruler-value")
            }.padding(.horizontal, 12).padding(.top, 10)
            HStack(spacing: 4) {
                nudgeButton(-1, symbol: "minus", label: "减小")
                GeometryReader { geometry in
                    Canvas { context, size in
                        let middle = size.width / 2
                        let position = (value - range.lowerBound) / span
                        let scale = size.width * 1.9
                        for index in 0...50 {
                            let x = middle + (Double(index) / 50 - position) * scale
                            guard x >= 1, x < size.width - 1 else { continue }
                            let major = index.isMultiple(of: 5)
                            let length: CGFloat = major ? 14 : 6
                            var tick = Path()
                            tick.move(to: CGPoint(x: x, y: 15 - length / 2))
                            tick.addLine(to: CGPoint(x: x, y: 15 + length / 2))
                            context.stroke(tick, with: .color(.white.opacity(major ? 0.46 : 0.20)), lineWidth: 1)
                            if major {
                                let mark = range.lowerBound + span * Double(index) / 50
                                let label = Text(EditorStyle.number(mark, precision: span < 1 ? precision : min(precision, 1)))
                                    .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                                context.draw(label, at: CGPoint(x: x, y: 31))
                            }
                        }
                        let cursor = CGRect(x: middle - 1, y: 3, width: 2, height: 24)
                        context.fill(Path(roundedRect: cursor, cornerRadius: 1), with: .color(tint))
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 4)
                        .updating($adjusting) { _, state, _ in state = true }
                        .onChanged { drag in
                            if anchor == nil {
                                guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                                anchor = value
                                checkpoint()
                            }
                            let delta = Double(drag.translation.width / max(geometry.size.width, 1)) * span / 1.9
                            set((anchor ?? value) - delta)
                        })
                    .onChange(of: adjusting) { _, active in if !active { anchor = nil } }
                    .onTapGesture(count: 2) { reset() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityValue(reading)
                    .accessibilityHint("向上或向下轻扫微调，双击复位")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: nudge(1)
                        case .decrement: nudge(-1)
                        @unknown default: break
                        }
                    }
                    .accessibilityAction(named: Text("复位")) { reset() }
                }.frame(height: 40)
                nudgeButton(1, symbol: "plus", label: "增大")
            }.padding(.horizontal, 5)
        }
        .background(EditorStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EditorStyle.line))
    }

    private func set(_ number: Double) {
        value = min(range.upperBound, max(range.lowerBound, number))
    }

    private func nudge(_ direction: Double) {
        let next = min(range.upperBound, max(range.lowerBound, value + direction * step))
        guard next != value else { return }
        checkpoint()
        set(next)
    }

    private func reset() {
        guard value != neutral else { return }
        checkpoint()
        set(neutral)
    }

    private func nudgeButton(_ direction: Double, symbol: String, label: String) -> some View {
        Button { nudge(direction) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("\(label)\(title)")
            .disabled(direction < 0 ? value <= range.lowerBound : value >= range.upperBound)
    }
}

struct EditorParameter: Identifiable {
    let title: String
    let symbol: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let neutral: Double
    var step = 0.01
    var precision = 2
    var unit = ""
    var enabled = true
    var id: String { title }
}

struct ParameterInspector: View {
    let parameters: [EditorParameter]
    var tint = EditorStyle.accent
    var checkpoint: () -> Void
    @State private var active = 0

    var body: some View {
        let index = min(active, parameters.count - 1)
        let parameter = parameters[index]
        VStack(spacing: 9) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(parameters.count, 3)), spacing: 6) {
                ForEach(Array(parameters.enumerated()), id: \.element.id) { number, item in
                    Button { active = number } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(item.title, systemImage: item.symbol)
                                .font(.caption2.weight(.medium)).lineLimit(1)
                            Text(EditorStyle.number(item.value.wrappedValue, precision: item.precision) + item.unit)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .editorCard(selected: index == number, tint: tint)
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(index == number ? .isSelected : [])
                        .accessibilityIdentifier("parameter-\(number)")
                }
            }
            PrecisionRuler(title: parameter.title, value: parameter.value, range: parameter.range, neutral: parameter.neutral,
                           step: parameter.step, precision: parameter.precision, unit: parameter.unit, tint: tint,
                           checkpoint: checkpoint).disabled(!parameter.enabled).id(parameter.id)
        }
    }
}

import SwiftUI
import ZoraCore

/// Remote-shooting helpers built only from commands the camera declared: shutter, property
/// writes, DeviceReady and manual focus drive. Each run is cancellable between commands.
struct ShootingToolsView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case timer = "延时快门", interval = "间隔拍摄", bracket = "包围曝光", focus = "焦点包围"
        var id: Self { self }
    }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("toolTimerDelay") private var timerDelay = 3.0
    @AppStorage("toolShots") private var shots = 30
    @AppStorage("toolInterval") private var interval = 10.0
    @AppStorage("toolStartDelay") private var startDelay = 0.0
    @AppStorage("toolBracketFrames") private var bracketFrames = 3
    @AppStorage("toolBracketSpacing") private var bracketSpacing = 3
    @AppStorage("toolBracketCode") private var bracketCode = 0x5010
    @AppStorage("toolStackShots") private var stackShots = 10
    @AppStorage("toolStackSteps") private var stackSteps = 50
    @AppStorage("toolStackNear") private var stackNear = false
    @State private var tool = Tool.timer
    private var bracketCandidates: [CameraProperty] {
        model.properties.filter { BracketPlan.supportedCodes.contains($0.code) && $0.writable && $0.options.count >= 3 }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Picker("工具", selection: $tool) { ForEach(Tool.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented) }
                switch tool {
                case .timer:
                    Section {
                        Stepper("延时 \(Int(timerDelay)) 秒", value: $timerDelay, in: 1...60, step: 1)
                        Button("开始倒计时", systemImage: "timer") { start { try await model.runInterval(.selfTimer(timerDelay)) } }
                    } footer: { Text("倒计时由手机计时，到点发送一次快门。适合避免按快门带来的机身抖动，或拍自己。") }
                case .interval:
                    Section {
                        Stepper("张数 \(shots)", value: $shots, in: 2...9999, step: shots < 100 ? 1 : 10)
                        Stepper("间隔 \(Int(interval)) 秒", value: $interval, in: 1...3600, step: interval < 60 ? 1 : 10)
                        Stepper("开始前等待 \(Int(startDelay)) 秒", value: $startDelay, in: 0...3600, step: 5)
                        LabeledContent("预计总时长", value: Duration.seconds(startDelay + Double(max(shots - 1, 0)) * interval).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                        Button("开始间隔拍摄", systemImage: "clock.arrow.2.circlepath") { start { try await model.runInterval(IntervalPlan(shots: shots, interval: interval, startDelay: startDelay)) } }
                    } footer: { Text("请保持 ZORA 在前台并接上电源。若一次拍摄（含长曝光写卡）超过间隔，会跳过错过的时间点，不会连续补拍。开启自动导入时，空档内会顺带导入新照片。") }
                case .bracket:
                    Section {
                        if bracketCandidates.isEmpty {
                            Text("相机当前没有可写、且有多个可选值的曝光补偿 / 快门 / ISO。请切换到可调整这些参数的拍摄模式后，在拍摄页点“刷新”。").foregroundStyle(.secondary)
                        } else {
                            Picker("包围参数", selection: $bracketCode) { ForEach(bracketCandidates) { Text($0.title).tag(Int($0.code)) } }
                            Picker("张数", selection: $bracketFrames) { ForEach([3, 5, 7, 9], id: \.self) { Text("\($0) 张").tag($0) } }
                            Stepper("间隔 \(bracketSpacing) 档", value: $bracketSpacing, in: 1...12)
                            if let property = bracketCandidates.first(where: { Int($0.code) == bracketCode }) {
                                let preview = (try? BracketPlan(property: property, frames: bracketFrames, spacing: bracketSpacing))?.values.map(property.label(for:)).joined(separator: "  ·  ")
                                Text(preview ?? "超出相机允许范围，请减少张数或间隔").font(.caption.monospacedDigit()).foregroundStyle(preview == nil ? Color.red : .secondary)
                            }
                            Button("开始包围曝光", systemImage: "plusminus") { start { try await model.runBracket(code: UInt16(bracketCode), frames: bracketFrames, spacing: bracketSpacing) } }
                                .disabled(!bracketCandidates.contains(where: { Int($0.code) == bracketCode }))
                        }
                    } footer: { Text("“档”指相机列出的相邻可选值（通常 1/3 EV）。只使用相机声明的值，拍完恢复原设置。可用于 HDR 合成。") }
                case .focus:
                    Section {
                        if model.canFocusStack {
                            Stepper("张数 \(stackShots)", value: $stackShots, in: 2...300)
                            Stepper("每张调焦步长 \(stackSteps)", value: $stackSteps, in: 1...2000, step: stackSteps < 100 ? 5 : 50)
                            Toggle("由远向近移动", isOn: $stackNear)
                            Button("开始焦点包围", systemImage: "square.3.layers.3d") {
                                start { try await model.runFocusStack(FocusStackPlan(shots: stackShots, steps: UInt32(stackSteps), towardNear: stackNear)) }
                            }
                        } else {
                            Text("相机需要同时声明拍照、实时取景和手动调焦指令，且镜头支持电子调焦。").foregroundStyle(.secondary)
                        }
                    } footer: { Text("先对焦在最近（或最远）的主体上，再开始。每张之间按固定步长驱动镜头，到达行程边界会自动结束。用于微距/产品景深合成。") }
                }
                if let status = model.sequenceStatus {
                    Section { HStack { ProgressView(); Text(status).monospacedDigit(); Spacer(); Button("停止", role: .destructive) { model.cancelOperation() } } }
                }
            }.navigationTitle("拍摄工具").toolbar { Button("完成") { dismiss() } }
        }
    }
    private func start(_ run: @escaping @MainActor () async throws -> Void) {
        model.perform(run)
    }
}

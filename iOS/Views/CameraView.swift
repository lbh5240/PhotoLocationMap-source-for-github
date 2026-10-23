import SwiftUI
import ZoraCore

struct CameraView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var showFiles = false
    @State private var grid = true
    @State private var peaking = false
    @State private var zebra = false
    @State private var focusSteps = 100
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ZORA").font(.system(size: 28, weight: .black, design: .rounded)).tracking(5)
                            Text("��Ŀ�⣬�����˿̡�").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { connecting = true } label: {
                            Label(model.device == nil ? "�������" : model.device!.model, systemImage: model.device == nil ? "wifi.slash" : "wifi")
                                .font(.caption.weight(.medium)).padding(12).zoraGlass()
                        }.accessibilityIdentifier("connectCamera")
                    }
                    VStack(spacing: 0) {
                        ZStack {
                            Color.black
                            if let preview = model.preview, model.streaming, let image = UIImage(data: preview.jpeg) {
                                Image(uiImage: image).resizable().scaledToFit()
                                if peaking, let data = preview.peakingPNG, let overlay = UIImage(data: data) { Image(uiImage: overlay).resizable().scaledToFit() }
                                if zebra, let data = preview.zebraPNG, let overlay = UIImage(data: data) { Image(uiImage: overlay).resizable().scaledToFit() }
                                if grid { GridOverlay() }
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "viewfinder").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(Color.zoraAmber)
                                    Text(model.device == nil ? "�ȴ���� Nikon Z7 II" : "׼����ʼʵʱȡ��").font(.headline)
                                    Text("����������������ʵͼ�����ʾ").font(.caption).foregroundStyle(.secondary)
                                }.padding()
                            }
                        }.aspectRatio(3/2, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 22))
                        HStack {
                            Label(model.streaming ? "LIVE �� �������" : "STANDBY", systemImage: model.streaming ? "circle.fill" : "circle")
                                .foregroundStyle(model.streaming ? Color.zoraAmber : .secondary)
                            Spacer()
                            Text("NIKON Z7 II �� ʵ������").foregroundStyle(.secondary)
                        }.font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.top, 10)
                    }
                    HStack(spacing: 14) {
                        monitorButton("����", icon: "grid", enabled: $grid)
                        monitorButton("��ֵ", icon: "waveform.path", enabled: $peaking)
                        monitorButton("������", icon: "line.3.horizontal", enabled: $zebra)
                    }
                    if let preview = model.preview, model.streaming {
                        VStack(alignment: .leading, spacing: 8) {
                            HistogramView(bins: preview.histogram).frame(height: 52)
                            Text("Ԥ��ֱ��ͼ �� �������� \(preview.clippedFraction*100, specifier: "%.1f")% �� �࿴������ʾͼ��")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.zoraPanel()
                    }
                    HStack(spacing: 32) {
                        Button { model.perform { await model.stopStream(); try await model.camera.autoFocus() } } label: { Image(systemName: "scope").font(.title2) }
                            .disabled(model.device?.operations.contains(PTPOperation.autoFocus) != true || model.busy).accessibilityLabel("�Զ��Խ�")
                        Button { model.perform { try await model.capture() } } label: {
                            Circle().fill(Color.zoraAmber).frame(width: 68, height: 68)
                                .padding(6).overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 2))
                        }.disabled(model.device?.canCapture != true || model.busy).accessibilityLabel("�ͷſ���")
                        Button { model.perform { if model.streaming { await model.stopStream() } else { try await model.startStream() } } } label: {
                            Image(systemName: model.streaming ? "stop.circle" : "play.circle").font(.title)
                        }.disabled(model.device?.canLiveView != true || model.busy).accessibilityLabel(model.streaming ? "ֹͣȡ��" : "��ʼȡ��")
                    }.padding(14).frame(maxWidth: .infinity).zoraGlass()
                    if let device = model.device {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("\(model.connectionType ?? "���") �� ��չ����", systemImage: model.connectionType == "USB" ? "cable.connector" : "wifi").font(.headline)
                            if device.operations.contains(PTPOperation.remoteControl) {
                                Button(model.remoteControl ? "�ͷ��������" : "�ӹ��������") { model.perform { try await model.setRemoteControl(!model.remoteControl) } }.disabled(model.busy)
                                Text("USB ȡ����������ܾ������Ƚӹܿ��ƣ��������ͷţ��ָ�����������") .font(.caption).foregroundStyle(.secondary)
                            }
                            if device.canRecordMovie {
                                HStack {
                                    Button("��ʼ¼��", systemImage: "record.circle") { model.perform { try await model.setMovieRecording(true) } }
                                    Spacer()
                                    Button("����¼��", systemImage: "stop.circle") { model.perform { try await model.setMovieRecording(false) } }
                                }.disabled(model.busy)
                                Text(model.recordingRequested ? "��ʼ¼��ָ���ѱ����ܣ��������ָʾȷ��¼��" : "�����������ѡ����Ƶģʽ���ٷ���¼��ָ��") .font(.caption).foregroundStyle(.secondary)
                            }
                            if device.operations.contains(PTPOperation.manualFocus) {
                                Stepper("�������� \(focusSteps)", value: $focusSteps, in: 1...1000, step: 1)
                                HStack {
                                    Button("�������", systemImage: "arrow.down.right.and.arrow.up.left") { model.perform { try await model.driveFocus(near: true, steps: UInt32(focusSteps)) } }
                                    Spacer()
                                    Button("������Զ", systemImage: "arrow.up.left.and.arrow.down.right") { model.perform { try await model.driveFocus(near: false, steps: UInt32(focusSteps)) } }
                                }.disabled(model.busy)
                                Text("��Ծ�ͷ����������������ϵȡ���ھ�ͷ�������ڼ����ͣͼ����") .font(.caption).foregroundStyle(.secondary)
                            }
                            if device.operations.contains(PTPOperation.terminateCapture) {
                                Button("��ֹ���� / ���ع�", systemImage: "stop.hand") { model.perform { await model.stopStream(); try await model.camera.terminateCapture() } }.disabled(model.busy)
                            }
                        }.zoraPanel()
                    }
                    if !model.properties.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("�ع���ɫ��").font(.headline)
                            ForEach(model.properties) { property in PropertyRow(property: property) }
                        }.zoraPanel()
                    }
                    Button("�������洢��", systemImage: "sdcard") { showFiles = true }
                        .disabled(model.device == nil || model.busy)
                    if let progress = model.connectionProgress { Label(progress, systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(Color.zoraAmber) }
                    if model.connectivity.bluetooth.authenticated {
                        HStack {
                            Label("��������֤", systemImage: "checkmark.shield")
                            Spacer()
                            if let battery = model.connectivity.bluetooth.battery { Label("\(battery)%", systemImage: "battery.100percent") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Text("���ӡ��ع⡢�Խ���ȡ���Ŀ�����ȡ���ڹ̼������������������֤�� Wi-Fi �����ѽ�����ʵЭ�飬Z7 II ��������Դ���֤��")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(20)
            }.background(Color.zoraBackground).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $connecting) { ConnectionView() }
                .sheet(isPresented: $showFiles) { CameraFilesView() }
        }
    }
    private func monitorButton(_ title: String, icon: String, enabled: Binding<Bool>) -> some View {
        Button { enabled.wrappedValue.toggle() } label: {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(enabled.wrappedValue ? Color.zoraAmber : .secondary).padding(12).frame(maxWidth: .infinity)
        }.zoraGlass().accessibilityAddTraits(enabled.wrappedValue ? .isSelected : [])
    }
}

private struct GridOverlay: View {
    var body: some View { Canvas { context, size in
        var p = Path()
        for n in 1...2 {
            let x = size.width*CGFloat(n)/3, y = size.height*CGFloat(n)/3
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
    }.allowsHitTesting(false) }
}

struct HistogramView: View {
    let bins: [Int]
    var body: some View { Canvas { context, size in
        let maximum = max(1, bins.max() ?? 1)
        var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
        for (i, count) in bins.enumerated() {
            path.addLine(to: CGPoint(x: CGFloat(i)*size.width/255, y: size.height*(1-CGFloat(count)/CGFloat(maximum))))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
        context.fill(path, with: .color(.zoraAmber.opacity(0.8)))
    }.accessibilityLabel("ͼ������ֱ��ͼ") }
}

private struct PropertyRow: View {
    @Environment(AppModel.self) private var model
    let property: CameraProperty
    @State private var text = ""
    var body: some View {
        HStack {
            Text(property.title).font(.caption)
            Spacer()
            if !property.allowed.isEmpty && property.writable {
                Menu("\(property.current)") {
                    ForEach(property.allowed, id: \.self) { value in Button("\(value)") { model.perform { try await model.set(property, value: value) } } }
                }
            } else {
                TextField("\(property.current)", text: $text).multilineTextAlignment(.trailing).frame(width: 90).keyboardType(.numbersAndPunctuation)
                Button("����") {
                    guard let value = Int64(text) else { model.error = "��������������"; return }
                    model.perform { try await model.set(property, value: value) }
                }.disabled(!property.writable || model.busy)
            }
        }
    }
}

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cameraHost") private var host = "192.168.1.1"
    @State private var ssid = ""
    @State private var password = ""
    @State private var connectionMode = 0
    var body: some View {
        @Bindable var bluetooth = model.connectivity.bluetooth
        @Bindable var settings = model
        NavigationStack {
            Form {
                Section {
                    Picker("���ӷ�ʽ", selection: $connectionMode) { Text("����").tag(0); Text("USB ����").tag(1) }.pickerStyle(.segmented).accessibilityIdentifier("connectionMode")
                }
                if connectionMode == 1 {
                    Section("USB ����������") {
                        Text("ʹ��֧�����ݴ���� USB-C ������ iPhone/iPad �� Z7 II�����������Lightning �豸����� USB ת���������粻��ʱʹ�ô�����ת������")
                        Button("���� USB ���", systemImage: "cable.connector") { Task { await model.usb.search() } }.accessibilityIdentifier("searchUSBCamera")
                        Text(model.usb.status).font(.caption).accessibilityIdentifier("usbConnectionStatus")
                        ForEach(model.usb.cameras) { camera in
                            Button(camera.name) { model.perform { try await model.connectUSB(camera.id); dismiss() } }.disabled(model.busy)
                        }
                        if model.connectionType == "USB" { Button("�Ͽ� USB �Ự") { model.perform { try await model.disconnect() } }.disabled(model.busy) }
                        Text("�״����������ý�������Ȩ�ޡ�USB ���Ӳ���Ҫ��� Wi-Fi�����ӳɹ��������㡢ȡ�����ļ����ɫ���ܡ���ʵ�������谴����͹̼����ա�") .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                Section("1 �� ��������뻽��") {
                    Text("�״����ӣ��� Z7 II �п����������������豸 �� ��ԣ�������������ɨ�貢ѡ���������ϵͳ�������ʾȷ������롣")
                    Label(bluetooth.status, systemImage: bluetooth.authenticated ? "checkmark.shield" : "antenna.radiowaves.left.and.right").font(.caption)
                    Button("���� Nikon ���", systemImage: "dot.radiowaves.left.and.right") { bluetooth.scan() }.disabled(bluetooth.working || bluetooth.authenticated)
                    ForEach(bluetooth.nearby.sorted(by: { $0.rssi > $1.rssi })) { item in
                        Button { bluetooth.connect(item.id) } label: {
                            HStack { Text(item.name); Spacer(); Text("\(item.rssi) dBm").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(bluetooth.working || bluetooth.authenticated)
                    }
                    if bluetooth.identity != nil {
                        Button("�����ѱ������") { bluetooth.retrySaved() }.disabled(bluetooth.working || bluetooth.authenticated)
                        Toggle("�Զ�������������", isOn: $bluetooth.autoReconnect)
                        Toggle("ǰ̨���Ӻ��Զ����Ѳ����� Wi-Fi", isOn: $settings.autoWake)
                        Button("���Ѳ��������", systemImage: "bolt.horizontal.circle") { model.perform { try await model.wakeAndConnect(); dismiss() } }
                            .disabled(!bluetooth.authenticated || model.busy)
                        Button("ͬ�����ʱ�������") { Task { await bluetooth.refreshTelemetry() } }.disabled(!bluetooth.authenticated)
                        if let battery = bluetooth.battery { Label("������� \(battery)%", systemImage: "battery.100percent") }
                        Button("�Ͽ�����") { bluetooth.disconnect() }
                        Button("���Ǳ����������", role: .destructive) { bluetooth.disconnect(forget: true) }
                    }
                    DisclosureGroup("�״�ϵͳ���������˵��") {
                        Text("Nikon ��֤��ɲ�����ϵͳ����ɡ��������Ҫ����ԣ��ɴ�ϵͳ���ѡ�������� iPhone ����������ȷ��������ٷ������������� iOS/�����Ͽ��ܲ���ʾϵͳѡ������")
                        Button("��ϵͳ���ѡ����") { bluetooth.showSystemPairing() }
                        Text("�Զ�������Ҫ����������ֿ������ػ����ӻ���������ػ�ʱ���͡�����Ӱ�졣����ģʽ��ȡ����ء�ǿ���˳� App ��ϵͳ��̨����ʱ�޷���֤���ѡ���̨�ָ�ֻ��������������Wi-Fi �л���ǰ̨��ɡ�")
                    }.font(.caption)
                }
                Section("2 �� ������� Wi-Fi") {
                    Text("������˵��п��������������豸/Wi-Fi�������� iPhone �����м�������ȵ㣬Ҳ�����·����������ʾ�� SSID��")
                    TextField("��� SSID", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Wi-Fi ����", text: $password)
                    Button("�������������Կ�״�") { model.perform { try model.saveCameraWiFi(ssid: ssid, password: password, host: host); password = "" } }
                        .disabled(model.busy || !bluetooth.authenticated || ssid.isEmpty)
                    Text("�״α���һ���ȵ���Ϣ�������������������ν����ӡ�iOS ������Ҫ��ȷ�ϼ������硣���벻����������־��") .font(.caption).foregroundStyle(.secondary)
                    Button("����� Wi-Fi") { model.perform { try await model.connectivity.join(ssid: ssid, password: password); password = "" } }.disabled(model.busy || ssid.isEmpty)
                }
                Section("3 �� �ֶ� PTP/IP ���� / �����ַ") {
                    TextField("��� IP / ������", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("Ĭ�ϵ�ַֻ�ǿɱ༭����㡣�밴�����ǰ����ʵ�ʵ�ַ��д��15740 �˿ڻ����Ҫ�������̼����졣")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("������ʵ����") { model.perform { try await model.connect(host: host); dismiss() } }.disabled(model.busy)
                    if model.device != nil { Button("�Ͽ�����", role: .destructive) { model.perform { try await model.disconnect() } } }
                }
                }
                if let progress = model.connectionProgress { Section { ProgressView(progress) } }
                Section("�������") {
                    Text("�׶Σ�\(bluetooth.state.rawValue) �� PTP��\(model.device == nil ? "δ����" : "����֤")").font(.caption)
                    ShareLink(item: bluetooth.diagnostics.joined(separator: "\n")) { Label("��������������������", systemImage: "square.and.arrow.up") }
                    DisclosureGroup("����¼�") {
                        ForEach(Array(bluetooth.diagnostics.suffix(12).enumerated()), id: \.offset) { _, line in Text(line).font(.caption2).textSelection(.enabled) }
                    }
                    DisclosureGroup("����¼�") {
                        ForEach(Array(model.protocolEvents.suffix(12).enumerated()), id: \.offset) { _, event in
                            Text(String(format: "0x%04X", event.code) + " �� " + event.parameters.map(String.init).joined(separator: ", ")).font(.caption2)
                        }
                    }
                }
            }.navigationTitle("�������").toolbar { ToolbarItem(placement: .confirmationAction) { Button("���") { dismiss() } } }
        }
    }
}

private struct CameraFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var settings = model
        NavigationStack {
            List {
                Text("���洢����ҳ��ȡ��֧�ַֿ��ȡ����������س��� 64 MiB �� RAW�����ڵ��� 4 GiB ����չ���������� Files ���롣") .font(.caption).foregroundStyle(.secondary)
                Button("ˢ������ļ�") { model.perform { try await model.listCameraFiles() } }.disabled(model.busy)
                if model.cameraFilesChanged { Label("���Ŀ¼�б仯����ˢ�º�������", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(Color.zoraAmber) }
                if !model.cardStorageIDs.isEmpty {
                    Picker("�洢��", selection: $settings.selectedStorage) {
                        ForEach(model.cardStorageIDs, id: \.self) { id in Text(model.storages.first(where: { $0.id == id })?.description ?? String(format: "�洢�� %08X", id)).tag(Optional(id)) }
                    }.onChange(of: model.selectedStorage) { _, _ in model.perform { try await model.loadCameraPage(reset: true) } }.disabled(model.busy)
                }
                ForEach(model.storages) { storage in
                    VStack(alignment: .leading) {
                        Text(storage.description.isEmpty ? storage.label : storage.description)
                        Text("���� \(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.freeBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.capacity), countStyle: .file))") .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let data = model.cameraThumbnail, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240) }
                ForEach(model.cameraObjects) { object in
                    HStack { VStack(alignment: .leading) { Text(object.filename); Text(ByteCountFormatter.string(fromByteCount: Int64(object.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if model.device?.operations.contains(PTPOperation.thumbnail) == true { Button("Ԥ��") { model.perform { try await model.loadThumbnail(object) } }.disabled(model.busy) }
                        Button("����") { model.perform { try await model.download(object) } }.disabled(model.busy || object.format == 0x3001) }
                }
                Text("����ʾ \(model.cameraObjects.count) / \(model.objectTotal) ��").font(.caption).foregroundStyle(.secondary)
                if model.nextObjectOffset != nil { Button("������һҳ") { model.perform { try await model.loadCameraPage(reset: false) } }.disabled(model.busy) }
            }.navigationTitle("����ļ�").toolbar { Button("���") { dismiss() } }
        }
    }
}

import Foundation
import CoreBluetooth
import Observation
import ExternalAccessory
import ZoraCore

@MainActor @Observable final class NikonBluetooth: NSObject, NikonBLECommandSink, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum State: String { case idle, scanning, connecting, authenticating, registering, systemPairing, authenticated, needsConfirmation, disconnected, failed }
    struct Nearby: Identifiable { let id: UUID; let name: String; let rssi: Int }
    private static func uuid(_ short: String) -> CBUUID { CBUUID(string: "0000\(short)-3dd4-4255-8d62-6dc7b9bd5561") }
    private static let service = uuid("de00"), pairing = uuid("2000"), name = uuid("2002")
    private static let wake = uuid("2005"), time = uuid("2006"), control = uuid("2008"), battery = uuid("2a19")
    private(set) var state = State.idle
    private(set) var status = "尚未连接蓝牙"
    private(set) var step = 0
    private(set) var nearby: [Nearby] = []
    private(set) var battery: Int?
    private(set) var identity: NikonBLEIdentity?
    private(set) var diagnostics: [String] = []
    private(set) var working = false
    private(set) var automationGeneration = UUID()
    var autoReconnect = UserDefaults.standard.object(forKey: "bleAutoReconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "bleAutoReconnect"); if !autoReconnect { retryTask?.cancel() } }
    }
    private var central: CBCentralManager?
    private var devices: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pending: [String: (UUID, CheckedContinuation<Data, Error>)] = [:]
    private var frames: [Data] = [], controls: [Data] = []
    private var sessionToken = UUID()
    private var handshake: NikonBLEHandshake?
    private var registration = NikonBLERegistration()
    private var scanTask: Task<Void, Never>?, pairingTask: Task<Void, Never>?, retryTask: Task<Void, Never>?, keepAlive: Task<Void, Never>?, controlTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var userDisconnected = false, foreground = true, resumeRequested = false, scanRequested = false
    private var pickerPresented = false
    private var systemPairingEvidenceForSerial: String?
    private var gattBusy = false
    private var gattWaiters: [CheckedContinuation<Void, Error>] = []
    var onAuthenticated: (@MainActor () -> Void)?
    var authenticated: Bool { state == .authenticated && registration.ready }
    var systemPairingConfirmed: Bool {
        guard let serial = identity?.serial else { return false }
        return authenticated || systemPairingEvidenceForSerial == serial
    }

    override init() {
        identity = try? Keychain.loadValue(NikonBLEIdentity.self, id: "nikon.ble.identity")
        super.init()
        diagnostics = Array((UserDefaults.standard.stringArray(forKey: "bluetoothDiagnostics") ?? []).suffix(100))
        log("ZORA \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") · \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if identity != nil { _ = manager() }
    }
    private func log(_ value: String) {
        diagnostics.append("\(Date().formatted(date: .omitted, time: .standard)) · \(value)")
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count-100) }
        UserDefaults.standard.set(diagnostics, forKey: "bluetoothDiagnostics")
    }
    private func phase(_ state: State, _ step: Int, _ message: String) { self.state = state; self.step = step; status = message; log(message) }
    private func manager() -> CBCentralManager {
        if let central { return central }
        let value = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "app.zora.camera.nikon.central", CBCentralManagerOptionShowPowerAlertKey: true])
        central = value; return value
    }
    func resume(foreground: Bool = true) {
        self.foreground = foreground
        guard foreground else { keepAlive?.cancel(); return }
        if authenticated { startKeepAlive(); return }
        guard autoReconnect, identity?.registrationVerified == true, !working, !userDisconnected, state != .needsConfirmation else { return }
        resumeRequested = true; if manager().state == .poweredOn { reconnectSaved() }
    }
    func scan() {
        guard !working, !authenticated, !pickerPresented else { return }
        userDisconnected = false; scanRequested = true; nearby = []; retryTask?.cancel(); scanTask?.cancel()
        let central = manager()
        guard central.state == .poweredOn else { status = "等待蓝牙授权或开启…"; return }
        scanRequested = false; phase(.scanning, 0, "搜索 Nikon 相机 · 请打开相机配对菜单")
        central.scanForPeripherals(withServices: foreground ? nil : [Self.service], options: nil)
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15)); guard !Task.isCancelled, let self else { return }
            central.stopScan(); if state == .scanning { phase(.idle, 0, nearby.isEmpty ? "未发现 Nikon，请检查配对菜单、相机电源和蓝牙" : "选择你的相机开始完整配对") }
        }
    }
    func connect(_ id: UUID) { begin(id, forceSystemPairing: false) }
    private func begin(_ id: UUID, forceSystemPairing: Bool) {
        guard !working, (!pickerPresented || state == .needsConfirmation), !authenticated else { return }
        guard manager().state == .poweredOn else { status = "请先开启蓝牙"; return }
        guard let p = devices[id] ?? manager().retrievePeripherals(withIdentifiers: [id]).first else { status = "已保存相机暂不可达，请重新扫描；配对身份不会被清除"; return }
        userDisconnected = false; scanRequested = false; resumeRequested = false; retryTask?.cancel(); scanTask?.cancel(); central?.stopScan()
        pairingTask?.cancel(); controlTask?.cancel(); keepAlive?.cancel()
        sessionToken = UUID(); let epoch = sessionToken
        clear(ZoraError.disconnected); working = true; peripheral = p; p.delegate = self
        let saved = identity?.peripheralID == id ? identity : nil
        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await authenticate(p, saved: saved)
                if forceSystemPairing { try await systemPairAndReauthenticate() }
                else {
                    do { try await finishRegistration(previouslyVerified: saved?.registrationVerified == true, systemPaired: systemPairingEvidenceForSerial == identity?.serial) }
                    catch ZoraError.timeout {
                        // A first enrollment can require classic pairing after releasing BLE.
                        try await systemPairAndReauthenticate()
                    }
                }
                try Task.checkCancellation(); guard epoch == sessionToken, registration.ready, let current = identity else { throw ZoraError.disconnected }
                let verified = NikonBLEIdentity(peripheralID: current.peripheralID, device: current.device, nonce: current.nonce, serial: current.serial, registrationVerified: true)
                try Keychain.saveValue(verified, id: "nikon.ble.identity"); identity = verified
                working = false; retryAttempt = 0; phase(.authenticated, 5, "蓝牙会话已验证 · 相机注册与校时请求已处理")
                startKeepAlive(); onAuthenticated?(); drainControl()
            } catch {
                guard epoch == sessionToken, !userDisconnected else { return }
                attention(error)
            }
        }
    }
    private func authenticate(_ p: CBPeripheral, saved: NikonBLEIdentity?) async throws {
        characteristics = [:]; frames = []; controls = []; handshake = nil; registration = NikonBLERegistration(); battery = nil
        peripheral = p; p.delegate = self
        if p.state == .disconnecting { _ = try await operation("disconnect", timeout: 12) {} }
        phase(.connecting, 1, "1/5 · 建立蓝牙链路（尚未完成配对）")
        _ = try await operation("connect", timeout: 35) {
            if p.state == .connected { self.finish("connect") } else { self.central?.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]) }
        }
        phase(.authenticating, 2, "2/5 · 发现服务并完成 Nikon 身份握手")
        _ = try await operation("services") { p.discoverServices([Self.service]) }
        guard let service = p.services?.first(where: { $0.uuid == Self.service }) else { throw ZoraError.unsupported("相机未提供 Nikon 智能设备服务") }
        _ = try await operation("characteristics") { p.discoverCharacteristics(nil, for: service) }
        guard characteristics[Self.name] != nil, characteristics[Self.control] != nil, characteristics[Self.time] != nil else { throw ZoraError.unsupported("缺少 Nikon 注册所需特征，不能将链路连接视为配对完成") }
        try await subscribe(Self.pairing); try await subscribe(Self.control)
        handshake = NikonBLEHandshake(identity: saved)
        try await write(handshake!.initial.data, to: Self.pairing)
        let challenge = try await nextPairingFrame()
        guard let response = try handshake?.receive(challenge) else { throw ZoraError.malformed("缺少 Nikon 认证响应") }
        try await write(response, to: Self.pairing)
        let confirmation = try await nextPairingFrame(); _ = try handshake?.receive(confirmation)
        guard let h = handshake, h.phase == .authenticated, let serial = h.serial else { throw ZoraError.disconnected }
        if let saved, saved.serial != serial { throw ZoraError.malformed("相机序列号与保存身份不同；请人工确认后重新配对") }
        let provisional = NikonBLEIdentity(peripheralID: p.identifier, device: h.initial.device, nonce: h.initial.nonce, serial: serial, registrationVerified: saved?.registrationVerified)
        try Keychain.saveValue(provisional, id: "nikon.ble.identity"); identity = provisional
        try await write(NikonBLEPayload.controllerName("ZORA Camera"), to: Self.name)
        log("Nikon 身份已认证并保存；继续处理相机注册，尚不启动 Wi-Fi")
    }
    private func finishRegistration(previouslyVerified: Bool, systemPaired: Bool) async throws {
        registration = NikonBLERegistration(previouslyVerified: previouslyVerified, systemPairingCompleted: systemPaired); registration.confirmName()
        phase(.registering, 4, "4/5 · 等待相机完成注册 · 确认两端配对码后请勿退出")
        // Send actual time, then service both time and connection requests. GPS bits remain intact.
        try await Task.sleep(for: .milliseconds(500)); try await write(NikonBLEPayload.time(Date()), to: Self.time); registration.confirmTime()
        if characteristics[Self.control]?.properties.contains(.read) == true {
            let data = try await read(Self.control); enqueueControl(data)
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if !controls.isEmpty { try await serviceControl(controls.removeFirst()) }
            else if registration.ready {
                // A quiet period catches connection requests that follow the clock request.
                do { let frame = try await nextControl(timeout: 2); try await serviceControl(frame) }
                catch ZoraError.timeout { return }
            } else { let frame = try await nextControl(timeout: 10); try await serviceControl(frame) }
        }
        throw ZoraError.timeout
    }
    private func serviceControl(_ data: Data) async throws {
        let request = try NikonControlRequest(data); registration.observe(request)
        log("相机请求 · 校时 \(request.wantsTime ? "是" : "否") / 建立连接 \(request.wantsConnection ? "是" : "否")")
        let receipt = try await NikonRegistrationExchange.respond(to: data, using: self)
        if receipt.timeProvided { registration.confirmTime() }
        registration.confirmAcknowledgment()
        if receipt.connectionProvided { registration.confirmConnection() }
    }
    func sendBLE(_ data: Data, characteristic: UInt16) async throws { try await write(data, to: Self.uuid(String(format: "%04x", characteristic))) }
    private func systemPairAndReauthenticate() async throws {
        guard foreground, let saved = identity, let p = peripheral else { throw ZoraError.unsupported("请回到前台继续系统配对；保存身份仍保留") }
        phase(.systemPairing, 3, "3/5 · 释放蓝牙链路后打开系统配对 · 请选择你的 Nikon 并确认相同配对码")
        if p.state != .disconnected { _ = try await operation("disconnect", timeout: 12) { self.central?.cancelPeripheralConnection(p) } }
        characteristics = [:]; frames = []; controls = []; handshake = nil
        #if targetEnvironment(simulator)
        throw ZoraError.unsupported("模拟器不能完成相机系统配对，请使用 iPhone")
        #else
        guard !pickerPresented else { throw ZoraError.unsupported("系统配对窗口尚未结束，请先完成或取消该窗口") }
        pickerPresented = true
        _ = try await operation("systemPair", timeout: 90, fatalTimeout: false) {
            EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [weak self] error in
                let value = error as NSError?
                let already = value?.domain == EABluetoothAccessoryPickerErrorDomain && value?.code == 0
                let message = value?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }; pickerPresented = false
                    if message == nil || already { systemPairingEvidenceForSerial = saved.serial; finish("systemPair") }
                    else { finish("systemPair", error: ZoraError.unsupported("系统配对未完成：\(message!)。请确认相机与 iPhone 上的配对码，然后重试")) }
                }
            }
        }
        for _ in 0..<50 where !foreground { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() }
        guard foreground else { throw ZoraError.unsupported("系统配对已返回，请回到前台继续验证") }
        try await authenticate(p, saved: saved)
        try await finishRegistration(previouslyVerified: false, systemPaired: true)
        #endif
    }
    private func operation(_ key: String, timeout: Int = 15, fatalTimeout: Bool = true, start: () -> Void) async throws -> Data {
        try Task.checkCancellation(); guard pending[key] == nil else { throw ZoraError.busy }
        let token = UUID(), epoch = sessionToken
        let result: Data = try await withCheckedThrowingContinuation { c in
            pending[key] = (token,c)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, sessionToken == epoch, pending[key]?.0 == token else { return }
                log("超时阶段：\(key)")
                if fatalTimeout { fail(ZoraError.timeout) } else { finish(key, error: ZoraError.timeout) }
            }
            start()
        }
        try Task.checkCancellation(); guard epoch == sessionToken else { throw CancellationError() }; return result
    }
    private func finish(_ key: String, data: Data = Data(), error: Error? = nil) {
        guard let (_,c) = pending.removeValue(forKey: key) else { return }
        if let error { c.resume(throwing: error) } else { c.resume(returning: data) }
    }
    private func withGATT<T: Sendable>(_ action: @MainActor () async throws -> T) async throws -> T {
        let epoch = sessionToken
        if gattBusy { try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in gattWaiters.append(c) } }
        else { gattBusy = true }
        defer { if epoch == sessionToken { if gattWaiters.isEmpty { gattBusy = false } else { gattWaiters.removeFirst().resume() } } }
        try Task.checkCancellation(); guard epoch == sessionToken else { throw CancellationError() }; return try await action()
    }
    private func subscribe(_ uuid: CBUUID) async throws {
        try await withGATT {
            guard let p = self.peripheral, let c = self.characteristics[uuid], c.properties.contains(.notify) || c.properties.contains(.indicate) else { throw ZoraError.unsupported("相机缺少注册通知特征") }
            _ = try await self.operation("notify:\(uuid)", timeout: 45) { p.setNotifyValue(true, for: c) }
        }
    }
    private func write(_ data: Data, to uuid: CBUUID) async throws {
        try await withGATT {
            guard let p = self.peripheral, p.state == .connected, let c = self.characteristics[uuid], c.properties.contains(.write) else { throw ZoraError.unsupported("相机缺少可确认写入的蓝牙特征 \(uuid.uuidString.prefix(8))") }
            _ = try await self.operation("write:\(uuid)", timeout: self.working ? 45 : 15) { p.writeValue(data, for: c, type: .withResponse) }
        }
    }
    private func read(_ uuid: CBUUID) async throws -> Data {
        try await withGATT {
            guard let p = self.peripheral, p.state == .connected, let c = self.characteristics[uuid], c.properties.contains(.read) else { throw ZoraError.unsupported("蓝牙特征不可读取") }
            return try await self.operation("read:\(uuid)") { p.readValue(for: c) }
        }
    }
    private func nextPairingFrame() async throws -> Data {
        if !frames.isEmpty { return frames.removeFirst() }; return try await operation("frame", timeout: 60) {}
    }
    private func nextControl(timeout: Int) async throws -> Data {
        if !controls.isEmpty { return controls.removeFirst() }; return try await operation("controlFrame", timeout: timeout, fatalTimeout: false) {}
    }
    private func enqueueControl(_ data: Data) {
        guard data.count == 2 else { log("忽略长度异常的注册请求"); return }
        if pending["controlFrame"] != nil { finish("controlFrame", data: data) }
        else if controls.last != data, controls.count < 32 { controls.append(data) }
        drainControl()
    }
    private func drainControl() {
        guard authenticated, !working, controlTask == nil, !controls.isEmpty else { return }
        let epoch = sessionToken
        controlTask = Task { [weak self] in
            guard let self else { return }; defer { if sessionToken == epoch { controlTask = nil } }
            do {
                while !controls.isEmpty, state == .authenticated, !Task.isCancelled { try await serviceControl(controls.removeFirst()) }
            } catch { if sessionToken == epoch, !Task.isCancelled { attention(error) } }
        }
    }
    func wakeWiFi() async throws {
        guard authenticated else { throw ZoraError.unsupported("相机配对注册尚未完成，不能提前切换到 Wi-Fi") }
        try await write(registration.wakeCommand(), to: Self.wake)
        status = "相机接受 Wi-Fi 唤醒写入 · 等待热点与 PTP 验证"; log(status)
    }
    func refreshTelemetry() async {
        guard authenticated, !working else { return }
        do {
            try await write(NikonBLEPayload.time(Date()), to: Self.time)
            if characteristics[Self.battery]?.properties.contains(.read) == true {
                let result = try await read(Self.battery); if result.count == 1, result[0] <= 100 { battery = Int(result[0]) }
            }
        } catch { log("校时/电量未完成：\(error.localizedDescription)") }
    }
    private func startKeepAlive() {
        keepAlive?.cancel(); guard foreground else { return }
        keepAlive = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled { guard let self, authenticated else { return }; await refreshTelemetry(); try? await Task.sleep(for: .seconds(45)) }
        }
    }
    func disconnect(forget: Bool = false) {
        sessionToken = UUID(); automationGeneration = UUID(); userDisconnected = true; scanRequested = false; resumeRequested = false
        pairingTask?.cancel(); controlTask?.cancel(); controlTask = nil; retryTask?.cancel(); scanTask?.cancel(); keepAlive?.cancel(); central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }; peripheral = nil; clear(ZoraError.disconnected)
        phase(.disconnected, 0, "蓝牙已断开；未完成的相机身份保留，可继续配对")
        if forget { Keychain.delete(id: "nikon.ble.identity"); Keychain.delete(id: "nikon.wifi"); identity = nil; status = "本机资料已移除；系统绑定请在 iPhone 蓝牙设置中忽略设备" }
    }
    private func clear(_ error: Error) {
        let values = pending.values.map { $0.1 }; pending.removeAll(); for c in values { c.resume(throwing: error) }
        let waiters = gattWaiters; gattWaiters = []; gattBusy = false; for c in waiters { c.resume(throwing: error) }
        handshake = nil; registration = NikonBLERegistration(); characteristics = [:]; frames = []; controls = []; working = false; battery = nil
    }
    private func attention(_ error: Error) {
        let message = error.localizedDescription; disconnect(); userDisconnected = false
        phase(.needsConfirmation, 3, "配对尚未完成：\(message)。请继续系统配对或在两端确认后重试，身份不会重置")
    }
    private func fail(_ error: Error) {
        let verified = identity?.registrationVerified == true
        disconnect(); userDisconnected = false; phase(verified ? .failed : .needsConfirmation, 0, error.localizedDescription)
        if verified { scheduleReconnect() }
    }
    private func scheduleReconnect() {
        guard autoReconnect, !userDisconnected, identity?.registrationVerified == true, central?.state == .poweredOn, let delay = NikonBLEPayload.reconnectDelay(attempt: retryAttempt) else { return }
        retryAttempt += 1; retryTask?.cancel()
        retryTask = Task { [weak self] in try? await Task.sleep(for: .seconds(delay)); guard !Task.isCancelled, let self else { return }; reconnectSaved() }
    }
    private func reconnectSaved() {
        guard let identity, central?.state == .poweredOn, !working, !authenticated, !userDisconnected, !pickerPresented else { return }
        begin(identity.peripheralID, forceSystemPairing: false)
    }
    func retrySaved() { userDisconnected = false; retryAttempt = 0; resumeRequested = true; if manager().state == .poweredOn { reconnectSaved() } }
    func showSystemPairing() {
        guard identity != nil else { status = "请先扫描并选择相机，完成 Nikon 身份握手"; return }
        guard !working, !pickerPresented else { status = "请先完成或取消当前配对步骤"; return }
        let id = identity!.peripheralID; disconnect(); userDisconnected = false; begin(id, forceSystemPairing: true)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            let requestedScan = scanRequested
            disconnect(); userDisconnected = false; scanRequested = requestedScan
            phase(.disconnected, 0, central.state == .unauthorized ? "请在设置中允许 ZORA 使用蓝牙" : "请开启蓝牙后继续配对"); return
        }
        if scanRequested { scan() } else if resumeRequested || (autoReconnect && identity?.registrationVerified == true && !userDisconnected) { reconnectSaved() }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard manufacturer.prefix(2) == Data([0x99,0x03]) || services.contains(Self.service) || p.identifier == identity?.peripheralID else { return }
        if let saved = identity, NikonAdvertisement.controllerID(manufacturer) == saved.device, saved.peripheralID != p.identifier {
            let rebound = NikonBLEIdentity(peripheralID: p.identifier, device: saved.device, nonce: saved.nonce, serial: saved.serial, registrationVerified: saved.registrationVerified)
            do { try Keychain.saveValue(rebound, id: "nikon.ble.identity"); identity = rebound; log("已定位保存身份的相机广播，后续仍校验相机序列号") } catch { log("相机标识更新未保存") }
        }
        devices[p.identifier] = p; nearby.removeAll { $0.id == p.identifier }
        nearby.append(Nearby(id: p.identifier, name: p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Nikon（未广播名称）", rssi: RSSI.intValue))
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { guard p === peripheral else { return }; finish("connect") }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { guard p === peripheral else { return }; fail(error ?? ZoraError.disconnected) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        if pending["disconnect"] != nil { finish("disconnect"); return }
        fail(error ?? ZoraError.disconnected)
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard autoReconnect, identity?.registrationVerified == true, let id = identity?.peripheralID,
              let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where: { $0.identifier == id }) else { return }
        devices[id] = p; resumeRequested = true; if central.state == .poweredOn { reconnectSaved() }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) { guard p === peripheral else { return }; finish("services", error: error) }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral else { return }; for c in service.characteristics ?? [] { characteristics[c.uuid] = c }; finish("characteristics", error: error)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, characteristics[c.uuid] === c else { return }
        finish("notify:\(c.uuid)", error: error ?? (c.isNotifying ? nil : ZoraError.unsupported("蓝牙通知订阅未启用")))
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, characteristics[c.uuid] === c else { return }; finish("write:\(c.uuid)", error: error)
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, characteristics[c.uuid] === c else { return }
        if pending["read:\(c.uuid)"] != nil { finish("read:\(c.uuid)", data: c.value ?? Data(), error: error); return }
        guard error == nil, let data = c.value else { if c.uuid == Self.pairing { fail(error ?? ZoraError.malformed("空认证帧")) }; return }
        if c.uuid == Self.pairing {
            guard state == .authenticating else { return }
            guard data.count == 17, frames.count < 4 else { fail(ZoraError.malformed("异常 Nikon 蓝牙认证帧")); return }
            if pending["frame"] != nil { finish("frame", data: data) } else { frames.append(data) }
        } else if c.uuid == Self.control { enqueueControl(data) }
    }
}

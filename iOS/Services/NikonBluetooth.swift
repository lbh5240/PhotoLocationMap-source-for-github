import Foundation
import CoreBluetooth
import Observation
import ExternalAccessory
import ZoraCore

/// Native transport for the real Nikon smart-device GATT protocol.
/// Authentication success is deliberately separate from OS bonding and PTP readiness.
@MainActor @Observable final class NikonBluetooth: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum State: String { case idle, scanning, connecting, authenticating, authenticated, disconnected, failed }
    struct Nearby: Identifiable { let id: UUID; let name: String; let rssi: Int }
    private static func uuid(_ short: String) -> CBUUID { CBUUID(string: "0000\(short)-3dd4-4255-8d62-6dc7b9bd5561") }
    private static let service = uuid("de00"), pairing = uuid("2000"), name = uuid("2002")
    private static let wake = uuid("2005"), time = uuid("2006"), control = uuid("2008"), battery = uuid("2a19")
    private(set) var state = State.idle
    private(set) var status = "尚未连接蓝牙"
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
    private var frames: [Data] = []
    private var sessionToken = UUID()
    private var handshake: NikonBLEHandshake?
    private var scanTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var retryAttempt = 0
    private var userDisconnected = false
    private var foreground = true
    private var resumeRequested = false
    private var scanRequested = false
    var onAuthenticated: (@MainActor () -> Void)?
    var authenticated: Bool { state == .authenticated }

    override init() {
        identity = try? Keychain.loadValue(NikonBLEIdentity.self, id: "nikon.ble.identity")
        super.init()
        if identity != nil { _ = manager() }
    }
    private func log(_ value: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        diagnostics.append("\(stamp) · \(value)")
        if diagnostics.count > 80 { diagnostics.removeFirst(diagnostics.count - 80) }
    }
    private func manager() -> CBCentralManager {
        if let central { return central }
        let created = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "app.zora.camera.nikon.central",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        central = created; return created
    }
    func resume(foreground: Bool = true) {
        self.foreground = foreground
        if !foreground { keepAlive?.cancel(); return }
        if authenticated { startKeepAlive(); return }
        guard autoReconnect, identity != nil, !working, !userDisconnected else { return }
        resumeRequested = true
        let central = manager()
        if central.state == .poweredOn { reconnectSaved() }
    }
    func scan() {
        guard !working, !authenticated else { return }
        userDisconnected = false; scanRequested = true; nearby = []; retryTask?.cancel(); scanTask?.cancel()
        let central = manager()
        guard central.state == .poweredOn else { resumeRequested = false; status = "等待蓝牙授权或开启…"; return }
        scanRequested = false
        state = .scanning; status = "搜索 Nikon 相机 · 请打开相机配对菜单"
        central.scanForPeripherals(withServices: foreground ? nil : [Self.service], options: nil)
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15)); guard !Task.isCancelled, let self else { return }
            central.stopScan()
            if state == .scanning { state = .idle; status = nearby.isEmpty ? "未发现 Nikon，请检查配对菜单和蓝牙设置" : "选择你的相机开始认证" }
        }
    }
    func connect(_ id: UUID) {
        guard !working, !authenticated else { return }
        guard manager().state == .poweredOn else { status = "请先开启蓝牙"; return }
        scanRequested = false
        userDisconnected = false; retryTask?.cancel(); scanTask?.cancel(); central?.stopScan()
        guard let p = devices[id] ?? manager().retrievePeripherals(withIdentifiers: [id]).first else { status = "相机不可达，请重新扫描"; return }
        working = true; state = .connecting; status = "连接蓝牙链路…"; peripheral = p; p.delegate = self
        let token = UUID(); sessionToken = token
        characteristics = [:]; frames = []; handshake = nil; battery = nil
        log("开始 BLE 连接（不记录配对密钥或密码）")
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await operation("connect", timeout: 30) {
                    if p.state == .connected { self.finish("connect", data: Data()) }
                    else { self.central?.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]) }
                }
                state = .authenticating; status = "发现 Nikon 服务…"
                _ = try await operation("services") { p.discoverServices([Self.service]) }
                guard let service = p.services?.first(where: { $0.uuid == Self.service }) else { throw ZoraError.unsupported("相机未提供 Nikon 智能设备服务") }
                _ = try await operation("characteristics") { p.discoverCharacteristics(nil, for: service) }
                guard characteristics[Self.pairing] != nil, characteristics[Self.name] != nil else { throw ZoraError.unsupported("相机 GATT 不支持当前认证流程") }
                _ = try await operation("notify") { p.setNotifyValue(true, for: self.characteristics[Self.pairing]!) }
                if let control = characteristics[Self.control], control.properties.contains(.notify) || control.properties.contains(.indicate) {
                    _ = try await operation("notify") { p.setNotifyValue(true, for: control) }
                }
                handshake = NikonBLEHandshake(identity: identity?.peripheralID == id ? identity : nil)
                status = "Nikon 认证中 · 请确认系统/相机上的配对提示"
                try await write(handshake!.initial.data, to: Self.pairing)
                let challenge = try await nextFrame()
                guard let reply = try handshake?.receive(challenge) else { throw ZoraError.malformed("缺少 Nikon 认证响应") }
                try await write(reply, to: Self.pairing)
                let confirmation = try await nextFrame()
                _ = try handshake?.receive(confirmation)
                guard let h = handshake, h.phase == .authenticated, let serial = h.serial else { throw ZoraError.disconnected }
                if let saved = identity, saved.peripheralID == id, saved.serial != serial { throw ZoraError.malformed("相机身份与已保存序列号不符，请人工确认后重新配对") }
                try await write(NikonBLEPayload.controllerName("ZORA Camera"), to: Self.name)
                let saved = NikonBLEIdentity(peripheralID: id, device: h.initial.device, nonce: h.initial.nonce, serial: serial)
                try Keychain.saveValue(saved, id: "nikon.ble.identity"); identity = saved
                working = false; retryAttempt = 0; state = .authenticated
                status = "Nikon 蓝牙认证完成 · 系统绑定/唤醒仍需真机核验"
                log("Nikon challenge / confirmation / client-name 写入完成")
                startKeepAlive(); onAuthenticated?()
            } catch { if sessionToken == token, !userDisconnected { fail(error) } }
        }
    }
    private func operation(_ key: String, timeout: Int = 15, start: () -> Void) async throws -> Data {
        try Task.checkCancellation()
        guard pending[key] == nil else { throw ZoraError.busy }
        let token = UUID()
        let result: Data = try await withCheckedThrowingContinuation { c in
            pending[key] = (token, c)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, pending[key]?.0 == token else { return }
                fail(ZoraError.unsupported("蓝牙操作超时（\(key)），请检查相机配对提示"))
            }
            start()
        }
        try Task.checkCancellation()
        return result
    }
    private func finish(_ key: String, data: Data = Data(), error: Error? = nil) {
        guard let (_, c) = pending.removeValue(forKey: key) else { return }
        if let error { c.resume(throwing: error) } else { c.resume(returning: data) }
    }
    private func nextFrame() async throws -> Data {
        try Task.checkCancellation()
        if !frames.isEmpty { return frames.removeFirst() }
        return try await operation("frame", timeout: 45) {}
    }
    private func write(_ data: Data, to uuid: CBUUID) async throws {
        guard let p = peripheral, p.state == .connected, let c = characteristics[uuid], c.properties.contains(.write) else {
            throw ZoraError.unsupported("相机缺少可确认写入的蓝牙特征 \(uuid.uuidString.prefix(8))")
        }
        _ = try await operation("write:\(uuid)") { p.writeValue(data, for: c, type: .withResponse) }
    }
    func wakeWiFi() async throws {
        guard authenticated, let handshake else { throw ZoraError.disconnected }
        try await write(handshake.wifiWakeCommand(), to: Self.wake)
        status = "相机接受 Wi-Fi 唤醒写入 · 等待热点与 PTP 验证"
        log("2005 Wi-Fi wake write acknowledged; not proof of Wi-Fi readiness")
    }
    func refreshTelemetry() async {
        guard authenticated, !working else { return }
        do {
            if characteristics[Self.time] != nil { try await write(NikonBLEPayload.time(Date()), to: Self.time) }
            if let c = characteristics[Self.battery], c.properties.contains(.read), let p = peripheral {
                let result = try await operation("read:\(Self.battery)") { p.readValue(for: c) }
                if result.count == 1, result[0] <= 100 { battery = Int(result[0]) }
            }
        } catch { log("校时/电量读取未完成：\(error.localizedDescription)") }
    }
    private func startKeepAlive() {
        keepAlive?.cancel(); guard foreground else { return }
        keepAlive = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                guard let self, authenticated else { return }
                await refreshTelemetry()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }
    func disconnect(forget: Bool = false) {
        sessionToken = UUID()
        automationGeneration = UUID(); pairingTask?.cancel()
        userDisconnected = true; scanRequested = false; retryTask?.cancel(); scanTask?.cancel(); keepAlive?.cancel(); central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        clear(ZoraError.disconnected); peripheral = nil; state = .disconnected; status = "蓝牙已断开"; battery = nil
        if forget { Keychain.delete(id: "nikon.ble.identity"); Keychain.delete(id: "nikon.wifi"); identity = nil; status = "本机配对资料已移除；系统绑定请在蓝牙设置中忽略设备" }
    }
    private func clear(_ error: Error) {
        let values = pending.values.map { $0.1 }; pending.removeAll()
        for c in values { c.resume(throwing: error) }
        handshake = nil; characteristics = [:]; frames = []; working = false; battery = nil
    }
    private func fail(_ error: Error) {
        sessionToken = UUID()
        pairingTask?.cancel()
        let old = peripheral; peripheral = nil
        clear(error); state = .failed; status = error.localizedDescription; log(status); keepAlive?.cancel()
        if let old { central?.cancelPeripheralConnection(old) }
        scheduleReconnect()
    }
    private func scheduleReconnect() {
        guard autoReconnect, !userDisconnected, identity != nil, central?.state == .poweredOn else { return }
        guard let delay = NikonBLEPayload.reconnectDelay(attempt: retryAttempt) else { log("自动重连已达上限，请手动重试"); return }
        retryAttempt += 1; retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay)); guard !Task.isCancelled, let self else { return }
            reconnectSaved()
        }
    }
    private func reconnectSaved() {
        guard let identity, central?.state == .poweredOn, !working, !authenticated, !userDisconnected else { return }
        resumeRequested = false; connect(identity.peripheralID)
    }
    func retrySaved() { userDisconnected = false; retryAttempt = 0; resumeRequested = true; let c = manager(); if c.state == .poweredOn { reconnectSaved() } }

    /// Public OS accessory picker is an explicit fallback for classic Bluetooth
    /// bonding. Its completion never changes our Nikon-authentication state.
    func showSystemPairing() {
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [weak self] error in
            let description = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.log(description.map { "系统配对选择器：\($0)" } ?? "系统选择器已结束；请重新连接验证 Nikon 认证")
            }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            pairingTask?.cancel()
            retryTask?.cancel(); keepAlive?.cancel()
            clear(ZoraError.disconnected); peripheral = nil; state = .disconnected
            status = central.state == .unauthorized ? "请在设置中允许 ZORA 使用蓝牙" : "请开启蓝牙后重试"; return
        }
        if scanRequested { scan() }
        else if resumeRequested || (autoReconnect && identity != nil && !userDisconnected) { reconnectSaved() }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard manufacturer?.prefix(2) == Data([0x99,0x03]) || services.contains(Self.service) || p.identifier == identity?.peripheralID else { return }
        devices[p.identifier] = p
        let item = Nearby(id: p.identifier, name: p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Nikon（未广播名称）", rssi: RSSI.intValue)
        nearby.removeAll { $0.id == p.identifier }; nearby.append(item)
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { return }; finish("connect")
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }; fail(error ?? ZoraError.disconnected)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }; fail(error ?? ZoraError.disconnected)
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard autoReconnect, let id = identity?.peripheralID,
              let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where: { $0.identifier == id }) else { return }
        devices[id] = p; resumeRequested = true; log("系统已恢复已知相机，重新认证后才允许写入")
        if central.state == .poweredOn { reconnectSaved() }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }; finish("services", error: error)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral else { return }
        for c in service.characteristics ?? [] { characteristics[c.uuid] = c }
        finish("characteristics", error: error)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        finish("notify", error: error ?? (c.isNotifying ? nil : ZoraError.unsupported("蓝牙通知订阅未启用")))
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }; finish("write:\(c.uuid)", error: error)
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if pending["read:\(c.uuid)"] != nil { finish("read:\(c.uuid)", data: c.value ?? Data(), error: error); return }
        guard error == nil, let data = c.value else { if c.uuid == Self.pairing { fail(error ?? ZoraError.malformed("空认证帧")) }; return }
        if c.uuid == Self.pairing {
            guard state == .authenticating else { return }
            guard data.count == 17, frames.count < 4 else { fail(ZoraError.malformed("异常 Nikon 蓝牙认证帧")); return }
            if pending["frame"] != nil { finish("frame", data: data) } else { frames.append(data) }
        } else if c.uuid == Self.control, authenticated, data.count == 2, data[0] & 0x0f == 1 {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await write(NikonBLEPayload.time(Date()), to: Self.time)
                    try await write(Data([data[0] & 0xf0, data[1]]), to: Self.control)
                } catch { log("相机请求校时未完成：\(error.localizedDescription)") }
            }
        }
    }
}

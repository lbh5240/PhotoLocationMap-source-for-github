import Foundation
import CoreBluetooth
import Network
import NetworkExtension
import Observation
import ZoraCore

@MainActor @Observable final class Connectivity: NSObject, @preconcurrency CBCentralManagerDelegate {
    var bluetoothStatus = "尚未扫描"
    var peripherals: [UUID: String] = [:]
    var online = false
    private var central: CBCentralManager?
    private let monitor = NWPathMonitor()
    override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.online = online }
        }
        monitor.start(queue: DispatchQueue(label: "zora.path"))
    }
    func scan() {
        peripherals = [:]
        if let central { centralManagerDidUpdateState(central) }
        else { central = CBCentralManager(delegate: self, queue: .main) }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { bluetoothStatus = "蓝牙不可用或未获授权"; return }
        bluetoothStatus = "扫描中（仅发现设备，未实现 Nikon 配对）"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.central?.stopScan(); self?.bluetoothStatus = "扫描结束 · Nikon 私有配对待验证"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String { peripherals[peripheral.identifier] = name }
    }
    func join(ssid: String, password: String) async throws {
        guard !ssid.isEmpty else { throw ZoraError.malformed("请输入相机 SSID") }
        let config = password.isEmpty ? NEHotspotConfiguration(ssid: ssid) : NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        config.joinOnce = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(config) { error in
                if let error = error as NSError?, error.code != NEHotspotConfigurationError.alreadyAssociated.rawValue { c.resume(throwing: error) }
                else { c.resume() }
            }
        }
    }
}

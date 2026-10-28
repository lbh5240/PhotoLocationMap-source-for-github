import Foundation
import CoreBluetooth
import Network
import NetworkExtension
import Observation
import ZoraCore

@MainActor @Observable final class Connectivity: NSObject {
    let bluetooth = NikonBluetooth()
    var online = false
    private let monitor = NWPathMonitor()
    override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.online = online }
        }
        monitor.start(queue: DispatchQueue(label: "zora.path"))
    }
    func join(ssid: String, password: String) async throws {
        guard !ssid.isEmpty else { throw ZoraError.malformed("请输入相机 SSID") }
        let config = password.isEmpty ? NEHotspotConfiguration(ssid: ssid) : NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        config.joinOnce = true
        let gate = CallbackGate<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                gate.install(c)
                NEHotspotConfigurationManager.shared.apply(config) { error in
                    if let error = error as NSError?, !(error.domain == NEHotspotConfigurationErrorDomain && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) { gate.resolve(.failure(error)) }
                    else { gate.resolve(.success(())) }
                }
                Task { try? await Task.sleep(for: .seconds(45)); gate.resolve(.failure(ZoraError.unsupported("系统加入 Wi-Fi 未在时限内完成，请处理系统提示后重试"))) }
            }
        } onCancel: { gate.resolve(.failure(CancellationError())) }
    }
}

import Foundation
import CoreLocation
import Observation
import ZoraCore

/// Phone-side geotagging for photos imported from the camera. Runs only in the foreground
/// while the user has enabled it; the location never leaves the device except inside exports.
@MainActor @Observable final class LocationTagger {
    private(set) var latest: GeoTag?
    private(set) var status = "未开启"
    var enabled = UserDefaults.standard.bool(forKey: "geotagEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "geotagEnabled"); enabled ? start() : stop() }
    }
    private var task: Task<Void, Never>?
    private var session: CLServiceSession?
    /// A fix older than ten minutes is not attached to a new photo.
    var current: GeoTag? { latest.flatMap { $0.isFresh() ? $0 : nil } }
    func start() {
        guard enabled, task == nil else { return }
        status = "正在获取位置"
        session = CLServiceSession(authorization: .whenInUse)
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self, !Task.isCancelled else { return }
                    if update.authorizationDenied || update.authorizationDeniedGlobally { self.status = "定位权限被拒绝，请在系统设置中允许"; continue }
                    guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
                    self.latest = GeoTag(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                         altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                                         accuracy: location.horizontalAccuracy, timestamp: location.timestamp)
                    self.status = String(format: "已定位 · 精度 %.0f 米", location.horizontalAccuracy)
                }
            } catch { self?.status = "定位不可用：\(error.localizedDescription)" }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        session?.invalidate(); session = nil
        if !enabled { latest = nil; status = "未开启" }
    }
}

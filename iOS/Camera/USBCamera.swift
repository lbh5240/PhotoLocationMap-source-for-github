import Foundation
import ImageCaptureCore
import Observation
import ZoraCore

/// All platform calls run on the main actor. Each callback belongs to exactly
/// one request token; late callbacks cannot satisfy another command.
@MainActor @Observable final class USBCamera: NSObject, PTPDirectTransport,
    @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    struct Found: Identifiable { let id: String; let name: String }
    private(set) var cameras: [Found] = []
    private(set) var status = "USB ��δ����"
    private(set) var selectedID: String?
    private let browser = ICDeviceBrowser()
    private var devices: [String: ICCameraDevice] = [:]
    private var camera: ICCameraDevice?
    private var browsing = false
    private var opened = false
    private var closing = false
    private var epoch = UUID()
    private var pending: (UUID, CheckedContinuation<PTPResult, Error>)?
    private var lifecycle: (UUID, CheckedContinuation<Void, Error>)?
    private var stream: AsyncStream<CameraTransportEvent>?
    private var eventSink: AsyncStream<CameraTransportEvent>.Continuation?
    var onRemoval: (@MainActor () -> Void)?

    func search() async {
        #if targetEnvironment(simulator)
        status = "ģ��������������ʵ USB �������ʹ�� iPhone / iPad"
        #else
        guard !browsing else { status = cameras.isEmpty ? "���ڼ��� USB ��Σ����������ߡ������Դ��Ȩ��" : "��ѡ�� Nikon USB ���"; return }
        browser.delegate = self
        let allowed = await withCheckedContinuation { c in browser.requestContentsAuthorization { value in c.resume(returning: value == .authorized) } }
        guard allowed else { status = "USB ý�����δ����Ȩ������ϵͳ��˽���������� ZORA"; return }
        browsing = true; browser.start(); status = "���� USB ��� �� �����������߲��������"
        #endif
    }
    func select(_ id: String) throws {
        guard !opened, !closing, camera == nil, devices[id] != nil else { throw ZoraError.unsupported("���ȵȴ����� USB �Ự�Ͽ�����ѡ���������ӵ����") }
        selectedID = id
    }
    func open() async throws {
        guard !closing else { throw ZoraError.busy }
        guard let id = selectedID, let device = devices[id], device.usbVendorID == 0x04b0 else { throw ZoraError.disconnected }
        let allowed = await withCheckedContinuation { c in browser.requestControlAuthorization { value in c.resume(returning: value == .authorized) } }
        guard allowed else { throw ZoraError.unsupported("USB �������Ȩ��δ����Ȩ") }
        guard device.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else { throw ZoraError.unsupported("�� USB �豸δ�ṩ PTP ��������") }
        guard camera == nil else { throw ZoraError.busy }
        epoch = UUID(); let token = epoch
        camera = device; device.delegate = self; status = "���ڴ�ϵͳ USB ����Ự��"
        let pair = AsyncStream<CameraTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        stream = pair.stream; eventSink = pair.continuation
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lifecycle = (token,c)
                device.requestOpenSession(options: nil) { [weak self] error in
                    let message = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, lifecycle?.0 == token, epoch == token else { return }
                        let waiter = lifecycle?.1; lifecycle = nil
                        if let message { waiter?.resume(throwing: ZoraError.unsupported(message)) }
                        else { opened = true; status = "ϵͳ USB �Ự�Ѵ򿪣����ڶ�ȡ�������"; waiter?.resume() }
                    }
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, lifecycle?.0 == token else { return }; invalidate(ZoraError.timeout)
                }
            }
            try Task.checkCancellation()
        } catch { await close(); throw error }
    }
    func execute(code: UInt16, transaction: UInt32, parameters: [UInt32], sending: Data?) async throws -> PTPResult {
        try Task.checkCancellation()
        guard opened, let device = camera else { throw ZoraError.disconnected }
        guard pending == nil else { throw ZoraError.busy }
        guard code != PTPOperation.openSession, code != PTPOperation.closeSession else { throw ZoraError.unsupported("USB �Ự���������� ImageCaptureCore ����") }
        let command = try PTPUSBContainer.command(code: code, transaction: transaction, parameters: parameters)
        let token = UUID(), session = epoch
        return try await withTaskCancellationHandler {
            let result: PTPResult = try await withCheckedThrowingContinuation { c in
                pending = (token,c)
                device.requestSendPTPCommand(command, outData: sending) { [weak self] data, response, error in
                    let incoming = data, reply = response, message = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, pending?.0 == token, epoch == session else { return }
                        let waiter = pending?.1; pending = nil
                        do {
                            if let message { throw ZoraError.unsupported(message) }
                            // IC correlates this callback and may renumber transaction IDs.
                            // Parse its actual response; do not synthesize ACK/data containers.
                            let result = try PTPUSBContainer.response(reply, payload: incoming)
                            waiter?.resume(returning: result)
                        } catch { waiter?.resume(throwing: error) }
                    }
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, pending?.0 == token, epoch == session else { return }; invalidate(ZoraError.timeout)
                }
            }
            try Task.checkCancellation(); return result
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, pending?.0 == token else { return }; invalidate(CancellationError())
            }
        }
    }
    func eventStream() -> AsyncStream<CameraTransportEvent> { stream ?? AsyncStream { $0.finish() } }
    private func invalidate(_ error: Error) {
        epoch = UUID(); opened = false
        let request = pending?.1, opening = lifecycle?.1; pending = nil; lifecycle = nil
        request?.resume(throwing: error); opening?.resume(throwing: error)
        eventSink?.yield(.disconnected); eventSink?.finish(); eventSink = nil
        status = error.localizedDescription
    }
    func close() async {
        guard !closing else { return }; closing = true; defer { closing = false }
        let old = camera; camera = nil
        invalidate(ZoraError.disconnected); stream = nil
        guard let old else { return }
        // Closing is bounded. A new open is blocked until this close returns.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let gate = USBVoidGate(c)
            old.requestCloseSession(options: nil) { _ in gate.resume() }
            Task { try? await Task.sleep(for: .seconds(5)); gate.resume() }
        }
        old.delegate = nil; status = "USB �Ự�ѹر�"
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let item = device as? ICCameraDevice, item.usbVendorID == 0x04b0,
              item.transportType == ICDeviceTransport.transportTypeUSB.rawValue, let id = item.uuidString else { return }
        devices[id] = item; cameras.removeAll { $0.id == id }; cameras.append(Found(id: id, name: item.name ?? "Nikon USB ���"))
        status = "�ѷ��� Nikon USB �������ѡ������"
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if let id = device.uuidString { devices.removeValue(forKey: id); cameras.removeAll { $0.id == id } }
        if device === camera { removed() }
    }
    private func removed() { invalidate(ZoraError.disconnected); onRemoval?(); status = "USB ����Ѱγ�����ֹͣ�Ự" }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) { if device === camera { removed() } }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        guard camera === self.camera, opened else { return }
        do { eventSink?.yield(.ptp(try CameraEvent(usbContainer: eventData))) }
        catch { status = "�յ��޷������� USB �¼���δ�ݴ˸�����Ƭ״̬" }
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// Callback and timeout may race on arbitrary system queues.
private final class USBVoidGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() { lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume() }
}

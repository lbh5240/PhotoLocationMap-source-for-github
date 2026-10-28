import Foundation

/// A callback, cancellation and timeout may race, including cancellation before
/// installation. Exactly one result is delivered; late results are ignored.
public final class CallbackGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var stored: Result<Value, Error>?
    private var completed = false
    public init() {}
    public func install(_ value: CheckedContinuation<Value, Error>) {
        lock.lock()
        let result = stored
        if result == nil { continuation = value } else { stored = nil }
        lock.unlock()
        if let result { value.resume(with: result) }
    }
    @discardableResult public func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); return false }
        completed = true
        let value = continuation; continuation = nil
        if value == nil { stored = result }
        lock.unlock(); value?.resume(with: result); return true
    }
}

public protocol NikonBLECommandSink: Sendable {
    func sendBLE(_ data: Data, characteristic: UInt16) async throws
}
public struct NikonRegistrationReceipt: Sendable {
    public let timeProvided: Bool, connectionProvided: Bool
}
public enum NikonRegistrationExchange {
    /// Service known requests only, preserving GPS and reserved bits. BT 02 and
    /// Wi-Fi 01 are deliberately different operations.
    public static func respond(to data: Data, using sink: any NikonBLECommandSink, now: Date = Date()) async throws -> NikonRegistrationReceipt {
        let request = try NikonControlRequest(data)
        if request.wantsTime { try await sink.sendBLE(NikonBLEPayload.time(now), characteristic: 0x2006) }
        let acknowledgment = request.acknowledgment(timeProvided: request.wantsTime, connectionProvided: request.wantsConnection)
        if acknowledgment != data { try await sink.sendBLE(acknowledgment, characteristic: 0x2008) }
        if request.wantsConnection { try await sink.sendBLE(Data([2]), characteristic: 0x2005) }
        return NikonRegistrationReceipt(timeProvided: request.wantsTime, connectionProvided: request.wantsConnection)
    }
}

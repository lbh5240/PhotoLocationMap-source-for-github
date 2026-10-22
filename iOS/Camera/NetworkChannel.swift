import Foundation
import Network
import ZoraCore

private final class ResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    @discardableResult func resolve(_ result: Result<T, Error>) -> Bool {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result); return c != nil
    }
}

/// All NW callbacks use a serial queue. A timeout tears down the channel to avoid a late reply becoming the next transaction.
final class NetworkSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "camera.network.\(UUID())")
    init(host: String, port: UInt16) throws {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port) else { throw ZoraError.malformed("相机地址") }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }
    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let gate = ResumeGate(c)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.resolve(.success(()))
                    case .failed(let error): gate.resolve(.failure(error))
                    case .cancelled: gate.resolve(.failure(CancellationError()))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now()+10) { [connection] in
                    if gate.resolve(.failure(ZoraError.timeout)) { connection.cancel() }
                }
                connection.start(queue: queue)
            }
        } onCancel: { self.connection.cancel() }
    }
    func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let gate = ResumeGate(c)
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { gate.resolve(.failure(error)) } else { gate.resolve(.success(())) }
                })
                queue.asyncAfter(deadline: .now()+10) { [connection] in
                    if gate.resolve(.failure(ZoraError.timeout)) { connection.cancel() }
                }
            }
        } onCancel: { self.connection.cancel() }
    }
    func receive(timeout: Bool = true) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                let gate = ResumeGate(c)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { gate.resolve(.failure(error)) }
                    else if let data, !data.isEmpty { gate.resolve(.success(data)) }
                    else { gate.resolve(.failure(complete ? ZoraError.disconnected : ZoraError.malformed("empty TCP read"))) }
                }
                if timeout { queue.asyncAfter(deadline: .now()+15) { [connection] in
                    if gate.resolve(.failure(ZoraError.timeout)) { connection.cancel() }
                }
                }
            }
        } onCancel: { self.connection.cancel() }
    }
    func close() { connection.cancel() }
}

actor PacketChannel: PTPPacketTransport {
    private let socket: NetworkSocket
    private var framer = PTPFramer()
    private var pending: [PTPPacket] = []
    init(host: String, port: UInt16) throws { socket = try NetworkSocket(host: host, port: port) }
    func open() async throws { try await socket.open() }
    func send(_ packet: PTPPacket) async throws { try await socket.send(packet.encoded) }
    func read(timeout: Bool = true) async throws -> PTPPacket {
        while pending.isEmpty { pending += try framer.feed(await socket.receive(timeout: timeout)) }
        return pending.removeFirst()
    }
    func close() { socket.close() }
}

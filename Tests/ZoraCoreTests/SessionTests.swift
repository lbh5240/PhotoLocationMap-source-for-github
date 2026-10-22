import XCTest
@testable import ZoraCore

/// Scripted packets below are synthetic test fixtures, never a production camera driver.
final class SessionTests: XCTestCase, @unchecked Sendable {
    func testRealSessionPipelineOverExplicitProtocolFixture() async throws {
        let info = fixtureInfo()
        var ack = Data(); ack.appendLE(UInt32(9)); ack.append(Data(repeating: 0, count: 20))
        let command = ScriptedTransport(packets: [.init(type: 2, payload: ack)] + dataPhase(id: 0, data: info) + [response(id: 0), response(id: 1), response(id: 2)])
        let event = ScriptedTransport(packets: [.init(type: 4)])
        let factory = FixtureFactory(command: command, event: event)
        let session = CameraSession(guid: UUID()) { _, _ in factory.next() }
        let device = try await session.connect(host: "test-fixture-only")
        XCTAssertEqual(device.model, "Z 7_2")
        try await session.capture()
        try await session.disconnect()
        let sent = await command.sent
        XCTAssertEqual(sent.map(\.type), [1, 6, 6, 6, 6])
        var request = BinaryReader(sent[3].payload)
        _ = try request.integer(UInt32.self)
        XCTAssertEqual(try request.integer(UInt16.self), PTPOperation.capture)
        let current = await session.device; XCTAssertNil(current)
    }
    func testRejectedHandshakeNeverConnects() async throws {
        let command = ScriptedTransport(packets: [.init(type: 5)])
        let event = ScriptedTransport(packets: [])
        let factory = FixtureFactory(command: command, event: event)
        let session = CameraSession(guid: UUID()) { _, _ in factory.next() }
        do { _ = try await session.connect(host: "test-fixture-only"); XCTFail("must reject") } catch {}
        let current = await session.device; XCTAssertNil(current)
        let closed = await command.closed; XCTAssertTrue(closed)
    }
    func testUnsupportedOperationSendsNothing() async throws {
        let session = CameraSession(guid: UUID()) { _, _ in ScriptedTransport(packets: []) }
        do { try await session.capture(); XCTFail("must require session") } catch { XCTAssertEqual(error as? ZoraError, .disconnected) }
    }
    func testCameraErrorPreservesSessionButOversizedTransferClosesIt() async throws {
        var ack = Data(); ack.appendLE(UInt32(9)); ack.append(Data(repeating: 0, count: 20))
        var rejected = Data(); rejected.appendLE(UInt16(0x2019)); rejected.appendLE(UInt32(1))
        var oversized = Data(); oversized.appendLE(UInt32(2)); oversized.appendLE(UInt64(PTPFramer.maximumPacket+1))
        let command = ScriptedTransport(packets: [.init(type: 2, payload: ack)] + dataPhase(id: 0, data: fixtureInfo()) + [response(id: 0), .init(type: 7, payload: rejected), .init(type: 9, payload: oversized)])
        let factory = FixtureFactory(command: command, event: ScriptedTransport(packets: [.init(type: 4)]))
        let session = CameraSession(guid: UUID()) { _,_ in factory.next() }
        _ = try await session.connect(host: "test-fixture-only")
        do { try await session.capture(); XCTFail("must reject busy camera") } catch { XCTAssertEqual(error as? ZoraError, .cameraResponse(0x2019)) }
        var device = await session.device; XCTAssertNotNil(device)
        do { try await session.capture(); XCTFail("must reject oversized data") } catch {}
        device = await session.device; XCTAssertNil(device)
    }
    private func fixtureInfo() -> Data {
        var data = Data(); data.appendLE(UInt16(100)); data.appendLE(UInt32(10)); data.appendLE(UInt16(100)); data.append(0); data.appendLE(UInt16(0))
        data.appendLE(UInt32(4)); for op: UInt16 in [0x1001,0x1002,0x1003,0x100e] { data.appendLE(op) }
        for _ in 0..<4 { data.appendLE(UInt32(0)) }
        for string in ["Nikon", "Z 7_2", "FIXTURE", "FIXTURE"] {
            data.append(UInt8(string.utf16.count+1)); for c in string.utf16 { data.appendLE(c) }; data.appendLE(UInt16(0))
        }
        return data
    }
    private func response(id: UInt32) -> PTPPacket {
        var p = Data(); p.appendLE(UInt16(0x2001)); p.appendLE(id); return .init(type: 7, payload: p)
    }
    private func dataPhase(id: UInt32, data: Data) -> [PTPPacket] {
        var start = Data(); start.appendLE(id); start.appendLE(UInt64(data.count))
        var end = Data(); end.appendLE(id); end.append(data)
        return [.init(type: 9, payload: start), .init(type: 12, payload: end), response(id: id)]
    }
}

private actor ScriptedTransport: PTPPacketTransport {
    var packets: [PTPPacket]
    var sent: [PTPPacket] = []
    var closed = false
    init(packets: [PTPPacket]) { self.packets = packets }
    func open() async throws {}
    func send(_ packet: PTPPacket) async throws { sent.append(packet) }
    func read(timeout: Bool) async throws -> PTPPacket {
        while packets.isEmpty {
            if closed { throw ZoraError.disconnected }
            try await Task.sleep(for: .milliseconds(5))
        }
        return packets.removeFirst()
    }
    func close() async { closed = true }
}
private final class FixtureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let command: ScriptedTransport, event: ScriptedTransport
    init(command: ScriptedTransport, event: ScriptedTransport) { self.command = command; self.event = event }
    func next() -> any PTPPacketTransport {
        lock.lock(); defer { lock.unlock() }; index += 1; return index % 2 == 1 ? command : event
    }
}

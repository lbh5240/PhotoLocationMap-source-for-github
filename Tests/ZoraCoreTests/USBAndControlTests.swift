import Foundation
import XCTest
@testable import ZoraCore

/// Explicit protocol fixtures: these test real code paths, not camera interoperability.
final class USBAndControlTests: XCTestCase, @unchecked Sendable {
    func testUSBCommandWireVectorAndParameterLimit() throws {
        XCTAssertEqual(try PTPUSBContainer.command(code: 0x9207, transaction: 7, parameters: [.max,0]),
            Data([20,0,0,0,1,0,7,0x92,7,0,0,0,255,255,255,255,0,0,0,0]))
        XCTAssertThrowsError(try PTPUSBContainer.command(code: 1, transaction: 1, parameters: Array(repeating: 0, count: 6)))
    }
    func testUSBResponseChecksHeaderErrorAndOptionalDaemonTransaction() throws {
        let reply = container(type: 3, code: 0x2001, transaction: 99, parameters: [3])
        XCTAssertEqual(try PTPUSBContainer.response(reply, payload: Data([1,2,3])).parameters, [3])
        XCTAssertThrowsError(try PTPUSBContainer.response(reply, payload: Data(), expectedTransaction: 1))
        XCTAssertThrowsError(try PTPUSBContainer.response(Data(reply.dropLast()), payload: Data()))
        XCTAssertThrowsError(try PTPUSBContainer.response(container(type: 2, code: 0x2001, transaction: 99), payload: Data()))
        XCTAssertThrowsError(try PTPUSBContainer.response(container(type: 3, code: 0x2019, transaction: 99), payload: Data())) {
            XCTAssertEqual($0 as? ZoraError, .cameraResponse(0x2019))
        }
    }
    func testUSBAndIPEventsHaveSameSemantics() throws {
        let usb = try CameraEvent(usbContainer: container(type: 4, code: 0x4002, transaction: .max, parameters: [0x1234]))
        var ip = Data(); ip.appendLE(UInt16(0x4002)); ip.appendLE(UInt32.max); ip.appendLE(UInt32(0x1234))
        XCTAssertEqual(usb, try CameraEvent(ipPayload: ip)); XCTAssertTrue(usb.changesStorage)
        XCTAssertThrowsError(try CameraEvent(usbContainer: container(type: 4, code: 0x4002, transaction: 1, parameters: [1,2,3,4])))
        XCTAssertThrowsError(try CameraEvent(ipPayload: Data([1])))
    }
    func testSystemManagedSessionDoesNotSendFakeOpenOrCloseCommands() async throws {
        let fixture = DirectFixture(operations: [0x1001,0x100e])
        let camera = session(); let info = try await camera.connect(using: fixture)
        XCTAssertEqual(info.model, "Z 7_2")
        try await camera.capture(); try await camera.disconnect()
        let calls = await fixture.calls
        XCTAssertEqual(calls.map(\.code), [0x1001,0x100e])
        let opened = await fixture.openCount, closed = await fixture.closeCount
        XCTAssertEqual(opened,1); XCTAssertEqual(closed,1)
    }
    func testFailedDeviceInformationNeverMarksUSBConnected() async throws {
        let fixture = DirectFixture(operations: [])
        await fixture.setFailure(code: 0x1001, response: 0x2005)
        let camera = session()
        do { _ = try await camera.connect(using: fixture); XCTFail("must fail") } catch {}
        let device = await camera.device, closed = await fixture.closeCount
        XCTAssertNil(device); XCTAssertEqual(closed,1)
    }
    func testUnsupportedVideoOperationSendsNothing() async throws {
        let fixture = DirectFixture(operations: [0x1001]); let camera = session(); _ = try await camera.connect(using: fixture)
        do { try await camera.startMovie(); XCTFail("must gate") } catch {}
        let calls = await fixture.calls; XCTAssertEqual(calls.count,1)
        try await camera.disconnect()
    }
    func testNikonCaptureMovieAndManualFocusUseDocumentedParameters() async throws {
        let fixture = DirectFixture(operations: [0x1001,0x9207,0x920a,0x920b,0x9204,0x90c8])
        let camera = session(); _ = try await camera.connect(using: fixture)
        try await camera.capture(); try await camera.startMovie(); try await camera.stopMovie()
        let result = try await camera.driveFocus(near: false, steps: 100)
        XCTAssertEqual(result,.completed)
        let calls = await fixture.calls
        XCTAssertEqual(calls.map(\.code), [0x1001,0x9207,0x920a,0x920b,0x9204,0x90c8])
        XCTAssertEqual(calls[1].parameters,[UInt32.max,0]); XCTAssertEqual(calls[4].parameters,[2,100])
        try await camera.disconnect()
    }
    func testFocusLimitsAndEndOfTravelAreNotFalseSuccess() async throws {
        let fixture = DirectFixture(operations: [0x1001,0x9204]); let camera = session(); _ = try await camera.connect(using: fixture)
        do { _ = try await camera.driveFocus(near: true, steps: 0); XCTFail("invalid steps") } catch {}
        await fixture.setFailure(code: 0x9204, response: 0xa00c)
        let result = try await camera.driveFocus(near: true, steps: 10)
        XCTAssertEqual(result,.endOfTravel); let device = await camera.device; XCTAssertNotNil(device)
        try await camera.disconnect()
    }
    func testRemoteControlIsReleasedBeforeSystemSessionCloses() async throws {
        let fixture = DirectFixture(operations: [0x1001,0x90c2]); let camera = session(); _ = try await camera.connect(using: fixture)
        try await camera.setRemoteControl(true); try await camera.disconnect()
        let calls = await fixture.calls
        XCTAssertEqual(calls.suffix(2).map(\.parameters),[[1],[0]])
    }
    func testStorageAndDirectoryPagingDoNotTruncateAfter200() async throws {
        let fixture = DirectFixture(operations: [0x1001,0x1004,0x1005,0x1007,0x1008,0x9209])
        let camera = session(); _ = try await camera.connect(using: fixture)
        let ids = try await camera.storageIDs(); XCTAssertEqual(ids,[0x10001])
        let storage = try await camera.storageInfo(ids[0]); XCTAssertEqual(storage.capacity,128_000_000_000)
        let page = try await camera.objectPage(storage: ids[0], offset: 200, limit: 100)
        XCTAssertEqual(page.objects.count,50); XCTAssertEqual(page.objects.first?.id,201); XCTAssertNil(page.nextOffset); XCTAssertEqual(page.total,250)
        let calls = await fixture.calls; XCTAssertTrue(calls.contains { $0.code == 0x9209 })
        try await camera.disconnect()
    }
    func testRAWLargerThan64MiBUsesBoundedChunksAndCommitsWholeFile() async throws {
        let size = UInt32(65*1024*1024+13)
        let fixture = DirectFixture(operations: [0x1001,0x101b], size: size)
        let camera = session(); _ = try await camera.connect(using: fixture)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("zora-\(UUID()).nef")
        defer { try? FileManager.default.removeItem(at: target) }
        let object = try CameraObject(handle: 17, data: objectInfo(size: size))
        try await camera.download(object, to: target)
        let bytes = try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber
        XCTAssertEqual(bytes?.uint64Value,UInt64(size))
        let file = try FileHandle(forReadingFrom: target); defer { try? file.close() }
        XCTAssertEqual(try file.read(upToCount: 4),Data([0,0,0,0])); try file.seek(toOffset: UInt64(size)-4)
        XCTAssertEqual(try file.read(upToCount: 4),Data(repeating: 16, count: 4))
        let chunks = await fixture.calls.filter { $0.code == 0x101b }
        XCTAssertEqual(chunks.count,17); XCTAssertTrue(chunks.allSatisfy { $0.parameters[2] <= 4*1024*1024 })
        try await camera.disconnect()
    }
    func testWrongChunkLengthNeverPublishesPartialFile() async throws {
        let fixture = DirectFixture(operations: [0x1001,0x101b], size: 100)
        await fixture.setBadChunk(true)
        let camera = session(); _ = try await camera.connect(using: fixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zora-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("bad.nef")
        do { try await camera.download(CameraObject(handle: 1,data: objectInfo(size: 100)),to: target); XCTFail("must reject") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try await camera.disconnect()
    }
    func testUSBRemovalClearsVerifiedSession() async throws {
        let fixture = DirectFixture(operations: [0x1001]); let camera = session(); _ = try await camera.connect(using: fixture)
        await fixture.remove()
        for _ in 0..<50 { if await camera.device == nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        let device = await camera.device; XCTAssertNil(device)
    }
    func testPausingMonitorDoesNotIssueDuplicateLiveViewStart() async throws {
        let fixture = DirectFixture(operations: [0x1001,0x9201,0x9202]); let camera = session(); _ = try await camera.connect(using: fixture)
        try await camera.startLiveView(); try await camera.startLiveView(); try await camera.stopLiveView()
        let codes = await fixture.calls.map(\.code); XCTAssertEqual(codes,[0x1001,0x9201,0x9202])
        try await camera.disconnect()
    }
    private func session() -> CameraSession { CameraSession(guid: UUID()) { _,_ in throw ZoraError.unsupported("USB fixture must never use TCP") } }
}

private func container(type: UInt16, code: UInt16, transaction: UInt32, parameters: [UInt32] = []) -> Data {
    var data = Data(); data.appendLE(UInt32(12+parameters.count*4)); data.appendLE(type); data.appendLE(code); data.appendLE(transaction)
    for p in parameters { data.appendLE(p) }; return data
}
private func text(_ s: String) -> Data {
    var d = Data([UInt8(s.utf16.count+1)]); for c in s.utf16 { d.appendLE(c) }; d.appendLE(UInt16(0)); return d
}
private func objectInfo(size: UInt32) -> Data {
    var d = Data(); d.appendLE(UInt32(0x10001)); d.appendLE(UInt16(0xb101)); d.appendLE(UInt16(0)); d.appendLE(size)
    d.append(Data(repeating: 0,count: 40)); d.append(text("fixture.nef")); return d
}
private actor DirectFixture: PTPDirectTransport {
    struct Call: Sendable { let code: UInt16; let parameters: [UInt32] }
    let operations: [UInt16], size: UInt32
    var calls: [Call] = [], openCount = 0, closeCount = 0
    var failures: [UInt16: UInt16] = [:], badChunk = false
    let stream: AsyncStream<CameraTransportEvent>
    let sink: AsyncStream<CameraTransportEvent>.Continuation
    init(operations: [UInt16], size: UInt32 = 0) {
        self.operations = operations; self.size = size
        let pair = AsyncStream<CameraTransportEvent>.makeStream(); stream = pair.stream; sink = pair.continuation
    }
    func setFailure(code: UInt16, response: UInt16) { failures[code] = response }
    func setBadChunk(_ value: Bool) { badChunk = value }
    func open() async throws { openCount += 1 }
    func close() async { closeCount += 1; sink.finish() }
    func eventStream() -> AsyncStream<CameraTransportEvent> { stream }
    func remove() { sink.yield(.disconnected); sink.finish() }
    func execute(code: UInt16, transaction: UInt32, parameters: [UInt32], sending: Data?) async throws -> PTPResult {
        calls.append(Call(code: code,parameters: parameters))
        if let error = failures[code] { throw ZoraError.cameraResponse(error) }
        var data = Data(), params: [UInt32] = []
        switch code {
        case 0x1001:
            data.appendLE(UInt16(100)); data.appendLE(UInt32(10)); data.appendLE(UInt16(100)); data.append(0); data.appendLE(UInt16(0))
            data.appendLE(UInt32(operations.count)); for op in operations { data.appendLE(op) }
            for _ in 0..<4 { data.appendLE(UInt32(0)) }
            for s in ["Nikon","Z 7_2","FIXTURE","FIXTURE"] { data.append(text(s)) }
        case 0x9209,0x1004: data.appendLE(UInt32(1)); data.appendLE(UInt32(0x10001))
        case 0x1005:
            for v: UInt16 in [3,2,0] { data.appendLE(v) }; data.appendLE(UInt64(128_000_000_000)); data.appendLE(UInt64(64_000_000_000)); data.appendLE(UInt32(1000)); data.append(text("CFexpress")); data.append(text("Fixture"))
        case 0x1007: data.appendLE(UInt32(250)); for v: UInt32 in 1...250 { data.appendLE(v) }
        case 0x1008: data = objectInfo(size: size)
        case 0x101b:
            let count = min(parameters[2],size-parameters[1])
            data = Data(repeating: UInt8(parameters[1] / (4*1024*1024)),count: Int(count)); params = [badChunk ? count+1 : count]
        default: break
        }
        return PTPResult(data: data,parameters: params)
    }
}

import Foundation
import XCTest
@testable import ZoraCore

/// Regression transcripts, not a claim of Z7 II interoperability.
final class PairingWorkflowTests: XCTestCase, @unchecked Sendable {
    func testLegacyIdentityMigratesAsUnverifiedWithoutChangingNonce() throws {
        let json = Data("{\"peripheralID\":\"00112233-4455-6677-8899-AABBCCDDEEFF\",\"device\":12345,\"nonce\":67890,\"serial\":\"B123456\"}".utf8)
        let identity = try JSONDecoder().decode(NikonBLEIdentity.self, from: json)
        XCTAssertNil(identity.registrationVerified)
        let retry = NikonBLEHandshake(identity: identity)
        XCTAssertEqual(retry.initial.device,12345); XCTAssertEqual(retry.initial.nonce,67890)
    }
    func testNameAndClockWriteAloneDoNotCompleteNewRegistration() {
        var flow = NikonBLERegistration(); flow.confirmName(); flow.confirmTime(); flow.confirmAcknowledgment()
        XCTAssertFalse(flow.ready); XCTAssertThrowsError(try flow.wakeCommand())
    }
    func testConnectionThenTimeRequestCompletesRegistrationOnlyAfterAcknowledgments() throws {
        var flow = NikonBLERegistration(); flow.confirmName(); flow.confirmTime()
        flow.observe(try NikonControlRequest(Data([0,1]))); flow.confirmAcknowledgment()
        XCTAssertFalse(flow.ready)
        flow.confirmConnection(); XCTAssertFalse(flow.ready)
        flow.observe(try NikonControlRequest(Data([1,0]))); flow.confirmTime()
        XCTAssertFalse(flow.ready); flow.confirmAcknowledgment()
        XCTAssertTrue(flow.ready); XCTAssertEqual(try flow.wakeCommand(),Data([1]))
    }
    func testSystemPairingStillRequiresLiveRegistrationIO() {
        var flow = NikonBLERegistration(systemPairingCompleted: true)
        XCTAssertFalse(flow.ready); flow.confirmName(); XCTAssertFalse(flow.ready)
        flow.confirmTime(); XCTAssertFalse(flow.ready); flow.confirmAcknowledgment(); XCTAssertTrue(flow.ready)
    }
    func testVerifiedReconnectAlsoRequiresNewClockAndControlAcknowledgments() {
        var flow = NikonBLERegistration(previouslyVerified: true)
        XCTAssertFalse(flow.ready); flow.confirmName(); flow.confirmTime(); XCTAssertFalse(flow.ready)
        flow.confirmAcknowledgment(); XCTAssertTrue(flow.ready)
    }
    func testCombinedControlRequestsKeepGPSAndReservedBits() throws {
        let request = try NikonControlRequest(Data([0x11,0xa1]))
        XCTAssertTrue(request.wantsTime); XCTAssertTrue(request.wantsConnection)
        XCTAssertEqual(request.acknowledgment(timeProvided: true,connectionProvided: true),Data([0x10,0xa0]))
        XCTAssertEqual(request.acknowledgment(timeProvided: false,connectionProvided: true),Data([0x11,0xa0]))
    }
    func testUnknownControlValuesAreNotGuessedOrCleared() throws {
        let request = try NikonControlRequest(Data([0x22,0x22]))
        XCTAssertFalse(request.wantsTime); XCTAssertFalse(request.wantsConnection)
        XCTAssertEqual(request.acknowledgment(timeProvided: true,connectionProvided: true),Data([0x22,0x22]))
        XCTAssertThrowsError(try NikonControlRequest(Data([1])))
    }
    func testActualRegistrationExchangeWritesClockThenAckThenBTEstablishment() async throws {
        let transport = RecordingGATT()
        let receipt = try await NikonRegistrationExchange.respond(to: Data([0x11,0xa1]),using: transport,now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(receipt.timeProvided); XCTAssertTrue(receipt.connectionProvided)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.characteristic),[0x2006,0x2008,0x2005])
        XCTAssertEqual(calls[0].data.count,10); XCTAssertEqual(calls[1].data,Data([0x10,0xa0])); XCTAssertEqual(calls[2].data,Data([2]))
        XCTAssertFalse(calls.contains { $0.characteristic == 0x2005 && $0.data == Data([1]) })
    }
    func testConnectionOnlyRequestIsNotIgnoredAfterPairingCodeConfirmation() async throws {
        let transport = RecordingGATT()
        _ = try await NikonRegistrationExchange.respond(to: Data([0,1]),using: transport)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.characteristic),[0x2008,0x2005])
        XCTAssertEqual(calls.map(\.data),[Data([0,0]),Data([2])])
    }
    func testFailedAckNeverSendsEstablishmentOrUnlocksWake() async throws {
        let transport = RecordingGATT(failure: 0x2008)
        var flow = NikonBLERegistration(); flow.confirmName(); flow.observe(try NikonControlRequest(Data([1,1])))
        do { _ = try await NikonRegistrationExchange.respond(to: Data([1,1]),using: transport); XCTFail("must fail") } catch {}
        let calls = await transport.calls
        XCTAssertFalse(calls.contains { $0.characteristic == 0x2005 }); XCTAssertFalse(flow.ready); XCTAssertThrowsError(try flow.wakeCommand())
    }
    func testGPSRequestWithoutLocationPermissionCausesNoWrites() async throws {
        let transport = RecordingGATT(); _ = try await NikonRegistrationExchange.respond(to: Data([0x10,0]),using: transport)
        let calls = await transport.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testRepeatConnectionRequestRevokesReadinessUntilServiced() throws {
        var flow = NikonBLERegistration(previouslyVerified: true); flow.confirmName(); flow.confirmTime(); flow.confirmAcknowledgment()
        XCTAssertTrue(flow.ready); flow.observe(try NikonControlRequest(Data([0,1])))
        XCTAssertFalse(flow.ready); flow.confirmAcknowledgment(); XCTAssertFalse(flow.ready); flow.confirmConnection(); XCTAssertTrue(flow.ready)
    }
    func testNamelessReconnectAdvertisementMatchesOnlySavedController() {
        XCTAssertEqual(NikonAdvertisement.controllerID(Data([0x99,3,1,0x33,0x22,0x11,0x1f])),0x11223301)
        XCTAssertNil(NikonAdvertisement.controllerID(Data([0x99,3,1])))
        XCTAssertNil(NikonAdvertisement.controllerID(Data([0x98,3,1,2,3,4])))
    }
    func testCancellationBeforeContinuationInstallResumesExactlyOnce() async {
        let gate = CallbackGate<Int>(); XCTAssertTrue(gate.resolve(.failure(CancellationError())))
        XCTAssertFalse(gate.resolve(.success(42)))
        do { _ = try await withCheckedThrowingContinuation { gate.install($0) }; XCTFail("must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testConcurrentCallbacksDeliverExactlyOneResult() async throws {
        let gate = CallbackGate<Int>()
        let result = Task { try await withCheckedThrowingContinuation { gate.install($0) } }
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for i in 0..<32 { group.addTask { gate.resolve(.success(i)) } }
            var count = 0; for await winner in group { if winner { count += 1 } }; return count
        }
        XCTAssertEqual(winners,1); let value = try await result.value; XCTAssertTrue((0..<32).contains(value))
        XCTAssertFalse(gate.resolve(.failure(ZoraError.timeout)))
    }
}

private actor RecordingGATT: NikonBLECommandSink {
    struct Write: Sendable { let characteristic: UInt16; let data: Data }
    var calls: [Write] = []
    let failure: UInt16?
    init(failure: UInt16? = nil) { self.failure = failure }
    func sendBLE(_ data: Data, characteristic: UInt16) async throws {
        calls.append(Write(characteristic: characteristic,data: data))
        if characteristic == failure { throw ZoraError.disconnected }
    }
}

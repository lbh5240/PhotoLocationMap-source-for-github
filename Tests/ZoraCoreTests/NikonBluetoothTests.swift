import Foundation
import XCTest
@testable import ZoraCore

final class NikonBluetoothTests: XCTestCase {
    private let first = NikonPairingFrame(stage: 1, timestamp: 0x677da144ec13e1db, device: 0x3c3ae501, nonce: 0x3fdaa451)
    private let challenge = NikonPairingFrame(stage: 2, timestamp: 0xb9943d5e8026fa29, device: 0xa8b3f2e4, nonce: 0x16d56a13)
    private var confirmation: Data {
        var result = Data(repeating: 0, count: 17); result[0] = 4
        result.replaceSubrange(9..<16, with: Data("B123456".utf8)); return result
    }
    func testStandardBlowfishKnownAnswer() {
        let cipher = NikonBlowfish(key: Array(repeating: 0, count: 8))
        let block = cipher.encrypt(0, 0)
        XCTAssertEqual(block.0, 0x4ef99745); XCTAssertEqual(block.1, 0x6198dd78)
    }
    func testPublishedZ50IIChallengeVectorNotZ7IIHardwareTest() throws {
        var h = try NikonBLEHandshake(initial: first)
        let result = try XCTUnwrap(h.receive(challenge.data))
        XCTAssertEqual(result, Data([3,0xdb,0xe1,0x13,0xec,0x44,0xa1,0x7d,0x67,0x53,0xad,0xf1,0x79,0x35,0x8a,0x83,0x23]))
        XCTAssertEqual(h.phase, .confirmation)
        XCTAssertThrowsError(try h.wifiWakeCommand())
        XCTAssertNil(try h.receive(confirmation))
        XCTAssertEqual(h.phase, .authenticated); XCTAssertEqual(h.serial, "B123456")
        XCTAssertEqual(try h.wifiWakeCommand(), Data([1]))
        XCTAssertThrowsError(try h.receive(confirmation))
    }
    func testTamperedChallengeNeverEnablesWake() throws {
        var h = try NikonBLEHandshake(initial: first)
        var data = challenge.data; data[9] ^= 1
        XCTAssertThrowsError(try h.receive(data)); XCTAssertEqual(h.phase, .challenge)
        XCTAssertThrowsError(try h.wifiWakeCommand())
    }
    func testOutOfOrderAndMalformedFramesRejected() throws {
        var h = try NikonBLEHandshake(initial: first)
        XCTAssertThrowsError(try h.receive(confirmation))
        XCTAssertThrowsError(try h.receive(challenge.data + Data([0])))
        XCTAssertThrowsError(try h.receive(Data()))
        _ = try h.receive(challenge.data)
        XCTAssertThrowsError(try h.receive(challenge.data))
        var bad = confirmation; bad[10] = 0xff
        XCTAssertThrowsError(try h.receive(bad)); XCTAssertThrowsError(try h.wifiWakeCommand())
    }
    func testLittleEndianFrameRoundTripPreservesUInt64() throws {
        let f = NikonPairingFrame(stage: 2, timestamp: UInt64.max, device: 0x12345678, nonce: UInt32.max)
        XCTAssertEqual(try NikonPairingFrame(data: f.data), f)
        XCTAssertEqual(Array(f.data[9..<13]), [0x78,0x56,0x34,0x12])
    }
    func testNewIdentityAndReconnectUseFreshChallenge() {
        let h = NikonBLEHandshake(); XCTAssertEqual(h.initial.device & 255, 1)
        let identity = NikonBLEIdentity(peripheralID: UUID(), device: first.device, nonce: first.nonce, serial: "B123456")
        let reused = NikonBLEHandshake(identity: identity)
        XCTAssertEqual(reused.initial.device, first.device); XCTAssertEqual(reused.initial.nonce, first.nonce)
        XCTAssertNotEqual(reused.initial.timestamp, first.timestamp)
    }
    func testTimePayloadHandlesNegativeFractionalTimezone() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(NikonBLEPayload.time(date, timeZone: TimeZone(secondsFromGMT: -12600)!),
            Data([0xb2,0x07,1,1,0,0,0,0,0xfd,0xe2]))
        XCTAssertEqual(NikonBLEPayload.time(date, timeZone: TimeZone(secondsFromGMT: 28800)!).suffix(2), Data([8,0]))
    }
    func testClientNameIsFixedASCIIAndRejectsOverflow() throws {
        XCTAssertEqual(try NikonBLEPayload.controllerName("ZORA Camera").count, 32)
        XCTAssertThrowsError(try NikonBLEPayload.controllerName("相机"))
        XCTAssertThrowsError(try NikonBLEPayload.controllerName(String(repeating: "a", count: 32)))
    }
    func testReconnectIsBoundedAndBacksOff() {
        XCTAssertEqual((0..<6).map { NikonBLEPayload.reconnectDelay(attempt: $0) }, [2,4,8,16,30,nil])
        XCTAssertNil(NikonBLEPayload.reconnectDelay(attempt: -1))
    }
}

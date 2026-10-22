import XCTest
@testable import ZoraCore

final class ProtocolTests: XCTestCase {
    func testOperationWireVector() throws {
        let packet = try PTPPacket.operation(0x100E, transaction: 7, parameters: [0, 0])
        XCTAssertEqual(SHA256Digest.hex(packet.encoded), "1a00000006000000010000000e10070000000000000000000000")
    }
    func testFramerEverySplitBoundaryAndCoalescing() throws {
        let packet = try PTPPacket.operation(0x1001, transaction: 0)
        for boundary in 0...packet.encoded.count {
            var framer = PTPFramer()
            let first = try framer.feed(Data(packet.encoded.prefix(boundary)))
            let second = try framer.feed(Data(packet.encoded.dropFirst(boundary)))
            XCTAssertEqual(first + second, [packet])
        }
        var framer = PTPFramer()
        XCTAssertEqual(try framer.feed(packet.encoded + packet.encoded), [packet, packet])
    }
    func testFramerRejectsUnderflowAndOversize() {
        for n: UInt32 in [0, 7, UInt32.max] {
            var bytes = Data(); bytes.appendLE(n); bytes.appendLE(UInt32(7)); var f = PTPFramer()
            XCTAssertThrowsError(try f.feed(bytes))
        }
    }
    func testReaderTruncationDoesNotCrash() {
        for n in 0..<4 { var r = BinaryReader(Data(repeating: 0, count: n)); XCTAssertThrowsError(try r.integer(UInt32.self)) }
        var r = BinaryReader(Data([255])); XCTAssertThrowsError(try r.ptpString())
    }
    func testInitializationHasGUIDNameAndVersion() {
        let p = PTPPacket.initialize(guid: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!, name: "Z")
        XCTAssertEqual(SHA256Digest.hex(p.payload), "00112233445566778899aabbccddeeff5a00000000000100")
    }
    func testTransactionRejectsWrongIDAndLength() throws {
        var transaction = PTPTransaction(id: 1)
        var data = Data(); data.appendLE(UInt32(2)); data.appendLE(UInt64(0))
        XCTAssertThrowsError(try transaction.consume(.init(type: 9, payload: data)))
        var t = PTPTransaction(id: 1); data = Data(); data.appendLE(UInt32(1)); data.appendLE(UInt64(10))
        XCTAssertNil(try t.consume(.init(type: 9, payload: data)))
        XCTAssertThrowsError(try t.consume(response(id: 1)))
    }
    func testCompleteTransactionDataPhase() throws {
        var t = PTPTransaction(id: 1)
        var start = Data(); start.appendLE(UInt32(1)); start.appendLE(UInt64(3))
        var end = Data(); end.appendLE(UInt32(1)); end.append(contentsOf: [1, 2, 3])
        XCTAssertNil(try t.consume(.init(type: 9, payload: start)))
        XCTAssertNil(try t.consume(.init(type: 12, payload: end)))
        XCTAssertEqual(try t.consume(response(id: 1))?.data, Data([1, 2, 3]))
    }
    func testLiveViewHeaderAndTruncation() throws {
        let jpeg = Data([0xff,0xd8,0xff,0xe0,0,0,0xff,0xd9])
        XCTAssertEqual(try LiveViewJPEG.extract(Data(repeating: 0, count: 384)+jpeg), jpeg)
        XCTAssertThrowsError(try LiveViewJPEG.extract(Data(jpeg.dropLast())))
    }
    func testScalarPropertyEnumGatesWrites() throws {
        var data = Data(); data.appendLE(UInt16(0x500F)); data.appendLE(UInt16(4)); data.append(1)
        data.appendLE(UInt16(100)); data.appendLE(UInt16(200)); data.append(2); data.appendLE(UInt16(2)); data.appendLE(UInt16(100)); data.appendLE(UInt16(200))
        let property = try CameraProperty(data: data)
        XCTAssertEqual(property.current, 200); XCTAssertEqual(try property.encode(100), Data([100, 0]))
        XCTAssertThrowsError(try property.encode(400))
    }
    func testDeviceInfoCapabilities() throws {
        var data = Data(); data.appendLE(UInt16(100)); data.appendLE(UInt32(10)); data.appendLE(UInt16(100)); data.append(0); data.appendLE(UInt16(0))
        let ops: [UInt16] = [0x1001, 0x1002, 0x9201, 0x9202, 0x9203]
        data.appendLE(UInt32(ops.count)); for op in ops { data.appendLE(op) }
        for _ in 0..<4 { data.appendLE(UInt32(0)) }
        for string in ["Nikon", "Z 7_2", "1.00", "redacted"] {
            data.append(UInt8(string.utf16.count+1)); for c in string.utf16 { data.appendLE(c) }; data.appendLE(UInt16(0))
        }
        let info = try CameraDeviceInfo(data: data)
        XCTAssertEqual(info.model, "Z 7_2"); XCTAssertTrue(info.canLiveView)
    }
    private func response(id: UInt32) -> PTPPacket {
        var p = Data(); p.appendLE(UInt16(0x2001)); p.appendLE(id); return .init(type: 7, payload: p)
    }
}

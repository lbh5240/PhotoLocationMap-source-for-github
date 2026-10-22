import XCTest
@testable import ZoraCore

final class ImagingTests: XCTestCase {
    func testIdentityCubeAndInvalidRows() throws {
        let text = "LUT_3D_SIZE 2\n" + ["0 0 0", "1 0 0", "0 1 0", "1 1 0", "0 0 1", "1 0 1", "0 1 1", "1 1 1"].joined(separator: "\n")
        let lut = try CubeLUT(text: text)
        XCTAssertEqual(lut.dimension, 2); XCTAssertEqual(lut.rgba.count, 32)
        XCTAssertEqual(lut.rgba[4], 1); XCTAssertEqual(lut.rgba[7], 1)
        XCTAssertThrowsError(try CubeLUT(text: text+"\n0 0 0"))
        XCTAssertThrowsError(try CubeLUT(text: text.replacingOccurrences(of: "1 1 1", with: "nan 1 1")))
        XCTAssertThrowsError(try CubeLUT(text: "LUT_3D_SIZE 999\n"))
    }
    func testRecipeValidation() throws {
        XCTAssertEqual(try Recipe.presets[0].validated().name, "原色")
        XCTAssertThrowsError(try Recipe(name: "bad", exposure: .nan).validated())
        XCTAssertThrowsError(try Recipe(name: "bad", contrast: 9).validated())
    }
    func testMonitorHistogramAndClipping() throws {
        let frame = try FrameAnalysis(rgba: [0,0,0,255,255,255,255,255], width: 2, height: 1)
        XCTAssertEqual(frame.histogram[0], 1); XCTAssertEqual(frame.histogram[255], 1)
        XCTAssertEqual(frame.clippedFraction, 0.5); XCTAssertEqual(frame.zebra, [0, 255])
        XCTAssertThrowsError(try FrameAnalysis(rgba: [], width: Int.max, height: 0))
    }
    func testPeakingFindsAnEdge() throws {
        var rgba = [UInt8]()
        for _ in 0..<3 { for x in 0..<3 { let c: UInt8 = x == 2 ? 255 : 0; rgba += [c,c,c,255] } }
        let result = try FrameAnalysis(rgba: rgba, width: 3, height: 3)
        XCTAssertEqual(result.peaking[4], 255)
    }
}

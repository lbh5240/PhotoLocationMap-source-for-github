import Foundation
import XCTest
@testable import ZoraCore

/// 0.5 feature fixtures. They verify real code paths and parameter encoding, not Z7 II interoperability.
final class FeatureTests: XCTestCase, @unchecked Sendable {
    // MARK: Property presentation
    func testPropertyLabelsUsePhotographicNotation() {
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x5007, value: 560), "f/5.6")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x5007, value: 1100), "f/11")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x500D, value: 40), "1/250")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x500D, value: 1), "1/8000")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x500D, value: 3333), "1/3")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x500D, value: 25000), "2.5\"")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x500D, value: 0xFFFFFFFF), "B 门")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0xD100, value: 0x00010FA0), "1/4000")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0xD100, value: 0x000D000A), "1.3\"")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x5010, value: -333), "-0.3 EV")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x5010, value: 667), "+0.7 EV")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x5010, value: 0), "±0 EV")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x500F, value: 64), "ISO 64")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x500e, value: 3), "A 光圈优先")
        XCTAssertEqual(CameraPropertyFormat.describe(code: 0x5005, value: 0x9999), "0x9999")
    }
    func testOptionsExpandOnlySmallRanges() throws {
        let small = try CameraProperty(data: rangeProperty(code: 0x500F, low: 100, high: 6400, step: 100, current: 100))
        XCTAssertEqual(small.options.count, 64); XCTAssertEqual(small.options.first, 100)
        let large = try CameraProperty(data: rangeProperty(code: 0x500F, low: 0, high: 100000, step: 1, current: 1))
        XCTAssertTrue(large.options.isEmpty)
    }
    // MARK: Sequences
    func testBracketUsesOnlyCameraDeclaredValuesInCameraOrder() throws {
        let ev = try CameraProperty(data: enumProperty(code: 0x5010, values: [-1000,-667,-333,0,333,667,1000], current: 0))
        XCTAssertEqual(try BracketPlan(property: ev, frames: 3, spacing: 3).values, [0,-1000,1000])
        XCTAssertEqual(try BracketPlan(property: ev, frames: 5, spacing: 1).values, [0,-333,333,-667,667])
        XCTAssertThrowsError(try BracketPlan(property: ev, frames: 5, spacing: 3))
        XCTAssertThrowsError(try BracketPlan(property: ev, frames: 4, spacing: 1))
        let readOnly = try CameraProperty(data: enumProperty(code: 0x5010, values: [-333,0,333], current: 0, writable: false))
        XCTAssertThrowsError(try BracketPlan(property: readOnly, frames: 3, spacing: 1))
        let packed = try CameraProperty(data: enumProperty(code: 0xD100, values: [1,2,3], current: 2))
        XCTAssertThrowsError(try BracketPlan(property: packed, frames: 3, spacing: 1))
    }
    func testIntervalPlanSkipsOverrunSlotsInsteadOfBursting() throws {
        let plan = try IntervalPlan(shots: 5, interval: 10, startDelay: 2).validated()
        XCTAssertEqual(plan.offset(of: 0), 2); XCTAssertEqual(plan.totalDuration, 42)
        XCTAssertEqual(plan.nextIndex(after: 0, elapsed: 5), 1)
        XCTAssertEqual(plan.nextIndex(after: 0, elapsed: 25), 3)
        XCTAssertNil(plan.nextIndex(after: 4, elapsed: 50))
        XCTAssertThrowsError(try IntervalPlan(shots: 0, interval: 10).validated())
        XCTAssertThrowsError(try IntervalPlan(shots: 2, interval: .nan).validated())
        XCTAssertEqual(IntervalPlan.selfTimer(5).shots, 1)
        XCTAssertThrowsError(try FocusStackPlan(shots: 1, steps: 10).validated())
    }
    // MARK: Events
    func testNikonCheckEventParsingAndSessionPolling() async throws {
        let list = eventList([(0x4002, 77), (0x4006, 0x5007)])
        let parsed = try NikonEventList.parse(list)
        XCTAssertEqual(parsed.count, 2); XCTAssertEqual(parsed[0].addedObject, 77); XCTAssertTrue(parsed[1].changesProperty)
        XCTAssertThrowsError(try NikonEventList.parse(Data(list.dropLast())))
        let fixture = FeatureFixture(operations: [0x1001, 0x90c7]); await fixture.setEvents(list)
        let camera = session(); _ = try await camera.connect(using: fixture)
        let received = try await camera.pollEvents(); XCTAssertEqual(received, 2)
        let first = await camera.events(after: 0); XCTAssertEqual(first.events.map(\.code), [0x4002, 0x4006]); XCTAssertEqual(first.latest, 2)
        let none = await camera.events(after: first.latest); XCTAssertTrue(none.events.isEmpty)
        let revision = await camera.storageRevision; XCTAssertEqual(revision, 1)
        try await camera.disconnect()
        let silent = FeatureFixture(operations: [0x1001]); let other = session(); _ = try await other.connect(using: silent)
        let zero = try await other.pollEvents(); XCTAssertEqual(zero, 0)
        let calls = await silent.calls; XCTAssertEqual(calls.map(\.code), [0x1001])
        try await other.disconnect()
    }
    // MARK: Touch AF
    func testLiveViewGeometryRequiresHeaderMatchingJPEG() throws {
        let payload = liveViewPayload(header: [640, 424, 8256, 5504])
        let geometry = try XCTUnwrap(LiveViewGeometry.parse(payload))
        XCTAssertEqual(geometry, LiveViewGeometry(jpegWidth: 640, jpegHeight: 424, wholeWidth: 8256, wholeHeight: 5504))
        let point = try geometry.sensorPoint(x: 0.5, y: 0.5); XCTAssertEqual(point.x, 4128); XCTAssertEqual(point.y, 2752)
        XCTAssertThrowsError(try geometry.sensorPoint(x: 1.2, y: 0))
        XCTAssertNil(LiveViewGeometry.parse(liveViewPayload(header: [])))
        XCTAssertNil(LiveViewGeometry.parse(liveViewPayload(header: [640, 424, 300, 200])))
        XCTAssertNil(LiveViewGeometry.parse(liveViewPayload(header: [100, 100, 8256, 5504])))
    }
    func testTouchAFNeedsLiveViewAndSendsSensorCoordinates() async throws {
        let fixture = FeatureFixture(operations: [0x1001, 0x9201, 0x9202, 0x9205]); let camera = session(); _ = try await camera.connect(using: fixture)
        let geometry = LiveViewGeometry(jpegWidth: 640, jpegHeight: 424, wholeWidth: 8256, wholeHeight: 5504)
        do { try await camera.setAFArea(x: 0.5, y: 0.5, geometry: geometry); XCTFail("needs live view") } catch {}
        try await camera.startLiveView(); try await camera.setAFArea(x: 0.25, y: 0.5, geometry: geometry)
        let calls = await fixture.calls
        XCTAssertEqual(calls.map(\.code), [0x1001, 0x9201, 0x9205]); XCTAssertEqual(calls[2].parameters, [2064, 2752])
        try await camera.disconnect()
    }
    // MARK: Files
    func testDeleteIsCapabilityGatedAndMarksDirectoryChanged() async throws {
        let gated = FeatureFixture(operations: [0x1001]); let a = session(); _ = try await a.connect(using: gated)
        do { try await a.deleteObject(5); XCTFail("must gate") } catch {}
        let gatedCalls = await gated.calls; XCTAssertEqual(gatedCalls.count, 1); try await a.disconnect()
        let fixture = FeatureFixture(operations: [0x1001, 0x100b]); let camera = session(); _ = try await camera.connect(using: fixture)
        try await camera.deleteObject(5)
        let calls = await fixture.calls; XCTAssertEqual(calls.last?.code, 0x100b); XCTAssertEqual(calls.last?.parameters, [5, 0])
        let revision = await camera.storageRevision; XCTAssertEqual(revision, 1)
        try await camera.disconnect()
    }
    func testObjectInfoReadsOptionalCaptureDateAndKind() throws {
        let dated = try CameraObject(handle: 3, data: objectInfo(name: "DSC_0001.NEF", size: 10, date: "20261103T101530"))
        XCTAssertEqual(dated.kind, .raw); XCTAssertEqual(dated.displayDate, "2026-11-03 10:15"); XCTAssertEqual(dated.storage, 0x10001)
        let plain = try CameraObject(handle: 4, data: objectInfo(name: "DSC_0002.JPG", size: 10, date: nil))
        XCTAssertEqual(plain.kind, .jpeg); XCTAssertEqual(plain.captureDate, ""); XCTAssertNotEqual(plain.sourceKey, dated.sourceKey)
    }
    func testInterruptedChunkDownloadResumesAfterReconnect() async throws {
        let size = UInt32(10*1024*1024 + 5)
        let fixture = FeatureFixture(operations: [0x1001, 0x101b]); await fixture.configureDownload(size: size, failOnChunk: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zora-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let object = try CameraObject(handle: 9, data: objectInfo(name: "DSC_0009.NEF", size: size, date: "20261103T101530"))
        let target = directory.appendingPathComponent("out.nef")
        let camera = session(); _ = try await camera.connect(using: fixture)
        do { try await camera.download(object, to: target); XCTFail("first attempt must fail") } catch {}
        let partial = directory.appendingPathComponent(CameraSession.partialName(for: object))
        let kept = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
        XCTAssertEqual(kept?.uint64Value, 4*1024*1024); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        _ = try await camera.connect(using: fixture)
        let progress = ProgressRecorder()
        try await camera.download(object, to: target) { value in progress.record(value) }
        let offsets = await fixture.calls.filter { $0.code == 0x101b }.map { $0.parameters[1] }
        XCTAssertEqual(offsets, [0, 4*1024*1024, 4*1024*1024, 8*1024*1024])
        let bytes = try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber
        XCTAssertEqual(bytes?.uint64Value, UInt64(size)); XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let file = try FileHandle(forReadingFrom: target); defer { try? file.close() }
        try file.seek(toOffset: 4*1024*1024); XCTAssertEqual(try file.read(upToCount: 1), Data([1]))
        try file.seek(toOffset: UInt64(size) - 1); XCTAssertEqual(try file.read(upToCount: 1), Data([2]))
        XCTAssertEqual(progress.values.first?.resumedFrom, 4*1024*1024); XCTAssertEqual(progress.values.last?.fraction, 1)
        try await camera.disconnect()
    }
    func testWaitUntilReadyPollsBusyCameraWithinBound() async throws {
        let fixture = FeatureFixture(operations: [0x1001, 0x90c8]); await fixture.queueFailures(0x90c8, [0x2019, 0x2019])
        let camera = session(); _ = try await camera.connect(using: fixture)
        try await camera.waitUntilReady()
        let calls = await fixture.calls; XCTAssertEqual(calls.filter { $0.code == 0x90c8 }.count, 3)
        try await camera.disconnect()
    }
    // MARK: Library, looks and location
    func testLibraryFavoritesRatingDeleteAndCameraDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("staging.jpg"); try Data([1,2,3]).write(to: source)
        let libraryRoot = root.appendingPathComponent("library")
        let library = try AssetLibrary(root: libraryRoot)
        let location = GeoTag(latitude: 31.2, longitude: 121.5, timestamp: Date(timeIntervalSince1970: 1_000_000))
        let asset = try await library.importFile(source, originalName: "DSC_0001.JPG", sourceKey: "k1", location: location)
        XCTAssertEqual(asset.originalName, "DSC_0001.JPG")
        do { _ = try await library.importFile(source, sourceKey: "k1"); XCTFail("duplicate camera import") } catch {}
        try await library.setFavorite(true, for: asset.id); try await library.setRating(4, for: asset.id)
        do { try await library.setRating(6, for: asset.id); XCTFail("rating range") } catch {}
        let reload = try AssetLibrary(root: libraryRoot); let items = await reload.assets()
        XCTAssertTrue(items[0].isFavorite); XCTAssertEqual(items[0].rating, 4); XCTAssertEqual(items[0].location, location)
        let file = try await reload.url(for: items[0])
        try await reload.delete(asset.id)
        let remaining = await reload.assets(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let legacy = #"[{"id":"00000000-0000-0000-0000-0000000000AA","originalName":"a.nef","storedName":"a.nef","importedAt":0,"bytes":4}]"#
        let legacyRoot = root.appendingPathComponent("legacy"); try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: legacyRoot.appendingPathComponent("library.json"))
        let old = try AssetLibrary(root: legacyRoot); let oldItems = await old.assets()
        XCTAssertEqual(oldItems.count, 1); XCTAssertFalse(oldItems[0].isFavorite); XCTAssertNil(oldItems[0].sourceKey)
    }
    func testRecipeDecodesLegacyJSONAndValidatesNewControls() throws {
        let json = #"{"id":"00000000-0000-0000-0000-0000000000BB","name":"旧风格","exposure":0.5,"contrast":1.1,"saturation":0.9,"temperature":5000}"#
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8)).validated()
        XCTAssertEqual(recipe.grain, 0); XCTAssertEqual(recipe.highlightRecovery, 0); XCTAssertEqual(recipe.exposure, 0.5)
        let roundTrip = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(Recipe(name: "x", vignette: 0.4)))
        XCTAssertEqual(roundTrip.vignette, 0.4)
        XCTAssertThrowsError(try Recipe(name: "x", grain: 2).validated())
        for preset in Recipe.presets { XCTAssertNoThrow(try preset.validated()); XCTAssertTrue(preset.isPreset) }
        XCTAssertEqual(Set(Recipe.presets.map(\.id)).count, Recipe.presets.count)
    }
    func testGeoTagProducesImageIOGPSDictionary() throws {
        let tag = try GeoTag(latitude: -33.5, longitude: 151.25, altitude: -10, accuracy: 5, timestamp: Date(timeIntervalSince1970: 0)).validated()
        let gps = tag.exifGPS()
        XCTAssertEqual(gps["LatitudeRef"] as? String, "S"); XCTAssertEqual(gps["Latitude"] as? Double, 33.5)
        XCTAssertEqual(gps["LongitudeRef"] as? String, "E"); XCTAssertEqual(gps["AltitudeRef"] as? Int, 1)
        XCTAssertEqual(gps["DateStamp"] as? String, "1970:01:01"); XCTAssertEqual(gps["TimeStamp"] as? String, "00:00:00.00")
        XCTAssertThrowsError(try GeoTag(latitude: 91, longitude: 0).validated())
        XCTAssertFalse(tag.isFresh(at: Date(timeIntervalSince1970: 3600)))
    }
    // MARK: Upload
    func testQueueRecordsSizeConfirmationAndCanBeCleared() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.nef"); try Data([7]).write(to: file)
        let destination = NASDestination(kind: .webDAV, endpoint: URL(string: "https://nas.example/dav")!, prefix: "Photos")
        let queue = try UploadQueue(store: root.appendingPathComponent("q.json"))
        try await queue.enqueue(file: file, key: "a.nef", destination: destination)
        try await queue.enqueue(file: file, key: "b.nef", destination: destination)
        try await queue.drain(using: ConfirmingTransport(confirm: true), online: true)
        var jobs = await queue.snapshot(); XCTAssertEqual(jobs.map(\.remoteVerified), [true, true])
        try await queue.remove(jobs[1].id); try await queue.clearCompleted()
        jobs = await queue.snapshot(); XCTAssertTrue(jobs.isEmpty)
        try await queue.enqueue(file: file, key: "c.nef", destination: destination)
        try await queue.drain(using: ConfirmingTransport(confirm: false), online: true)
        jobs = await queue.snapshot(); XCTAssertEqual(jobs[0].state, .complete); XCTAssertNil(jobs[0].remoteVerified)
    }
    func testS3SignerSignsMethod() throws {
        let url = URL(string: "https://nas.example/bucket/a.nef")!, credential = NASCredential(username: "a", secret: "b")
        let put = try S3Signer.sign(url: url, payloadHash: "h", credential: credential, region: "us-east-1", date: Date(timeIntervalSince1970: 0))
        let head = try S3Signer.sign(url: url, method: "HEAD", payloadHash: "h", credential: credential, region: "us-east-1", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(head.httpMethod, "HEAD"); XCTAssertNotEqual(put.value(forHTTPHeaderField: "Authorization"), head.value(forHTTPHeaderField: "Authorization"))
    }
    private func session() -> CameraSession { CameraSession(guid: UUID()) { _,_ in throw ZoraError.unsupported("fixture must never use TCP") } }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DownloadProgress] = []
    func record(_ value: DownloadProgress) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return stored }
}

private actor ConfirmingTransport: UploadTransport {
    let confirm: Bool
    init(confirm: Bool) { self.confirm = confirm }
    func upload(file: URL, key: String, destination: NASDestination) async throws { _ = try Data(contentsOf: file) }
    func uploadConfirmingSize(file: URL, key: String, destination: NASDestination) async throws -> Bool {
        try await upload(file: file, key: key, destination: destination); return confirm
    }
}

private func ptpText(_ s: String) -> Data {
    var d = Data([UInt8(s.utf16.count+1)]); for c in s.utf16 { d.appendLE(c) }; d.appendLE(UInt16(0)); return d
}
private func objectInfo(name: String, size: UInt32, date: String?) -> Data {
    var d = Data(); d.appendLE(UInt32(0x10001)); d.appendLE(UInt16(0x3000)); d.appendLE(UInt16(0)); d.appendLE(size)
    d.append(Data(repeating: 0, count: 40)); d.append(ptpText(name))
    if let date { d.append(ptpText(date)); d.append(ptpText(date)) }
    return d
}
private func enumProperty(code: UInt16, values: [Int64], current: Int64, writable: Bool = true) -> Data {
    var d = Data(); d.appendLE(code); d.appendLE(UInt16(5)); d.append(writable ? 1 : 0)
    d.appendLE(Int32(current)); d.appendLE(Int32(current)); d.append(2); d.appendLE(UInt16(values.count))
    for v in values { d.appendLE(Int32(v)) }; return d
}
private func rangeProperty(code: UInt16, low: Int64, high: Int64, step: Int64, current: Int64) -> Data {
    var d = Data(); d.appendLE(code); d.appendLE(UInt16(6)); d.append(1)
    for v in [current, current, low, high, step] { d.appendLE(UInt32(v)) }
    // Form byte sits between current value and range fields.
    d.insert(1, at: 13); return d
}
private func eventList(_ entries: [(UInt16, UInt32)]) -> Data {
    var d = Data(); d.appendLE(UInt16(entries.count)); for (code, parameter) in entries { d.appendLE(code); d.appendLE(parameter) }; return d
}
/// Big-endian header pairs followed by a minimal baseline JPEG of 640×424.
private func liveViewPayload(header: [UInt16]) -> Data {
    var d = Data(); for value in header { d.append(UInt8(value >> 8)); d.append(UInt8(value & 0xff)) }
    if !header.isEmpty { d.append(Data(repeating: 0, count: 8)) }
    d.append(contentsOf: [0xff,0xd8, 0xff,0xc0, 0x00,0x11, 0x08, 0x01,0xa8, 0x02,0x80, 0x03, 1,0x22,0, 2,0x11,1, 3,0x11,1, 0xff,0xd9])
    return d
}
private func deviceInfo(operations: [UInt16]) -> Data {
    var d = Data(); d.appendLE(UInt16(100)); d.appendLE(UInt32(10)); d.appendLE(UInt16(100)); d.append(0); d.appendLE(UInt16(0))
    d.appendLE(UInt32(operations.count)); for op in operations { d.appendLE(op) }
    for _ in 0..<4 { d.appendLE(UInt32(0)) }
    for s in ["Nikon", "Z 7_2", "FIXTURE", "FIXTURE0001"] { d.append(ptpText(s)) }
    return d
}

private actor FeatureFixture: PTPDirectTransport {
    struct Call: Sendable { let code: UInt16; let parameters: [UInt32] }
    let operations: [UInt16]
    var calls: [Call] = []
    var failures: [UInt16: [UInt16]] = [:]
    var events = Data([0, 0])
    var size: UInt32 = 0, failOnChunk: Int?, chunkCalls = 0
    var sink: AsyncStream<CameraTransportEvent>.Continuation?
    init(operations: [UInt16]) { self.operations = operations }
    func setEvents(_ data: Data) { events = data }
    func queueFailures(_ code: UInt16, _ responses: [UInt16]) { failures[code] = responses }
    func configureDownload(size: UInt32, failOnChunk: Int?) { self.size = size; self.failOnChunk = failOnChunk }
    func open() async throws {}
    func close() async { sink?.finish(); sink = nil }
    func eventStream() -> AsyncStream<CameraTransportEvent> {
        let pair = AsyncStream<CameraTransportEvent>.makeStream(); sink = pair.continuation; return pair.stream
    }
    func execute(code: UInt16, transaction: UInt32, parameters: [UInt32], sending: Data?) async throws -> PTPResult {
        calls.append(Call(code: code, parameters: parameters))
        if var queued = failures[code], !queued.isEmpty {
            let response = queued.removeFirst(); failures[code] = queued; throw ZoraError.cameraResponse(response)
        }
        switch code {
        case 0x1001: return PTPResult(data: deviceInfo(operations: operations), parameters: [])
        case 0x90c7: let data = events; events = Data([0, 0]); return PTPResult(data: data, parameters: [])
        case 0x101b:
            defer { chunkCalls += 1 }
            if chunkCalls == failOnChunk { throw ZoraError.timeout }
            let count = min(parameters[2], size - parameters[1])
            return PTPResult(data: Data(repeating: UInt8(parameters[1] / (4*1024*1024)), count: Int(count)), parameters: [count])
        default: return PTPResult(data: Data(), parameters: [])
        }
    }
}

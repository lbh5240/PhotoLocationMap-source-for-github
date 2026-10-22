import XCTest
@testable import ZoraCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StorageTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func destination() -> NASDestination { .init(kind: .webDAV, endpoint: URL(string: "https://nas.example/dav")!, prefix: "Photos") }
    func testSHA256PublishedVectors() {
        XCTAssertEqual(SHA256Digest.hex(SHA256Digest.hash(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(SHA256Digest.hash(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(SHA256Digest.hash(Data(repeating: 0x61, count: 1000000))), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
    func testHMACRFC4231() {
        XCTAssertEqual(SHA256Digest.hex(SHA256Digest.hmac(key: Data(repeating: 0x0b, count: 20), message: Data("Hi There".utf8))), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }
    func testS3SigningFixedVector() throws {
        let request = try S3Signer.sign(url: URL(string: "https://nas.example:9000/photos/a%20b.jpg")!, payloadHash: SHA256Digest.hex(SHA256Digest.hash(Data("hello".utf8))), credential: .init(username: "test", secret: "secret"), region: "us-east-1", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "19700101T000000Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "nas.example:9000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=test/19700101/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=bd09923ba7c5ea1db64c862e1cf80cdd200e6726985eee59b2efdf76ac0f87be")
    }
    func testTargetEncodesUnicodeAndRejectsHTTPTraversal() throws {
        let url = try destination().target(key: "照片 1.nef")
        XCTAssertTrue(url.absoluteString.contains("%20")); XCTAssertTrue(url.path.hasSuffix("Photos/照片 1.nef"))
        XCTAssertThrowsError(try destination().target(key: "../secret"))
        var d = destination(); d.endpoint = URL(string: "http://nas.example")!
        XCTAssertThrowsError(try d.validated())
    }
    func testS3CanonicalPathEncodesReservedCharacters() throws {
        XCTAssertEqual(S3Signer.encodedPath("/照片/a!b+c@d.nef"), "/%E7%85%A7%E7%89%87/a%21b%2Bc%40d.nef")
        let request = try S3Signer.sign(url: URL(string: "https://nas.example/bucket/a!b+c.nef")!, payloadHash: "hash", credential: .init(username: "a", secret: "b"), region: "us-east-1", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/bucket/a%21b%2Bc.nef")
    }
    func testLibraryImportPreservesRAWAndPersistsRecipe() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("test.nef"), bytes = Data([1,2,3,4])
        try bytes.write(to: source)
        let libraryRoot = root.appendingPathComponent("library")
        let library = try AssetLibrary(root: libraryRoot)
        let asset = try await library.importFile(source)
        XCTAssertTrue(asset.isRAW)
        try await library.apply(Recipe.presets[1], to: asset.id)
        let reload = try AssetLibrary(root: libraryRoot)
        let items = await reload.assets(); XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].recipe?.name, "琥珀日光")
        let importedURL = try await library.url(for: asset)
        XCTAssertEqual(try Data(contentsOf: importedURL), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testOfflineQueueRestartsDeduplicatesAndCompletes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.nef"); try Data([42]).write(to: file)
        let store = root.appendingPathComponent("queue.json"), destination = destination()
        let queue = try UploadQueue(store: store)
        try await queue.enqueue(file: file, key: "a.nef", destination: destination)
        try await queue.enqueue(file: file, key: "a.nef", destination: destination)
        let transport = RecordingTransport()
        try await queue.drain(using: transport, online: false)
        let before = await transport.calls; XCTAssertEqual(before, 0)
        let reopened = try UploadQueue(store: store)
        try await reopened.drain(using: transport, online: true)
        let jobs = await reopened.snapshot(); XCTAssertEqual(jobs.count, 1); XCTAssertEqual(jobs.first?.state, .complete)
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
    }
    func testTransientFailureBackoffAndPermanentAuthFailure() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jpg"); try Data([1]).write(to: file)
        let queue = try UploadQueue(store: root.appendingPathComponent("q.json"))
        try await queue.enqueue(file: file, key: "a.jpg", destination: destination())
        let now = Date(), transport = RecordingTransport(failure: .http(503))
        try await queue.drain(using: transport, online: true, now: now)
        var jobs = await queue.snapshot(); XCTAssertEqual(jobs[0].state, .retry); XCTAssertGreaterThan(jobs[0].nextAttempt, now)
        try await queue.drain(using: transport, online: true, now: now)
        let attempts = await transport.calls; XCTAssertEqual(attempts, 1)
        try await queue.drain(using: RecordingTransport(failure: .http(401)), online: true, now: now.addingTimeInterval(30))
        jobs = await queue.snapshot(); XCTAssertEqual(jobs[0].state, .blocked)
        try await queue.retryBlocked(); jobs = await queue.snapshot(); XCTAssertEqual(jobs[0].state, .queued)
    }
    func testCrashRecoveryOfUploadingJob() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("q.json")
        var job = UploadJob(file: root.appendingPathComponent("a.jpg"), key: "a.jpg", destination: destination()); job.state = .uploading
        try JSONEncoder().encode([job]).write(to: store)
        let queue = try UploadQueue(store: store); let jobs = await queue.snapshot()
        XCTAssertEqual(jobs[0].state, .queued)
    }
    func testCorruptQueueIsNotSilentlyDiscarded() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("q.json"); try Data("broken".utf8).write(to: store)
        XCTAssertThrowsError(try UploadQueue(store: store))
    }
    func testHTTPUploadAgainstOptInLocalTLSFixture() async throws {
        guard let value = ProcessInfo.processInfo.environment["ZORA_TEST_HTTPS"], let endpoint = URL(string: value) else { throw XCTSkip("Set ZORA_TEST_HTTPS to local trusted TLS fixture URL") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.nef"); try Data("ZORA INTEGRATION PAYLOAD".utf8).write(to: file)
        let transport = HTTPUploadTransport { _ in .init(username: "fixture", secret: "fixture-password") }
        try await transport.upload(file: file, key: "integration.nef", destination: .init(kind: .webDAV, endpoint: endpoint, prefix: ""))
    }
}

private actor RecordingTransport: UploadTransport {
    var calls = 0
    let failure: ZoraError?
    init(failure: ZoraError? = nil) { self.failure = failure }
    func upload(file: URL, key: String, destination: NASDestination) async throws {
        calls += 1; if let failure { throw failure }
        _ = try Data(contentsOf: file)
    }
}

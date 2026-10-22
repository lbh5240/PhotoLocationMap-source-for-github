import XCTest
@testable import ZoraCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class PipelineTests: XCTestCase, @unchecked Sendable {
    func testImportOfflineRestartUploadThroughActualHTTPTransportWithExplicitURLProtocolFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jX1sAAAAASUVORK5CYII=")!
        try png.write(to: source)
        let library = try AssetLibrary(root: root.appendingPathComponent("library"))
        let asset = try await library.importFile(source)
        let local = try await library.url(for: asset)
        let queueURL = root.appendingPathComponent("queue.json"), queue = try UploadQueue(store: queueURL)
        try await queue.enqueue(file: local, key: "fixture.png", destination: .init(kind: .webDAV, endpoint: URL(string: "https://fixture.invalid")!, prefix: ""))
        let transport = HTTPUploadTransport(credentials: { _ in .init(username: "fixture", secret: "fixture-password") }, sessionFactory: {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExplicitHTTPFixture.self]
            return URLSession(configuration: config)
        })
        try await queue.drain(using: transport, online: false)
        let reopened = try UploadQueue(store: queueURL)
        try await reopened.drain(using: transport, online: true)
        let jobs = await reopened.snapshot(); XCTAssertEqual(jobs[0].state, .complete)
        XCTAssertEqual(try Data(contentsOf: local), png)
        XCTAssertFalse(String(data: try Data(contentsOf: queueURL), encoding: .utf8)!.contains("fixture-password"))
    }
}

/// In-process HTTP fixture. No request is sent to a network or a real NAS.
private final class ExplicitHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid = request.httpMethod == "PUT" && request.url?.path == "/fixture.png"
            && request.value(forHTTPHeaderField: "Authorization") == "Basic \(Data("fixture:fixture-password".utf8).base64EncodedString())"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 201 : 401, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

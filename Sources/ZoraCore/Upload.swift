import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DestinationKind: String, Codable, CaseIterable, Sendable { case webDAV, s3 }
public struct NASDestination: Codable, Sendable, Equatable {
    public var kind: DestinationKind
    public var endpoint: URL
    public var bucket: String
    public var region: String
    public var prefix: String
    public var credentialID: String
    public init(kind: DestinationKind, endpoint: URL, bucket: String = "", region: String = "us-east-1", prefix: String = "ZORA", credentialID: String = "nas") {
        self.kind = kind; self.endpoint = endpoint; self.bucket = bucket; self.region = region; self.prefix = prefix; self.credentialID = credentialID
    }
    public func validated() throws -> Self {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, !credentialID.isEmpty,
              !prefix.split(separator: "/").contains(".."), !prefix.contains("\\"),
              kind != .s3 || (!bucket.isEmpty && !bucket.contains("/") && !region.isEmpty) else {
            throw ZoraError.malformed("NAS 需要 HTTPS 地址、有效目录和凭据标识")
        }
        return self
    }
    public func target(key: String) throws -> URL {
        _ = try validated()
        guard !key.isEmpty, !key.contains("\\"), !key.split(separator: "/").contains("..") else { throw ZoraError.malformed("object key") }
        var url = endpoint
        if kind == .s3 { url.appendPathComponent(bucket) }
        for part in (prefix + "/" + key).split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }
}

public struct NASCredential: Sendable {
    public let username: String, secret: String
    public let token: String?
    public init(username: String, secret: String, token: String? = nil) { self.username = username; self.secret = secret; self.token = token }
}

public enum S3Signer {
    static func encodedPath(_ path: String) -> String {
        path.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45,46,95,126,47].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    public static func sign(url: URL, payloadHash: String, credential: NASCredential, region: String, date: Date) throws -> URLRequest {
        guard url.scheme == "https", let host = url.host, url.query == nil else { throw ZoraError.malformed("S3 target URL") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        let authority = host.lowercased() + (url.port.map { ":\($0)" } ?? "")
        var headers = ["host": authority, "x-amz-content-sha256": payloadHash, "x-amz-date": timestamp]
        if let token = credential.token, !token.isEmpty { headers["x-amz-security-token"] = token }
        let names = headers.keys.sorted(), signed = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding else { throw ZoraError.malformed("S3 path") }
        let path = encodedPath(decodedPath)
        components.percentEncodedPath = path
        guard let canonicalURL = components.url else { throw ZoraError.malformed("S3 encoded URL") }
        let canonical = "PUT\n\(path.isEmpty ? "/" : path)\n\n\(canonicalHeaders)\n\(signed)\n\(payloadHash)"
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(SHA256Digest.hex(SHA256Digest.hash(Data(canonical.utf8))))"
        var key = Data(("AWS4" + credential.secret).utf8)
        for part in [day, region, "s3", "aws4_request"] { key = SHA256Digest.hmac(key: key, message: Data(part.utf8)) }
        let signature = SHA256Digest.hex(SHA256Digest.hmac(key: key, message: Data(toSign.utf8)))
        var request = URLRequest(url: canonicalURL); request.httpMethod = "PUT"; request.timeoutInterval = 120
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credential.username)/\(scope), SignedHeaders=\(signed), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
}

public enum UploadState: String, Codable, Sendable { case queued, uploading, retry, blocked, complete }
public struct UploadJob: Identifiable, Codable, Sendable {
    public let id: UUID
    public let file: URL
    public let key: String
    public let destination: NASDestination
    public var state: UploadState = .queued
    public var attempts: Int = 0
    public var nextAttempt: Date = .distantPast
    public var lastError: String?
    public init(file: URL, key: String, destination: NASDestination) { id = UUID(); self.file = file; self.key = key; self.destination = destination }
}

public protocol UploadTransport: Sendable {
    func upload(file: URL, key: String, destination: NASDestination) async throws
}

public actor UploadQueue {
    private let store: URL
    private var jobs: [UploadJob]
    private var running = false
    public init(store: URL) throws {
        self.store = store
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        var loaded = FileManager.default.fileExists(atPath: store.path)
            ? try JSONDecoder().decode([UploadJob].self, from: Data(contentsOf: store)) : []
        for i in loaded.indices where loaded[i].state == .uploading { loaded[i].state = .queued }
        jobs = loaded
    }
    public func snapshot() -> [UploadJob] { jobs }
    public func enqueue(file: URL, key: String, destination: NASDestination) throws {
        _ = try destination.validated(); _ = try destination.target(key: key)
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else { throw ZoraError.malformed("上传原文件不存在") }
        guard !jobs.contains(where: { $0.file == file && $0.key == key && $0.destination == destination && $0.state != .blocked }) else { return }
        var next = jobs; next.append(UploadJob(file: file, key: key, destination: destination)); try commit(next)
    }
    public func retryBlocked() throws {
        var next = jobs
        for i in next.indices where next[i].state == .blocked || next[i].state == .retry {
            next[i].state = .queued; next[i].attempts = 0; next[i].nextAttempt = .distantPast; next[i].lastError = nil
        }
        try commit(next)
    }
    /// One durable worker per queue. Force quit recovers uploading jobs; repeated PUT uses same key.
    public func drain(using transport: any UploadTransport, online: Bool, now: Date = Date()) async throws {
        guard online, !running else { return }
        running = true; defer { running = false }
        let eligible = jobs.filter { ($0.state == .queued || $0.state == .retry) && $0.nextAttempt <= now }.map(\.id)
        for id in eligible {
            try Task.checkCancellation()
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { continue }
            var next = jobs; next[i].state = .uploading; next[i].attempts += 1; try commit(next)
            let job = jobs[i]
            do {
                try await transport.upload(file: job.file, key: job.key, destination: job.destination)
                next = jobs; next[i].state = .complete; next[i].lastError = nil; try commit(next)
            } catch {
                next = jobs
                let code = (error as? ZoraError)
                let permanent: Bool
                if case .http(let status) = code { permanent = (400..<500).contains(status) && status != 408 && status != 429 }
                else { permanent = false }
                next[i].state = permanent || job.attempts >= 8 ? .blocked : .retry
                next[i].nextAttempt = now.addingTimeInterval(min(3600, pow(2, Double(job.attempts))*5))
                // Do not persist URLs, credentials or response bodies in diagnostics.
                next[i].lastError = permanent ? "认证或目标目录错误，请检查 NAS 设置" : "上传未完成，等待网络恢复后重试"
                try commit(next)
                if error is CancellationError { throw error }
            }
        }
    }
    private func commit(_ next: [UploadJob]) throws {
        try JSONEncoder().encode(next).write(to: store, options: .atomic); jobs = next
    }
}

public struct HTTPUploadTransport: UploadTransport {
    private let credentials: @Sendable (String) async throws -> NASCredential
    private let sessionFactory: @Sendable () -> URLSession
    public init(credentials: @escaping @Sendable (String) async throws -> NASCredential) {
        self.credentials = credentials
        sessionFactory = { URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil) }
    }
    init(credentials: @escaping @Sendable (String) async throws -> NASCredential, sessionFactory: @escaping @Sendable () -> URLSession) {
        self.credentials = credentials; self.sessionFactory = sessionFactory
    }
    public func upload(file: URL, key: String, destination: NASDestination) async throws {
        let credential = try await credentials(destination.credentialID)
        let target = try destination.target(key: key)
        var request: URLRequest
        if destination.kind == .s3 {
            // Mapping avoids an additional file copy. The pure Swift digest is bounded by the file limit below.
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256*1024*1024 else { throw ZoraError.unsupported("S3 单文件上限为 256 MiB；大文件 multipart 待实现") }
            let hash = SHA256Digest.hex(SHA256Digest.hash(try Data(contentsOf: file, options: .mappedIfSafe)))
            request = try S3Signer.sign(url: target, payloadHash: hash, credential: credential, region: destination.region, date: Date())
        } else {
            request = URLRequest(url: target); request.httpMethod = "PUT"; request.timeoutInterval = 120
            let basic = Data("\(credential.username):\(credential.secret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let session = sessionFactory()
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.upload(for: request, fromFile: file)
        guard let response = response as? HTTPURLResponse else { throw ZoraError.malformed("HTTP response") }
        guard (200..<300).contains(response.statusCode) else { throw ZoraError.http(response.statusCode) }
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

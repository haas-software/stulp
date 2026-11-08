import Foundation
@testable import StulpKit

/// Answers URLSession requests in tests. Handlers are registered per host, so suites that run in
/// parallel each get their own stub without sharing state.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data = Data("null".utf8)

        static func json(_ text: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(text.utf8)) }
    }

    struct Seen: Sendable {
        let method: String
        let path: String
        let query: String?
        let authorization: String?
        let body: Data?

        var json: JSONValue? { body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
    }

    typealias Handler = @Sendable (Seen) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [Seen]] = [:]

    /// A client for a fresh, unique host that this handler answers.
    static func client(logSource: String = "test", _ handler: @escaping Handler) -> (StulpClient, host: String) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let connection = StulpConnection(baseURL: URL(string: "http://\(host)")!, accessKey: "secret-key")
        return (StulpClient(connection: connection, logSource: logSource, session: session), host)
    }

    /// The requests a host received, without the fire-and-forget console lines.
    static func requests(_ host: String, includingLog: Bool = false) -> [Seen] {
        lock.withLock { seen[host] ?? [] }.filter { includingLog || $0.path != "/api/stulp/log" }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let entry = Seen(
            method: request.httpMethod ?? "GET", path: url.path(), query: url.query(),
            authorization: request.value(forHTTPHeaderField: "Authorization"), body: Self.body(of: request))
        let host = url.host() ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.seen[host, default: []].append(entry)
            return Self.handlers[host]
        }
        let reply = handler?(entry) ?? Reply(status: 404, body: Data(#"{"error":"no stub"}"#.utf8))
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

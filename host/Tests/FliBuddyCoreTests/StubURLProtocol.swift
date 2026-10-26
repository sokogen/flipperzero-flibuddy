import Foundation
@testable import FliBuddyCore

/// A request as the stub saw it, with the body read out of `httpBodyStream`.
struct RecordedRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data?

    /// The body decoded as a JSON object.
    var json: [String: Any] {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

struct StubResponse: Sendable {
    var status: Int
    var body: Data

    static func json(_ status: Int, _ text: String) -> StubResponse {
        StubResponse(status: status, body: Data(text.utf8))
    }
}

/// Answers requests for one host with a handler and records them in order.
///
/// Every `StubServer` gets a unique host name, so swift-testing can run suites in
/// parallel against the shared `StubURLProtocol` registry.
final class StubServer: @unchecked Sendable {
    let host = "stub-\(UUID().uuidString.lowercased()).test"
    var baseURL: URL { URL(string: "http://\(host):8000")! }

    private let lock = NSLock()
    private var handler: @Sendable (RecordedRequest) throws -> StubResponse
    private var recorded: [RecordedRequest] = []

    init(_ handler: @escaping @Sendable (RecordedRequest) throws -> StubResponse) {
        self.handler = handler
        StubURLProtocol.register(self)
    }

    deinit { StubURLProtocol.unregister(host) }

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func client(apiKey: String = "bb_test") throws -> BambuddyClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try BambuddyClient(baseURL: baseURL, apiKey: apiKey, session: URLSession(configuration: configuration))
    }

    fileprivate func respond(to request: RecordedRequest) throws -> StubResponse {
        let handler = lock.withLock {
            recorded.append(request)
            return self.handler
        }
        return try handler(request)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer) { lock.withLock { servers[server.host] = server } }
    static func unregister(_ host: String) { _ = lock.withLock { servers.removeValue(forKey: host) } }
    private static func server(for host: String?) -> StubServer? { lock.withLock { host.flatMap { servers[$0] } } }

    override class func canInit(with request: URLRequest) -> Bool { server(for: request.url?.host) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read)
        )
        do {
            let stub = try server.respond(to: recorded)
            let response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

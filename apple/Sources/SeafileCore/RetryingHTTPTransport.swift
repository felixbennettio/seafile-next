import Foundation

/// One shared connection pool, with bounded recovery for replay-safe requests.
public struct RetryingHTTPTransport: HTTPTransport {
    public static let shared = RetryingHTTPTransport(transport: URLSessionTransport())
    private let transport: any HTTPTransport
    private let retryDelays: [Duration]

    public init(transport: any HTTPTransport, retryDelays: [Duration] = [.milliseconds(400), .seconds(1)]) {
        self.transport = transport
        self.retryDelays = retryDelays
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, replaySafe: false)
    }
    public func data(for request: URLRequest, replaySafe: Bool) async throws -> (Data, URLResponse) {
        try await perform(request, replaySafe: replaySafe) { try await $0.data(for: request) }
    }
    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await perform(request) { try await $0.download(for: request) }
    }
    public func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) {
        // A connection may break after the server committed an upload.
        try await perform(request, allowsRetry: false) { try await $0.upload(for: request, from: file) }
    }

    public func responseWithoutRedirect(for request: URLRequest) async throws -> HTTPURLResponse {
        // Single-use SSO visits are not replay-safe despite using GET.
        try await perform(request, allowsRetry: false) { try await $0.responseWithoutRedirect(for: request) }
    }
    public func freshConnection() -> any HTTPTransport {
        _ = transport.freshConnection()
        return self
    }

    private func perform<T: Sendable>(_ request: URLRequest, replaySafe: Bool = false, allowsRetry: Bool = true,
                                     operation: (any HTTPTransport) async throws -> T) async throws -> T {
        let safe = allowsRetry && (replaySafe || ["GET", "HEAD"].contains(request.httpMethod ?? "GET"))
        var connection = transport
        for attempt in 0...retryDelays.count {
            try Task.checkCancellation()
            do { return try await operation(connection) }
            catch let error as URLError {
                try Task.checkCancellation()
                // Certificate failures, cancellation, and HTTP errors are not
                // transient. A TLS handshake reset may recover on a new socket;
                // every new connection still uses Apple's normal trust checks.
                let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed]
                if transient.contains(error.code) { connection = transport.freshConnection() }
                guard safe, transient.contains(error.code), attempt < retryDelays.count else {
                    var info = error.userInfo
                    let host = request.url?.host ?? "the server"
                    info[NSLocalizedDescriptionKey] = "\(error.localizedDescription) [\(host), URL \(error.code.rawValue)]"
                    throw URLError(error.code, userInfo: info)
                }
                try await Task.sleep(for: retryDelays[attempt])
            }
        }
        throw SeafileError.invalidResponse
    }
}

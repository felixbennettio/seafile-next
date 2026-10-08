import Foundation
import Testing
@testable import SeafileCore

private final class RecoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private actor FlakyHTTP: HTTPTransport {
    private var failures: [URLError.Code]
    private let reply: String
    var requests: [URLRequest] = []
    nonisolated let recoveries = RecoveryCounter()
    init(_ failures: [URLError.Code], reply: String = "[]") { self.failures = failures; self.reply = reply }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if !failures.isEmpty { throw URLError(failures.removeFirst()) }
        return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let (data, response) = try await data(for: request)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary)
        return (temporary, response)
    }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) { try await data(for: request) }
    nonisolated func freshConnection() -> any HTTPTransport { recoveries.record(); return self }
}

@Test func readRequestRecoversFromConnectionLossAndTLSReset() async throws {
    let underlying = FlakyHTTP([.networkConnectionLost, .secureConnectionFailed])
    let transport = RetryingHTTPTransport(transport: underlying, retryDelays: [.zero, .zero])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/seafile/"), transport: transport)
    #expect(try await api.repositories().isEmpty)
    #expect(await underlying.requests.count == 3)
    #expect(underlying.recoveries.count == 2)
}

@Test func transientRecoveryIsBoundedAndReportsCodeWithoutSensitiveQuery() async throws {
    let underlying = FlakyHTTP(Array(repeating: .secureConnectionFailed, count: 4))
    let transport = RetryingHTTPTransport(transport: underlying, retryDelays: [.zero, .zero])
    let request = URLRequest(url: URL(string: "https://cloud.example/download?token=private-test-nonce")!)
    do { _ = try await transport.data(for: request); Issue.record("Expected bounded TLS failure") }
    catch let error as URLError {
        #expect(error.code == .secureConnectionFailed)
        #expect(error.localizedDescription.contains("URL -1200"))
        #expect(!error.localizedDescription.contains("private-test-nonce"))
    }
    #expect(await underlying.requests.count == 3)
}

@Test func invalidCertificatesAreNeverRetriedOrAccepted() async throws {
    for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .clientCertificateRejected] {
        let underlying = FlakyHTTP([code])
        let transport = RetryingHTTPTransport(transport: underlying, retryDelays: [.zero, .zero])
        await #expect(throws: URLError.self) { try await transport.data(for: URLRequest(url: URL(string: "https://cloud.example/")!)) }
        #expect(await underlying.requests.count == 1)
        #expect(underlying.recoveries.count == 0)
    }
}

@Test func failedMutationRecoversThePoolForTheNextReadWithoutReplayingMutation() async throws {
    let underlying = FlakyHTTP([.secureConnectionFailed])
    let transport = RetryingHTTPTransport(transport: underlying, retryDelays: [.zero, .zero])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/"), transport: transport)
    await #expect(throws: URLError.self) { try await api.delete(repo: "test-repo", path: "/test.txt", isDirectory: false) }
    #expect(underlying.recoveries.count == 1)
    #expect(try await api.repositories().isEmpty)
    let requests = await underlying.requests
    #expect(requests.count == 2)
    #expect(requests[0].httpMethod == "DELETE" && requests[1].httpMethod == "GET")
}

@Test func fileMutationsAndUploadsAreNotReplayedAfterConnectionLoss() async throws {
    for method in ["POST", "PUT", "DELETE"] {
        let underlying = FlakyHTTP([.networkConnectionLost])
        let transport = RetryingHTTPTransport(transport: underlying, retryDelays: [.zero, .zero])
        var request = URLRequest(url: URL(string: "https://cloud.example/seafile/file/")!)
        request.httpMethod = method
        await #expect(throws: URLError.self) { try await transport.data(for: request) }
        #expect(await underlying.requests.count == 1)
    }
    let underlying = FlakyHTTP([.networkConnectionLost])
    let transport = RetryingHTTPTransport(transport: underlying, retryDelays: [.zero, .zero])
    await #expect(throws: URLError.self) {
        try await transport.upload(for: URLRequest(url: URL(string: "https://cloud.example/upload")!), from: URL(fileURLWithPath: "/unused-fixture"))
    }
    #expect(await underlying.requests.count == 1)
}

@Test func passwordAuthenticationCanRecoverWithoutChangingCredentials() async throws {
    let underlying = FlakyHTTP([.networkConnectionLost], reply: #"{"token":"test-token"}"#)
    let transport = RetryingHTTPTransport(transport: underlying, retryDelays: [.zero])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/seafile/"), transport: transport)
    #expect(try await api.authenticate(username: "test@example.invalid", password: "reserved+&=字") == "test-token")
    let requests = await underlying.requests
    #expect(requests.count == 2)
    #expect(requests[0].httpBody == requests[1].httpBody)
    #expect(requests[1].value(forHTTPHeaderField: "X-Seafile-OTP") == nil)
}

@Test func aSingleUseBrowserVisitIsNeverReplayed() async throws {
    let underlying = FlakyHTTP([.networkConnectionLost])
    let transport = RetryingHTTPTransport(transport: underlying, retryDelays: [.zero, .zero])
    await #expect(throws: URLError.self) {
        try await transport.responseWithoutRedirect(for: URLRequest(url: URL(string: "https://cloud.example/client-sso/test-nonce/")!))
    }
    #expect(await underlying.requests.count == 1)
}

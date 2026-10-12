import Foundation
import Testing
#if os(macOS)
import Network
#endif
@testable import SeafileCore

private actor DesktopHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, String)]
    init(_ replies: [(Int, String)]) { self.replies = replies }
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = replies.removeFirst()
        return (Data(reply.1.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) { throw SeafileError.invalidResponse }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) { try data(for: request) }
}

@Test func realServerEncryptionCapabilitiesDecodeWithoutBreakingSSO() async throws {
    let http = DesktopHTTP([(200, #"{"version":"13.0.25","encrypted_library_version":4,"encrypted_library_pwd_hash_algo":"argon2id","encrypted_library_pwd_hash_params":"t=3,m=65536,p=1","features":["client-sso-via-local-browser"]}"#)])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.invalid/seafile/"), transport: http)
    let info = try await api.serverInfo()
    #expect(info.encrypted_library_version == 4)
    #expect(info.encrypted_library_pwd_hash_algo == "argon2id")
    #expect(info.supportsBrowserSSO)
}

@Test func copyFolderUsesTheServerTaskAndChecksItsOutcome() async throws {
    let http = DesktopHTTP([(200, #"{"task_id":"task-1"}"#), (200, #"{"successful":true,"failed":false,"canceled":false}"#)])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.invalid/nested/"), token: "test", transport: http)
    let folder = try JSONDecoder().decode(DirectoryEntry.self, from: Data(#"{"name":"a+b & 目录","type":"dir"}"#.utf8))
    try await api.copyMove(repo: "source", parent: "/Parent/", entry: folder, destinationRepo: "target", destinationPath: "/Destination/", move: true)
    let requests = await http.requests
    #expect(requests[0].url!.path == "/nested/api/v2.1/copy-move-task")
    let fields = URLComponents(string: "?" + String(decoding: requests[0].httpBody!, as: UTF8.self))!.queryItems!
    #expect(fields.first { $0.name == "src_dirent_name" }?.value == folder.name)
    #expect(fields.first { $0.name == "operation" }?.value == "move")
    #expect(fields.first { $0.name == "dirent_type" }?.value == "dir")
    #expect(requests[1].url!.path == "/nested/api/v2.1/query-copy-move-progress")
}

@Test func sharedPermissionUpdatesPutRecipientInQueryAsRequiredBySeahub() async throws {
    let http = DesktopHTTP([(200, "{}"), (200, "{}")])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.invalid/seafile/"), transport: http)
    try await api.setPrivateShare(repo: "repo", path: "/Folder/", user: "name+tag@example.org", permission: "r", operation: "update")
    try await api.setPrivateShare(repo: "repo", path: "/Folder/", group: 42, operation: "remove")
    let requests = await http.requests
    #expect(requests[0].httpMethod == "POST")
    let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: true)!.queryItems!
    #expect(query.first { $0.name == "username" }?.value == "name+tag@example.org")
    #expect(query.first { $0.name == "share_type" }?.value == "user")
    #expect(requests[1].httpMethod == "DELETE" && requests[1].httpBody == nil)
}

@Test func sharingDoesNotReportSuccessWhenServerReturnsRecipientFailure() async throws {
    let http = DesktopHTTP([(200, #"{"success":[],"failed":[{"error_msg":"User not found"}]}"#)])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.invalid/"), transport: http)
    await #expect(throws: SeafileError.self) { try await api.setPrivateShare(repo: "repo", path: "/", user: "missing@example.org") }
}

@Test func passwordLoginRegistersTheSameDeviceAsSSOAndSupportsOTP() async throws {
    let http = DesktopHTTP([(200, #"{"token":"test-token"}"#)])
    let device = SSODevice(platform: "mac", identifier: String(repeating: "a", count: 40), name: "My Mac", clientVersion: "1.0", systemVersion: "26")
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.invalid/"), transport: http)
    _ = try await api.authenticate(username: "user", password: "pass", otp: "123456", device: device)
    let request = await http.requests[0]
    let query = URLComponents(string: "?" + String(decoding: request.httpBody!, as: UTF8.self))!.queryItems!
    #expect(query.first { $0.name == "device_id" }?.value == device.identifier)
    #expect(query.first { $0.name == "device_name" }?.value == "My Mac")
    #expect(request.value(forHTTPHeaderField: "X-Seafile-OTP") == "123456")
}

@Test func recursiveUploadRejectsSymlinksWithoutReadingTheirTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
    let http = DesktopHTTP([])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.invalid/"), transport: http)
    await #expect(throws: SeafileError.self) { try await api.uploadTree(repo: "repo", directory: "/", item: link) }
    #expect(await http.requests.isEmpty)
}

#if os(macOS)
private final class DesktopProxyFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "seafile.tests.proxy")
    private let listener: NWListener
    // All mutable fixture state is confined to queue.
    private var ready: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let ready else { return }
                    switch state {
                    case .ready:
                        self.ready = nil
                        if let port = listener.port { ready.resume(returning: port.rawValue) }
                        else { ready.resume(throwing: SeafileError.invalidResponse) }
                    case .failed(let error): self.ready = nil; ready.resume(throwing: error)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    connections.append(connection)
                    connection.start(queue: queue)
                    receive(connection, buffered: Data())
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.stopOnQueue() }
            }
        }
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        if let ready { self.ready = nil; ready.resume(throwing: URLError(.timedOut)) }
        for connection in connections { connection.cancel() }
        connections.removeAll(); listener.cancel()
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = buffered
            if let data { request.append(data) }
            guard error == nil, request.count <= 16_384 else { connection.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || data?.isEmpty != false { connection.cancel() }
                else { receive(connection, buffered: request) }
                return
            }
            let valid = request.starts(with: Data("GET http://proxy-fixture.invalid/seafile/api2/repos/ ".utf8))
            let response = valid ? "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]" :
                "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Test(.timeLimit(.minutes(1))) func nativeHTTPProxyCarriesAPIRequestsWithoutChangingSystemSettings() async throws {
    let fixture = try DesktopProxyFixture()
    let port = Int(try await fixture.start())
    defer { fixture.stop() }
    var settings = ClientNetworkSettings(); settings.proxy = .http; settings.host = "127.0.0.1"; settings.port = port
    let api = SeafileAPI(endpoint: try ServerEndpoint("http://proxy-fixture.invalid/seafile/"), transport: URLSessionTransport(settings: settings))
    #expect(try await api.repositories().isEmpty)
}
#endif

#if os(macOS)
@Test func finderPathsCannotEscapeOrMatchASiblingLibrary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = root.appendingPathComponent("library", isDirectory: true)
    let outside = root.appendingPathComponent("library-sibling", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("escape"), withDestinationURL: outside)
    #expect(LocalSyncPath.relative(library, within: library) == "/")
    #expect(LocalSyncPath.relative(library.appendingPathComponent("Folder/file.txt"), within: library) == "/Folder/file.txt")
    #expect(LocalSyncPath.relative(outside.appendingPathComponent("file.txt"), within: library) == nil)
    #expect(LocalSyncPath.relative(library.appendingPathComponent("escape/file.txt"), within: library) == nil)
}
#endif

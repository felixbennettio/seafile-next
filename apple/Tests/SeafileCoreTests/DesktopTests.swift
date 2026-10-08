import Foundation
import Testing
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

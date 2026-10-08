import Foundation
import Testing
@testable import SeafileCore

private actor MockHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, Data)]
    let redirect: String
    init(_ replies: [(Int, String)], redirect: String = "https://cloud.example/accounts/login/") {
        self.replies = replies.map { ($0.0, Data($0.1.utf8)) }; self.redirect = redirect
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = replies.removeFirst()
        return (reply.1, HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil,
                                      headerFields: reply.0 == 302 ? ["Location": redirect] : nil)!)
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        requests.append(request)
        let reply = replies.removeFirst()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try reply.1.write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!)
    }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) { try await data(for: request) }
}

private let ssoNonce = String(repeating: "a", count: 60)
private let testDevice = SSODevice(platform: "ios", identifier: "00000000-0000-4000-8000-000000000001", name: "Test iPhone", clientVersion: "1.0", systemVersion: "26.0")

@Test func browserSSOPreservesDeploymentPathAndAllDeviceFields() async throws {
    let transport = MockHTTP([
        (200, #"{"version":"13.0.25","features":["client-sso-via-local-browser"]}"#),
        (200, "{\"link\":\"https://cloud.example/nested/site/client-sso/\(ssoNonce)/\"}"),
        (200, #"{"status":"waiting"}"#),
        (200, #"{"status":"success","username":"canonical@example.org","apiToken":"sso-token"}"#)
    ])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/nested/site/"), transport: transport)
    let challenge = try await api.beginSSO(device: testDevice)
    let url = URLComponents(url: challenge.browserURL, resolvingAgainstBaseURL: true)!
    #expect(url.path == "/nested/site/client-sso/\(ssoNonce)/")
    #expect(url.queryItems?.count == 5)
    #expect(url.queryItems?.first { $0.name == "shib_device_name" }?.value == "Test iPhone")
    #expect(try await api.checkSSO(challenge) == nil)
    let identity = try await api.checkSSO(challenge)
    #expect(identity?.username == "canonical@example.org")
    #expect(identity?.apiToken == "sso-token")
    let requests = await transport.requests
    #expect(requests[1].httpMethod == "POST")
    #expect(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: true)?.path == "/nested/site/api2/client-sso-link/\(ssoNonce)/")
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
}

@Test func browserSSORejectsUnexpectedLinkOriginsAndPaths() async throws {
    for link in ["https://other.example/seafile/client-sso/\(ssoNonce)/", "http://cloud.example/seafile/client-sso/\(ssoNonce)/",
                 "https://cloud.example/client-sso/\(ssoNonce)/", "https://cloud.example/seafile/client-sso/../invalid/"] {
        let transport = MockHTTP([(200, #"{"version":"13.0.25","features":["client-sso-via-local-browser"]}"#), (200, "{\"link\":\"\(link)\"}")])
        let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/seafile/"), transport: transport)
        await #expect(throws: SeafileError.self) { try await api.beginSSO(device: testDevice) }
    }
}

@Test func browserSSOReportsDisabledFeatureWithoutCreatingALink() async throws {
    let transport = MockHTTP([(200, #"{"version":"13.0.25","features":["seafile-basic"]}"#)])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/"), transport: transport)
    await #expect(throws: SeafileError.self) { try await api.beginSSO(device: testDevice) }
    #expect(await transport.requests.count == 1)
}

@Test func browserSSODoesNotAcceptIncompleteSuccessOrExpiredSession() async throws {
    for reply in [#"{"status":"success","username":"canonical@example.org","apiToken":""}"#, #"{"status":"error"}"#] {
        let transport = MockHTTP([(200, #"{"version":"13.0.25","features":["client-sso-via-local-browser"]}"#),
                                  (200, "{\"link\":\"https://cloud.example/client-sso/\(ssoNonce)/\"}"), (200, reply)])
        let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/"), transport: transport)
        let challenge = try await api.beginSSO(device: testDevice)
        await #expect(throws: SeafileError.self) { try await api.checkSSO(challenge) }
    }
}

@Test func authenticatedAccountInfoUsesCanonicalServerIdentity() async throws {
    let transport = MockHTTP([(200, #"{"email":"internal-user@auth.local","name":"Display name","contact_email":"external@example.org"}"#)])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/seafile/"), token: "sso-token", transport: transport)
    let profile = try await api.accountInfo()
    #expect(profile.email == "internal-user@auth.local")
    #expect(profile.name == "Display name")
    #expect(await transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Token sso-token")
}

@Test func deploymentPathAndUnicodeFilenameSurviveRequests() async throws {
    let transport = MockHTTP([(200, "{\"dirent_list\":[]}")])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/seafile"), token: "unit-test-token", transport: transport)
    _ = try await api.directory(repo: "repo-id", path: "/目录/a+b & c/")
    let request = await transport.requests[0]
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.path == "/seafile/api/v2.1/repos/repo-id/dir/")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.queryItems?.first?.value == "/目录/a+b & c/")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.percentEncodedQuery?.contains("a%2Bb") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Token unit-test-token")
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
}

@Test func directBrowserSSOBypassesBrokenLoginButtonAndEncodesNestedNext() async throws {
    let transport = MockHTTP([
        (200, #"{"version":"13.0.25","features":["client-sso-via-local-browser"]}"#),
        (200, "{\"link\":\"https://cloud.example/nested/site/client-sso/\(ssoNonce)/\"}"), (302, "")
    ])
    let device = SSODevice(platform: "ios", identifier: testDevice.identifier, name: "Phone + Test & Co",
                           clientVersion: "1.0", systemVersion: "26.0")
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/nested/site/"), transport: transport)
    let challenge = try await api.beginSSO(device: device, preferSSO: true)
    let url = URLComponents(url: challenge.browserURL, resolvingAgainstBaseURL: true)!
    #expect(url.path == "/nested/site/sso/")
    #expect(url.queryItems?.count == 1)
    let next = try #require(url.queryItems?.first?.value)
    let completion = try #require(URLComponents(string: "https://cloud.example" + next))
    #expect(completion.path == "/nested/site/client-sso/\(ssoNonce)/complete/")
    #expect(completion.queryItems?.count == 5)
    #expect(completion.queryItems?.first { $0.name == "shib_device_name" }?.value == device.name)
    #expect(completion.percentEncodedQuery?.contains("%2B") == true)
    #expect(await transport.requests.count == 3)
}

@Test func directSSORejectsAVisitedNonceOrAnExternalLoginRedirect() async throws {
    for (status, redirect) in [(200, "https://cloud.example/accounts/login/"), (302, "https://other.example/login/")] {
        let transport = MockHTTP([(200, #"{"version":"13.0.25","features":["client-sso-via-local-browser"]}"#),
                                  (200, "{\"link\":\"https://cloud.example/client-sso/\(ssoNonce)/\"}"), (status, "")], redirect: redirect)
        let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/"), transport: transport)
        await #expect(throws: SeafileError.self) { try await api.beginSSO(device: testDevice, preferSSO: true) }
    }
}

@Test func starredItemsIncludeFoldersAndUseTheServerFolderAPI() async throws {
    let transport = MockHTTP([
        (200, #"{"starred_item_list":[{"repo_id":"repo-id","repo_name":"Library","path":"/Projects/","obj_name":"Projects","is_dir":true,"deleted":false},{"repo_id":"repo-id","repo_name":"Library","path":"/a+b.txt","obj_name":"a+b.txt","is_dir":false,"deleted":false}]}"#),
        (200, "{}"), (200, "{}")
    ])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/seafile/"), token: "unit-test-token", transport: transport)
    let items = try await api.starredItems()
    #expect(items.count == 2 && items[0].isDirectory && !items[1].isDirectory)
    try await api.setStarred(repo: "repo-id", path: items[0].path, starred: true)
    try await api.setStarred(repo: "repo-id", path: items[1].path, starred: false)
    let requests = await transport.requests
    #expect(requests.allSatisfy { $0.url?.path == "/seafile/api/v2.1/starred-items" })
    #expect(String(decoding: requests[1].httpBody!, as: UTF8.self) == "path=%2FProjects%2F&repo_id=repo-id")
    #expect(requests[2].httpMethod == "DELETE")
    #expect(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: true)?.percentEncodedQuery?.contains("a%2Bb.txt") == true)
}

@Test func twoFactorLoginEncodesReservedCharactersWithoutChangingPassword() async throws {
    let transport = MockHTTP([(200, "{\"token\":\"returned-token\"}")])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/nested/site/"), transport: transport)
    let token = try await api.authenticate(username: "name+tag@example.org", password: "字+&= %", otp: "123456")
    let request = await transport.requests[0]
    #expect(token == "returned-token")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.path == "/nested/site/api2/auth-token/")
    #expect(request.value(forHTTPHeaderField: "X-Seafile-OTP") == "123456")
    #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("password=%E5%AD%97%2B%26%3D%20%25"))
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func downloadDoesNotSendAccountTokenToAnotherOrigin() async throws {
    let transport = MockHTTP([(200, "\"https://cdn.example/signed-download\""), (200, "file contents")])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/seafile/"), token: "unit-test-token", transport: transport)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("example.txt")
    try await api.download(repo: "repo-id", path: "/example.txt", destination: file)
    let requests = await transport.requests
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Token unit-test-token")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == "file contents")
}

@Test func failedDownloadDoesNotReplaceExistingCachedFile() async throws {
    let transport = MockHTTP([(200, "\"https://cloud.example/seafile/seafhttp/file\""), (503, "Unavailable")])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/seafile/"), token: "unit-test-token", transport: transport)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("example.txt")
    try Data("existing copy".utf8).write(to: file)
    await #expect(throws: SeafileError.self) { try await api.download(repo: "repo-id", path: "/example.txt", destination: file) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "existing copy")
}

@Test func signedDownloadCannotDowngradeHTTPS() async throws {
    let transport = MockHTTP([(200, "\"http://cloud.example/seafhttp/file\"")])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://cloud.example/"), transport: transport)
    await #expect(throws: SeafileError.self) {
        try await api.download(repo: "repo-id", path: "/example.txt", destination: URL(fileURLWithPath: "/tmp/unused-seafile-next-test"))
    }
}

@Test func serverCannotWriteOutsideDownloadDirectoryThroughFileNames() throws {
    let hostile = Data("{\"dirent_list\":[{\"name\":\"../../outside.txt\",\"type\":\"file\"}]}".utf8)
    struct Listing: Decodable { let dirent_list: [DirectoryEntry] }
    #expect(throws: SeafileError.self) { try JSONDecoder().decode(Listing.self, from: hostile) }
}

@Test func multipartUploadStreamsBinaryFileWithCorrectFieldBoundaries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("文件.txt"), output = root.appendingPathComponent("body")
    let payload = Data((0..<200_000).map { UInt8($0 % 256) })
    try payload.write(to: file)
    try MultipartFile.write(file: file, directory: "/folder/", replace: false, boundary: "test-boundary", to: output)
    let body = try Data(contentsOf: output)
    #expect(body.range(of: payload) != nil)
    #expect(body.starts(with: Data("--test-boundary\r\n".utf8)))
    #expect(body.suffix(21) == Data("\r\n--test-boundary--\r\n".utf8).suffix(21))
}

@Test func oneServerPathDoesNotShareAnotherAccountsCache() throws {
    let first = ServerAccount(endpoint: try ServerEndpoint("https://cloud.example/a/"), email: "user@example.org")
    let second = ServerAccount(endpoint: try ServerEndpoint("https://cloud.example/b/"), email: "user@example.org")
    #expect(LocalFiles.cacheURL(account: first, repo: "same-repo", path: "/a.pdf") != LocalFiles.cacheURL(account: second, repo: "same-repo", path: "/a.pdf"))
}

#if os(macOS)
@Test func nativeRPCUsesTheExistingDaemonProtocolAndPreservesNullPassword() throws {
    let data = try DaemonRPC.encodeCall("seafile_download", arguments: [.string("repo"), .integer(1), .null])
    let envelope = try JSONDecoder().decode(JSONValue.self, from: data).object!
    #expect(envelope["service"] == .string("seafile-rpcserver"))
    let inner = try JSONDecoder().decode([JSONValue].self, from: Data(envelope["request"]!.string!.utf8))
    #expect(inner == [.string("seafile_download"), .string("repo"), .integer(1), .null])
}
#endif

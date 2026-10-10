import Foundation
import Testing
@testable import SeafileCore

private let wikiID = "00000000-0000-4000-8000-000000000001"
private actor WikiHTTP: HTTPTransport {
    let replies: [String: (Int, String)]
    var requests: [URLRequest] = []
    init(_ replies: [String: (Int, String)] = [:]) { self.replies = replies }
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!.path
        let reply = replies[path] ?? (200, "{}")
        return (Data(reply.1.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) throws -> (URL, URLResponse) { throw SeafileError.invalidResponse }
    func upload(for request: URLRequest, from file: URL) throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}

@Test func wikiCatalogKeepsOwnedSharedGroupAndOlderWikisSeparate() async throws {
    let http = WikiHTTP([
        "/seafile/api/v2.1/wikis2/": (200, #"{"wikis":[{"id":"00000000-0000-4000-8000-000000000001","repo_id":"00000000-0000-4000-8000-000000000001","name":"Team","type":"mine","is_published":true},{"id":"00000000-0000-4000-8000-000000000002","repo_id":"00000000-0000-4000-8000-000000000002","name":"Shared","type":"shared"}],"group_wikis":[{"group_id":7,"group_name":"Group","wiki_info":[{"id":"00000000-0000-4000-8000-000000000003","repo_id":"00000000-0000-4000-8000-000000000003","name":"Group wiki","type":"group"}]}]}"#),
        "/seafile/api/v2.1/wikis/": (200, #"{"data":[{"id":8,"repo_id":"00000000-0000-4000-8000-000000000004","name":"Older","slug":"older-wiki"}]}"#)
    ])
    let catalog = try await SeafileAPI(endpoint: ServerEndpoint("https://fixture.invalid/seafile/"), transport: http).wikiCatalog()
    #expect(catalog.modernAvailable && catalog.warnings.isEmpty)
    #expect(catalog.wikis.count == 2 && catalog.groups.count == 1 && catalog.legacy.count == 1)
    #expect(catalog.wikis[0].canManage && catalog.wikis[0].published)
    #expect(!catalog.wikis[1].canManage && !catalog.groups[0].wikis[0].canManage && !catalog.legacy[0].canManage)
    #expect(catalog.legacy[0].id == "legacy:8")
}

@Test func legacyOnlyWikiServerStillShowsItsContentAndOtherFailuresAreVisible() async throws {
    for status in [404, 503] {
        let http = WikiHTTP([
            "/api/v2.1/wikis2/": (status, #"{"detail":"Unavailable"}"#),
            "/api/v2.1/wikis/": (200, #"{"data":[{"id":8,"repo_id":"repo","name":"Older","slug":"older"}]}"#)
        ])
        let catalog = try await SeafileAPI(endpoint: ServerEndpoint("https://fixture.invalid/"), transport: http).wikiCatalog()
        #expect(!catalog.modernAvailable && catalog.legacy.count == 1)
        #expect(catalog.warnings.isEmpty == (status == 404))
    }
    let bothFailed = WikiHTTP(["/api/v2.1/wikis2/": (401, "{}"), "/api/v2.1/wikis/": (401, "{}")])
    await #expect(throws: SeafileError.self) { try await SeafileAPI(endpoint: ServerEndpoint("https://fixture.invalid/"), transport: bothFailed).wikiCatalog() }
}

@Test func wikiMutationsUseOriginalMethodsAndEncodeNamesWithoutReplayingWrites() async throws {
    let http = WikiHTTP(), api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/nested/site/"), token: "fixture-token", transport: http)
    try await api.createWiki(name: " Team 知识库 ")
    try await api.renameWiki(id: wikiID, name: "名称 + &")
    try await api.publishWiki(id: wikiID, suffix: "team-docs")
    try await api.unpublishWiki(id: wikiID)
    try await api.deleteWiki(id: wikiID)
    let requests = await http.requests
    #expect(requests.map(\.httpMethod) == ["POST", "PUT", "POST", "DELETE", "DELETE"])
    #expect(requests[0].url!.path == "/nested/site/api/v2.1/wikis2")
    #expect(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("owner=me"))
    let fields = URLComponents(string: "?" + String(decoding: requests[1].httpBody!, as: UTF8.self))!.queryItems!
    #expect(fields.first { $0.name == "wiki_name" }?.value == "名称 + &")
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Token fixture-token" })
    for id in ["../escape", "id?next=https://other.invalid", "not-a-uuid"] {
        await #expect(throws: SeafileError.self) { try await api.deleteWiki(id: id) }
    }
    for suffix in ["abcd", "has_space", String(repeating: "a", count: 31), "https://other.invalid", "你好你好你好"] {
        await #expect(throws: SeafileError.self) { try await api.publishWiki(id: wikiID, suffix: suffix) }
    }
    #expect(await http.requests.count == 5)
}

@Test func documentSessionPreservesUnicodeReservedCharactersAndNeverPlacesTokenInURL() async throws {
    let endpoint = try ServerEndpoint("https://fixture.invalid/nested/site/")
    let target = try ServerDocumentSession.fileURL(repo: wikiID, path: "/文件 + &?/report..txt", endpoint: endpoint)
    #expect(target.query == nil && target.fragment == nil)
    #expect(URLComponents(url: target, resolvingAgainstBaseURL: true)!.path == "/nested/site/lib/\(wikiID)/file/文件 + &?/report..txt")
    let request = try ServerDocumentSession.loginRequest(target: target, endpoint: endpoint, token: "fixture-token")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Token fixture-token")
    #expect(!request.url!.absoluteString.contains("fixture-token"))
    let next = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!.queryItems!.first { $0.name == "next" }!.value!
    #expect(next == URLComponents(url: target, resolvingAgainstBaseURL: true)!.percentEncodedPath)
    #expect(URL(string: next, relativeTo: endpoint.url)!.absoluteURL == target)
    let editor = try ServerDocumentSession.fileURL(repo: wikiID, path: "/notes.md", endpoint: endpoint, editing: true)
    #expect(editor.query == "mode=edit")
    let editorLogin = try ServerDocumentSession.loginRequest(target: editor, endpoint: endpoint, token: "fixture-token")
    #expect(URLComponents(url: editorLogin.url!, resolvingAgainstBaseURL: true)!.queryItems!.first { $0.name == "next" }!.value!.hasSuffix("notes%2Emd?mode=edit"))
}

@Test func documentSessionRejectsOtherOriginsPathsCredentialsAndTraversal() throws {
    let endpoint = try ServerEndpoint("https://fixture.invalid/seafile/")
    for target in ["https://other.invalid/seafile/wikis/1/", "http://fixture.invalid/seafile/wikis/1/", "https://fixture.invalid:444/seafile/wikis/1/", "https://fixture.invalid/seafile-evil/", "https://fixture.invalid/admin/", "https://user:password@fixture.invalid/seafile/", "https://fixture.invalid/seafile/%2e%2e/private/"] {
        #expect(!ServerDocumentSession.allows(URL(string: target)!, endpoint: endpoint))
        #expect(throws: SeafileError.self) { try ServerDocumentSession.loginRequest(target: URL(string: target)!, endpoint: endpoint, token: "fixture-token") }
    }
    for path in ["/../file", "/folder/./file", "relative", "/"] {
        #expect(throws: SeafileError.self) { try ServerDocumentSession.fileURL(repo: wikiID, path: path, endpoint: endpoint) }
    }
    #expect(throws: SeafileError.self) { try ServerDocumentSession.loginRequest(target: endpoint.url, endpoint: endpoint, token: "token\r\nInjected: value") }
}

@Test func documentNavigationDoesNotForwardAPIHeadersToEditorsOrOtherServices() throws {
    let endpoint = try ServerEndpoint("https://fixture.invalid/seafile/")
    let target = try ServerDocumentSession.fileURL(repo: wikiID, path: "/document.sdoc", endpoint: endpoint)
    let bridge = try ServerDocumentSession.loginRequest(target: target, endpoint: endpoint, token: "fixture-token")
    #expect(ServerDocumentSession.allowsNavigation(bridge, endpoint: endpoint, mainFrame: true))
    for url in [target, URL(string: "https://fixture.invalid/other-app/")!, URL(string: "https://editor.invalid/frame/")!] {
        var request = URLRequest(url: url); request.setValue("Token fixture-token", forHTTPHeaderField: "Authorization")
        #expect(!ServerDocumentSession.allowsNavigation(request, endpoint: endpoint, mainFrame: true))
        #expect(!ServerDocumentSession.allowsNavigation(request, endpoint: endpoint, mainFrame: false))
        if url == target {
            let safe = try ServerDocumentSession.sessionRedirect(request, endpoint: endpoint)
            #expect(safe.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(ServerDocumentSession.allowsNavigation(safe, endpoint: endpoint, mainFrame: true))
        } else { #expect(throws: SeafileError.self) { try ServerDocumentSession.sessionRedirect(request, endpoint: endpoint) } }
    }
    let editor = URLRequest(url: URL(string: "https://editor.invalid/frame/")!)
    #expect(ServerDocumentSession.allowsNavigation(editor, endpoint: endpoint, mainFrame: false))
    #expect(!ServerDocumentSession.allowsNavigation(editor, endpoint: endpoint, mainFrame: true))
    #expect(!ServerDocumentSession.allowsNavigation(URLRequest(url: URL(string: "http://editor.invalid/frame/")!), endpoint: endpoint, mainFrame: false))
}

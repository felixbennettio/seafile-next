import Foundation
import Testing
@testable import SeafileCore

private let commentRepo = "00000000-0000-4000-8000-000000000001"
private let commentDocument = "00000000-0000-4000-8000-000000000004"
private actor CommentHTTP: HTTPTransport {
    let response: String
    let failWrites: Bool
    var requests: [URLRequest] = []
    init(response: String = "{}", failWrites: Bool = false) { self.response = response; self.failWrites = failWrites }
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if failWrites && request.httpMethod != "GET" { throw URLError(.networkConnectionLost) }
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) throws -> (URL, URLResponse) { throw SeafileError.invalidResponse }
    func upload(for request: URLRequest, from file: URL) throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}

@Test func nativeCommentQueriesUseTheOriginalUUIDAPIAndResolutionPagination() async throws {
    let http = CommentHTTP(response: #"{"comments":[{"id":1,"comment":"<p>Comment</p>","resolved":false,"user_name":"Fixture member","user_email":"first@fixture.invalid","replies":[{"id":3,"reply":"<p>Reply</p>"}]}],"total_count":1}"#)
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/nested/site/"), token: "fixture-token", transport: http)
    let result = try await api.documentComments(repo: commentRepo, document: commentDocument, page: 2, resolved: false)
    #expect(result.comments[0].replies?.first?.id == 3 && result.total_count == 1)
    let request = try #require(await http.requests.first)
    let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: true))
    #expect(components.path == "/nested/site/api/v2.1/repos/\(commentRepo)/file/\(commentDocument)/comments/")
    #expect(components.queryItems?.first { $0.name == "page" }?.value == "2")
    #expect(components.queryItems?.first { $0.name == "per_page" }?.value == "25")
    #expect(components.queryItems?.first { $0.name == "resolved" }?.value == "false")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Token fixture-token")
    #expect(!request.url!.absoluteString.contains("fixture-token"))
}

@Test func nativeCommentsEscapePlainInputAndUseDistinctReplyEndpoints() async throws {
    let http = CommentHTTP(), api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/seafile/"), transport: http)
    try await api.addDocumentComment(repo: commentRepo, document: commentDocument, text: "中文 <script> & +\nsecond line")
    try await api.replyToDocumentComment(repo: commentRepo, document: commentDocument, comment: 1, text: "Reply")
    try await api.editDocumentComment(repo: commentRepo, document: commentDocument, comment: 1, text: "Edited")
    try await api.resolveDocumentComment(repo: commentRepo, document: commentDocument, comment: 1, resolved: true)
    try await api.editDocumentReply(repo: commentRepo, document: commentDocument, comment: 1, reply: 3, text: "Edited reply")
    try await api.deleteDocumentReply(repo: commentRepo, document: commentDocument, comment: 1, reply: 3)
    try await api.deleteDocumentComment(repo: commentRepo, document: commentDocument, comment: 1)
    let requests = await http.requests
    #expect(requests.map(\.httpMethod) == ["POST", "POST", "PUT", "PUT", "PUT", "DELETE", "DELETE"])
    func form(_ index: Int, _ field: String) -> String? {
        URLComponents(string: "?" + String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self))?.queryItems?.first { $0.name == field }?.value
    }
    #expect(form(0, "comment") == "<p>中文 &lt;script&gt; &amp; +<br>second line</p>")
    #expect(form(1, "type") == "reply" && requests[1].url!.path.hasSuffix("/comments/1/replies"))
    #expect(form(3, "resolved") == "true")
    #expect(form(4, "reply") == "<p>Edited reply</p>" && requests[4].url!.path.hasSuffix("/comments/1/replies/3"))
}

@Test func lostCommentWriteIsNeverAutomaticallySubmittedAgain() async throws {
    let http = CommentHTTP(failWrites: true)
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: http)
    await #expect(throws: URLError.self) { try await api.addDocumentComment(repo: commentRepo, document: commentDocument, text: "One submission") }
    #expect(await http.requests.count == 1)
}

@Test func invalidCommentTargetsAndEmptyOrOversizedInputNeverReachTheServer() async throws {
    let http = CommentHTTP(), api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: http)
    for text in [" \n", "text\0", String(repeating: "a", count: 65_537)] {
        await #expect(throws: SeafileError.self) { try await api.addDocumentComment(repo: commentRepo, document: commentDocument, text: text) }
    }
    await #expect(throws: SeafileError.self) { try await api.documentComments(repo: "../other", document: commentDocument) }
    await #expect(throws: SeafileError.self) { try await api.documentComments(repo: commentRepo, document: "../other") }
    await #expect(throws: SeafileError.self) { try await api.documentComments(repo: commentRepo, document: commentDocument, page: 0) }
    await #expect(throws: SeafileError.self) { try await api.deleteDocumentComment(repo: commentRepo, document: commentDocument, comment: 0) }
    await #expect(throws: SeafileError.self) { try await api.deleteDocumentReply(repo: commentRepo, document: commentDocument, comment: 1, reply: -1) }
    #expect(await http.requests.isEmpty)
}

@Test func commentSummariesRemoveActiveHTMLAndDoNotFlattenRichEdits() throws {
    let text = "A & <tag> + \"quoted\"\n中文"
    #expect(CommentText.plain(try CommentText.html(text)) == text)
    #expect(CommentText.plain("<p>&amp;lt; &#38;lt;</p>") == "&lt; &lt;")
    #expect(CommentText.plain("<p>First<br>Second &#x4E2D;&#25991;</p><script>secret()</script><style>hide</style><img src='https://other.invalid/image'>") == "First\nSecond 中文")
    #expect(CommentText.canEdit("<p>Plain<br>text</p>"))
    #expect(!CommentText.canEdit("<p><span class='mention'>Member</span></p>"))
    #expect(!CommentText.canEdit("<p><img src='https://other.invalid/image'></p>"))
}

@Test func malformedCommentListsAreNotShownAsValidEmptyContent() async throws {
    for json in [#"{"comments":[],"total_count":-1}"#, #"{"comments":[{"id":0,"comment":"bad","resolved":false}],"total_count":1}"#, #"{"comments":[{"id":1,"comment":"one","resolved":false},{"id":1,"comment":"duplicate","resolved":false}],"total_count":2}"#] {
        let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: CommentHTTP(response: json))
        await #expect(throws: SeafileError.self) { try await api.documentComments(repo: commentRepo, document: commentDocument) }
    }
}

@Test func wikiPagesRetainServerDocumentIDsAndRejectUnsafeOrDuplicateNavigation() async throws {
    let valid = #"{"wiki":{"wiki_config":{"pages":[{"id":"Ab12","name":"首页","path":"/首页.sdoc","docUuid":"00000000-0000-4000-8000-000000000004"}]}}}"#
    let http = CommentHTTP(response: valid), api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/seafile/"), transport: http)
    let pages = try await api.wikiPages(id: commentRepo)
    #expect(pages.first?.name == "首页" && pages.first?.documentID == commentDocument)
    #expect(await http.requests.first?.url?.path == "/seafile/api/v2.1/wiki2/\(commentRepo)/config")
    let empty = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: CommentHTTP(response: #"{"wiki":{"wiki_config":{}}}"#))
    #expect(try await empty.wikiPages(id: commentRepo).isEmpty)
    for bad in [valid.replacingOccurrences(of: "Ab12", with: "../x"), valid.replacingOccurrences(of: "/首页.sdoc", with: "/../首页.sdoc"), valid.replacingOccurrences(of: commentDocument, with: "bad-uuid")] {
        let malformed = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: CommentHTTP(response: bad))
        await #expect(throws: SeafileError.self) { try await malformed.wikiPages(id: commentRepo) }
    }
}

import Foundation
import Testing
@testable import SeafileCore

private actor CopyMoveHTTP: HTTPTransport {
    private var replies: [String]
    var requests: [URLRequest] = []
    init(_ replies: [String]) { self.replies = replies }
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw SeafileError.local("Unexpected repeated request") }
        return (Data(replies.removeFirst().utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) throws -> (URL, URLResponse) { throw SeafileError.invalidResponse }
    func upload(for request: URLRequest, from file: URL) throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}

private func copy(_ http: CopyMoveHTTP, move: Bool = false) async throws {
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/seafile/"), transport: http)
    let entry = try JSONDecoder().decode(DirectoryEntry.self, from: Data(#"{"name":"空间 + &.txt","type":"file"}"#.utf8))
    try await api.copyMove(repo: "source", parent: "/原目录", entry: entry, destinationRepo: "target", destinationPath: "/目标", move: move)
}

@Test func inlineCopyMoveDoesNotPollOrRepeatTheCompletedMutation() async throws {
    let http = CopyMoveHTTP(["{}"])
    try await copy(http, move: true)
    let requests = await http.requests
    #expect(requests.count == 1 && requests[0].httpMethod == "POST")
    let fields = URLComponents(string: "?" + String(decoding: requests[0].httpBody!, as: UTF8.self))!.queryItems!
    #expect(fields.first { $0.name == "src_dirent_name" }?.value == "空间 + &.txt")
    #expect(fields.first { $0.name == "operation" }?.value == "move")
}

@Test func backgroundCopyPollsTheTaskAndNeverResubmitsTheMutation() async throws {
    let http = CopyMoveHTTP([#"{"task_id":"task + &"}"#, #"{"successful":true,"failed":false,"canceled":false}"#])
    try await copy(http)
    let requests = await http.requests
    #expect(requests.count == 2 && requests[1].httpMethod == "GET")
    let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: true)!.queryItems!
    #expect(query.first { $0.name == "task_id" }?.value == "task + &")
}

@Test func failedCancelledAndMalformedCopyRepliesAreNeverReportedAsSuccess() async throws {
    for replies in [[#"{"task_id":""}"#], [#"{"detail":"unexpected"}"#], [#"{"task_id":"task"}"#, #"{"successful":false,"failed":true,"canceled":false}"#], [#"{"task_id":"task"}"#, #"{"successful":false,"failed":false,"canceled":true}"#]] {
        let http = CopyMoveHTTP(replies)
        await #expect(throws: SeafileError.self) { try await copy(http) }
        #expect(await http.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
}

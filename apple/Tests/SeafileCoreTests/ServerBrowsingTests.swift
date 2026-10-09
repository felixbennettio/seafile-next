import Foundation
import Testing
@testable import SeafileCore

private actor SearchHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    let json: String
    init(_ json: String) { self.json = json }
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) throws -> (URL, URLResponse) { throw SeafileError.invalidResponse }
    func upload(for request: URLRequest, from file: URL) throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}

@Test func communitySearchUsesTheOriginalLibraryAPIAndPreservesUnicodeAndDirectoryTypes() async throws {
    let http = SearchHTTP(#"{"data":[{"path":"/空间 + &/notes.txt","type":"file"},{"path":"/空间 + &","type":"folder"}]}"#)
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/seafile/"), transport: http)
    let result = try await api.searchInLibrary("空间 + &", repo: "repo-test")
    #expect(result.results.count == 2 && !result.has_more)
    #expect(result.results[0].name == "notes.txt" && result.results[0].fullpath == "/空间 + &/notes.txt")
    #expect(!result.results[0].is_dir && result.results[1].is_dir)
    #expect(result.results.allSatisfy { $0.repo_id == "repo-test" })
    let request = await http.requests[0]
    #expect(request.url!.path == "/seafile/api/v2.1/search-file")
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!.queryItems!
    #expect(items.first { $0.name == "q" }?.value == "空间 + &")
    #expect(items.first { $0.name == "repo_id" }?.value == "repo-test")
}

@Test func communitySearchRejectsMalformedServerPathsInsteadOfNavigatingToAnotherLocation() async throws {
    for path in ["../file.txt", "/../file.txt", "/folder/./file.txt", "/", "/folder\0name"] {
        let data = try JSONSerialization.data(withJSONObject: ["data": [["path": path, "type": "file"]]])
        let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: SearchHTTP(String(decoding: data, as: UTF8.self)))
        await #expect(throws: SeafileError.self) { try await api.searchInLibrary("file", repo: "repo-test") }
    }
}

@Test func advancedSearchRequiresBothAdvertisedServerFeatures() throws {
    for (features, expected) in [([], false), (["seafile-pro"], false), (["file-search"], false), (["seafile-pro", "file-search"], true)] {
        let data = try JSONSerialization.data(withJSONObject: ["version": "13.0.25", "features": features])
        #expect(try JSONDecoder().decode(ServerInfo.self, from: data).supportsAdvancedSearch == expected)
    }
}

@Test func serverActivityAndCommitDetailsFollowTheOriginalResponseContracts() async throws {
    let activities = SearchHTTP(#"{"events":[{"repo_id":"repo-test","repo_name":"Documents","op_type":"edit","time":"2026-10-09T00:00:00Z","commit_id":"commit-test","name":"notes.txt","path":"/notes.txt","author_name":"User"}]}"#)
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/seafile/"), transport: activities)
    let events = try await api.activities(page: 2)
    #expect(events.count == 1 && events[0].commit_id == "commit-test")
    let query = URLComponents(url: await activities.requests[0].url!, resolvingAgainstBaseURL: true)!.queryItems!
    #expect(query.first { $0.name == "page" }?.value == "2")
    let changes = SearchHTTP(#"{"added_files":["/new.txt"],"modified_files":["/notes.txt"],"renamed_files":["/old.txt","/renamed.txt"]}"#)
    let detailAPI = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/seafile/"), transport: changes)
    let result = try await detailAPI.commitChanges(repo: "repo-test", commit: "commit-test")
    #expect(result.items.count == 3)
    #expect(result.items.contains { $0.0 == "Renamed" && $0.1 == "/old.txt → /renamed.txt" })
    #expect(await changes.requests[0].url!.path == "/seafile/api2/repo_history_changes/repo-test")
}

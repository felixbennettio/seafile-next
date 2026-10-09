import Foundation
import Testing
@testable import SeafileCore

private actor CreationHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var replayPolicies: [Bool] = []
    let body: Data
    let failure: URLError?
    init(_ reply: String, failure: URLError? = nil) { body = Data(reply.utf8); self.failure = failure }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await data(for: request, replaySafe: false) }
    func data(for request: URLRequest, replaySafe: Bool) async throws -> (Data, URLResponse) {
        requests.append(request); replayPolicies.append(replaySafe)
        if let failure { throw failure }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) { throw SeafileError.invalidResponse }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}

@Test func newFileUsesDeploymentUnicodePathAndTheServersNonOverwritingName() async throws {
    let transport = CreationHTTP(#"{"type":"file","repo_id":"repo","parent_dir":"/空间 + &","obj_name":"笔记 + &(1).md","size":0}"#)
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.org/seafile/"), token: "test-token", transport: transport)
    #expect(try await api.createFile(repo: "repo", parent: "/空间 + &", name: "笔记 + &.md") == "笔记 + &(1).md")
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.path == "/seafile/api/v2.1/repos/repo/file/")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/空间 + &/笔记 + &.md")
    #expect(String(decoding: request.httpBody!, as: UTF8.self) == "operation=create")
    #expect(await transport.replayPolicies == [false])
}

@Test func newFileRejectsInvalidInputWithoutContactingTheServer() async throws {
    let transport = CreationHTTP("{}"), api = SeafileAPI(endpoint: try ServerEndpoint("https://example.org/"), transport: transport)
    for name in ["", "   ", ".", "..", "a/b", "a\\b", "a\0b", String(repeating: "相", count: 90)] {
        await #expect(throws: Error.self) { try await api.createFile(repo: "repo", parent: "/", name: name) }
    }
    #expect(await transport.requests.isEmpty)
}

@Test func newFileRejectsUnexpectedServerLocationsAndMalformedResults() async throws {
    for reply in [#"{"type":"file","repo_id":"other","parent_dir":"/","obj_name":"a.txt"}"#,
        #"{"type":"file","repo_id":"repo","parent_dir":"/other","obj_name":"a.txt"}"#,
        #"{"type":"dir","repo_id":"repo","parent_dir":"/","obj_name":"a.txt"}"#,
        #"{"type":"file","repo_id":"repo","parent_dir":"/","obj_name":"../a.txt"}"#, "{}"] {
        let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.org/"), transport: CreationHTTP(reply))
        await #expect(throws: Error.self) { try await api.createFile(repo: "repo", parent: "/", name: "a.txt") }
    }
}

@Test func uncertainFileCreationIsNeverReplayedAndExplainsTheRequiredRefresh() async throws {
    let transport = CreationHTTP("{}", failure: URLError(.networkConnectionLost))
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://example.org/"), transport: transport)
    do { _ = try await api.createFile(repo: "repo", parent: "/", name: "a.txt"); Issue.record("Creation should report the lost response") }
    catch { #expect(error.localizedDescription.contains("Refresh this folder")) }
    #expect(await transport.requests.count == 1)
    #expect(await transport.replayPolicies == [false])
}

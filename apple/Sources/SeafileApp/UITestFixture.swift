#if DEBUG
import Foundation
import SeafileCore

// Available only in Debug simulator tests. No real accounts, Keychain writes,
// Files domains or network requests are used by the navigation regression test.
actor UITestFixture: HTTPTransport {
    nonisolated let accounts: [ServerAccount]
    let failListing: Bool
    let slowTransfers: Bool
    private var favorites: Set<String> = ["/welcome.txt"]
    init(accounts: [ServerAccount], failListing: Bool, slowTransfers: Bool = false) { self.accounts = accounts; self.failListing = failListing; self.slowTransfers = slowTransfers }
    static func fromLaunchArguments() -> UITestFixture? {
        var arguments = ProcessInfo.processInfo.arguments
        if let fixture = Bundle.main.object(forInfoDictionaryKey: "SeafileUITestFixture") as? String {
            if fixture == "signed-in" { arguments.append("--ui-test-signed-in") }
            if fixture == "signed-out" { arguments.append("--ui-test-signed-out") }
        }
        guard arguments.contains("--ui-test-signed-in") || arguments.contains("--ui-test-signed-out") else { return nil }
        let endpoint = try! ServerEndpoint("https://fixture.invalid/seafile/")
        return UITestFixture(accounts: arguments.contains("--ui-test-signed-in") ? [
            ServerAccount(endpoint: endpoint, email: "first@fixture.invalid", name: "First account"),
            ServerAccount(endpoint: try! ServerEndpoint("https://fixture.invalid/other/"), email: "second@fixture.invalid", name: "Second account")
        ] : [], failListing: arguments.contains("--ui-test-server-error"), slowTransfers: arguments.contains("--ui-test-slow-transfer"))
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!.path
        let json: String
        if path.hasSuffix("api2/repos/") {
            if failListing { return (Data(#"{"detail":"Server temporarily unavailable"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!) }
            json = path.hasPrefix("/other/") ? #"[{"id":"second-repo","name":"Second library","encrypted":false,"permission":"rw","size":0}]"# : #"[{"id":"first-repo","name":"My documents","encrypted":false,"permission":"rw","size":24}]"#
        } else if path.hasSuffix("/dir/") {
            let directory = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.queryItems?.first { $0.name == "p" }?.value
            json = directory == "/" ? #"{"dirent_list":[{"name":"Projects","type":"dir"},{"name":"welcome.txt","type":"file","size":24}]}"# : #"{"dirent_list":[{"name":"notes.txt","type":"file","size":12}]}"#
        } else if path.hasSuffix("starred-items/") {
            let fields = URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems
            let itemPath = (request.httpMethod == "DELETE" ? URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.queryItems : fields)?.first { $0.name == "path" }?.value
            if request.httpMethod == "POST", let itemPath { favorites.insert(itemPath.hasPrefix("/Projects") ? "/Projects/" : itemPath) }
            if request.httpMethod == "DELETE", let itemPath { favorites.remove(itemPath) }
            let list: [[String: Any]] = favorites.sorted().map {
                ["repo_id": "first-repo", "repo_name": "My documents", "path": $0,
                 "obj_name": ($0 as NSString).lastPathComponent, "is_dir": $0.hasSuffix("/"), "deleted": false]
            }
            let body = try JSONSerialization.data(withJSONObject: ["starred_item_list": list])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        else if path.hasSuffix("/file/") { json = #""https://fixture.invalid/signed-download""# }
        else if path.hasSuffix("server-info/") { json = #"{"version":"13.0.25","features":["client-sso-via-local-browser"]}"# }
        else if path.hasSuffix("auth-token/") { json = #"{"token":"fixture-token"}"# }
        else if path.hasSuffix("account/info/") { json = #"{"email":"first@fixture.invalid","name":"First account"}"# }
        else { throw SeafileError.local("Unexpected fixture request") }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        guard request.url?.path == "/signed-download" else { throw SeafileError.invalidResponse }
        if slowTransfers { try await Task.sleep(for: .seconds(3)) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Welcome to the preview regression test.\n".utf8).write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}
#endif

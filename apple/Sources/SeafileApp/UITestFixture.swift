#if DEBUG
import Foundation
import ImageIO
import SeafileCore

// Available only in Debug simulator tests. No real accounts, Keychain writes,
// Files domains or network requests are used by the navigation regression test.
actor UITestFixture: HTTPTransport {
    nonisolated let accounts: [ServerAccount]
    let failListing: Bool
    let slowTransfers: Bool
    let failSecondMutation: Bool
    nonisolated let legacySSO: Bool
    private var favorites: Set<String> = ["/welcome.txt"]
    private var files: Set<String> = ["/welcome.txt", "/Projects/notes.txt", "/Projects/todo.txt"]
    private var folders: Set<String> = ["/Projects"]
    private var mutationCount = 0
    private var failedMutation = false
    private var confirmedMutations: Set<String> = []
    private var createdLibraries: [String: String] = [:]
    private var uploadedContent: [String: Data] = [:]
    private var downloadsReleased = false
    init(accounts: [ServerAccount], failListing: Bool, slowTransfers: Bool = false, failSecondMutation: Bool = false, legacySSO: Bool = false, mediaFiles: Bool = false) { self.accounts = accounts; self.failListing = failListing; self.slowTransfers = slowTransfers; self.failSecondMutation = failSecondMutation; self.legacySSO = legacySSO
        if mediaFiles {
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAABw0lEQVR4nJVSPWtUQRQ9Z+bt6tNkzaKiZPGjUyEQCBEhQvzAKo2dnRb+D3+EnbVI2MLCINoKEWIRliAELBRUEiNxsx/Jso99szNzZWZfSEQUHW4x3HvP/Tj30BiD/3nqN49E+1eAgOVgf8aoQ4V9SDVfYDagIkZcMPwCTvY/hC6jWUe7DmiceoCTd4uIF8gwJOwDBNQQi701bi/CduEH4GsZm0P3DUhM3ETpNLwZYWhMDpKfHrH5QiozcuIaXIajF/hjCfnnULNck0uPcaQWx6OCLqG1zM57jN9A5bbaWWXeV+2Gaq+pLFO5V50P3FxEouFtHMlZVK/72XmIUysL7H+kXoXtozIlkwvorvP7S2bb4gySFH4Ylx71yZrMWnApB7tSnXFXn8IPUbuvhpYbr/ROw88+kcrlEa2Ey/W7h9zbZO+bjF1xc8/Asl6+F6hLL7K3xa23/PocWo1oldCEx9jf9ZO33HwdpQnYDEyTpWmaLqyT8hk5ewfeM2opMusMO+tSnQqzukGobXpsNaBTiJfj5zB+PuQciC9somEtxAf6Q5UEiSoO7QFnwgEOqVUgElOLoxaeQjgqhg6kEVePrr968BNNbMjV9vzJQwAAAABJRU5ErkJggg== ".trimmingCharacters(in: .whitespaces))!
            for file in ["/photo-one.png", "/photo-two.png"] { files.insert(file); uploadedContent[file] = png }
        }
    }
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
        ] : [], failListing: arguments.contains("--ui-test-server-error"), slowTransfers: arguments.contains("--ui-test-slow-transfer"), failSecondMutation: arguments.contains("--ui-test-partial-mutation"), legacySSO: arguments.contains("--ui-test-legacy-sso"), mediaFiles: arguments.contains("--ui-test-media"))
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!.path
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.queryItems ?? []
        let fields = URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems ?? []
        func value(_ name: String, in values: [URLQueryItem]) -> String? { values.first { $0.name == name }?.value }
        func reply(_ object: Any, status: Int = 200) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if path.contains("api/v2.1/repos/"), path.hasSuffix("/file/"), request.httpMethod == "POST", value("operation", in: fields) == "create" {
            let target = value("p", in: query) ?? "", parent = (target as NSString).deletingLastPathComponent
            let name = (target as NSString).lastPathComponent, stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var unique = name, counter = 1
            while files.contains((parent == "/" ? "" : parent) + "/" + unique) {
                unique = stem + "(\(counter))" + (ext.isEmpty ? "" : "." + ext); counter += 1
            }
            let created = (parent == "/" ? "" : parent) + "/" + unique
            files.insert(created); uploadedContent[created] = Data()
            return try reply(["type": "file", "repo_id": "first-repo", "parent_dir": parent, "obj_name": unique, "size": 0])
        }
        if path.hasSuffix("api2/repos/"), request.httpMethod == "POST" {
            guard let name = value("name", in: fields), !name.isEmpty else { throw SeafileError.invalidResponse }
            let id = "created-" + UUID().uuidString
            createdLibraries[id] = name
            return try reply(["repo_id": id])
        }
        if request.httpMethod == "DELETE", path.contains("api2/repos/"), let id = path.split(separator: "/").last, createdLibraries[String(id)] != nil {
            createdLibraries.removeValue(forKey: String(id))
            return try reply([String: String]())
        }
        if path.hasSuffix("copy-move-task/") || (request.httpMethod == "DELETE" && (path.hasSuffix("/dir/") || path.hasSuffix("/file/"))) {
            let key = path.hasSuffix("copy-move-task/") ? "copy:" + (value("src_dirent_name", in: fields) ?? "") : "delete:" + (value("p", in: query) ?? "")
            guard !confirmedMutations.contains(key) else { return try reply(["detail": "A completed item was submitted again"], status: 409) }
            mutationCount += 1
            if failSecondMutation && mutationCount == 2 && !failedMutation {
                failedMutation = true
                return try reply(["detail": "Fixture stopped the second item"], status: 503)
            }
            if path.hasSuffix("copy-move-task/") {
                guard value("src_repo_id", in: fields) == "first-repo", value("dst_repo_id", in: fields) == "first-repo",
                      let parent = value("src_parent_dir", in: fields), let destination = value("dst_parent_dir", in: fields),
                      let name = value("src_dirent_name", in: fields) else { throw SeafileError.invalidResponse }
                let source = (parent == "/" ? "" : parent) + "/" + name
                let target = (destination == "/" ? "" : destination) + "/" + name
                guard files.contains(source), !files.contains(target) else { return try reply(["detail": "Invalid copy source or existing target"], status: 409) }
                files.insert(target)
                if value("operation", in: fields) == "move" { files.remove(source) }
                confirmedMutations.insert(key)
                return try reply(["task_id": "fixture-task"])
            } else {
                guard let target = value("p", in: query), files.contains(target) || folders.contains(target) else { throw SeafileError.invalidResponse }
                files = files.filter { $0 != target && !$0.hasPrefix(target + "/") }
                folders = folders.filter { $0 != target && !$0.hasPrefix(target + "/") }
                confirmedMutations.insert(key)
                return try reply([String: String]())
            }
        }
        if path.hasSuffix("query-copy-move-progress/") { return try reply(["successful": true, "failed": false, "canceled": false]) }
        if path.hasSuffix("shared_items/") { return try reply([]) }
        if path.hasSuffix("groupandcontacts/") { return try reply(["groups": [], "contacts": []]) }
        if path.hasSuffix("share-links/") {
            guard value("password", in: fields) == "fixture-link-password", value("expiration_time", in: fields) != nil else {
                return try reply(["detail": "Password or expiration was missing"], status: 400)
            }
            return try reply(["link": "https://fixture.invalid/seafile/d/fixture-share/"])
        }
        let json: String
        if path.hasSuffix("api2/repos/") {
            if failListing { return (Data(#"{"detail":"Server temporarily unavailable"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!) }
            if !path.hasPrefix("/other/") {
                let libraries: [[String: Any]] = [["id": "first-repo", "name": "My documents", "encrypted": false, "permission": "rw", "size": 24]] + createdLibraries.map { ["id": $0.key, "name": $0.value, "encrypted": false, "permission": "rw", "size": 0] }
                return try reply(libraries)
            }
            json = #"[{"id":"second-repo","name":"Second library","encrypted":false,"permission":"rw","size":0}]"#
        } else if path.hasSuffix("search-file/") {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!.queryItems!
            guard query.first(where: { $0.name == "repo_id" })?.value == "first-repo" else { throw SeafileError.local("Search crossed library boundaries") }
            json = #"{"data":[{"path":"/Projects","type":"folder"},{"path":"/Projects/notes.txt","type":"file"}]}"#
        } else if path.hasSuffix("activities/") {
            json = #"{"events":[{"repo_id":"first-repo","repo_name":"My documents","op_type":"edit","time":"2026-10-09T00:00:00Z","commit_id":"fixture-commit","name":"notes.txt","path":"/Projects/notes.txt","author_name":"First account"}]}"#
        } else if path.contains("repo_history_changes/") {
            json = #"{"modified_files":["/Projects/notes.txt"],"added_files":["/new-file.txt"]}"#
        } else if path.hasSuffix("/dir/") {
            let directory = try RemoteDirectoryPath.canonical(value("p", in: query) ?? "/")
            func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
            let list: [[String: Any]] = folders.filter { parent($0) == directory }.sorted().map { ["name": ($0 as NSString).lastPathComponent, "type": "dir"] } + files.filter { parent($0) == directory }.sorted().map { ["name": ($0 as NSString).lastPathComponent, "type": "file", "size": uploadedContent[$0]?.count ?? 24] }
            return try reply(["dirent_list": list])
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
        else if path.hasSuffix("/upload-link/") { json = #""https://fixture.invalid/upload""# }
        else if path.hasSuffix("/file/detail/") {
            guard let file = value("p", in: query), files.contains(file) else { return try reply(["detail": "File not found"], status: 404) }
            return try reply(["name": (file as NSString).lastPathComponent, "type": "file", "size": uploadedContent[file]?.count ?? 24])
        }
        else if path.hasSuffix("/file/") {
            var link = URLComponents(string: "https://fixture.invalid/signed-download")!
            link.queryItems = [.init(name: "p", value: value("p", in: query) ?? "/welcome.txt")]
            return (try JSONEncoder().encode(link.url!.absoluteString), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        else if path.hasSuffix("server-info/") { return try reply(["version": "13.0.25", "features": legacySSO ? [] : ["client-sso-via-local-browser"]]) }
        else if path.hasSuffix("auth-token/") { json = #"{"token":"fixture-token"}"# }
        else if path.hasSuffix("account/info/") { json = #"{"email":"first@fixture.invalid","name":"First account"}"# }
        else { throw SeafileError.local("Unexpected fixture request") }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        guard request.url?.path == "/signed-download" else { throw SeafileError.invalidResponse }
        // Tests release the download after navigating away. A fixed delay
        // races XCTest's idle waiting and can finish before the actual click.
        while slowTransfers && !downloadsReleased { try await Task.sleep(for: .milliseconds(100)) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.queryItems?.first { $0.name == "p" }?.value ?? "/welcome.txt"
        try (uploadedContent[path] ?? Data("Welcome to the preview regression test.\n".utf8)).write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) {
        guard request.url?.path == "/upload", let contentType = request.value(forHTTPHeaderField: "Content-Type"),
              let boundary = contentType.components(separatedBy: "boundary=").last else { throw SeafileError.invalidResponse }
        let body = try Data(contentsOf: file)
        guard let start = body.range(of: Data("name=\"file\"; filename=\"".utf8)),
              let filenameEnd = body.range(of: Data([34]), in: start.upperBound..<body.endIndex),
              let header = body.range(of: Data("\r\n\r\n".utf8), in: filenameEnd.upperBound..<body.endIndex),
              let end = body.range(of: Data(("\r\n--" + boundary).utf8), in: header.upperBound..<body.endIndex) else { throw SeafileError.invalidResponse }
        let filename = String(decoding: body[start.upperBound..<filenameEnd.lowerBound], as: UTF8.self)
        let content = Data(body[header.upperBound..<end.lowerBound])
        func contains(_ text: String) -> Bool { body.range(of: Data(text.utf8)) != nil }
        if filename == "notes.txt" {
            guard contains("/Projects"), contains("name=\"replace\"\r\n\r\n1\r\n"), String(decoding: content, as: UTF8.self).contains("Editor fixture change") else { throw SeafileError.invalidResponse }
            uploadedContent["/Projects/notes.txt"] = content
        } else {
            // The simulator also contains its own JPEG photos. Validate real
            // exported images, rather than accepting only the injected PNG.
            let image = CGImageSourceCreateWithData(content as CFData, nil).map { CGImageSourceGetCount($0) > 0 } ?? false
            if ProcessInfo.processInfo.arguments.contains("--ui-test-jpeg-backup") {
                let source = CGImageSourceCreateWithData(content as CFData, nil)
                let expected = filename.hasSuffix(".jpg") ? "public.jpeg" : "public.heic"
                guard let source, CGImageSourceGetType(source) as String? == expected else { throw SeafileError.local("Photo backup uploaded a different image format than its filename") }
            }
            let movie = content.count > 8 && content.subdata(in: 4..<8) == Data("ftyp".utf8)
            guard content.starts(with: Data("Photo backup fixture ".utf8)) || image || movie else { throw SeafileError.local("Photo backup did not export a valid image or video resource") }
            guard contains("name=\"parent_dir\"\r\n\r\n/\r\n"), contains("name=\"replace\"\r\n\r\n0\r\n") else { throw SeafileError.local("Photo backup attempted an invalid destination or replacement") }
            guard !files.contains("/" + filename) else { throw SeafileError.local("Photo backup submitted an existing resource again") }
            files.insert("/" + filename); uploadedContent["/" + filename] = content
        }
        return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func releaseDownloads() { downloadsReleased = true }
}
#endif

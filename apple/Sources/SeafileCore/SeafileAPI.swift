import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest, replaySafe: Bool) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse)
    func freshConnection() -> any HTTPTransport
    func responseWithoutRedirect(for request: URLRequest) async throws -> HTTPURLResponse
}

extension HTTPTransport {
    public func data(for request: URLRequest, replaySafe: Bool) async throws -> (Data, URLResponse) { try await data(for: request) }
    public func freshConnection() -> any HTTPTransport { self }
    public func responseWithoutRedirect(for request: URLRequest) async throws -> HTTPURLResponse {
        let (_, response) = try await data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SeafileError.invalidResponse }
        return response
    }
}

public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session = URLSession(configuration: URLSessionTransport.configuration())
    public override init() {
        super.init()
    }
    private static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        // A long resource timeout is needed for large transfers, so waiting
        // for connectivity here could otherwise stall a login for hours.
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        // API authentication uses headers. Web sign-in belongs to the browser.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return config
    }
    deinit { session.invalidateAndCancel() }
    private func connection() -> URLSession { lock.withLock { session } }
    public func freshConnection() -> any HTTPTransport {
        let previous = lock.withLock {
            let previous = session
            session = URLSession(configuration: Self.configuration())
            return previous
        }
        // Let other in-flight requests finish. Subsequent operations use the
        // new pool too, so a failed TLS connection cannot poison the whole app.
        previous.finishTasksAndInvalidate()
        return self
    }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await connection().data(for: request, delegate: self) }
    public func download(for request: URLRequest) async throws -> (URL, URLResponse) { try await connection().download(for: request, delegate: self) }
    public func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) { try await connection().upload(for: request, fromFile: file, delegate: self) }
    public func responseWithoutRedirect(for request: URLRequest) async throws -> HTTPURLResponse {
        let (_, response) = try await connection().data(for: request, delegate: StopRedirect())
        guard let response = response as? HTTPURLResponse else { throw SeafileError.invalidResponse }
        return response
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if let original = task.originalRequest?.url, let next = request.url {
            if original.scheme == "https" && next.scheme != "https" { completionHandler(nil); return }
            if original.host?.lowercased() != next.host?.lowercased() || original.port != next.port || original.scheme != next.scheme {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
                redirected.setValue(nil, forHTTPHeaderField: "X-Seafile-OTP")
            }
        }
        completionHandler(redirected)
    }
}

private final class StopRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor SeafileAPI {
    public let endpoint: ServerEndpoint
    private let token: String?
    private let transport: any HTTPTransport
    public init(endpoint: ServerEndpoint, token: String? = nil, transport: any HTTPTransport = RetryingHTTPTransport.shared) {
        self.endpoint = endpoint; self.token = token; self.transport = transport
    }

    func startSSOVisit(_ url: URL) async throws {
        // Visiting this single-use URL records accessed_at. Do not follow it
        // into the server login page or replay a possibly completed visit.
        let response = try await transport.responseWithoutRedirect(for: makeRequest(url))
        guard (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: url)?.absoluteURL,
              endpoint.isSameOrigin(target) else { throw SeafileError.invalidResponse }
    }

    private func makeRequest(_ url: URL, method: String = "GET", form: [String: String]? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("seafile-next/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if endpoint.isSameOrigin(url), let token { request.setValue("Token \(token)", forHTTPHeaderField: "Authorization") }
        if let form {
            request.httpBody = Self.formData(form)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public static func formData(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }

    private func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw SeafileError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = object["error_msg"] as? String ?? object["detail"] as? String ?? object["error"] as? String ?? message
            }
            throw SeafileError.server(http.statusCode, String(message.prefix(500)))
        }
    }

    public func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], form: [String: String]? = nil, replaySafe: Bool = false) async throws -> Data {
        let request = makeRequest(try endpoint.api(path, query: query), method: method, form: form)
        let (data, response) = try await transport.data(for: request, replaySafe: replaySafe)
        try validate(response, data: data)
        return data
    }

    public func authenticate(username: String, password: String, otp: String = "") async throws -> String {
        var request = makeRequest(try endpoint.api("api2/auth-token/"), method: "POST", form: ["username": username, "password": password])
        if !otp.isEmpty { request.setValue(otp, forHTTPHeaderField: "X-Seafile-OTP") }
        // This endpoint retrieves/creates the same account token. Replaying it
        // is safe; file mutations and multipart uploads are never replayed.
        let (data, response) = try await transport.data(for: request, replaySafe: true)
        try validate(response, data: data)
        struct Login: Decodable { let token: String }
        let result = try JSONDecoder().decode(Login.self, from: data)
        guard !result.token.isEmpty else { throw SeafileError.invalidResponse }
        return result.token
    }

    public func repositories() async throws -> [Repository] {
        try JSONDecoder().decode([Repository].self, from: await request("api2/repos/"))
    }

    public func directory(repo: String, path: String) async throws -> [DirectoryEntry] {
        struct Listing: Decodable { let dirent_list: [DirectoryEntry] }
        return try JSONDecoder().decode(Listing.self, from: await request("api/v2.1/repos/\(repo)/dir/", query: [.init(name: "p", value: path)])).dirent_list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func unlock(repo: String, password: String) async throws {
        _ = try await request("api2/repos/\(repo)/", method: "POST", form: ["password": password])
    }

    public func createDirectory(repo: String, path: String) async throws {
        _ = try await request("api2/repos/\(repo)/dir/", method: "POST", query: [.init(name: "p", value: path)], form: ["operation": "mkdir"])
    }

    public func delete(repo: String, path: String, isDirectory: Bool) async throws {
        _ = try await request("api2/repos/\(repo)/\(isDirectory ? "dir" : "file")/", method: "DELETE", query: [.init(name: "p", value: path)])
    }

    public func rename(repo: String, path: String, isDirectory: Bool, to name: String) async throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw SeafileError.unsafeFilename }
        _ = try await request("api2/repos/\(repo)/\(isDirectory ? "dir" : "file")/", method: "POST", query: [.init(name: "p", value: path)], form: ["operation": "rename", "newname": name])
    }

    public func shareLink(repo: String, path: String, password: String = "") async throws -> URL {
        var form = ["repo_id": repo, "path": path]
        if !password.isEmpty { form["password"] = password }
        struct Link: Decodable { let link: String }
        let result = try JSONDecoder().decode(Link.self, from: await request("api/v2.1/share-links/", method: "POST", form: form))
        return try transferURL(result.link)
    }

    public func setStarred(repo: String, path: String, starred: Bool) async throws {
        if starred {
            _ = try await request("api/v2.1/starred-items/", method: "POST", form: ["repo_id": repo, "path": path])
        } else {
            _ = try await request("api/v2.1/starred-items/", method: "DELETE", query: [.init(name: "repo_id", value: repo), .init(name: "path", value: path)])
        }
    }

    public func starredItems() async throws -> [StarredItem] {
        struct Listing: Decodable { let starred_item_list: [StarredItem] }
        return try JSONDecoder().decode(Listing.self, from: await request("api/v2.1/starred-items/")).starred_item_list
    }

    public func downloadInfo(repo: String) async throws -> DownloadInfo {
        try JSONDecoder().decode(DownloadInfo.self, from: await request("api2/repos/\(repo)/download-info/"))
    }

    private func transferURL(_ value: String) throws -> URL {
        guard let url = URL(string: value, relativeTo: endpoint.url)?.absoluteURL,
              ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil else { throw SeafileError.invalidResponse }
        if endpoint.url.scheme == "https", url.scheme != "https" { throw SeafileError.invalidResponse }
        return url
    }

    public func download(repo: String, path: String, destination: URL) async throws {
        let data = try await request("api2/repos/\(repo)/file/", query: [.init(name: "p", value: path)])
        let link = try JSONDecoder().decode(String.self, from: data)
        let (temporary, response) = try await transport.download(for: makeRequest(try transferURL(link)))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try validate(response)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }

    public func upload(repo: String, directory: String, file: URL, replace: Bool = false) async throws {
        let data = try await request("api2/repos/\(repo)/upload-link/", query: [.init(name: "p", value: directory)])
        let link = try JSONDecoder().decode(String.self, from: data)
        var components = URLComponents(url: try transferURL(link), resolvingAgainstBaseURL: true)!
        components.queryItems = (components.queryItems ?? []) + [.init(name: "ret-json", value: "1")]
        let boundary = "seafile-next-" + UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try MultipartFile.write(file: file, directory: directory, replace: replace, boundary: boundary, to: temporary)
        var request = makeRequest(components.url!, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (result, response) = try await transport.upload(for: request, from: temporary)
        try validate(response, data: result)
    }
}

public enum MultipartFile {
    public static func write(file: URL, directory: String, replace: Bool, boundary: String, to output: URL) throws {
        let filename = file.lastPathComponent
        guard !filename.contains("\r"), !filename.contains("\n"), !filename.contains("\0") else { throw SeafileError.unsafeFilename }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output), reader = try FileHandle(forReadingFrom: file)
        defer { try? writer.close(); try? reader.close() }
        func write(_ string: String) throws { try writer.write(contentsOf: Data(string.utf8)) }
        for (name, value) in [("parent_dir", directory), ("replace", replace ? "1" : "0")] {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let quoted = filename.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(quoted)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        while let chunk = try reader.read(upToCount: 64 * 1024), !chunk.isEmpty { try writer.write(contentsOf: chunk) }
        try write("\r\n--\(boundary)--\r\n")
    }
}

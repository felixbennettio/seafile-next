import Foundation

public struct Wiki: Decodable, Identifiable, Sendable {
    public let wikiID: String, name: String, repoID: String
    public let kind: String, ownerName: String?, slug: String?
    public let published: Bool
    public let permission: String
    public var writable: Bool { ["rw", "admin", "rwd"].contains(permission) }
    public var legacy = false
    public var id: String { (legacy ? "legacy:" : "wiki:") + wikiID }
    public var canManage: Bool { !legacy && kind == "mine" }
    enum CodingKeys: String, CodingKey {
        case wikiID = "id", name, repoID = "repo_id", kind = "type"
        case ownerName = "owner_nickname", slug, published = "is_published"
        case permission
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? values.decode(String.self, forKey: .wikiID) { wikiID = string }
        else { wikiID = String(try values.decode(Int.self, forKey: .wikiID)) }
        name = try values.decode(String.self, forKey: .name)
        repoID = try values.decode(String.self, forKey: .repoID)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "shared"
        ownerName = try values.decodeIfPresent(String.self, forKey: .ownerName)
        slug = try values.decodeIfPresent(String.self, forKey: .slug)
        published = try values.decodeIfPresent(Bool.self, forKey: .published) ?? false
        permission = try values.decodeIfPresent(String.self, forKey: .permission) ?? (kind == "mine" ? "rw" : "r")
    }
}

public struct WikiGroup: Decodable, Identifiable, Sendable {
    public let id: Int, name: String, wikis: [Wiki]
    enum CodingKeys: String, CodingKey { case id = "group_id", name = "group_name", wikis = "wiki_info" }
}

public struct WikiCatalog: Sendable {
    public let wikis: [Wiki], groups: [WikiGroup], legacy: [Wiki]
    public let modernAvailable: Bool
    public let warnings: [String]
}

extension SeafileAPI {
    /// Keep the two original APIs independent: an old server may only expose
    /// legacy wikis. A failed request must not turn a partial list into "empty".
    public func wikiCatalog() async throws -> WikiCatalog {
        struct Modern: Decodable, Sendable { let wikis: [Wiki]; let group_wikis: [WikiGroup] }
        struct Legacy: Decodable, Sendable { let data: [Wiki] }
        func load<T: Decodable & Sendable>(_ path: String, as: T.Type) async -> Result<T, Error> {
            do { return .success(try JSONDecoder().decode(T.self, from: await request(path))) }
            catch { return .failure(error) }
        }
        async let modernResult = load("api/v2.1/wikis2/", as: Modern.self)
        async let legacyResult = load("api/v2.1/wikis/", as: Legacy.self)
        let (modern, old) = await (modernResult, legacyResult)
        try Task.checkCancellation()
        if case .failure(let first) = modern, case .failure = old { throw first }
        var wikis: [Wiki] = [], groups: [WikiGroup] = [], legacy: [Wiki] = [], warnings: [String] = []
        var available = false
        switch modern {
        case .success(let result): wikis = result.wikis; groups = result.group_wikis; available = true
        case .failure(let error):
            if !Self.wikiEndpointUnavailable(error) { warnings.append("Some wikis could not be loaded. Refresh to try again.") }
        }
        switch old {
        case .success(let result): legacy = result.data.map { var wiki = $0; wiki.legacy = true; return wiki }
        case .failure(let error):
            if !Self.wikiEndpointUnavailable(error) { warnings.append("Older wikis could not be loaded. Refresh to try again.") }
        }
        return WikiCatalog(wikis: wikis, groups: groups, legacy: legacy, modernAvailable: available, warnings: warnings)
    }
    private static func wikiEndpointUnavailable(_ error: Error) -> Bool {
        if case SeafileError.server(let status, _) = error { return [404, 405].contains(status) }
        return false
    }
    private func wikiPath(_ id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw SeafileError.invalidResponse }
        return "api/v2.1/wiki2/\(id)/"
    }
    public func renameWiki(id: String, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name.count <= 255,
              try RemoteDirectoryPath.canonical("/" + name) == "/" + name else { throw SeafileError.unsafeFilename }
        _ = try await request(wikiPath(id), method: "PUT", form: ["wiki_name": name])
    }
    public func deleteWiki(id: String) async throws {
        _ = try await request(wikiPath(id), method: "DELETE")
    }
    public func createWiki(name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 255,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.init(charactersIn: " -_")).contains($0) }) else { throw SeafileError.unsafeFilename }
        _ = try await request("api/v2.1/wikis2/", method: "POST", form: ["name": name, "owner": "me"])
    }
    public func publishWiki(id: String, suffix: String) async throws {
        let suffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...30).contains(suffix.utf8.count), suffix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }) else { throw SeafileError.local("Use 5–30 letters, numbers or hyphens for the public address.") }
        _ = try await request(wikiPath(id) + "publish/", method: "POST", form: ["publish_url": suffix])
    }
    public func unpublishWiki(id: String) async throws {
        _ = try await request(wikiPath(id) + "publish/", method: "DELETE")
    }
    public func wikiPages(id: String) async throws -> [WikiPage] {
        struct Reply: Decodable {
            struct WikiConfig: Decodable {
                struct Config: Decodable { let pages: [WikiPage]? }
                let wiki_config: Config
            }
            let wiki: WikiConfig
        }
        let pages = try JSONDecoder().decode(Reply.self, from: await request(wikiPath(id) + "config/")).wiki.wiki_config.pages ?? []
        guard Set(pages.map(\.id)).count == pages.count else { throw SeafileError.invalidResponse }
        for page in pages {
            guard page.id.utf8.count == 4, page.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  UUID(uuidString: page.documentID) != nil, page.path != "/", try RemoteDirectoryPath.canonical(page.path) == page.path else { throw SeafileError.invalidResponse }
        }
        return pages
    }
}

public struct WikiPage: Decodable, Identifiable, Sendable {
    public let id: String, name: String, path: String, documentID: String
    enum CodingKeys: String, CodingKey { case id, name, path; case documentID = "docUuid" }
}

/// URLs for the server's existing collaborative editors. Tokens never belong
/// in these URLs. WebKit receives one scoped Authorization header to establish
/// an ephemeral server session using the same mobile-login bridge as legacy iOS.
public enum ServerDocumentSession {
    public static func wikiURL(_ wiki: Wiki, endpoint: ServerEndpoint) throws -> URL {
        if wiki.legacy {
            guard let slug = wiki.slug, !slug.isEmpty, !slug.contains("/"), !slug.contains(".."),
                  !slug.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SeafileError.invalidResponse }
            let encoded = slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_")))!
            return try endpoint.api("published/\(encoded)/")
        }
        guard UUID(uuidString: wiki.wikiID) != nil else { throw SeafileError.invalidResponse }
        return try endpoint.api("wikis/\(wiki.wikiID)/")
    }
    public static func fileURL(repo: String, path: String, endpoint: ServerEndpoint, editing: Bool = false) throws -> URL {
        guard UUID(uuidString: repo) != nil, path != "/", try RemoteDirectoryPath.canonical(path) == path else { throw SeafileError.unsafeFilename }
        var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: true)!
        let safe = CharacterSet.alphanumerics.union(.init(charactersIn: "-_~"))
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: safe)! }.joined(separator: "/")
        components.percentEncodedPath += "lib/\(repo)/file/" + encoded
        if editing { components.queryItems = [.init(name: "mode", value: "edit")] }
        guard let result = components.url, allows(result, endpoint: endpoint) else { throw SeafileError.invalidResponse }
        return result
    }
    public static func allows(_ url: URL, endpoint: ServerEndpoint) -> Bool {
        guard endpoint.isSameOrigin(url), url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let base = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: true)?.path else { return false }
        let path = components.path
        guard path.hasPrefix(base), !path.contains("\\"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }
    public static func loginRequest(target: URL, endpoint: ServerEndpoint, token: String) throws -> URLRequest {
        guard allows(target, endpoint: endpoint), !token.isEmpty,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SeafileError.invalidResponse }
        let targetComponents = URLComponents(url: target, resolvingAgainstBaseURL: true)!
        let next = targetComponents.percentEncodedPath + (targetComponents.percentEncodedQuery.map { "?" + $0 } ?? "")
        let url = try endpoint.api("mobile-login/", query: [.init(name: "next", value: next)])
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Token " + token, forHTTPHeaderField: "Authorization")
        return request
    }
    public static func allowsNavigation(_ request: URLRequest, endpoint: ServerEndpoint, mainFrame: Bool) -> Bool {
        guard let url = request.url else { return false }
        let hasAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        if hasAuthorization {
            // The API token is sent exactly once to the server's session bridge.
            // Even a same-origin redirect must not carry it to another service.
            guard let bridge = try? endpoint.api("mobile-login/"), url.path == bridge.path,
                  request.httpMethod == "GET" else { return false }
            return allows(url, endpoint: endpoint)
        }
        if allows(url, endpoint: endpoint) { return true }
        return !mainFrame && url.scheme == "https" && url.user == nil && url.password == nil
    }
    public static func sessionRedirect(_ request: URLRequest, endpoint: ServerEndpoint) throws -> URLRequest {
        guard let url = request.url, allows(url, endpoint: endpoint) else { throw SeafileError.invalidResponse }
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        return safe
    }
}

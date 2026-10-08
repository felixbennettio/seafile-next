import Foundation

public struct ServerEndpoint: Hashable, Codable, Sendable {
    public let url: URL

    public init(_ value: String) throws {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw SeafileError.invalidServer }
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        guard let url = components.url else { throw SeafileError.invalidServer }
        self.url = url
    }

    public func api(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains(".."),
              let relative = URL(string: path, relativeTo: url)?.absoluteURL,
              var components = URLComponents(url: relative, resolvingAgainstBaseURL: true) else { throw SeafileError.invalidServer }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        // Django parses query strings as form data, where a literal '+' is a
        // space. URLComponents leaves '+' unescaped unless we encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = components.url else { throw SeafileError.invalidServer }
        return result
    }

    public func isSameOrigin(_ other: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
        return url.scheme?.lowercased() == other.scheme?.lowercased()
            && url.host?.lowercased() == other.host?.lowercased() && port(url) == port(other)
    }
}

public enum SeafileError: LocalizedError, Sendable {
    case invalidServer, invalidResponse, unsafeFilename
    case server(Int, String)
    case local(String)
    public var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter an HTTP or HTTPS server address, including its deployment path."
        case .invalidResponse: "The server returned an unexpected response."
        case .unsafeFilename: "The server returned an invalid file name."
        case .server(let code, let message): "\(message) (\(code))"
        case .local(let message): message
        }
    }
}

public struct ServerAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let endpoint: ServerEndpoint
    public let email: String
    public var name: String
    public init(id: UUID = UUID(), endpoint: ServerEndpoint, email: String, name: String? = nil) {
        self.id = id; self.endpoint = endpoint; self.email = email; self.name = name ?? email
    }
}

private extension KeyedDecodingContainer {
    func flexibleBool(_ key: Key) -> Bool {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        return false
    }
}

public struct Repository: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let encrypted: Bool
    public let permission: String
    public let size: Int64
    public let mtime: Double
    public let type: String
    public let owner: String?
    public let description: String?
    public var writable: Bool { ["rw", "admin", "rwd"].contains(permission) }
    enum CodingKeys: String, CodingKey { case id, name, encrypted, permission, size, mtime, type, owner; case description = "desc" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        encrypted = values.flexibleBool(.encrypted)
        permission = try values.decodeIfPresent(String.self, forKey: .permission) ?? "r"
        size = try values.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mtime = try values.decodeIfPresent(Double.self, forKey: .mtime) ?? 0
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "repo"
        owner = try values.decodeIfPresent(String.self, forKey: .owner)
        description = try values.decodeIfPresent(String.self, forKey: .description)
    }
}

public struct DirectoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let name: String
    public let type: String
    public let size: Int64
    public let mtime: Double?
    public let objectID: String?
    public let locked: Bool
    public let lockedByMe: Bool
    public let lockOwner: String?
    public var id: String { type + ":" + name }
    public var isDirectory: Bool { type == "dir" }
    enum CodingKeys: String, CodingKey {
        case name, type, size, mtime; case objectID = "id"; case locked = "is_locked", lockedByMe = "locked_by_me", lockOwner = "lock_owner_name"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw SeafileError.unsafeFilename }
        type = try values.decode(String.self, forKey: .type)
        size = try values.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mtime = try values.decodeIfPresent(Double.self, forKey: .mtime)
        objectID = try values.decodeIfPresent(String.self, forKey: .objectID)
        locked = values.flexibleBool(.locked)
        lockedByMe = values.flexibleBool(.lockedByMe)
        lockOwner = try values.decodeIfPresent(String.self, forKey: .lockOwner)
    }
    public func path(in directory: String) -> String { (directory.hasSuffix("/") ? directory : directory + "/") + name }
}

public struct DownloadInfo: Decodable, Sendable {
    public let repo_id: String, repo_name: String, token: String, email: String
    public let repo_version: Int
    public let magic: String?, random_key: String?, salt: String?
    public let enc_version: Int?, pwd_hash_algo: String?, pwd_hash_params: String?, pwd_hash: String?
}

public struct StarredItem: Decodable, Identifiable, Sendable {
    public let repo: String, path: String, name: String, repositoryName: String
    public let isDirectory: Bool, deleted: Bool
    public var id: String { repo + ":" + path }
    enum CodingKeys: String, CodingKey {
        case repo = "repo_id", path, name = "obj_name", repositoryName = "repo_name"
        case isDirectory = "is_dir", deleted
    }
}

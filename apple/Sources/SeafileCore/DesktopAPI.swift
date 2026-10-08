import Foundation

public struct FileSearchPage: Decodable, Sendable {
    public let results: [FileSearchItem]
    public let has_more: Bool
}
public struct FileSearchItem: Decodable, Identifiable, Sendable {
    public let repo_id: String, name: String, fullpath: String
    public let is_dir: Bool
    public var id: String { repo_id + ":" + fullpath }
}
public struct ActivityPage: Decodable, Sendable { public let events: [RemoteActivity] }
public struct RemoteActivity: Decodable, Identifiable, Sendable {
    public let repo_id: String, repo_name: String, op_type: String, time: String
    public let author_name: String?, commit_id: String?, path: String?, name: String?, obj_type: String?
    public var id: String { [repo_id, time, commit_id ?? "", op_type, path ?? "", name ?? ""].joined(separator: ":") }
}
public struct SharingDirectory: Decodable, Sendable {
    public struct Group: Decodable, Identifiable, Sendable { public let id: Int, name: String }
    public struct User: Decodable, Identifiable, Sendable { public let email: String; public let name: String?; public var id: String { email } }
    public let groups: [Group], contacts: [User]
}
public struct PrivateShare: Decodable, Identifiable, Sendable {
    public struct User: Decodable, Sendable { public let name: String, nickname: String? }
    public struct Group: Decodable, Sendable { public let id: Int, name: String }
    public let share_type: String, permission: String
    public let user_info: User?, group_info: Group?
    public var id: String { share_type + ":" + (user_info?.name ?? String(group_info?.id ?? 0)) }
    public var name: String { user_info?.nickname ?? user_info?.name ?? group_info?.name ?? id }
}

extension SeafileAPI {
    public func search(_ query: String, repo: String? = nil, page: Int = 1) async throws -> FileSearchPage {
        var items: [URLQueryItem] = [.init(name: "q", value: query), .init(name: "page", value: String(page)), .init(name: "per_page", value: "50")]
        if let repo { items.append(.init(name: "search_repo", value: repo)) }
        return try JSONDecoder().decode(FileSearchPage.self, from: await request("api2/search/", query: items))
    }
    public func activities(page: Int = 1) async throws -> [RemoteActivity] {
        try JSONDecoder().decode(ActivityPage.self, from: await request("api/v2.1/activities/", query: [.init(name: "page", value: String(page))])).events
    }
    public func createRepository(name: String, description: String, encryption: [String: String] = [:]) async throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SeafileError.unsafeFilename }
        var fields = encryption
        fields["name"] = name; fields["desc"] = description
        struct Reply: Decodable { let repo_id: String }
        return try JSONDecoder().decode(Reply.self, from: await request("api2/repos/", method: "POST", form: fields)).repo_id
    }
    public func subfolderRepository(repo: String, path: String, name: String, password: String = "") async throws -> String {
        var query: [URLQueryItem] = [.init(name: "p", value: path), .init(name: "name", value: name)]
        if !password.isEmpty { query.append(.init(name: "password", value: password)) }
        struct Reply: Decodable { let repo_id: String }
        return try JSONDecoder().decode(Reply.self, from: await request("api2/repos/\(repo)/dir/sub_repo/", query: query)).repo_id
    }
    public func leaveSharedRepository(repo: String, owner: String) async throws {
        _ = try await request("api2/beshared-repos/\(repo)/", method: "DELETE", query: [.init(name: "share_type", value: "personal"), .init(name: "from", value: owner)])
    }
    public func sharingDirectory() async throws -> SharingDirectory {
        try JSONDecoder().decode(SharingDirectory.self, from: await request("api2/groupandcontacts/"))
    }
    public func privateShares(repo: String, path: String) async throws -> [PrivateShare] {
        try JSONDecoder().decode([PrivateShare].self, from: await request("api2/repos/\(repo)/dir/shared_items/", query: [.init(name: "p", value: path)]))
    }
    public func setPrivateShare(repo: String, path: String, user: String? = nil, group: Int? = nil, permission: String = "rw", operation: String = "add") async throws {
        var fields = ["share_type": group == nil ? "user" : "group", "permission": permission]
        if let user { fields["username"] = user }
        if let group { fields["group_id"] = String(group) }
        let method = operation == "remove" ? "DELETE" : operation == "update" ? "POST" : "PUT"
        let query = [.init(name: "p", value: path)] + (method == "DELETE" ? fields.map { URLQueryItem(name: $0.key, value: $0.value) } : [])
        _ = try await request("api2/repos/\(repo)/dir/shared_items/", method: method, query: query, form: method == "DELETE" ? nil : fields)
    }
    public func uploadLink(repo: String, path: String, password: String = "") async throws -> URL {
        var fields = ["repo_id": repo, "path": path]
        if !password.isEmpty { fields["password"] = password }
        struct Reply: Decodable { let link: String }
        let reply = try JSONDecoder().decode(Reply.self, from: await request("api/v2.1/upload-links/", method: "POST", form: fields))
        guard let result = URL(string: reply.link, relativeTo: endpoint.url)?.absoluteURL, endpoint.isSameOrigin(result) else { throw SeafileError.invalidResponse }
        return result
    }
    public func internalLink(repo: String, path: String, directory: Bool) async throws -> URL {
        struct Reply: Decodable { let smart_link: String }
        let reply = try JSONDecoder().decode(Reply.self, from: await request("api/v2.1/smart-link/", query: [.init(name: "repo_id", value: repo), .init(name: "path", value: path), .init(name: "is_dir", value: directory ? "true" : "false")]))
        guard let result = URL(string: reply.smart_link, relativeTo: endpoint.url)?.absoluteURL, endpoint.isSameOrigin(result) else { throw SeafileError.invalidResponse }
        return result
    }
    public func lock(repo: String, path: String, locked: Bool) async throws {
        _ = try await request("api2/repos/\(repo)/file/", method: "PUT", form: ["p": path, "operation": locked ? "lock" : "unlock"])
    }
    public func copyMove(repo: String, parent: String, entry: DirectoryEntry, destinationRepo: String, destinationPath: String, move: Bool) async throws {
        struct TaskReply: Decodable { let task_id: String }
        let task = try JSONDecoder().decode(TaskReply.self, from: await request("api/v2.1/copy-move-task/", method: "POST", form: [
            "src_repo_id": repo, "src_parent_dir": parent, "src_dirent_name": entry.name,
            "dst_repo_id": destinationRepo, "dst_parent_dir": destinationPath,
            "operation": move ? "move" : "copy", "dirent_type": entry.isDirectory ? "dir" : "file"]))
        struct Progress: Decodable { let successful: Bool, failed: Bool, canceled: Bool }
        for _ in 0..<300 {
            try Task.checkCancellation()
            let progress = try JSONDecoder().decode(Progress.self, from: await request("api/v2.1/query-copy-move-progress/", query: [.init(name: "task_id", value: task.task_id)]))
            if progress.successful { return }
            if progress.failed || progress.canceled { throw SeafileError.local("The server could not complete the copy or move.") }
            try await Task.sleep(for: .seconds(1))
        }
        throw SeafileError.local("The operation is still running on the server. Refresh the destination folder to check it.")
    }
    public func authenticatedWebURL(next path: String) async throws -> URL {
        struct Token: Decodable { let token: String }
        let reply = try JSONDecoder().decode(Token.self, from: await request("api2/client-login/", method: "POST"))
        return try endpoint.api("client-login/", query: [.init(name: "token", value: reply.token), .init(name: "next", value: path)])
    }
}

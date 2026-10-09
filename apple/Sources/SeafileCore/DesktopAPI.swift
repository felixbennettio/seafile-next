import Foundation

public struct RemoteFileDetails: Decodable, Sendable {
    public let name: String, type: String
    public let size: Int64
}

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
    /// Per-file metadata avoids repeatedly downloading a large backup folder.
    /// Only a genuine 404 is treated as absence; permission/network errors stay visible.
    public func fileDetails(repo: String, path: String) async throws -> RemoteFileDetails? {
        guard try RemoteDirectoryPath.canonical(path) == path, path != "/" else { throw SeafileError.unsafeFilename }
        do {
            let entry = try JSONDecoder().decode(RemoteFileDetails.self, from: await request("api2/repos/\(repo)/file/detail/", query: [.init(name: "p", value: path)]))
            guard entry.name == (path as NSString).lastPathComponent, entry.type == "file", entry.size >= 0 else { throw SeafileError.invalidResponse }
            return entry
        } catch SeafileError.server(404, _) { return nil }
    }
    /// Community servers search names within a library. The global search
    /// endpoint requires a Pro server with file-search enabled.
    public func searchInLibrary(_ query: String, repo: String) async throws -> FileSearchPage {
        struct Reply: Decodable {
            struct Item: Decodable { let path: String, type: String }
            let data: [Item]
        }
        let reply = try JSONDecoder().decode(Reply.self, from: await request("api/v2.1/search-file/", query: [
            .init(name: "repo_id", value: repo), .init(name: "q", value: query)]))
        let results = try reply.data.map { item in
            let components = item.path.split(separator: "/")
            guard item.path.hasPrefix("/"), !components.isEmpty,
                  !components.contains("."), !components.contains(".."), !item.path.contains("\0"),
                  ["file", "folder"].contains(item.type) else { throw SeafileError.invalidResponse }
            return FileSearchItem(repo_id: repo, name: String(components.last!), fullpath: item.path, is_dir: item.type == "folder")
        }
        return FileSearchPage(results: results, has_more: false)
    }
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
    public func deleteRepository(repo: String) async throws {
        _ = try await request("api2/repos/\(repo)/", method: "DELETE")
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
        let query: [URLQueryItem] = [.init(name: "p", value: path)] + (method != "PUT" ? fields.map { URLQueryItem(name: $0.key, value: $0.value) } : [])
        let reply = try await request("api2/repos/\(repo)/dir/shared_items/", method: method, query: query, form: method == "DELETE" ? nil : fields)
        if operation == "add" {
            struct Result: Decodable { struct Failure: Decodable { let error_msg: String }; let failed: [Failure] }
            let result = try JSONDecoder().decode(Result.self, from: reply)
            if let failure = result.failed.first { throw SeafileError.local(failure.error_msg) }
        }
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
        struct TaskReply: Decodable { let task_id: String? }
        let data = try await request("api/v2.1/copy-move-task/", method: "POST", form: [
            "src_repo_id": repo, "src_parent_dir": parent, "src_dirent_name": entry.name,
            "dst_repo_id": destinationRepo, "dst_parent_dir": destinationPath,
            "operation": move ? "move" : "copy", "dirent_type": entry.isDirectory ? "dir" : "file"])
        let task = try JSONDecoder().decode(TaskReply.self, from: data)
        // The original server returns {} when the operation finishes inline.
        // Only background operations have a task_id to poll.
        guard let taskID = task.task_id else {
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result.isEmpty else { throw SeafileError.invalidResponse }
            return
        }
        guard !taskID.isEmpty else { throw SeafileError.invalidResponse }
        struct Progress: Decodable { let successful: Bool, failed: Bool, canceled: Bool }
        for _ in 0..<300 {
            try Task.checkCancellation()
            let progress = try JSONDecoder().decode(Progress.self, from: await request("api/v2.1/query-copy-move-progress/", query: [.init(name: "task_id", value: taskID)]))
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

public struct CommitChanges: Decodable, Sendable {
    public let added_files: [String]?, deleted_files: [String]?, modified_files: [String]?
    public let added_dirs: [String]?, deleted_dirs: [String]?, renamed_files: [String]?
    public var items: [(String, String)] {
        var result: [(String, String)] = []
        for (kind, paths) in [("Added", added_files), ("Deleted", deleted_files), ("Modified", modified_files), ("New folder", added_dirs), ("Deleted folder", deleted_dirs)] {
            result += (paths ?? []).map { (kind, $0) }
        }
        let renamed = renamed_files ?? []
        for i in stride(from: 0, to: renamed.count - (renamed.count % 2), by: 2) { result.append(("Renamed", renamed[i] + " → " + renamed[i + 1])) }
        return result
    }
}

extension SeafileAPI {
    public func commitChanges(repo: String, commit: String) async throws -> CommitChanges {
        try JSONDecoder().decode(CommitChanges.self, from: await request("api2/repo_history_changes/\(repo)/", query: [.init(name: "commit_id", value: commit)]))
    }
    public func defaultRepository(create: Bool = false) async throws -> String? {
        struct Reply: Decodable { let exists: Bool?; let repo_id: String? }
        let reply = try JSONDecoder().decode(Reply.self, from: await request("api2/default-repo/", method: create ? "POST" : "GET"))
        return reply.exists == false ? nil : reply.repo_id
    }
    public func logoutDevice() async throws { _ = try await request("api2/logout-device/", method: "POST") }

    /// Folders use the same mkdir/file-transfer API as the original client.
    /// Do not follow symlinks outside the folder the user selected.
    public func uploadTree(repo: String, directory: String, item: URL, replace: Bool = false) async throws {
        let properties = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard properties.isSymbolicLink != true else { throw SeafileError.local("Symbolic links cannot be uploaded as folders.") }
        try Task.checkCancellation()
        if properties.isDirectory == true {
            let name = item.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw SeafileError.unsafeFilename }
            let childPath = (directory.hasSuffix("/") ? directory : directory + "/") + name
            let current = try await self.directory(repo: repo, path: directory)
            if let existing = current.first(where: { $0.name == name }) {
                guard existing.isDirectory else { throw SeafileError.local("A file already uses the folder name \(name).") }
            } else { try await createDirectory(repo: repo, path: childPath) }
            for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) {
                try await uploadTree(repo: repo, directory: childPath, item: child, replace: replace)
            }
        } else if properties.isRegularFile == true { try await upload(repo: repo, directory: directory, file: item, replace: replace) }
        else { throw SeafileError.local("This item is not a regular file or folder.") }
    }
    public func downloadTree(repo: String, path: String, destination: URL, directory: Bool) async throws {
        try Task.checkCancellation()
        if directory {
            // Explicitly refuse a pre-existing symlink before writing children.
            let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { throw SeafileError.unsafeFilename }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for entry in try await self.directory(repo: repo, path: path) {
                try await downloadTree(repo: repo, path: entry.path(in: path), destination: destination.appendingPathComponent(entry.name), directory: entry.isDirectory)
            }
        } else {
            guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw SeafileError.unsafeFilename }
            try await download(repo: repo, path: path, destination: destination)
        }
    }
}

extension SeafileAPI {
    public func thumbnail(repo: String, path: String, size: Int = 96) async throws -> Data {
        let data = try await request("api2/repos/\(repo)/thumbnail/", query: [.init(name: "p", value: path), .init(name: "size", value: String(size))])
        guard data.count <= 2 * 1024 * 1024 else { throw SeafileError.invalidResponse }
        return data
    }
}

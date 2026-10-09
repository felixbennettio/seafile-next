import Foundation

public enum RemoteDirectoryPath {
    public static func canonical(_ value: String) throws -> String {
        let components = value.split(separator: "/")
        guard value.hasPrefix("/"), !value.contains("\0"), !components.contains("."), !components.contains("..") else { throw SeafileError.unsafeFilename }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
    public static func allowsDestination(sourceRepo: String, sourceParent: String, entries: [DirectoryEntry], destinationRepo: String, destinationPath: String) -> Bool {
        guard !entries.isEmpty, !destinationRepo.isEmpty,
              let parent = try? canonical(sourceParent), let target = try? canonical(destinationPath) else { return false }
        guard sourceRepo == destinationRepo else { return true }
        guard target != parent else { return false }
        return !entries.contains { entry in
            guard entry.isDirectory, let folder = try? canonical(entry.path(in: parent)) else { return false }
            return target == folder || target.hasPrefix(folder + "/")
        }
    }
}

public struct RecentDirectory: Codable, Identifiable, Sendable {
    public let accountID: UUID, repoID: String, path: String
    public let visited: Date
    public var id: String { repoID + ":" + path }
}

public actor RecentDirectoryStore {
    private struct Archive: Codable { let version: Int; let items: [RecentDirectory] }
    private let file: URL
    private var items: [RecentDirectory]
    public init(directory: URL) throws {
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SeafileError.unsafeFilename }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("recent-directories.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? 0) < 1_048_576 else { throw SeafileError.unsafeFilename }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard archive.version == 1, archive.items.allSatisfy({ !$0.repoID.isEmpty && (try? RemoteDirectoryPath.canonical($0.path)) == $0.path }) else { throw SeafileError.invalidResponse }
            items = archive.items
        } else { items = [] }
    }
    public func directories(for account: UUID) -> [RecentDirectory] {
        Array(items.filter { $0.accountID == account }.sorted { $0.visited > $1.visited }.prefix(20))
    }
    public func record(account: UUID, repo: String, path: String) throws {
        guard !repo.isEmpty else { throw SeafileError.invalidResponse }
        let path = try RemoteDirectoryPath.canonical(path)
        var updated = items.filter { $0.accountID != account || $0.repoID != repo || $0.path != path }
        updated.append(RecentDirectory(accountID: account, repoID: repo, path: path, visited: Date()))
        let newest = Set(updated.filter { $0.accountID == account }.sorted { $0.visited > $1.visited }.prefix(20).map(\.id))
        updated.removeAll { $0.accountID == account && !newest.contains($0.id) }
        try save(updated)
    }
    public func remove(account: UUID) throws { try save(items.filter { $0.accountID != account }) }
    private func save(_ updated: [RecentDirectory]) throws {
        if FileManager.default.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw SeafileError.unsafeFilename }
        try JSONEncoder().encode(Archive(version: 1, items: updated)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        items = updated
    }
}

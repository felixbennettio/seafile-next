import Foundation
import CryptoKit

public struct TextDraft: Codable, Identifiable, Sendable {
    public let version: Int
    public let accountID: UUID, repository: String, path: String
    public let baseline: Data
    public let byteOrderMark: Bool
    public var text: String
    public var modifiedAt: Date
    public var id: String { repository + ":" + path }
    public var data: Data { (byteOrderMark ? Data([0xef, 0xbb, 0xbf]) : Data()) + Data(text.utf8) }
    public var changed: Bool { data != baseline }
    public func remoteMatchesBaseline(_ data: Data) -> Bool { data == baseline }
    public func alreadyUploaded(_ remote: Data) -> Bool { remote == data }
}

/// Drafts live outside the preview cache. Clearing downloaded files must never
/// remove edits that have not reached the server.
@MainActor public final class TextDraftStore {
    public static let maximumBytes = 2 * 1024 * 1024
    private let root: URL
    public init(root: URL) throws {
        self.root = root
        try Self.directory(root)
    }
    public func load(account: UUID, repository: String, path: String) throws -> TextDraft? {
        let file = try location(account: account, repository: repository, path: path)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let draft = try read(file)
        guard draft.accountID == account, draft.repository == repository, draft.path == path else { throw SeafileError.invalidResponse }
        return draft
    }
    public func create(account: UUID, repository: String, path: String, data: Data) throws -> TextDraft {
        if let old = try load(account: account, repository: repository, path: path) { return old }
        guard data.count <= Self.maximumBytes, !data.contains(0) else { throw SeafileError.local("The editor supports UTF-8 text files up to 2 MB.") }
        let bom = data.starts(with: [0xef, 0xbb, 0xbf])
        guard let text = String(data: bom ? Data(data.dropFirst(3)) : data, encoding: .utf8) else { throw SeafileError.local("This file is not UTF-8 text. Open it in another editor through Files.") }
        let draft = TextDraft(version: 1, accountID: account, repository: repository, path: path, baseline: data, byteOrderMark: bom, text: text, modifiedAt: Date())
        try save(draft); return draft
    }
    public func save(_ draft: TextDraft) throws {
        try validate(draft)
        let file = try location(account: draft.accountID, repository: draft.repository, path: draft.path)
        if FileManager.default.fileExists(atPath: file.path) { _ = try read(file) }
        try JSONEncoder().encode(draft).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func drafts(account: UUID) throws -> [TextDraft] {
        let folder = root.appendingPathComponent(account.uuidString)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        try Self.directory(folder)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { file in
                let draft = try read(file)
                let expected = try location(account: account, repository: draft.repository, path: draft.path)
                guard draft.accountID == account, expected.standardizedFileURL.resolvingSymlinksInPath() == file.standardizedFileURL.resolvingSymlinksInPath() else { throw SeafileError.local("The text draft file name does not match its history.") }
                return draft
            }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    public func remove(_ draft: TextDraft) throws {
        let file = try location(account: draft.accountID, repository: draft.repository, path: draft.path)
        if FileManager.default.fileExists(atPath: file.path) { _ = try read(file); try FileManager.default.removeItem(at: file) }
    }
    public func clearUnedited(account: UUID) throws {
        let drafts = try drafts(account: account)
        guard !drafts.contains(where: \.changed) else { throw SeafileError.local("Upload, export or discard your text drafts before removing this account.") }
        for draft in drafts { try remove(draft) }
    }
    private func location(account: UUID, repository: String, path: String) throws -> URL {
        guard !repository.isEmpty, try RemoteDirectoryPath.canonical(path) == path, path != "/" else { throw SeafileError.unsafeFilename }
        let folder = root.appendingPathComponent(account.uuidString)
        try Self.directory(folder)
        let digest = SHA256.hash(data: Data((repository + "\0" + path).utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".json")
    }
    private func read(_ file: URL) throws -> TextDraft {
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw SeafileError.unsafeFilename }
        let draft = try JSONDecoder().decode(TextDraft.self, from: Data(contentsOf: file))
        try validate(draft); return draft
    }
    private func validate(_ draft: TextDraft) throws {
        guard draft.version == 1, draft.baseline.count <= Self.maximumBytes, draft.data.count <= Self.maximumBytes,
              String(data: draft.baseline, encoding: .utf8) != nil, !draft.baseline.contains(0), !draft.text.contains("\0") else { throw SeafileError.invalidResponse }
    }
    private static func directory(_ url: URL) throws {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SeafileError.unsafeFilename }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

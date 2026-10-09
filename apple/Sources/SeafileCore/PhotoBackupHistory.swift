import Foundation
import CryptoKit

public struct PhotoBackupSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var repository: String
    public var path: String
    public var wifiOnly = true
    public var includeVideos = false
    public var includeLivePhotoVideo = true
    /// Empty means all accessible assets, including the user's limited selection.
    public var albums: [String] = []
    public init(repository: String, path: String) { self.repository = repository; self.path = path }
}

public struct PhotoBackupRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: String, accountID: UUID, repository: String, path: String
    public let asset: String, revision: String, resource: String, filename: String, digest: String
    public let size: Int64
    public private(set) var transferID: UUID?
    public private(set) var completed = false
    public init(accountID: UUID, repository: String, path: String, asset: String, revision: String,
                resource: String, filename: String, digest: String, size: Int64) {
        self.accountID = accountID; self.repository = repository; self.path = path
        self.asset = asset; self.revision = revision; self.resource = resource; self.filename = filename
        self.digest = digest; self.size = size
        self.id = Self.key(accountID: accountID, repository: repository, path: path, asset: asset, revision: revision, resource: resource)
    }
    public static func key(accountID: UUID, repository: String, path: String, asset: String, revision: String, resource: String) -> String {
        PhotoBackupFiles.digest(Data([accountID.uuidString, repository, path, asset, revision, resource].joined(separator: "\0").utf8))
    }
    fileprivate func submitted(_ id: UUID) -> Self { var copy = self; copy.transferID = id; return copy }
    fileprivate func confirmed() -> Self { var copy = self; copy.completed = true; return copy }
}

public enum PhotoBackupFiles {
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Hash large video resources incrementally instead of loading them into RAM.
    public static func digest(file: URL) throws -> (hash: String, size: Int64) {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var hash = SHA256(), size: Int64 = 0
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data); size += Int64(data.count) }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
    public static func filename(original: String, asset: String, digest: String) throws -> String {
        try validateName(original)
        let ext = (original as NSString).pathExtension.lowercased()
        var stem = (original as NSString).deletingPathExtension
        // Asset and content fingerprints prevent two cameras' IMG_0001 files,
        // edited versions and paired Live Photo resources from overwriting.
        let suffix = "_" + Self.digest(Data(asset.utf8)).prefix(10) + "_" + digest.prefix(12)
        let ending = suffix + (ext.isEmpty ? "" : "." + String(ext.prefix(15)))
        while (stem + ending).utf8.count > 255 { stem.removeLast() }
        let name = stem + ending
        try validateName(name); return name
    }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, ![".", ".."].contains(name), !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }), name.utf8.count <= 255 else { throw SeafileError.unsafeFilename }
    }
}

/// Persist before submitting a write and after an acknowledged upload or
/// verification of an existing file's bytes. An
/// interrupted or failed submission is never blindly sent again by a scan.
@MainActor public final class PhotoBackupHistory {
    private struct History: Codable { var version = 1; var settings: [UUID: PhotoBackupSettings] = [:]; var records: [String: PhotoBackupRecord] = [:] }
    private let file: URL
    private var history: History
    public init(root: URL) throws {
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SeafileError.unsafeFilename }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = root.appendingPathComponent("photo-backup.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? 0) < 64 * 1024 * 1024 else { throw SeafileError.unsafeFilename }
            history = try JSONDecoder().decode(History.self, from: Data(contentsOf: file))
            try validate(history)
        } else { history = History() }
    }
    public func settings(account: UUID) -> PhotoBackupSettings? { history.settings[account] }
    public func configure(account: UUID, settings: PhotoBackupSettings) throws {
        var next = history; next.settings[account] = settings; try commit(next)
    }
    public func record(_ id: String) -> PhotoBackupRecord? { history.records[id] }
    public func records(account: UUID, settings: PhotoBackupSettings) -> [PhotoBackupRecord] {
        history.records.values.filter { $0.accountID == account && $0.repository == settings.repository && $0.path == settings.path }
    }
    public func prepare(_ record: PhotoBackupRecord) throws {
        if let existing = history.records[record.id] {
            guard existing.digest == record.digest, existing.filename == record.filename, existing.size == record.size else { throw SeafileError.local("This photo resource changed while it was being backed up. Its previous upload record is preserved.") }
            return
        }
        var next = history; next.records[record.id] = record; try commit(next)
    }
    public func submitted(_ id: String, transfer: UUID) throws {
        guard let record = history.records[id], !record.completed, record.transferID == nil else { throw SeafileError.invalidResponse }
        var next = history; next.records[id] = record.submitted(transfer); try commit(next)
    }
    public func confirm(_ id: String, digest: String, size: Int64) throws {
        guard let record = history.records[id], record.digest == digest, record.size == size else { throw SeafileError.local("The uploaded photo does not match its local resource.") }
        var next = history; next.records[id] = record.confirmed(); try commit(next)
    }
    public func remove(account: UUID) throws {
        guard history.settings[account]?.enabled != true else { throw SeafileError.local("Turn off photo backup before removing this account.") }
        var next = history; next.settings[account] = nil; next.records = next.records.filter { $0.value.accountID != account }; try commit(next)
    }
    private func commit(_ next: History) throws {
        try validate(next)
        if FileManager.default.fileExists(atPath: file.path) {
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SeafileError.unsafeFilename }
        }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        history = next
    }
    private func validate(_ value: History) throws {
        guard value.version == 1 else { throw SeafileError.invalidResponse }
        func destination(_ repo: String, _ path: String) throws {
            guard !repo.isEmpty, !repo.contains("\0"), try RemoteDirectoryPath.canonical(path) == path else { throw SeafileError.unsafeFilename }
        }
        for setting in value.settings.values { try destination(setting.repository, setting.path) }
        for (id, record) in value.records {
            try destination(record.repository, record.path); try PhotoBackupFiles.validateName(record.filename)
            guard record.id == id, id == PhotoBackupRecord.key(accountID: record.accountID, repository: record.repository, path: record.path,
                  asset: record.asset, revision: record.revision, resource: record.resource), record.size >= 0,
                  record.digest.count == 64, record.digest.allSatisfy({ $0.isHexDigit }),
                  ![record.asset, record.revision, record.resource].contains(where: { $0.isEmpty || $0.contains("\0") }) else { throw SeafileError.invalidResponse }
        }
    }
}

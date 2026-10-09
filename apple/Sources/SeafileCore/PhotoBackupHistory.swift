import Foundation
import CryptoKit
import SQLite3

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

/// Small durable transactions keep a large photo library from rewriting all
/// previous upload records for every resource. Uncertain writes stay pending.
@MainActor public final class PhotoBackupHistory {
    private let database: BackupDatabase
    private var configurations: [UUID: PhotoBackupSettings] = [:]
    private var counts: [String: Int] = [:]
    public init(root: URL) throws {
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SeafileError.unsafeFilename }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("photo-backup.sqlite")
        database = try BackupDatabase(file: file)
        for row in try database.query("SELECT account,payload FROM settings") {
            guard let account = UUID(uuidString: row[0]) else { throw SeafileError.invalidResponse }
            let setting = try JSONDecoder().decode(PhotoBackupSettings.self, from: Data(row[1].utf8))
            try destination(setting.repository, setting.path); configurations[account] = setting
        }
    }
    public func settings(account: UUID) -> PhotoBackupSettings? { configurations[account] }
    public func configure(account: UUID, settings: PhotoBackupSettings) throws {
        try destination(settings.repository, settings.path)
        try database.execute("INSERT OR REPLACE INTO settings(account,payload) VALUES(?,?)", [account.uuidString, try encode(settings)])
        configurations[account] = settings
    }
    public func record(_ id: String) throws -> PhotoBackupRecord? {
        guard let row = try database.query("SELECT payload FROM records WHERE id=?", [id]).first else { return nil }
        let record = try decode(row[0]); guard record.id == id else { throw SeafileError.invalidResponse }; return record
    }
    public func records(account: UUID, settings: PhotoBackupSettings) throws -> [PhotoBackupRecord] {
        try database.query("SELECT payload FROM records WHERE account=? AND repo=? AND path=?", [account.uuidString, settings.repository, settings.path]).map {
            let record = try decode($0[0]); guard record.accountID == account, record.repository == settings.repository, record.path == settings.path else { throw SeafileError.invalidResponse }; return record
        }
    }
    public func completedCount(account: UUID, settings: PhotoBackupSettings) throws -> Int {
        let key = [account.uuidString, settings.repository, settings.path].joined(separator: "\0")
        if let count = counts[key] { return count }
        let row = try database.query("SELECT COUNT(*) FROM records WHERE account=? AND repo=? AND path=? AND completed=1", [account.uuidString, settings.repository, settings.path]).first
        guard let text = row?.first, let count = Int(text) else { throw SeafileError.invalidResponse }; counts[key] = count; return count
    }
    public func prepare(_ value: PhotoBackupRecord) throws {
        if let existing = try record(value.id) {
            guard existing.digest == value.digest, existing.filename == value.filename, existing.size == value.size else { throw SeafileError.local("This photo resource changed while it was being backed up. Its previous upload record is preserved.") }; return
        }
        try write(value)
    }
    public func submitted(_ id: String, transfer: UUID) throws {
        guard let record = try record(id), !record.completed, record.transferID == nil else { throw SeafileError.invalidResponse }
        try write(record.submitted(transfer))
    }
    public func confirm(_ id: String, digest: String, size: Int64) throws {
        guard let record = try record(id), record.digest == digest, record.size == size else { throw SeafileError.local("The uploaded photo does not match its local resource.") }
        try write(record.confirmed())
        if !record.completed {
            let key = [record.accountID.uuidString, record.repository, record.path].joined(separator: "\0")
            if let count = counts[key] { counts[key] = count + 1 }
        }
    }
    public func remove(account: UUID) throws {
        guard configurations[account]?.enabled != true else { throw SeafileError.local("Turn off photo backup before removing this account.") }
        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.execute("DELETE FROM records WHERE account=?", [account.uuidString])
            try database.execute("DELETE FROM settings WHERE account=?", [account.uuidString])
            try database.execute("COMMIT")
        } catch { try? database.execute("ROLLBACK"); throw error }
        configurations[account] = nil; counts = counts.filter { !$0.key.hasPrefix(account.uuidString + "\0") }
    }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private func write(_ record: PhotoBackupRecord) throws {
        try validate(record)
        try database.execute("INSERT OR REPLACE INTO records(id,account,repo,path,completed,payload) VALUES(?,?,?,?,?,?)",
            [record.id, record.accountID.uuidString, record.repository, record.path, record.completed ? "1" : "0", try encode(record)])
    }
    private func decode(_ text: String) throws -> PhotoBackupRecord {
        let record = try JSONDecoder().decode(PhotoBackupRecord.self, from: Data(text.utf8)); try validate(record); return record
    }
    private func destination(_ repo: String, _ path: String) throws {
        guard !repo.isEmpty, !repo.contains("\0"), try RemoteDirectoryPath.canonical(path) == path else { throw SeafileError.unsafeFilename }
    }
    private func validate(_ record: PhotoBackupRecord) throws {
        try destination(record.repository, record.path); try PhotoBackupFiles.validateName(record.filename)
        guard record.id == PhotoBackupRecord.key(accountID: record.accountID, repository: record.repository, path: record.path,
              asset: record.asset, revision: record.revision, resource: record.resource), record.size >= 0,
              record.digest.utf8.count == 64, record.digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              ![record.asset, record.revision, record.resource].contains(where: { $0.isEmpty || $0.contains("\0") }) else { throw SeafileError.invalidResponse }
    }
}

// Owned exclusively by the MainActor history. Its nonisolated destructor can
// close the C connection without accessing actor-isolated state.
private final class BackupDatabase {
    private var handle: OpaquePointer?
    private let file: URL
    private var inode: UInt64?
    init(file: URL) throws {
        self.file = file; try checkFiles()
        let exists = FileManager.default.fileExists(atPath: file.path)
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle); handle = nil; throw SeafileError.local("The photo backup database could not be opened.")
        }
        do {
            sqlite3_busy_timeout(handle, 3_000)
            if exists {
                guard try query("PRAGMA quick_check").first?.first == "ok", try query("PRAGMA user_version").first?.first == "1" else { throw SeafileError.local("The photo backup history is damaged or from another version. It is preserved.") }
            }
            try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL")
            if !exists {
                try execute("BEGIN IMMEDIATE")
                try execute("CREATE TABLE settings(account TEXT PRIMARY KEY,payload TEXT NOT NULL)")
                try execute("CREATE TABLE records(id TEXT PRIMARY KEY,account TEXT NOT NULL,repo TEXT NOT NULL,path TEXT NOT NULL,completed INTEGER NOT NULL,payload TEXT NOT NULL)")
                try execute("CREATE INDEX record_target ON records(account,repo,path,completed)")
                try execute("PRAGMA user_version=1"); try execute("COMMIT")
            }
            try permissions()
            inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? UInt64
            guard inode != nil else { throw SeafileError.unsafeFilename }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    private func checkFiles() throws {
        for name in [file.path, file.path + "-wal", file.path + "-shm"] {
            guard (try? URL(fileURLWithPath: name).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SeafileError.unsafeFilename }
        }
        if let inode {
            guard try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? UInt64 == inode else {
                throw SeafileError.local("The photo backup database was replaced. Its files are preserved.")
            }
            let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
            guard try reader.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else {
                throw SeafileError.local("The photo backup database is damaged. Its files are preserved.")
            }
        }
    }
    private func permissions() throws {
        for name in [file.path, file.path + "-wal", file.path + "-shm"] where FileManager.default.fileExists(atPath: name) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: name)
        }
    }
    func execute(_ sql: String, _ values: [String] = []) throws { _ = try query(sql, values); try permissions() }
    func query(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        try checkFiles()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw SeafileError.local("The photo backup database could not read or save a record. Its files are preserved.") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw SeafileError.invalidResponse }
        }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw SeafileError.local("The photo backup database could not read or save a record. Its files are preserved.") }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }
}

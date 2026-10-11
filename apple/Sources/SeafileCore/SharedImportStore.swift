import Foundation
import Darwin

public struct SharedImport: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, sending, uncertain, completed }
    public struct File: Codable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let bytes: Int64
        public internal(set) var state: State
    }
    public let id: UUID
    public let created: Date
    public internal(set) var accountID: UUID?
    public internal(set) var repository: String?
    public internal(set) var directory: String?
    public internal(set) var files: [File]
    public var completed: Bool { !files.isEmpty && files.allSatisfy { $0.state == .completed } }
}

/// Each share has its own manifest and an OS-released upload lease. The host
/// and extension can never replay a running upload or overwrite each other's
/// manifests. Tokens, server URLs and response bodies are not persisted here.
public final class SharedImportStore: @unchecked Sendable {
    public static let group = "group.io.felixbennett.seafile"
    private let root: URL
    private let lock = NSLock()
    public init(root: URL) throws { self.root = root; try Self.privateDirectory(root) }
    public static func shared() throws -> SharedImportStore {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw SeafileError.local("The shared import folder is unavailable. Open seafile-next and try again.")
        }
        return try SharedImportStore(root: group.appendingPathComponent("SharedImports", isDirectory: true))
    }

    public final class Lease: @unchecked Sendable {
        fileprivate let descriptor: Int32
        fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    }
    private func acquire(_ id: UUID, name: String, wait: Bool) throws -> Lease {
        let attributes = try folder(id).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw SeafileError.invalidResponse }
        let location = folder(id).appendingPathComponent(name)
        let descriptor = open(location.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SeafileError.local("Could not lock the preserved share.") }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            close(descriptor); throw SeafileError.local("This share is still being uploaded. Wait for it to finish.")
        }
        return Lease(descriptor)
    }
    public func uploadLease(_ id: UUID) throws -> Lease { try acquire(id, name: "upload.lock", wait: false) }
    public func verificationURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(UUID().uuidString + ".verify") }
    private func locked<T>(_ id: UUID, _ work: () throws -> T) throws -> T {
        try lock.withLock {
            let lease = try acquire(id, name: "manifest.lock", wait: true)
            defer { withExtendedLifetime(lease) {} }
            return try work()
        }
    }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifest(_ id: UUID) -> URL { folder(id).appendingPathComponent("share.json") }
    private func read(_ id: UUID) throws -> SharedImport {
        let attributes = try manifest(id).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw SeafileError.invalidResponse }
        let value = try JSONDecoder().decode(SharedImport.self, from: Data(contentsOf: manifest(id)))
        guard value.id == id, Set(value.files.map(\.id)).count == value.files.count else { throw SeafileError.invalidResponse }
        for file in value.files { try Self.validateName(file.name); guard file.bytes >= 0 else { throw SeafileError.invalidResponse } }
        if let directory = value.directory { try Self.validateDirectory(directory) }
        return value
    }
    private func save(_ value: SharedImport) throws {
        try JSONEncoder().encode(value).write(to: manifest(value.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest(value.id).path)
    }
    public func create() throws -> UUID {
        let id = UUID(), preparing = root.appendingPathComponent(".preparing-" + id.uuidString)
        try Self.privateDirectory(preparing)
        do {
            let file = preparing.appendingPathComponent("share.json")
            try JSONEncoder().encode(SharedImport(id: id, created: Date(), files: [])).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try FileManager.default.moveItem(at: preparing, to: folder(id)); return id
        } catch { try? FileManager.default.removeItem(at: preparing); throw error }
    }
    public func snapshot(_ id: UUID) throws -> SharedImport { try locked(id) { try read(id) } }
    public func list() throws -> [SharedImport] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SeafileError.invalidResponse }
            return try snapshot(id)
        }.sorted { $0.created > $1.created }
    }
    /// Copy inside the NSItemProvider callback, before its temporary URL expires.
    @discardableResult public func addFile(_ source: URL, name: String, to id: UUID) throws -> SharedImport.File {
        try Self.validateName(name)
        let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw SeafileError.local("Share individual files rather than folders or symbolic links.") }
        return try locked(id) {
            var value = try read(id)
            guard value.accountID == nil else { throw SeafileError.local("This share has already been submitted.") }
            let fileID = UUID(), directory = folder(id).appendingPathComponent(fileID.uuidString, isDirectory: true)
            try Self.privateDirectory(directory)
            let destination = directory.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let bytes = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                let file = SharedImport.File(id: fileID, name: name, bytes: bytes, state: .prepared)
                value.files.append(file); try save(value); return file
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
    }
    @discardableResult public func addData(_ data: Data, name: String, to id: UUID) throws -> SharedImport.File {
        try Self.validateName(name)
        guard data.count <= 4 * 1024 * 1024 else { throw SeafileError.local("Share large content as a file instead of text.") }
        let temporary = folder(id).appendingPathComponent(UUID().uuidString + ".input")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try addFile(temporary, name: name, to: id)
    }
    public func assign(_ id: UUID, accountID: UUID, repository: String, directory: String) throws {
        try Self.validateDirectory(directory)
        guard !repository.isEmpty, !repository.contains("/"), !repository.contains("..") else { throw SeafileError.invalidResponse }
        try locked(id) {
            var value = try read(id)
            guard !value.files.isEmpty, value.accountID == nil else { throw SeafileError.local("Select files before saving this share.") }
            value.accountID = accountID; value.repository = repository; value.directory = directory; try save(value)
        }
    }
    public func setState(_ state: SharedImport.State, fileID: UUID, in id: UUID) throws {
        try locked(id) {
            var value = try read(id)
            guard let index = value.files.firstIndex(where: { $0.id == fileID }) else { throw SeafileError.invalidResponse }
            value.files[index].state = state; try save(value)
            if state == .completed { try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(fileID.uuidString)) }
        }
    }
    public func fileURL(_ file: SharedImport.File, in id: UUID) throws -> URL {
        try Self.validateName(file.name)
        let directory = folder(id).appendingPathComponent(file.id.uuidString)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SeafileError.invalidResponse }
        let url = directory.appendingPathComponent(file.name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SeafileError.invalidResponse }
        return url
    }
    public func remove(_ id: UUID) throws {
        let lease = try uploadLease(id)
        defer { withExtendedLifetime(lease) {} }
        try locked(id) { try FileManager.default.removeItem(at: folder(id)) }
    }
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SeafileError.unsafeFilename }
    }
    private static func validateDirectory(_ path: String) throws {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw SeafileError.invalidResponse }
    }
    private static func privateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SeafileError.invalidResponse }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public enum SharedAppSecurity {
    public static var defaults: UserDefaults? { UserDefaults(suiteName: SharedImportStore.group) }
    // Before the upgraded host first opens, its legacy app-lock preference
    // has not been mirrored. Require authentication rather than bypass it.
    public static var requiresAuthentication: Bool { defaults?.object(forKey: "appLockEnabled") as? Bool ?? true }
    public static func setAuthenticationRequired(_ enabled: Bool) { defaults?.set(enabled, forKey: "appLockEnabled") }
}

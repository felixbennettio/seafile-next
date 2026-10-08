import Foundation
import Observation

public struct FileTransfer: Codable, Identifiable, Sendable {
    public enum Direction: String, Codable, Sendable { case upload, download }
    public enum State: String, Codable, Sendable { case queued, running, cancelling, completed, failed, cancelled }
    public let id: UUID
    public let accountID: UUID
    public let repository: String
    /// Upload parent directory, or download file/directory path.
    public let path: String
    public let name: String
    public let direction: Direction
    public let directory: Bool
    public let replace: Bool
    public let created: Date
    public internal(set) var state: State = .queued
    public internal(set) var bytes: Int64 = 0
    public internal(set) var expectedBytes: Int64 = 0
    public internal(set) var error: String?
    public var active: Bool { state == .queued || state == .running || state == .cancelling }
}

/// Owns transfers independently of browser views. Upload inputs are copied into
/// private storage before enqueueing; no expiring links or credentials are saved.
@MainActor @Observable
public final class FileTransferQueue {
    public typealias ClientFactory = @MainActor (UUID, @escaping @Sendable (Int64, Int64) -> Void) throws -> SeafileAPI
    public private(set) var transfers: [FileTransfer] = []
    public private(set) var revision = 0
    public private(set) var persistenceError: String?
    public private(set) var preparingUploads = 0
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private var clientFactory: ClientFactory?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiters: [UUID: [(Result<URL, Error>) -> Void]] = [:]
    @ObservationIgnored private var progressTime: [UUID: Date] = [:]
    @ObservationIgnored private var preparingAccounts: [UUID: Int] = [:]

    /// Disable transfers when storage cannot be read. Never overwrite an
    /// unreadable history or create new uploads without recoverable metadata.
    public init(unavailableRoot: URL, error: String) { root = unavailableRoot; persistent = true; persistenceError = error }

    public init(root: URL, persistent: Bool = true) throws {
        self.root = root; self.persistent = persistent
        try Self.privateDirectory(root)
        if persistent, FileManager.default.fileExists(atPath: manifest.path) {
            transfers = try JSONDecoder().decode([FileTransfer].self, from: Data(contentsOf: manifest))
            guard Set(transfers.map(\.id)).count == transfers.count else { throw SeafileError.local("The transfer history contains duplicate items.") }
            for index in transfers.indices {
                try Self.validateName(transfers[index].name)
                if transfers[index].state == .running || transfers[index].state == .cancelling {
                    // A server may already have accepted an interrupted upload.
                    // Never replay it automatically after a process restart.
                    if transfers[index].direction == .upload {
                        transfers[index].state = .failed
                        transfers[index].error = "The app closed during this upload. Check the server before retrying. Your local copy is preserved."
                    } else { transfers[index].state = .queued }
                }
            }
            try save()
        }
    }

    public func start(clientFactory: @escaping ClientFactory) {
        self.clientFactory = clientFactory
        pump()
    }

    public func hasPendingUploads(accountID: UUID) -> Bool {
        (preparingAccounts[accountID] ?? 0) > 0 || transfers.contains { $0.accountID == accountID && $0.direction == .upload && $0.state != .completed }
    }

    public func hasActiveTransfers(accountID: UUID) -> Bool { (preparingAccounts[accountID] ?? 0) > 0 || transfers.contains { $0.accountID == accountID && $0.active } }

    @discardableResult public func enqueueUpload(accountID: UUID, repository: String, parent: String, source: URL, name: String? = nil, replace: Bool = false) async throws -> UUID {
        try requireStorage()
        preparingUploads += 1; preparingAccounts[accountID, default: 0] += 1
        defer { preparingUploads -= 1; preparingAccounts[accountID, default: 0] -= 1 }
        let name = name ?? source.lastPathComponent
        try Self.validateName(name)
        let id = UUID(), folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let staged = folder.appendingPathComponent(name)
        let directory: Bool
        do {
            directory = try await Task.detached(priority: .utility) {
                try Self.privateDirectory(folder)
                return try Self.copyPrivateTree(source, to: staged)
            }.value
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
        let transfer = FileTransfer(id: id, accountID: accountID, repository: repository, path: parent, name: name,
            direction: .upload, directory: directory, replace: replace, created: Date())
        transfers.append(transfer)
        do { try save() } catch { transfers.removeAll { $0.id == id }; try? FileManager.default.removeItem(at: folder); throw error }
        pump()
        return id
    }

    @discardableResult public func enqueueDownload(accountID: UUID, repository: String, path: String, directory: Bool = false) throws -> UUID {
        try requireStorage()
        if let existing = transfers.first(where: { $0.accountID == accountID && $0.repository == repository && $0.path == path && $0.direction == .download && $0.active }) { return existing.id }
        let name = (path as NSString).lastPathComponent
        try Self.validateName(name)
        let transfer = FileTransfer(id: UUID(), accountID: accountID, repository: repository, path: path, name: name,
            direction: .download, directory: directory, replace: false, created: Date())
        transfers.append(transfer)
        do { try save() } catch { transfers.removeAll { $0.id == transfer.id }; throw error }
        pump()
        return transfer.id
    }

    public func result(for id: UUID) async throws -> URL {
        guard let transfer = transfers.first(where: { $0.id == id }) else { throw SeafileError.local("This transfer is no longer available.") }
        if transfer.state == .completed { return itemURL(transfer) }
        if transfer.state == .failed || transfer.state == .cancelled { throw SeafileError.local(transfer.error ?? "Transfer cancelled.") }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id, default: []].append { continuation.resume(with: $0) }
        }
    }

    public func localCopy(of transfer: FileTransfer) -> URL? {
        let item = itemURL(transfer)
        return FileManager.default.fileExists(atPath: item.path) ? item : nil
    }

    public func cachedDownload(accountID: UUID, repository: String, path: String) -> URL? {
        for transfer in transfers.reversed() where transfer.accountID == accountID && transfer.repository == repository && transfer.path == path && transfer.direction == .download && transfer.state == .completed {
            if let url = localCopy(of: transfer) { return url }
        }
        return nil
    }

    public func retry(_ id: UUID) throws {
        try requireStorage()
        guard let index = transfers.firstIndex(where: { $0.id == id }), !transfers[index].active else { return }
        guard transfers[index].state != .completed else { return }
        if transfers[index].direction == .upload, localCopy(of: transfers[index]) == nil { throw SeafileError.local("The preserved upload file is missing. Import it again.") }
        transfers[index].state = .queued; transfers[index].error = nil; transfers[index].bytes = 0
        try save(); pump()
    }

    public func cancel(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].active else { return }
        if let task = tasks[id] {
            transfers[index].state = .cancelling; task.cancel()
        } else {
            transfers[index].state = .cancelled
            transfers[index].error = "Transfer cancelled."
            finishWaiters(id, result: .failure(CancellationError()))
        }
        persistOrReport()
    }

    public func remove(_ id: UUID) throws {
        try requireStorage()
        guard let transfer = transfers.first(where: { $0.id == id }), !transfer.active else { return }
        let previous = transfers
        transfers.removeAll { $0.id == id }
        do { try save() } catch { transfers = previous; throw error }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }

    private func pump() {
        guard let clientFactory, persistenceError == nil else { return }
        while tasks.count < 2, let index = transfers.firstIndex(where: { $0.state == .queued }) {
            let id = transfers[index].id
            transfers[index].state = .running
            do { try save() } catch { persistenceError = error.localizedDescription; return }
            let transfer = transfers[index], destination = itemURL(transfer)
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                let result: Result<URL, Error>
                do {
                    let api = try clientFactory(transfer.accountID) { [weak self] done, total in
                        Task { @MainActor in self?.progress(id, done: done, total: total) }
                    }
                    try Task.checkCancellation()
                    if transfer.direction == .upload {
                        try await api.uploadTree(repo: transfer.repository, directory: transfer.path, item: destination, replace: transfer.replace)
                    } else {
                        try Self.privateDirectory(destination.deletingLastPathComponent())
                        try await api.downloadTree(repo: transfer.repository, path: transfer.path, destination: destination, directory: transfer.directory)
                        try FileManager.default.setAttributes([.posixPermissions: transfer.directory ? 0o700 : 0o600], ofItemAtPath: destination.path)
                    }
                    result = .success(destination)
                } catch { result = .failure(error) }
                self.finish(id, result: result)
            }
        }
    }

    private func progress(_ id: UUID, done: Int64, total: Int64) {
        let now = Date()
        if done != total, let previous = progressTime[id], now.timeIntervalSince(previous) < 0.2 { return }
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].active else { return }
        progressTime[id] = now
        transfers[index].bytes = max(0, done); transfers[index].expectedBytes = max(0, total)
    }

    private func finish(_ id: UUID, result: Result<URL, Error>) {
        tasks[id] = nil; progressTime[id] = nil
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success:
            transfers[index].state = .completed; transfers[index].error = nil
        case .failure(let error):
            transfers[index].state = error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
            transfers[index].error = transfers[index].state == .cancelled ? "Transfer cancelled. Check the server before retrying an upload." : error.localizedDescription
        }
        revision += 1
        persistOrReport()
        if case .success = result, transfers[index].direction == .upload, persistenceError == nil {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
        }
        finishWaiters(id, result: result)
        pump()
    }

    private func finishWaiters(_ id: UUID, result: Result<URL, Error>) { waiters.removeValue(forKey: id)?.forEach { $0(result) } }
    private func itemURL(_ transfer: FileTransfer) -> URL { root.appendingPathComponent(transfer.id.uuidString).appendingPathComponent(transfer.name) }
    private func requireStorage() throws { if let persistenceError { throw SeafileError.local("Transfer storage is unavailable. Your existing local files are preserved. \(persistenceError)") } }
    private var manifest: URL { root.appendingPathComponent("transfers.json") }
    private func persistOrReport() { do { try save() } catch { persistenceError = error.localizedDescription } }
    private func save() throws {
        guard persistent else { return }
        try JSONEncoder().encode(transfers).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    nonisolated private static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    nonisolated private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), !name.contains("\r"), !name.contains("\n") else { throw SeafileError.unsafeFilename }
    }
    nonisolated private static func copyPrivateTree(_ source: URL, to destination: URL) throws -> Bool {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw SeafileError.local("Symbolic links cannot be uploaded as files.") }
        if values.isDirectory == true {
            try privateDirectory(destination)
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try validateName(child.lastPathComponent)
                _ = try copyPrivateTree(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
            return true
        }
        guard values.isRegularFile == true else { throw SeafileError.local("This item is not a regular file or folder.") }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return false
    }
}

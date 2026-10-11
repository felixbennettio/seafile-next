import Foundation

@MainActor public enum SharedImportUploader {
    /// Confirm a lost response by comparing bytes, never by filename alone.
    public static func verify(_ fileID: UUID, in id: UUID, store: SharedImportStore, client: SeafileAPI) async throws -> Bool {
        let lease = try store.uploadLease(id)
        defer { withExtendedLifetime(lease) {} }
        let share = try store.snapshot(id)
        guard let file = share.files.first(where: { $0.id == fileID }), let repository = share.repository, let directory = share.directory,
              file.state == .sending || file.state == .uncertain else { throw SeafileError.invalidResponse }
        let path = (directory.hasSuffix("/") ? directory : directory + "/") + file.name
        guard let details = try await client.fileDetails(repo: repository, path: path), details.size == file.bytes else { return false }
        let input = try store.fileURL(file, in: id), downloaded = store.verificationURL(id)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await client.download(repo: repository, path: path, destination: downloaded)
        let identical = try await Task.detached(priority: .utility) {
            let local = try PhotoBackupFiles.digest(file: input), remote = try PhotoBackupFiles.digest(file: downloaded)
            return local.size == remote.size && local.hash == remote.hash
        }.value
        guard identical else { return false }
        try store.setState(.completed, fileID: fileID, in: id)
        return true
    }
    /// An interrupted write is never replayed without the user's confirmation.
    /// A later retry skips receipts for files already confirmed by the server.
    public static func upload(_ id: UUID, store: SharedImportStore, client: SeafileAPI,
                              retryUncertain: Bool = false,
                              progress: (Int, Int) -> Void = { _, _ in }) async throws {
        let lease = try store.uploadLease(id)
        defer { withExtendedLifetime(lease) {} }
        let share = try store.snapshot(id)
        guard share.accountID != nil, let repository = share.repository, let directory = share.directory else {
            throw SeafileError.local("Choose an account and destination for this share.")
        }
        for (index, file) in share.files.enumerated() {
            try Task.checkCancellation()
            if file.state == .completed { continue }
            if file.state == .sending { try store.setState(.uncertain, fileID: file.id, in: id) }
            if (file.state == .sending || file.state == .uncertain) && !retryUncertain { continue }
            let source = try store.fileURL(file, in: id)
            try store.setState(.sending, fileID: file.id, in: id)
            progress(index, share.files.count)
            do {
                // replace=false preserves any existing server file. A lost
                // response still needs manual checking before a repeated send.
                try await client.upload(repo: repository, directory: directory, file: source, replace: false)
                try store.setState(.completed, fileID: file.id, in: id)
            } catch {
                try? store.setState(.uncertain, fileID: file.id, in: id)
                throw error
            }
            progress(index + 1, share.files.count)
        }
        guard try store.snapshot(id).completed else {
            throw SeafileError.local("Some uploads were interrupted. Check the server before retrying; their local copies are preserved.")
        }
    }
}

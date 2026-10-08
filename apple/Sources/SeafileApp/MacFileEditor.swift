#if os(macOS)
import Foundation
import AppKit
import Observation
import CryptoKit
import SwiftUI
import SeafileCore

struct EditedFile: Codable, Identifiable {
    let id: String
    let accountID: UUID, repo: String, path: String, localURL: URL
    var objectID: String?
    var uploadedDigest: String
    var observedModification: Date?
    var error: String?
    var uploading = false
    var dirty: Bool? = nil
}

/// Keep editor copies separate from disposable preview/cache files. Failed
/// uploads and conflicting edits survive both app restarts and cache clearing.
@MainActor @Observable final class MacFileEditor {
    static let shared = MacFileEditor()
    var files: [EditedFile] = []
    private weak var model: AppModel?
    private var monitor: Task<Void, Never>?
    @ObservationIgnored private var opening: [String: Task<Void, Error>] = [:]
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/Editing", isDirectory: true)
    private var catalogue: URL { root.appendingPathComponent("files.json") }
    private init() {
        if let data = try? Data(contentsOf: catalogue), let stored = try? JSONDecoder().decode([EditedFile].self, from: data) {
            files = stored.map { var file = $0; file.uploading = false; return file }
        }
    }
    func start(model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for file in self.files where !file.uploading {
                    guard let modification = try? file.localURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          modification != file.observedModification else { continue }
                    do {
                        let digest = try await Self.fingerprint(file.localURL)
                        if let index = self.files.firstIndex(where: { $0.id == file.id }) {
                            self.files[index].observedModification = modification
                            self.files[index].dirty = digest != file.uploadedDigest
                            if digest != file.uploadedDigest && file.error == nil { await self.upload(file.id) }
                        }
                    } catch { self.setError(error.localizedDescription, id: file.id) }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func open(model: AppModel, account: ServerAccount, repo: Repository, entry: DirectoryEntry, path: String) async throws {
        start(model: model)
        let id = account.id.uuidString + ":" + repo.id + ":" + path
        if let existing = files.first(where: { $0.id == id }) {
            guard NSWorkspace.shared.open(existing.localURL) else { throw SeafileError.local("No application could open this file.") }
            return
        }
        if let pending = opening[id] { try await pending.value; return }
        // Opening a large file belongs to the editor, not to the browser's
        // cancellable command overlay. Repeated open requests share one task.
        let task = Task { [self] in
            let folder = root.appendingPathComponent(SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined())
            let local = folder.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let transfer = try model.transfers.enqueueDownload(accountID: account.id, repository: repo.id, path: path)
            let downloaded = try await model.transfers.result(for: transfer)
            try await TransferExportFiles.copy(downloaded, to: local, directory: false)
            let digest = try await Self.fingerprint(local)
            guard model.accounts.contains(where: { $0.id == account.id }) else { throw SeafileError.local("This account was removed while opening the file. Its downloaded copy is preserved.") }
            if repo.writable && (!entry.locked || entry.lockedByMe) {
                files.append(.init(id: id, accountID: account.id, repo: repo.id, path: path, localURL: local, objectID: entry.objectID,
                    uploadedDigest: digest, observedModification: try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
                try save()
            }
            guard NSWorkspace.shared.open(local) else { throw SeafileError.local("No application could open this file.") }
        }
        opening[id] = task
        defer { opening[id] = nil }
        try await task.value
    }
    func upload(_ id: String, overwrite: Bool = false) async {
        guard let model, let index = files.firstIndex(where: { $0.id == id }), !files[index].uploading,
              let account = model.accounts.first(where: { $0.id == files[index].accountID }) else { return }
        let file = files[index]
        files[index].uploading = true
        defer { if let index = files.firstIndex(where: { $0.id == id }) { files[index].uploading = false }; try? save() }
        do {
            let digest = try await Self.fingerprint(file.localURL)
            guard digest != file.uploadedDigest else { setError(nil, id: id); return }
            let api = try model.client(for: account)
            let parent = (file.path as NSString).deletingLastPathComponent
            let remote = try await api.directory(repo: file.repo, path: parent.isEmpty ? "/" : parent).first { $0.name == file.localURL.lastPathComponent }
            guard overwrite || (remote?.objectID == file.objectID && remote != nil) else {
                throw SeafileError.local("The server copy changed. Your local edits are preserved. Review both copies before choosing Upload and replace.")
            }
            guard remote?.locked != true || remote?.lockedByMe == true else { throw SeafileError.local("This file is locked by another user. Your edits are preserved.") }
            let snapshotRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: snapshotRoot) }
            let snapshot = snapshotRoot.appendingPathComponent(file.localURL.lastPathComponent)
            try FileManager.default.copyItem(at: file.localURL, to: snapshot)
            let snapshotDigest = try await Self.fingerprint(snapshot)
            try await api.upload(repo: file.repo, directory: parent, file: snapshot, replace: true)
            let localDigest = try await Self.fingerprint(file.localURL)
            let updated = try await api.directory(repo: file.repo, path: parent).first { $0.name == file.localURL.lastPathComponent }
            if let index = files.firstIndex(where: { $0.id == id }) {
                files[index].dirty = localDigest != snapshotDigest
                files[index].uploadedDigest = snapshotDigest; files[index].objectID = updated?.objectID; files[index].error = nil
                // Recheck after upload even if the editor saved during transfer.
                files[index].observedModification = nil
            }
        } catch { setError(error.localizedDescription, id: id) }
    }
    func hasChanges(_ file: EditedFile) -> Bool { file.dirty == true }
    func hasChanges(account: ServerAccount) -> Bool { files.contains { $0.accountID == account.id && hasChanges($0) } }
    func stopWatching(_ id: String) throws { files.removeAll { $0.id == id }; try save() }
    private func setError(_ error: String?, id: String) { if let index = files.firstIndex(where: { $0.id == id }) { files[index].error = error }; try? save() }
    private func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(files).write(to: catalogue, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogue.path)
    }
    private nonisolated static func fingerprint(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try Self.digest(url) }.value
    }
    private nonisolated static func digest(_ url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var hash = SHA256()
        while let bytes = try reader.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct EditedFilesView: View {
    @State private var replace: EditedFile?
    var body: some View {
        List(MacFileEditor.shared.files) { file in
            VStack(alignment: .leading, spacing: 8) {
                Text(file.localURL.lastPathComponent).font(.headline)
                Text(file.path).font(.caption).foregroundStyle(.secondary)
                Text(file.uploading ? "Uploading edits" : MacFileEditor.shared.hasChanges(file) ? "Local changes waiting to upload" : "Up to date")
                if let error = file.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Open") { NSWorkspace.shared.open(file.localURL) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.localURL]) }
                    Button("Retry upload") { Task { await MacFileEditor.shared.upload(file.id) } }.disabled(file.uploading)
                    Button("Upload and replace") { replace = file }.disabled(file.uploading)
                    Button("Stop watching") { try? MacFileEditor.shared.stopWatching(file.id) }.disabled(MacFileEditor.shared.hasChanges(file) || file.uploading)
                }.buttonStyle(.borderless)
            }.padding(.vertical, 4)
        }.navigationTitle("Edited files")
            .overlay { if MacFileEditor.shared.files.isEmpty { ContentUnavailableView("No edited files", systemImage: "pencil.and.outline") } }
            .confirmationDialog("Replace the server copy with these local edits?", isPresented: Binding(get: { replace != nil }, set: { if !$0 { replace = nil } })) {
                Button("Upload and replace", role: .destructive) { if let file = replace { Task { await MacFileEditor.shared.upload(file.id, overwrite: true) } } }
            }
    }
}
#endif

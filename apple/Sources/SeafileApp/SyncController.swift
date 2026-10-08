#if os(macOS)
import Foundation
import SwiftUI
import SeafileCore
import AppKit

struct SyncedLibrary: Identifiable {
    let id: String, name: String, folder: String
    var state: String
}

@MainActor @Observable
final class SyncController {
    static let shared = SyncController()
    var status = "Sync engine is stopped"
    var libraries: [SyncedLibrary] = []
    var paused = false
    var showSync: Repository?
    private var process: Process?
    private var starting = false
    private var scopes: [String: URL] = [:]
    private var bookmarks: [String: Data] = [:]
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sn", isDirectory: true)
    private var rpc: DaemonRPC { DaemonRPC(socketPath: root.appendingPathComponent("data/seafile.sock").path) }

    private init() {
        bookmarks = UserDefaults.standard.dictionary(forKey: "syncBookmarks") as? [String: Data] ?? [:]
        for (id, bookmark) in bookmarks {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { scopes[id] = url }
                if stale { bookmarks[id] = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
            } catch { status = "A sync folder needs to be selected again: \(error.localizedDescription)" }
        }
        UserDefaults.standard.set(bookmarks, forKey: "syncBookmarks")
    }

    func start() async {
        guard process?.isRunning != true, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            guard let executable = Bundle.main.url(forResource: "seaf-daemon", withExtension: nil, subdirectory: "Engine") else {
                throw SeafileError.local("The packaged sync engine is missing.")
            }
            for directory in ["config", "config/logs", "data", "worktrees"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-c", root.appendingPathComponent("config").path, "-d", root.appendingPathComponent("data").path, "-w", root.appendingPathComponent("worktrees").path, "-l", root.appendingPathComponent("seafile.log").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            self.process = process
            status = "Starting sync engine…"
            for _ in 0..<60 {
                guard process.isRunning else { throw SeafileError.local("The sync engine exited (\(process.terminationStatus)). Check the sync log.") }
                if (try? await rpc.call("seafile_get_config", [.string("use_proxy")])) != nil {
                    status = "Sync engine is ready"
                    await refresh()
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw SeafileError.local("The sync engine did not become ready within 30 seconds.")
        } catch { stop(); status = error.localizedDescription }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        // Retain the child until it exits; never launch a second engine over its database.
        status = "Sync engine is stopped"
    }

    func refresh() async {
        guard process?.isRunning == true else { if process != nil { status = "Sync engine stopped unexpectedly" }; return }
        do {
            paused = try await rpc.call("seafile_is_auto_sync_enabled") == .integer(0)
            let response = try await rpc.call("seafile_get_repo_list", [.integer(0), .integer(-1)])
            var results: [SyncedLibrary] = []
            for value in response.array ?? [] {
                guard let object = value.object, let id = object["id"]?.string else { continue }
                let task = try await rpc.call("seafile_get_repo_sync_task", [.string(id)])
                let state = task.object?["state"]?.string ?? (paused ? "Paused" : "Up to date")
                results.append(SyncedLibrary(id: id, name: object["name"]?.string ?? id, folder: object["worktree"]?.string ?? "", state: state))
            }
            libraries = results
            status = paused ? "Syncing is paused" : "\(results.count) synced libraries"
        } catch { status = error.localizedDescription }
    }

    func togglePause() async throws {
        _ = try await rpc.call(paused ? "seafile_enable_auto_sync" : "seafile_disable_auto_sync")
        paused.toggle()
        await refresh()
    }

    func disconnect(_ account: ServerAccount) async throws {
        // Clear this account's library tokens and cancel its clone tasks. The
        // engine keeps local files, and other accounts continue syncing.
        await start()
        guard process?.isRunning == true else { throw SeafileError.local(status) }
        _ = try await rpc.call("seafile_remove_repo_tokens_by_account", [.string(account.endpoint.url.absoluteString), .string(account.email)])
        await refresh()
    }

    func clone(repo: Repository, account: ServerAccount, api: SeafileAPI, folder: URL, password: String) async throws {
        let access = folder.startAccessingSecurityScopedResource()
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        bookmarks[repo.id] = bookmark
        if let old = scopes.removeValue(forKey: repo.id) { old.stopAccessingSecurityScopedResource() }
        if access { scopes[repo.id] = folder }
        UserDefaults.standard.set(bookmarks, forKey: "syncBookmarks")
        // Restart this app's own child after resolving the selected folder's scope.
        if let child = process, child.isRunning {
            stop()
            for _ in 0..<50 {
                if !child.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !child.isRunning else { throw SeafileError.local("The sync engine is still stopping. Try again shortly.") }
        }
        await start()
        guard process?.isRunning == true else { throw SeafileError.local(status) }
        let info = try await api.downloadInfo(repo: repo.id)
        var extra: [String: JSONValue] = ["server_url": .string(account.endpoint.url.absoluteString), "is_readonly": .integer(repo.writable ? 0 : 1), "username": .string(account.email)]
        for (name, value) in [("repo_salt", info.salt), ("pwd_hash_algo", info.pwd_hash_algo), ("pwd_hash_params", info.pwd_hash_params), ("pwd_hash", info.pwd_hash)] {
            if let value { extra[name] = .string(value) }
        }
        let extraString = String(decoding: try JSONEncoder().encode(JSONValue.object(extra)), as: UTF8.self)
        _ = try await rpc.call("seafile_download", [.string(info.repo_id), .integer(info.repo_version), .string(info.repo_name), .string(folder.path), .string(info.token), password.isEmpty ? .null : .string(password), info.magic.map(JSONValue.string) ?? .null, .string(info.email), info.random_key.map(JSONValue.string) ?? .null, .integer(info.enc_version ?? 0), .string(extraString)])
        await refresh()
    }

    func unsync(_ library: SyncedLibrary) async throws {
        _ = try await rpc.call("seafile_destroy_repo", [.string(library.id)])
        bookmarks.removeValue(forKey: library.id)
        if let url = scopes.removeValue(forKey: library.id) { url.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.set(bookmarks, forKey: "syncBookmarks")
        await refresh()
    }

    func revealLog() { NSWorkspace.shared.open(root.appendingPathComponent("seafile.log")) }
}

struct SyncView: View {
    var model: AppModel
    @State private var remove: SyncedLibrary?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        List {
            Section {
                Text(SyncController.shared.status)
                Button(SyncController.shared.paused ? "Resume syncing" : "Pause syncing") {
                    Task { do { try await SyncController.shared.togglePause() } catch { model.errorMessage = error.localizedDescription } }
                }
                Button("Open sync log") { SyncController.shared.revealLog() }
            }
            Section("Libraries") {
                ForEach(SyncController.shared.libraries) { library in
                    HStack {
                        VStack(alignment: .leading) { Text(library.name).font(.headline); Text(library.state).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: library.folder)) }
                        Button("Stop syncing") { remove = library }
                    }
                }
            }
        }.navigationTitle("Sync status")
            .task(id: phase) {
                guard phase == .active else { return }
                repeat { await SyncController.shared.refresh(); do { try await Task.sleep(for: .seconds(3)) } catch { return } } while !Task.isCancelled
            }
            .confirmationDialog("Stop syncing this library?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } })) {
                Button("Stop syncing") {
                    if let library = remove { Task { do { try await SyncController.shared.unsync(library) } catch { model.errorMessage = error.localizedDescription } } }
                }
            } message: { Text("The local folder and the server library are preserved.") }
    }
}

struct SyncLibrarySheet: View {
    var model: AppModel
    let account: ServerAccount, repo: Repository
    @State private var folder: URL?
    @State private var password = ""
    @State private var importing = false
    @State private var loading = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text(repo.name).font(.headline)
                Button(folder?.path ?? "Choose parent folder") { importing = true }
                Text("A new library folder is created here. Existing files will not be removed.").font(.caption).foregroundStyle(.secondary)
                if repo.encrypted { SecureField("Library password", text: $password) }
                if let error { Text(error).foregroundStyle(.red) }
                if loading { ProgressView("Starting sync") }
            }.formStyle(.grouped).navigationTitle("Sync library")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(loading) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sync") {
                            guard let folder else { return }
                            loading = true
                            Task {
                                do { try await SyncController.shared.clone(repo: repo, account: account, api: model.client(for: account), folder: folder, password: password); password = ""; dismiss() }
                                catch { self.error = error.localizedDescription }
                                loading = false
                            }
                        }.disabled(folder == nil || loading || (repo.encrypted && password.isEmpty))
                    }
                }
        }.frame(width: 460, height: 300)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                switch result { case .success(let url): folder = url; case .failure(let error): self.error = error.localizedDescription }
            }
    }
}
#endif

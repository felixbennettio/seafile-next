#if os(macOS)
import Foundation
import SwiftUI
import SeafileCore
import AppKit
import UserNotifications

struct SyncedLibrary: Identifiable {
    let id: String, name: String, folder: String
    var state: String
    var autoSync = true
    var syncInterval = 0
    var errorCode = 29
}

struct SyncTaskItem: Identifiable {
    let id: String, name: String, folder: String, state: String
    let errorCode: Int
    var progress: Double? = nil
    var rate = 0
}
struct SyncErrorItem: Identifiable {
    let id: Int, repo: String, library: String, path: String, errorCode: Int, timestamp: Int
}
struct SyncDeletionConfirmation: Identifiable {
    let id: String, library: String, description: String
}
struct SyncActivity: Identifiable {
    let id = UUID()
    let date = Date()
    let type: String, content: String
    var repo: String? = nil
    var commit: String? = nil
    var previousCommit: String? = nil
}

@MainActor @Observable
final class SyncController {
    static let shared = SyncController()
    var status = "Sync engine is stopped"
    var libraries: [SyncedLibrary] = []
    var paused = false
    var cloneTasks: [SyncTaskItem] = []
    var errors: [SyncErrorItem] = []
    var activity: [SyncActivity] = []
    var deletionConfirmations: [SyncDeletionConfirmation] = []
    var downloadRate = 0
    var uploadRate = 0
    var showErrors = false
    var showSync: Repository?
    private var process: Process?
    private var starting = false
    private var monitor: Task<Void, Never>?
    private var refreshing = false
    private var proxyEndpoint: URL?
    private var lastSystemProxy: ClientNetworkSettings?
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
                    try await apply(settings: DesktopPreferences.load(), network: ClientNetworkSettings.load())
                    status = "Sync engine is ready"
                    await refresh()
                    monitor?.cancel()
                    monitor = Task { [weak self] in
                        while !Task.isCancelled {
                            guard let self else { return }
                            await self.refresh()
                            do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        }
                    }
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw SeafileError.local("The sync engine did not become ready within 30 seconds.")
        } catch { stop(); status = error.localizedDescription }
    }

    func stop() {
        monitor?.cancel(); monitor = nil
        if let process, process.isRunning { process.terminate() }
        // Retain the child until it exits; never launch a second engine over its database.
        status = "Sync engine is stopped"
    }

    func refresh() async {
        guard process?.isRunning == true else { if process != nil { status = "Sync engine stopped unexpectedly" }; return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            paused = try await rpc.call("seafile_is_auto_sync_enabled") == .integer(0)
            let response = try await rpc.call("seafile_get_repo_list", [.integer(0), .integer(-1)])
            var results: [SyncedLibrary] = []
            for value in response.array ?? [] {
                guard let object = value.object, let id = object["id"]?.string else { continue }
                let task = try await rpc.call("seafile_get_repo_sync_task", [.string(id)])
                let state = task.object?["state"]?.string ?? (paused ? "Paused" : "Up to date")
                let interval = try await rpc.call("seafile_get_repo_property", [.string(id), .string("sync-interval")])
                results.append(SyncedLibrary(id: id, name: object["name"]?.string ?? id, folder: object["worktree"]?.string ?? "", state: state,
                    autoSync: object["auto-sync"]?.boolean ?? object["auto_sync"]?.boolean ?? true,
                    syncInterval: Int(interval.string ?? "0") ?? 0, errorCode: task.object?["error"]?.integer ?? 29))
            }
            libraries = results
            status = paused ? "Syncing is paused" : "\(results.count) synced libraries"
            cloneTasks = (try await rpc.call("seafile_get_clone_tasks")).array?.compactMap { value in
                guard let object = value.object, let id = object["repo_id"]?.string else { return nil }
                return SyncTaskItem(id: id, name: object["repo_name"]?.string ?? id, folder: object["worktree"]?.string ?? "",
                                    state: object["state"]?.string ?? "", errorCode: object["error"]?.integer ?? 29)
            } ?? []
            for index in cloneTasks.indices {
                let transfer = try await rpc.call("seafile_find_transfer_task", [.string(cloneTasks[index].id)])
                if let object = transfer.object {
                    let total = object["block_total"]?.integer ?? 0, done = object["block_done"]?.integer ?? 0
                    if total > 0 { cloneTasks[index].progress = min(1, max(0, Double(done) / Double(total))) }
                    cloneTasks[index].rate = object["rate"]?.integer ?? 0
                }
            }
            errors = (try await rpc.call("seafile_get_file_sync_errors", [.integer(0), .integer(-1)])).array?.compactMap { value in
                guard let object = value.object, let id = object["id"]?.integer else { return nil }
                return SyncErrorItem(id: id, repo: object["repo_id"]?.string ?? "", library: object["repo_name"]?.string ?? "",
                    path: object["path"]?.string ?? "", errorCode: object["err_id"]?.integer ?? 28, timestamp: object["timestamp"]?.integer ?? 0)
            } ?? []
            downloadRate = (try await rpc.call("seafile_get_download_rate")).integer ?? 0
            uploadRate = (try await rpc.call("seafile_get_upload_rate")).integer ?? 0
            try await pollNotifications()
            #if !APPSTORE
            await MacFinderBridge.shared.refresh()
            #endif
            if ClientNetworkSettings.load().proxy == .system { try await updateSystemProxy() }
        } catch { status = error.localizedDescription }
    }

    func pathStatus(library: SyncedLibrary, path: String, directory: Bool) async throws -> String {
        if paused || !library.autoSync { return "paused" }
        return try await rpc.call("seafile_get_path_sync_status", [.string(library.id), .string(path == "/" ? "" : path), .integer(directory ? 1 : 0)]).string ?? ""
    }
    func markLock(library: SyncedLibrary, path: String, locked: Bool) async throws {
        _ = try await rpc.call(locked ? "seafile_mark_file_locked" : "seafile_mark_file_unlocked", [.string(library.id), .string(path)])
    }
    func account(for library: SyncedLibrary, accounts: [ServerAccount]) async throws -> ServerAccount {
        let server = try await rpc.call("seafile_get_repo_property", [.string(library.id), .string("server-url")]).string
        let email = try await rpc.call("seafile_get_repo_property", [.string(library.id), .string("email")]).string
        let matches = accounts.filter { server.flatMap { try? ServerEndpoint($0) } == $0.endpoint && (email == nil || email?.isEmpty == true || email == $0.email) }
        guard matches.count == 1, let account = matches.first else { throw SeafileError.local("Sign in to this library's account first.") }
        return account
    }

    func togglePause() async throws {
        _ = try await rpc.call(paused ? "seafile_enable_auto_sync" : "seafile_disable_auto_sync")
        paused.toggle()
        await refresh()
    }

    func use(account: ServerAccount?) { proxyEndpoint = account?.endpoint.url; lastSystemProxy = nil }

    func apply(settings: DesktopPreferences, network: ClientNetworkSettings) async throws {
        guard process?.isRunning == true else { throw SeafileError.local(status) }
        for (key, value) in settings.daemonStrings {
            _ = try await rpc.call("seafile_set_config", [.string(key), .string(value)])
        }
        _ = try await rpc.call("seafile_set_download_rate_limit", [.integer(settings.downloadLimit * 1024)])
        _ = try await rpc.call("seafile_set_upload_rate_limit", [.integer(settings.uploadLimit * 1024)])
        _ = try await rpc.call("seafile_set_config_int", [.string("delete_confirm_threshold"), .integer(settings.deleteConfirmThreshold)])
        _ = try await rpc.call("seafile_set_config", [.string("disable_verify_certificate"), .string(network.verifyCertificates ? "false" : "true")])
        _ = try await rpc.call("seafile_set_config", [.string("use_proxy"), .string(network.proxy == .none ? "false" : "true")])
        _ = try await rpc.call("seafile_set_config", [.string("use_system_proxy"), .string(network.proxy == .system ? "true" : "false")])
        if network.proxy == .system { lastSystemProxy = nil; try await updateSystemProxy() }
        else { try await writeProxy(network) }
    }

    private func writeProxy(_ proxy: ClientNetworkSettings) async throws {
        let type = proxy.proxy == .none ? "none" : proxy.proxy == .socks5 ? "socks" : "http"
        for (key, value) in [("proxy_type", type), ("proxy_addr", proxy.host), ("proxy_username", proxy.username), ("proxy_password", proxy.password)] {
            _ = try await rpc.call("seafile_set_config", [.string(key), .string(value)])
        }
        _ = try await rpc.call("seafile_set_config_int", [.string("proxy_port"), .integer(proxy.port)])
    }

    private func updateSystemProxy() async throws {
        let url = proxyEndpoint ?? URL(string: "https://www.seafile.com/")!
        let proxy = try await SystemProxyResolver.resolve(for: url)
        guard proxy != lastSystemProxy else { return }
        let object: [String: Any] = ["type": proxy.proxy == .none ? "none" : proxy.proxy == .socks5 ? "socks" : "http",
            "addr": proxy.host, "port": proxy.port, "username": proxy.username, "password": proxy.password]
        let file = root.appendingPathComponent("data/system-proxy.txt")
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try await writeProxy(proxy)
        lastSystemProxy = proxy
    }

    private func pollNotifications() async throws {
        for _ in 0..<20 {
            guard let message = (try await rpc.call("seafile_get_sync_notification")).object,
                  let type = message["type"]?.string, let content = message["content"]?.string else { return }
            if type == "sync.del_confirmation", let data = content.data(using: .utf8),
               let object = try JSONDecoder().decode(JSONValue.self, from: data).object,
               let id = object["confirmation_id"]?.string {
                if !deletionConfirmations.contains(where: { $0.id == id }) {
                    deletionConfirmations.append(.init(id: id, library: object["repo_name"]?.string ?? "", description: object["delete_files"]?.string ?? ""))
                }
            } else if type != "transfer" {
                let parts = content.components(separatedBy: "\t")
                var event = SyncActivity(type: type, content: content)
                if (type == "sync.done" || type == "sync.multipart_upload"), parts.count == 5 {
                    event = SyncActivity(type: type, content: parts[0] + " · " + parts[4], repo: parts[1], commit: parts[2], previousCommit: parts[3])
                } else if type == "sync.error", let data = content.data(using: .utf8), let error = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object {
                    event = SyncActivity(type: type, content: (error["repo_name"]?.string ?? "") + " · " + SyncErrorDescription.message(error["err_id"]?.integer ?? 28))
                }
                activity.insert(event, at: 0)
                if activity.count > 200 { activity.removeLast() }
                if DesktopPreferences.load().notifySync, type == "sync.done" || type == "sync.multipart_upload" || type == "sync.error" {
                    let notification = UNMutableNotificationContent()
                    notification.title = "seafile-next"
                    notification.body = event.content
                    try? await UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: notification, trigger: nil))
                }
            }
        }
    }

    func localChanges(_ event: SyncActivity) async throws -> [(String, String)] {
        guard let repo = event.repo, let commit = event.commit, let previous = event.previousCommit else { return [] }
        let changes = try await rpc.call("seafile_diff", [.string(repo), .string(commit), .string(previous), .integer(1)], service: "seafile-threaded-rpcserver")
        return (changes.array ?? []).compactMap { item in
            guard let object = item.object, let status = object["status"]?.string, let name = object["name"]?.string else { return nil }
            let titles = ["add": "Added", "del": "Deleted", "mov": "Renamed", "mod": "Modified", "newdir": "New folder", "deldir": "Deleted folder"]
            return (titles[status] ?? status, name + (object["new_name"]?.string.map { " → " + $0 } ?? ""))
        }
    }

    func confirmDeletion(_ confirmation: SyncDeletionConfirmation, resync: Bool) async throws {
        _ = try await rpc.call("seafile_add_del_confirmation", [.string(confirmation.id), .integer(resync ? 1 : 0)])
        deletionConfirmations.removeAll { $0.id == confirmation.id }
        await refresh()
    }

    func syncNow(_ library: SyncedLibrary) async throws {
        _ = try await rpc.call("seafile_sync", [.string(library.id), .null])
        await refresh()
    }
    func setAutoSync(_ enabled: Bool, for library: SyncedLibrary) async throws {
        _ = try await rpc.call("seafile_set_repo_property", [.string(library.id), .string("auto-sync"), .string(enabled ? "true" : "false")])
        await refresh()
    }
    func setInterval(_ seconds: Int, for library: SyncedLibrary) async throws {
        guard seconds >= 0 else { throw SeafileError.local("The sync interval cannot be negative.") }
        _ = try await rpc.call("seafile_set_repo_property", [.string(library.id), .string("sync-interval"), .string(String(seconds))])
        await refresh()
    }
    func cancel(_ task: SyncTaskItem) async throws {
        _ = try await rpc.call("seafile_cancel_clone_task", [.string(task.id)])
        await refresh()
    }
    func remove(_ task: SyncTaskItem) async throws {
        _ = try await rpc.call("seafile_remove_clone_task", [.string(task.id)])
        await refresh()
    }
    func discardError(_ error: SyncErrorItem) async throws {
        _ = try await rpc.call("seafile_del_file_sync_error_by_id", [.integer(error.id)])
        await refresh()
    }
    func discardErrors(repo: String) async throws {
        for error in errors where error.repo == repo { _ = try await rpc.call("seafile_del_file_sync_error_by_id", [.integer(error.id)]) }
        await refresh()
    }
    func revealRoot() { NSWorkspace.shared.open(root.appendingPathComponent("worktrees")) }
    func revealLogs() { NSWorkspace.shared.open(root) }

    func updateServerAddress(from old: URL, to new: URL) async throws {
        await start()
        _ = try await rpc.call("seafile_update_repos_server_host", [.string(old.absoluteString), .string(new.absoluteString)])
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

    func encryptionFields(api: SeafileAPI, password: String) async throws -> [String: String] {
        await start()
        guard process?.isRunning == true else { throw SeafileError.local(status) }
        let server = try await api.serverInfo()
        let version = server.encrypted_library_version ?? 2
        guard (2...4).contains(version) else { throw SeafileError.local("This server uses an unsupported encryption version.") }
        let id = UUID().uuidString.lowercased()
        let algorithm = server.encrypted_library_pwd_hash_algo ?? "", params = server.encrypted_library_pwd_hash_params ?? ""
        let reply = try await rpc.call("seafile_generate_magic_and_random_key", [.integer(version), .string(id), .string(password), .string(algorithm), .string(params)])
        guard let object = reply.object, let magic = object["magic"]?.string, let key = object["random_key"]?.string else { throw SeafileError.invalidResponse }
        var result = ["repo_id": id, "enc_version": String(version), "magic": magic, "random_key": key]
        if let salt = object["salt"]?.string, !salt.isEmpty { result["salt"] = salt }
        if !algorithm.isEmpty, let hash = object["pwd_hash"]?.string, !hash.isEmpty {
            result["pwd_hash_algo"] = algorithm; result["pwd_hash_params"] = params; result["pwd_hash"] = hash
        }
        return result
    }

    func clone(repo: Repository, account: ServerAccount, api: SeafileAPI, folder: URL, password: String, existing: Bool = false, resync: Bool = false) async throws {
        let info = try await api.downloadInfo(repo: repo.id)
        guard info.repo_id == repo.id else { throw SeafileError.invalidResponse }
        if resync {
            guard let current = libraries.first(where: { $0.id == repo.id }),
                  URL(fileURLWithPath: current.folder).standardizedFileURL == folder.standardizedFileURL else {
                throw SeafileError.local("Resync requires this library’s existing local folder.")
            }
        }
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
        if resync { _ = try await rpc.call("seafile_destroy_repo", [.string(repo.id)]) }
        var extra: [String: JSONValue] = ["server_url": .string(account.endpoint.url.absoluteString), "is_readonly": .integer(repo.writable ? 0 : 1), "username": .string(account.email)]
        for (name, value) in [("repo_salt", info.salt), ("pwd_hash_algo", info.pwd_hash_algo), ("pwd_hash_params", info.pwd_hash_params), ("pwd_hash", info.pwd_hash)] {
            if let value { extra[name] = .string(value) }
        }
        let extraString = String(decoding: try JSONEncoder().encode(JSONValue.object(extra)), as: UTF8.self)
        let validation = try await rpc.call("seafile_check_path_for_clone", [.string(folder.path)])
        if let code = validation.integer, code != 0 { throw SeafileError.local("This folder cannot be used for syncing (\(code)). Choose another folder.") }
        _ = try await rpc.call(existing ? "seafile_clone" : "seafile_download", [.string(info.repo_id), .integer(info.repo_version), .string(info.repo_name), .string(folder.path), .string(info.token), password.isEmpty ? .null : .string(password), info.magic.map(JSONValue.string) ?? .null, .string(info.email), info.random_key.map(JSONValue.string) ?? .null, .integer(info.enc_version ?? 0), .string(extraString)])
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
    @State private var changeDetails: SyncActivity?
    @State private var pendingDeletion: SyncDeletionConfirmation?
    @State private var remove: SyncedLibrary?
    @State private var interval: SyncedLibrary?
    @State private var resync: SyncedLibrary?
    @State private var resyncRequest: SyncLibraryRequest?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        List {
            Section {
                Text(SyncController.shared.status)
                ForEach(SyncController.shared.deletionConfirmations) { confirmation in
                    Button("Review deletions in \(confirmation.library)") { pendingDeletion = confirmation }
                }
                Button(SyncController.shared.paused ? "Resume syncing" : "Pause syncing") {
                    Task { do { try await SyncController.shared.togglePause() } catch { model.errorMessage = error.localizedDescription } }
                }
                Button("Open sync log") { SyncController.shared.revealLog() }
                Text("Download: \(ByteCountFormatter.string(fromByteCount: Int64(SyncController.shared.downloadRate), countStyle: .file))/s · Upload: \(ByteCountFormatter.string(fromByteCount: Int64(SyncController.shared.uploadRate), countStyle: .file))/s")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show file sync errors") { SyncController.shared.showErrors = true }
            }
            Section("Libraries") {
                ForEach(SyncController.shared.libraries) { library in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(library.name).font(.headline)
                            Text(library.errorCode == 29 ? library.state : SyncErrorDescription.message(library.errorCode)).foregroundStyle(.secondary)
                            Text(verbatim: library.folder).font(.caption).textSelection(.enabled)
                            Text(library.autoSync ? (library.syncInterval == 0 ? "Automatic sync" : "Sync every \(library.syncInterval) seconds") : "Automatic sync disabled").font(.caption)
                        }
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: library.folder)) }
                        Menu("Actions") {
                            Button("Sync now") { run { try await SyncController.shared.syncNow(library) } }
                            Button(library.autoSync ? "Disable auto sync" : "Enable auto sync") { run { try await SyncController.shared.setAutoSync(!library.autoSync, for: library) } }
                            Button("Set sync interval") { interval = library }
                            Button("Resync this library") { resync = library }
                            Button("Show sync errors") { SyncController.shared.showErrors = true }
                            Button("Discard sync errors") { run { try await SyncController.shared.discardErrors(repo: library.id) } }
                            Button("Stop syncing") { remove = library }
                        }
                    }
                }
            }
            Section("Download tasks") {
                ForEach(SyncController.shared.cloneTasks) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.name).font(.headline)
                        Text(task.state == "error" ? SyncErrorDescription.message(task.errorCode) : task.state).foregroundStyle(.secondary)
                        Text(verbatim: task.folder).font(.caption)
                        if let progress = task.progress { ProgressView(value: progress); Text("\(Int(progress * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(task.rate), countStyle: .file))/s").font(.caption) }
                        if ["done", "canceled"].contains(task.state) { Button("Remove task") { run { try await SyncController.shared.remove(task) } } }
                        else { Button("Cancel download") { run { try await SyncController.shared.cancel(task) } } }
                    }
                }
                if SyncController.shared.cloneTasks.isEmpty { Text("No download tasks").foregroundStyle(.secondary) }
            }
            Section("Recent sync activity") {
                ForEach(SyncController.shared.activity) { event in
                    VStack(alignment: .leading) {
                        Text(event.content.replacingOccurrences(of: "\t", with: " · "))
                        Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        if event.repo != nil { Button("View changes") { changeDetails = event } }
                    }
                }
            }
        }.buttonStyle(.borderless).navigationTitle("Sync status")
            .sheet(isPresented: Binding(get: { SyncController.shared.showErrors }, set: { SyncController.shared.showErrors = $0 })) { SyncErrorsView(model: model) }
            .sheet(item: $changeDetails) { event in LocalSyncChangesView(event: event) }
            .sheet(item: $pendingDeletion) { confirmation in SyncDeletionSheet(model: model, confirmation: confirmation) }
            .onChange(of: SyncController.shared.deletionConfirmations.count) { _, _ in if let pendingDeletion, !SyncController.shared.deletionConfirmations.contains(where: { $0.id == pendingDeletion.id }) { self.pendingDeletion = nil } }
            .sheet(item: $interval) { library in SyncIntervalSheet(model: model, library: library) }
            .sheet(item: $resyncRequest) { request in
                SyncLibrarySheet(model: model, account: request.account, repo: request.repo, initialFolder: request.folder, resync: true)
            }
            .task(id: phase) {
                guard phase == .active else { return }
                repeat { await SyncController.shared.refresh(); do { try await Task.sleep(for: .seconds(3)) } catch { return } } while !Task.isCancelled
            }
            .confirmationDialog("Stop syncing this library?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } })) {
                Button("Stop syncing") {
                    if let library = remove { Task { do { try await SyncController.shared.unsync(library) } catch { model.errorMessage = error.localizedDescription } } }
                }
            } message: { Text("The local folder and the server library are preserved.") }
            .confirmationDialog("Resync this library?", isPresented: Binding(get: { resync != nil }, set: { if !$0 { resync = nil } })) {
                Button("Resync") {
                    if let library = resync, let account = model.account, let repo = model.repositories.first(where: { $0.id == library.id }) {
                        resyncRequest = SyncLibraryRequest(account: account, repo: repo, folder: URL(fileURLWithPath: library.folder))
                    } else { model.errorMessage = "Select the account that owns this synced library and refresh its libraries first." }
                }
            } message: { Text("The existing folder is merged with the server again. Local files are preserved.") }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { model.errorMessage = error.localizedDescription } }
    }
}

private struct SyncLibraryRequest: Identifiable {
    let id = UUID()
    let account: ServerAccount, repo: Repository
    let folder: URL
}

struct LocalSyncChangesView: View {
    let event: SyncActivity
    @State private var changes: [(String, String)] = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text(event.content).font(.headline)
                ForEach(Array(changes.enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading) { Text(item.element.0).font(.caption).foregroundStyle(.secondary); Text(item.element.1).textSelection(.enabled) }
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            }.navigationTitle("Change details").toolbar { Button("Done") { dismiss() } }
        }.frame(width: 580, height: 440).task {
            do { changes = try await SyncController.shared.localChanges(event) } catch { self.error = error.localizedDescription }
        }
    }
}

struct SyncIntervalSheet: View {
    var model: AppModel
    let library: SyncedLibrary
    @State private var seconds: Int
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, library: SyncedLibrary) { self.model = model; self.library = library; _seconds = State(initialValue: library.syncInterval) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(library.name).font(.headline)
            PreferenceInput("Sync interval in seconds (0 = automatic)") { TextField("Seconds", value: $seconds, format: .number.grouping(.never)).labelsHidden() }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save") {
                Task { do { try await SyncController.shared.setInterval(seconds, for: library); dismiss() } catch { model.errorMessage = error.localizedDescription } }
            }.disabled(seconds < 0) }
        }.padding(24).frame(width: 420)
    }
}

struct SyncErrorsView: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(SyncController.shared.errors) { error in
                VStack(alignment: .leading, spacing: 8) {
                    Text(error.library).font(.headline)
                    Text(verbatim: error.path).textSelection(.enabled)
                    Text(SyncErrorDescription.message(error.errorCode)).foregroundStyle(.secondary)
                    HStack {
                        Button("Show in Finder") {
                            if let library = SyncController.shared.libraries.first(where: { $0.id == error.repo }) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: library.folder).appendingPathComponent(error.path)])
                            }
                        }
                        Button("Discard error") { Task { do { try await SyncController.shared.discardError(error) } catch { model.errorMessage = error.localizedDescription } } }
                    }
                }
            }.buttonStyle(.borderless).navigationTitle("File sync errors")
                .overlay { if SyncController.shared.errors.isEmpty { ContentUnavailableView("No sync errors", systemImage: "checkmark.circle") } }
                .toolbar { Button("Done") { dismiss() } }
        }.frame(minWidth: 580, minHeight: 380)
    }
}

struct SyncDeletionSheet: View {
    var model: AppModel
    let confirmation: SyncDeletionConfirmation
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm file deletions").font(.title2)
            Text(confirmation.library).font(.headline)
            Text(confirmation.description)
            Text("Choose whether to sync these local deletions to the server or restore the library from the server.")
            HStack {
                Button("Restore from server") { decide(resync: true) }
                Spacer()
                Button("Sync deletions", role: .destructive) { decide(resync: false) }
            }.disabled(working)
        }.padding(24).frame(width: 520).interactiveDismissDisabled()
    }
    private func decide(resync: Bool) {
        working = true
        Task { do { try await SyncController.shared.confirmDeletion(confirmation, resync: resync) } catch { model.errorMessage = error.localizedDescription }; working = false }
    }
}

struct SyncLibrarySheet: View {
    var model: AppModel
    let account: ServerAccount, repo: Repository
    var initialFolder: URL? = nil
    var resync = false
    @State private var folder: URL?
    @State private var existing = false
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
                if DesktopPreferences.load().syncWithExistingFolder || resync {
                    Toggle("Merge with the selected existing folder", isOn: $existing).disabled(resync)
                }
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
                                do { try await SyncController.shared.clone(repo: repo, account: account, api: model.client(for: account), folder: folder, password: password, existing: existing, resync: resync); password = ""; dismiss() }
                                catch { self.error = error.localizedDescription }
                                loading = false
                            }
                        }.disabled(folder == nil || loading || (repo.encrypted && password.isEmpty))
                    }
                }
        }.frame(width: 500, height: 360)
            .onAppear { if let initialFolder { folder = initialFolder; existing = true } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                switch result { case .success(let url): folder = url; case .failure(let error): self.error = error.localizedDescription }
            }
    }
}
#endif

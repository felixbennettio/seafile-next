#if os(macOS) && !APPSTORE
import SwiftUI
import AppKit
import SeafileCore

struct FinderShareRequest: Identifiable {
    let id = UUID()
    let account: ServerAccount, repo: Repository, path: String, directory: Bool
}

@MainActor final class MacFinderBridge: NSObject {
    static let shared = MacFinderBridge()
    private weak var model: AppModel?
    private var observed: [URL: Date] = [:]
    private var writing = false
    private let stateFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/seafile-next/FinderBridge")
    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(request(_:)), name: .init("io.felixbennett.seafile.direct.finder-status"), object: nil)
    }
    @objc private func request(_ notification: Notification) {
        guard let object = notification.object as? String, object.utf8.count < 4096, let data = object.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String], let path = value["path"] else { return }
        let url = URL(fileURLWithPath: path)
        guard SyncController.shared.libraries.contains(where: { LocalSyncPath.relative(url, within: URL(fileURLWithPath: $0.folder)) != nil }) else { return }
        if observed.count >= 1000 { observed.removeAll() }
        observed[url] = Date()
    }
    func refresh() async {
        guard !writing else { return }; writing = true
        defer { writing = false }
        do {
            let libraries = DesktopPreferences.load().finderIntegration ? SyncController.shared.libraries : []
            observed = observed.filter { Date().timeIntervalSince($0.value) < 600 }
            var statuses: [String: String] = [:]
            for url in Set(observed.keys).union(libraries.map { URL(fileURLWithPath: $0.folder) }) {
                if let library = libraries.sorted(by: { $0.folder.count > $1.folder.count }).first(where: { LocalSyncPath.relative(url, within: URL(fileURLWithPath: $0.folder)) != nil }),
                   let path = LocalSyncPath.relative(url, within: URL(fileURLWithPath: library.folder)) {
                    statuses[url.path] = try await SyncController.shared.pathStatus(library: library, path: path, directory: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                }
            }
            try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: ["updated": Date().timeIntervalSince1970, "roots": libraries.map(\.folder), "statuses": statuses])
            let file = stateFolder.appendingPathComponent("state.json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* A Finder badge failure must not stop syncing or files. */ }
    }
    func handle(_ url: URL, model: AppModel) async {
        NSApp.activate(ignoringOtherApps: true)
        do {
            let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let action = fields.first { $0.name == "action" }?.value ?? "open"
            guard let path = fields.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return }
            let file = URL(fileURLWithPath: path)
            guard let library = SyncController.shared.libraries.sorted(by: { $0.folder.count > $1.folder.count }).first(where: { LocalSyncPath.relative(file, within: URL(fileURLWithPath: $0.folder)) != nil }),
                  let relative = LocalSyncPath.relative(file, within: URL(fileURLWithPath: library.folder)) else { throw SeafileError.local("This file is outside the synced libraries.") }
            let account = try await SyncController.shared.account(for: library, accounts: model.accounts)
            let api = try model.client(for: account)
            guard let repo = try await api.repositories().first(where: { $0.id == library.id }) else { throw SeafileError.local("This library is no longer available.") }
            let directory = (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            switch action {
            case "sync": try await SyncController.shared.syncNow(library)
            case "share": model.finderShare = FinderShareRequest(account: account, repo: repo, path: relative, directory: directory)
            case "history":
                guard !directory else { throw SeafileError.local("Select a file to open its history.") }
                var history = URLComponents(); history.path = account.endpoint.url.path + "repo/file_revisions/" + repo.id + "/"
                history.queryItems = [.init(name: "p", value: relative)]
                NSWorkspace.shared.open(try await api.authenticatedWebURL(next: history.string!))
            case "lock", "unlock", "lock-info":
                guard !directory else { throw SeafileError.local("Select a file to change its lock.") }
                let parent = (relative as NSString).deletingLastPathComponent
                guard let entry = try await api.directory(repo: repo.id, path: parent).first(where: { $0.name == file.lastPathComponent }) else { throw SeafileError.local("This file is not available on the server yet.") }
                if action == "lock-info" { model.errorMessage = entry.lockOwner ?? (entry.locked ? "Locked" : "This file is not locked."); return }
                guard repo.writable, !entry.locked || entry.lockedByMe else { throw SeafileError.local("This file is locked by another user or is read only.") }
                let confirmation = NSAlert(); confirmation.messageText = action == "lock" ? "Lock this file?" : "Unlock this file?"
                confirmation.informativeText = file.lastPathComponent
                confirmation.addButton(withTitle: action == "lock" ? "Lock" : "Unlock"); confirmation.addButton(withTitle: "Cancel")
                guard confirmation.runModal() == .alertFirstButtonReturn else { return }
                try await api.lock(repo: repo.id, path: relative, locked: action == "lock")
                try await SyncController.shared.markLock(library: library, path: relative, locked: action == "lock")
            case "open":
                model.select(account)
                model.location = BrowserLocation(account: account, repo: repo, path: directory ? relative : (relative as NSString).deletingLastPathComponent, filename: directory ? nil : file.lastPathComponent)
            default: throw SeafileError.local("This Finder action is unavailable.")
            }
        } catch { model.errorMessage = error.localizedDescription }
    }
}
#endif

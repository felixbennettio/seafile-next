import SwiftUI
import SeafileCore
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)

@MainActor @Observable final class MacFileClipboard {
    static let shared = MacFileClipboard()
    var accountID: UUID?
    var repo: Repository?
    var parent = "/"
    var entries: [DirectoryEntry] = []
    var cut = false
    func store(account: ServerAccount, repo: Repository, parent: String, entries: [DirectoryEntry], cut: Bool) {
        guard !repo.encrypted else { return }
        self.accountID = account.id; self.repo = repo; self.parent = parent; self.entries = entries; self.cut = cut
    }
    func clear() { accountID = nil; repo = nil; entries = [] }
}

#endif

struct ShareManagementSheet: View {
    var model: AppModel
    let account: ServerAccount, repo: Repository
    let path: String
    let directory: Bool
    @State private var password = ""
    @State private var expires = false
    @State private var expiration = Date().addingTimeInterval(7 * 86400)
    @State private var url: URL?
    @State private var shares: [PrivateShare] = []
    @State private var contacts: SharingDirectory?
    @State private var recipient = ""
    @State private var group = 0
    @State private var permission = "rw"
    @State private var working = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Share link") {
                    Text(path).textSelection(.enabled)
                    ActionInput("Password (optional)") { SecureField("Link password", text: $password).labelsHidden().accessibilityIdentifier("share.password") }
                    Toggle("Expires", isOn: $expires).accessibilityIdentifier("share.expires")
                    if expires { DatePicker("Expiration", selection: $expiration, in: Date()...) }
                    Button("Create download link") { run { url = try await model.client(for: account).shareLink(repo: repo.id, path: path, password: password, expires: expires ? expiration : nil) } }
                    if directory { Button("Create upload link") { run { url = try await model.client(for: account).uploadLink(repo: repo.id, path: path, password: password) } } }
                    Button("Get internal link") { run { url = try await model.client(for: account).internalLink(repo: repo.id, path: path, directory: directory) } }
                    #if os(macOS)
                    Button("Copy local file link") {
                        var link = URLComponents(); link.scheme = "seafile"; link.host = "openfile"
                        link.queryItems = [.init(name: "repo_id", value: repo.id), .init(name: "path", value: path)]
                        if let value = link.url { copy(value); message = "Link copied." }
                    }
                    #endif
                    if let url {
                        Text(verbatim: url.absoluteString).textSelection(.enabled).accessibilityIdentifier("share.result")
                        HStack { Button("Copy link") { copy(url); message = "Link copied." }; ShareLink(item: url) }
                    }
                }
                if directory {
                    Section("Share with people or groups") {
                        ActionInput("Email") { TextField("Email", text: $recipient).labelsHidden() }
                        if let contacts {
                            Picker("Contact", selection: $recipient) {
                                Text("Enter an email").tag("")
                                ForEach(contacts.contacts) { user in Text(user.name ?? user.email).tag(user.email) }
                            }
                            Picker("Group", selection: $group) {
                                Text("Share with a person").tag(0)
                                ForEach(contacts.groups) { value in Text(value.name).tag(value.id) }
                            }
                        }
                        Picker("Permission", selection: $permission) { Text("Read and write").tag("rw"); Text("Read only").tag("r") }
                        Button("Add share") {
                            run {
                                try await model.client(for: account).setPrivateShare(repo: repo.id, path: path, user: group == 0 ? recipient : nil, group: group == 0 ? nil : group, permission: permission)
                                await loadShares()
                            }
                        }.disabled(group == 0 && recipient.isEmpty)
                        ForEach(shares) { share in
                            HStack {
                                Text(share.name); Spacer()
                                Menu(share.permission == "rw" ? "Read and write" : "Read only") {
                                    Button("Read and write") { change(share, permission: "rw") }
                                    Button("Read only") { change(share, permission: "r") }
                                    Button("Remove share", role: .destructive) { change(share, operation: "remove") }
                                }
                            }
                        }
                    }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
                if working { ProgressView() }
            }.formStyle(.grouped).navigationTitle("Share")
                .toolbar { Button("Done") { dismiss() } }
                .disabled(working)
        }
        #if os(macOS)
        .frame(width: 570, height: 640)
        #endif
        .interactiveDismissDisabled(working)
        .task { if directory { await loadShares() } }
    }
    private func copy(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true; message = nil
        model.beginFileAction(account)
        Task { defer { working = false; model.endFileAction(account) }; do { try await operation() } catch { message = error.localizedDescription } }
    }
    private func loadShares() async {
        do {
            let api = try model.client(for: account)
            shares = try await api.privateShares(repo: repo.id, path: path)
            contacts = try await api.sharingDirectory()
        } catch { message = error.localizedDescription }
    }
    private func change(_ share: PrivateShare, permission: String = "rw", operation: String = "update") {
        run {
            try await model.client(for: account).setPrivateShare(repo: repo.id, path: path, user: share.user_info?.name, group: share.group_info?.id, permission: permission, operation: operation)
            await loadShares()
        }
    }
}

struct FileActionRequest: Identifiable {
    let id = UUID()
    let entries: [DirectoryEntry]
    let move: Bool
}
struct ShareActionRequest: Identifiable {
    let id = UUID()
    let path: String, directory: Bool
}

private struct ActionInput<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content.multilineTextAlignment(.leading).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
    }
}

struct FileDestinationSheet: View {
    var model: AppModel
    let account: ServerAccount, source: Repository
    let sourcePath: String
    let request: FileActionRequest
    let finished: () -> Void
    @State private var repoID = ""
    @State private var path = "/"
    @State private var folders: [DirectoryEntry] = []
    @State private var working = false
    @State private var error: String?
    @State private var folderError: String?
    @State private var folderLoading = false
    @State private var recent: [RecentDirectory] = []
    @State private var recentError: String?
    @State private var completed: Set<String> = []
    @State private var began = false
    @State private var checkedDestination = false
    @State private var stopRequested = false
    @State private var currentItem: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Library", selection: Binding(get: { repoID }, set: { repoID = $0; path = "/" })) {
                        ForEach(model.repositories.filter { $0.writable && !$0.encrypted }) { repository in Text(repository.name).tag(repository.id) }
                    }.disabled(began)
                    HStack {
                        Button("Parent folder", systemImage: "arrow.up") { path = parent(path) }.disabled(path == "/" || began)
                        Text(path).textSelection(.enabled)
                    }
                }
                if !recent.isEmpty && !began {
                    Section("Recent folders") {
                        ForEach(recent.filter { item in model.repositories.contains { $0.id == item.repoID && $0.writable && !$0.encrypted } }) { item in
                            Button { repoID = item.repoID; path = item.path } label: {
                                Label((model.repositories.first { $0.id == item.repoID }?.name ?? "") + " · " + item.path, systemImage: "clock")
                            }.disabled(!RemoteDirectoryPath.allowsDestination(sourceRepo: source.id, sourceParent: sourcePath, entries: request.entries, destinationRepo: item.repoID, destinationPath: item.path))
                        }
                    }
                }
                Section("Folders") {
                    ForEach(folders) { folder in
                        Button { path = folder.path(in: path) } label: { Label(folder.name, systemImage: "folder") }
                            .disabled(began || invalid(folder.path(in: path)))
                    }
                    if folderLoading { ProgressView("Loading folders") }
                    if let folderError { Text(folderError).foregroundStyle(.red) }
                }
                Section {
                    if let recentError { Text("Recent folders could not be saved: \(recentError)").font(.caption).foregroundStyle(.secondary) }
                    if began { Text("Completed \(completed.count) of \(request.entries.count)") }
                    if let currentItem { ProgressView(currentItem) }
                    if working { Button("Stop after this item") { stopRequested = true }.disabled(stopRequested) }
                    if let error {
                        Text(error).foregroundStyle(.red)
                        Text("The last item may still finish on the server. Check the destination before retrying; completed items will be kept.").font(.callout)
                        Toggle("I checked the destination and want to retry the remaining items", isOn: $checkedDestination).accessibilityIdentifier("destination.checked")
                    }
                }
            }.navigationTitle(request.move ? "Move to" : "Copy to")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(request.move ? "Move here" : "Copy here") { Task { await perform() } }
                            .disabled(working || folderLoading || folderError != nil || repoID.isEmpty || invalid(path) || (error != nil && !checkedDestination))
                            .accessibilityIdentifier("destination.perform")
                    }
                }
        }
        #if os(macOS)
        .frame(width: 570, height: 600)
        #endif
        .interactiveDismissDisabled(working)
        .task {
            repoID = model.repositories.first(where: { $0.id == source.id && $0.writable && !$0.encrypted })?.id ?? model.repositories.first(where: { $0.writable && !$0.encrypted })?.id ?? ""
            do { recent = await (try model.recentDirectories.get()).directories(for: account.id) }
            catch let caught { recentError = caught.localizedDescription }
        }
        .task(id: repoID + path) { await load() }
    }
    private func parent(_ path: String) -> String { let value = (path as NSString).deletingLastPathComponent; return value.isEmpty ? "/" : value }
    private func invalid(_ candidate: String) -> Bool {
        !RemoteDirectoryPath.allowsDestination(sourceRepo: source.id, sourceParent: sourcePath, entries: request.entries, destinationRepo: repoID, destinationPath: candidate)
    }
    private func load() async {
        guard !repoID.isEmpty else { return }
        let requestedRepo = repoID, requestedPath = path
        folderLoading = true; folderError = nil; folders = []
        defer { if repoID == requestedRepo && path == requestedPath { folderLoading = false } }
        do {
            let result = try await model.client(for: account).directory(repo: requestedRepo, path: requestedPath).filter(\.isDirectory)
            try Task.checkCancellation()
            guard repoID == requestedRepo, path == requestedPath else { return }
            folders = result
        } catch is CancellationError { }
        catch let caught { if repoID == requestedRepo && path == requestedPath { folderError = caught.localizedDescription } }
    }
    private func perform() async {
        guard !working, !invalid(path), error == nil || checkedDestination else { return }
        working = true; began = true; stopRequested = false; error = nil; checkedDestination = false
        model.beginFileAction(account)
        defer { working = false; currentItem = nil; model.endFileAction(account) }
        do {
            let api = try model.client(for: account)
            for entry in request.entries where !completed.contains(entry.id) {
                if stopRequested { break }
                currentItem = entry.name
                try await api.copyMove(repo: source.id, parent: sourcePath, entry: entry, destinationRepo: repoID, destinationPath: path, move: request.move)
                completed.insert(entry.id)
            }
            if !completed.isEmpty {
                do { try await (try model.recentDirectories.get()).record(account: account.id, repo: repoID, path: path) }
                catch let caught { recentError = caught.localizedDescription }
            }
            if stopRequested && completed.count != request.entries.count { finished(); return }
            finished(); dismiss()
        } catch { self.error = error.localizedDescription; finished() }
    }
}

struct BatchDeleteSheet: View {
    var model: AppModel
    let account: ServerAccount, repo: Repository
    let parent: String
    let entries: [DirectoryEntry]
    let finished: () -> Void
    @State private var working = false
    @State private var completed: Set<String> = []
    @State private var current: String?
    @State private var error: String?
    @State private var checked = false
    @State private var stopRequested = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("The selected items will be moved to library trash on the server.")
                Text("Completed \(completed.count) of \(entries.count)")
                ForEach(entries.filter { !completed.contains($0.id) }) { Label($0.name, systemImage: $0.isDirectory ? "folder" : "doc") }
                if let current { ProgressView(current) }
                if working { Button("Stop after this item") { stopRequested = true }.disabled(stopRequested) }
                if let error {
                    Text(error).foregroundStyle(.red)
                    Text("The last deletion may already have completed. Refresh the library before retrying; confirmed deletions will not be repeated.")
                    Toggle("I checked the library and want to retry the remaining items", isOn: $checked)
                }
            }.navigationTitle("Delete selected items")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Delete", role: .destructive) { Task { await perform() } }.disabled(working || (error != nil && !checked))
                            .accessibilityIdentifier("batch.deleteConfirm")
                    }
                }
        }
        #if os(macOS)
        .frame(width: 520, height: 500)
        #endif
        .interactiveDismissDisabled(working)
    }
    private func perform() async {
        guard !working, error == nil || checked else { return }
        working = true; error = nil; checked = false; stopRequested = false
        model.beginFileAction(account)
        defer { working = false; current = nil; model.endFileAction(account); finished() }
        do {
            let api = try model.client(for: account)
            for entry in entries where !completed.contains(entry.id) {
                if stopRequested { return }
                current = entry.name
                try await api.delete(repo: repo.id, path: entry.path(in: parent), isDirectory: entry.isDirectory)
                completed.insert(entry.id)
            }
            dismiss()
        } catch let caught { error = caught.localizedDescription }
    }
}

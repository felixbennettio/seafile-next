#if os(macOS)
import SwiftUI
import AppKit
import SeafileCore

struct MacShareSheet: View {
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
                    PreferenceInput("Password (optional)") { SecureField("Link password", text: $password).labelsHidden() }
                    Toggle("Expires", isOn: $expires)
                    if expires { DatePicker("Expiration", selection: $expiration, in: Date()...) }
                    Button("Create download link") { run { url = try await model.client(for: account).shareLink(repo: repo.id, path: path, password: password, expires: expires ? expiration : nil) } }
                    if directory { Button("Create upload link") { run { url = try await model.client(for: account).uploadLink(repo: repo.id, path: path, password: password) } } }
                    Button("Get internal link") { run { url = try await model.client(for: account).internalLink(repo: repo.id, path: path, directory: directory) } }
                    Button("Copy local file link") {
                        var link = URLComponents(); link.scheme = "seafile"; link.host = "openfile"
                        link.queryItems = [.init(name: "repo_id", value: repo.id), .init(name: "path", value: path)]
                        if let value = link.url { copy(value); message = "Link copied." }
                    }
                    if let url {
                        Text(verbatim: url.absoluteString).textSelection(.enabled)
                        HStack { Button("Copy link") { copy(url); message = "Link copied." }; ShareLink(item: url) }
                    }
                }
                if directory {
                    Section("Share with people or groups") {
                        PreferenceInput("Email") { TextField("Email", text: $recipient).labelsHidden() }
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
        }.frame(width: 570, height: 640).task { if directory { await loadShares() } }
    }
    private func copy(_ url: URL) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true; message = nil
        Task { defer { working = false }; do { try await operation() } catch { message = error.localizedDescription } }
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.move ? "Move to" : "Copy to").font(.title2)
            Picker("Library", selection: $repoID) {
                ForEach(model.repositories.filter { $0.writable && !$0.encrypted }) { repository in Text(repository.name).tag(repository.id) }
            }.onChange(of: repoID) { _, _ in path = "/" }
            HStack {
                Button("Parent folder", systemImage: "arrow.up") { path = parent(path) }.disabled(path == "/")
                Text(path).textSelection(.enabled)
            }
            List(folders) { folder in
                Button { path = folder.path(in: path) } label: { Label(folder.name, systemImage: "folder") }
                    .disabled(invalid(folder.path(in: path)))
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(working)
                Spacer()
                if working { ProgressView() }
                Button(request.move ? "Move here" : "Copy here") { Task { await perform() } }
                    .disabled(working || repoID.isEmpty || invalid(path) || (repoID == source.id && path == sourcePath))
            }
        }.padding(24).frame(width: 530, height: 480)
            .onAppear { repoID = model.repositories.first(where: { $0.id == source.id && !$0.encrypted })?.id ?? model.repositories.first(where: { $0.writable && !$0.encrypted })?.id ?? "" }
            .task(id: repoID + path) { await load() }
    }
    private func parent(_ path: String) -> String { let value = (path as NSString).deletingLastPathComponent; return value.isEmpty ? "/" : value }
    private func invalid(_ candidate: String) -> Bool {
        guard repoID == source.id else { return false }
        return request.entries.contains { entry in
            let value = entry.path(in: sourcePath)
            return entry.isDirectory && (candidate == value || candidate.hasPrefix(value + "/"))
        }
    }
    private func load() async {
        guard !repoID.isEmpty else { return }
        do { folders = try await model.client(for: account).directory(repo: repoID, path: path).filter(\.isDirectory); error = nil }
        catch { self.error = error.localizedDescription; folders = [] }
    }
    private func perform() async {
        working = true; error = nil
        defer { working = false }
        do {
            let api = try model.client(for: account)
            for entry in request.entries { try await api.copyMove(repo: source.id, parent: sourcePath, entry: entry, destinationRepo: repoID, destinationPath: path, move: request.move) }
            finished(); dismiss()
        } catch { self.error = error.localizedDescription; finished() }
    }
}
#endif

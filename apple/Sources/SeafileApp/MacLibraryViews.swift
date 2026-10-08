#if os(macOS)
import SwiftUI
import AppKit
import SeafileCore

struct ServerSearchView: View {
    var model: AppModel
    let account: ServerAccount
    var repo: Repository? = nil
    @State private var query = ""
    @State private var results: [FileSearchItem] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(results) { result in
                if let repository = model.repositories.first(where: { $0.id == result.repo_id }) {
                    NavigationLink {
                        RepositoryView(model: model, account: account, repo: repository,
                            path: result.is_dir ? result.fullpath : (result.fullpath as NSString).deletingLastPathComponent)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(result.name, systemImage: result.is_dir ? "folder" : "doc")
                            Text(repository.name + " · " + result.fullpath).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if more { Button("Load more") { Task { await search(next: true) } }.disabled(loading) }
        }.navigationTitle(repo.map { "Search in \($0.name)" } ?? "Search server")
            .searchable(text: $query, prompt: "Search files and folders")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar { Button("Search", systemImage: "magnifyingglass") { Task { await search() } }.disabled(query.isEmpty || loading) }
            .overlay { if loading { ProgressView() } }
    }
    private func search(next: Bool = false) async {
        guard !loading, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let requestedPage = next ? page + 1 : 1
            let response = try await model.client(for: account).search(query, repo: repo?.id, page: requestedPage)
            if next { results += response.results.filter { item in !results.contains { $0.id == item.id } } }
            else { results = response.results }
            page = requestedPage; more = response.has_more
        } catch { self.error = error.localizedDescription }
    }
}

struct ServerActivityView: View {
    var model: AppModel
    let account: ServerAccount
    @State private var events: [RemoteActivity] = []
    @State private var page = 0
    @State private var loading = false
    @State private var more = true
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(events) { event in
                NavigationLink { CommitChangesView(model: model, account: account, event: event) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.repo_name).font(.headline)
                        Text(event.op_type + (event.name.map { " · " + $0 } ?? ""))
                        Text((event.author_name ?? "") + " · " + event.time).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if more { Button("Load more") { Task { await load() } }.disabled(loading) }
        }.navigationTitle("Activity").task { if page == 0 { await load() } }
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(reset: true) } }.disabled(loading) }
            .overlay { if loading { ProgressView() } }
    }
    private func load(reset: Bool = false) async {
        guard !loading else { return }; loading = true
        defer { loading = false }
        do {
            let requestedPage = reset ? 1 : page + 1
            let response = try await model.client(for: account).activities(page: requestedPage)
            if reset { events = response } else { events += response.filter { event in !events.contains { $0.id == event.id } } }
            page = requestedPage; more = !response.isEmpty; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct CommitChangesView: View {
    var model: AppModel
    let account: ServerAccount
    let event: RemoteActivity
    @State private var changes: [(String, String)] = []
    @State private var error: String?
    var body: some View {
        List {
            Text(event.repo_name).font(.headline)
            Text(event.op_type + " · " + event.time)
            if let repository = model.repositories.first(where: { $0.id == event.repo_id }) {
                NavigationLink("Open library") { RepositoryView(model: model, account: account, repo: repository) }
            }
            ForEach(Array(changes.enumerated()), id: \.offset) { item in
                VStack(alignment: .leading) { Text(item.element.0).font(.caption).foregroundStyle(.secondary); Text(item.element.1).textSelection(.enabled) }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }.navigationTitle("Change details").task {
            guard let commit = event.commit_id, !commit.isEmpty else { return }
            do { changes = try await model.client(for: account).commitChanges(repo: event.repo_id, commit: commit).items }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct CreateLibrarySheet: View {
    var model: AppModel
    let account: ServerAccount
    @State private var name = ""
    @State private var description = ""
    @State private var encrypted = false
    @State private var password = ""
    @State private var repeatedPassword = ""
    @State private var localFolder: URL?
    @State private var importing = false
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                PreferenceInput("Name") { TextField("Library name", text: $name).labelsHidden() }
                PreferenceInput("Description") { TextField("Library description", text: $description).labelsHidden() }
                Toggle("Encrypted library", isOn: $encrypted)
                if encrypted {
                    PreferenceInput("Library password") { SecureField("Library password", text: $password).labelsHidden() }
                    PreferenceInput("Repeat password") { SecureField("Repeat password", text: $repeatedPassword).labelsHidden() }
                    Text("The encryption keys are generated on this Mac. Keep the password safe; it cannot be recovered.").font(.caption).foregroundStyle(.secondary)
                }
                Button(localFolder.map { "Sync folder: \($0.path)" } ?? "Create from an existing local folder") { importing = true }
                if localFolder != nil { Button("Create without a local folder") { localFolder = nil } }
                if let error { Text(error).foregroundStyle(.red) }
                if working { ProgressView("Creating library") }
            }.formStyle(.grouped).navigationTitle("New library")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await create() } }.disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (encrypted && (password.isEmpty || password != repeatedPassword))) }
                }
        }.frame(width: 520, height: 510)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                switch result { case .success(let folder): localFolder = folder; if name.isEmpty { name = folder.lastPathComponent }; case .failure(let error): self.error = error.localizedDescription }
            }
    }
    private func create() async {
        working = true; error = nil
        defer { working = false }
        do {
            let api = try model.client(for: account)
            var fields: [String: String] = [:]
            if encrypted { fields = try await SyncController.shared.encryptionFields(api: api, password: password) }
            let id = try await api.createRepository(name: name, description: description, encryption: fields)
            await model.refresh()
            if let localFolder, let repo = model.repositories.first(where: { $0.id == id }) {
                try await SyncController.shared.clone(repo: repo, account: account, api: api, folder: localFolder, password: password, existing: true)
            }
            password = ""; repeatedPassword = ""; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

#endif

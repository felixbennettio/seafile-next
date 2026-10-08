import SwiftUI
import SeafileCore
import UniformTypeIdentifiers
import QuickLook

struct BrowserView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var showPreferences = false
    #if os(iOS)
    private enum Page: Hashable { case files, starred, accounts }
    @State private var page: Page = .files
    #endif
    var body: some View {
        browser
        .sheet(isPresented: $model.showLogin) { LoginView(model: model) }
        .sheet(isPresented: $showPreferences) { PreferencesView(model: model) }
        #if os(macOS)
        .sheet(item: Binding(get: { SyncController.shared.deletionConfirmations.first }, set: { _ in })) { confirmation in
            SyncDeletionSheet(model: model, confirmation: confirmation)
        }
        #endif
        .alert("seafile-next", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .task { await model.restoreFileIntegration() }
        #if os(macOS)
        .task {
            #if DEBUG
            if model.uiFixture != nil { return }
            #endif
            SyncController.shared.use(account: model.account)
            await SyncController.shared.start()
        }
        #else
        .onChange(of: model.showLogin) { _, presented in
            if !presented, model.account != nil { page = .files }
        }
        #endif
    }

    @ViewBuilder private var browser: some View {
        #if os(iOS)
        TabView(selection: $page) {
            Tab("Files", systemImage: "folder", value: Page.files) {
                NavigationStack { fileRoot.toolbar { settingsButton } }.id(model.selectedAccountID)
            }
            Tab("Starred", systemImage: "star", value: Page.starred) {
                NavigationStack {
                    if let account = model.account { StarredView(model: model, account: account).id(account.id) }
                    else { accountPlaceholder }
                }.id(model.selectedAccountID)
            }
            Tab("Accounts", systemImage: "person.crop.circle", value: Page.accounts) {
                NavigationStack {
                    List { accountsSection { account in model.select(account); page = .files } }
                        .navigationTitle("Accounts").toolbar { settingsButton }
                }
            }
        }.tabViewStyle(.sidebarAdaptable)
        #else
        NavigationSplitView {
            List {
                accountsSection { model.select($0) }
                if let account = model.account {
                    Section {
                        NavigationLink { RepositoryList(model: model, account: account).id(account.id) } label: { Label("Libraries", systemImage: "folder") }
                        NavigationLink { StarredView(model: model, account: account) } label: { Label("Starred", systemImage: "star") }
                        NavigationLink { SyncView(model: model) } label: { Label("Sync status", systemImage: "arrow.triangle.2.circlepath") }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
            .navigationTitle("seafile-next")
            .toolbar { settingsButton }
        } detail: {
            NavigationStack { fileRoot }.id(model.selectedAccountID)
        }
        #endif
    }

    @ViewBuilder private var fileRoot: some View {
        if let account = model.account { RepositoryList(model: model, account: account).id(account.id) }
        else { accountPlaceholder }
    }

    private var accountPlaceholder: some View {
        ContentUnavailableView {
            Label("Your files, connected", systemImage: "externaldrive.badge.icloud")
        } description: { Text("Connect your Seafile server to browse your libraries.") }
        actions: { Button("Add account") { model.showLogin = true }.buttonStyle(.borderedProminent) }
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") { showPreferences = true }
    }

    private func accountsSection(select: @escaping (ServerAccount) -> Void) -> some View {
        Section("Accounts") {
            ForEach(model.accounts) { account in
                Button { select(account) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name).font(.headline)
                            Text(account.endpoint.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if account.id == model.selectedAccountID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("account.\(account.email)")
            }
            Button("Add account", systemImage: "plus") { model.showLogin = true }.accessibilityIdentifier("account.add")
        }
    }
}

struct RepositoryList: View {
    var model: AppModel
    let account: ServerAccount
    @Environment(\.scenePhase) private var phase
    @State private var search = ""
    var body: some View {
        List {
            if let error = model.listingError { Text(error).font(.callout).foregroundStyle(.secondary) }
            ForEach(model.repositories.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { repo in
                NavigationLink {
                    RepositoryView(model: model, account: account, repo: repo)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: repo.encrypted ? "lock.rectangle.stack" : "externaldrive").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(repo.name).font(.headline)
                            Text(ByteCountFormatter.string(fromByteCount: repo.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !repo.writable { Image(systemName: "eye").foregroundStyle(.secondary).help("Read only") }
                    }.padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("Libraries")
        .searchable(text: $search, prompt: "Find a library")
        .overlay {
            if model.repositories.isEmpty {
                if model.loading { ProgressView("Loading libraries") }
                else if let error = model.listingError {
                    ContentUnavailableView { Label("Could not load libraries", systemImage: "wifi.exclamationmark") }
                    description: { Text(error) }
                    actions: { Button("Try again") { Task { await model.refresh() } } }
                } else { ContentUnavailableView("No libraries", systemImage: "externaldrive") }
            }
        }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.loading) }
        .refreshable { await model.refresh() }
        .task(id: phase) {
            guard phase == .active else { return }
            repeat {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
    }
}

struct RepositoryView: View {
    var model: AppModel
    let account: ServerAccount
    let repo: Repository
    var path: String = "/"
    @State private var unlocked = false
    @State private var password = ""
    @State private var unlocking = false
    @State private var error: String?
    var body: some View {
        if !repo.encrypted || unlocked {
            DirectoryView(model: model, account: account, repo: repo, path: path)
        } else {
            Form {
                Section {
                    Label(repo.name, systemImage: "lock.rectangle.stack").font(.title2)
                    SecureField("Library password", text: $password)
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("Unlock") {
                        unlocking = true
                        Task {
                            do { try await model.client(for: account).unlock(repo: repo.id, password: password); password = ""; unlocked = true }
                            catch { self.error = error.localizedDescription }
                            unlocking = false
                        }
                    }.disabled(password.isEmpty || unlocking)
                }
            }.formStyle(.grouped).navigationTitle(repo.name)
        }
    }
}

private struct FilePrompt: Identifiable {
    let id = UUID()
    var entry: DirectoryEntry?
}

struct DirectoryView: View {
    var model: AppModel
    let account: ServerAccount
    let repo: Repository
    let path: String
    @State private var state = DirectoryModel()
    @State private var query = ""
    @State private var preview: URL?
    @State private var shareURL: URL?
    @State private var prompt: FilePrompt?
    @State private var deleteEntry: DirectoryEntry?
    @State private var showImport = false
    @State private var operation: Task<Void, Never>?
    @State private var operationLabel: String?
    @Environment(\.scenePhase) private var phase
    var title: String { path == "/" ? repo.name : (path as NSString).lastPathComponent }

    var body: some View {
        List {
            if let error = state.error { Text(error).foregroundStyle(.secondary).font(.callout) }
            ForEach(state.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { entry in
                Group {
                    if entry.isDirectory {
                        NavigationLink {
                            DirectoryView(model: model, account: account, repo: repo, path: entry.path(in: path))
                        } label: { row(entry) }
                    } else {
                        Button { download(entry) } label: { row(entry) }.buttonStyle(.plain)
                            .accessibilityIdentifier("file.\(entry.path(in: path))")
                    }
                }
                .contextMenu {
                    if !entry.isDirectory { Button("Open", systemImage: "doc") { download(entry) } }
                    Button("Create share link", systemImage: "square.and.arrow.up") {
                        run("Creating share link") { shareURL = try await model.client(for: account).shareLink(repo: repo.id, path: entry.path(in: path)) }
                    }
                    Button("Star", systemImage: "star") { run("Starring") { try await model.client(for: account).setStarred(repo: repo.id, path: entry.path(in: path), starred: true) } }
                    if repo.writable {
                        Button("Rename", systemImage: "pencil") { prompt = FilePrompt(entry: entry) }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteEntry = entry }
                    }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Find a file")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(state.loading)
            if repo.writable {
                Button("New folder", systemImage: "folder.badge.plus") { prompt = FilePrompt() }
                Button("Upload files", systemImage: "arrow.up.doc") { showImport = true }
            }
            #if os(macOS)
            Button("Sync library", systemImage: "arrow.triangle.2.circlepath") { SyncController.shared.showSync = repo }
            #endif
        }
        .overlay {
            if state.entries.isEmpty && state.error == nil {
                if state.loading { ProgressView() }
                else { ContentUnavailableView("Empty folder", systemImage: "folder") }
            }
            if let operationLabel {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(operationLabel)
                    Button("Cancel") { operation?.cancel() }
                }.padding(24).nextGlass()
            }
        }
        .refreshable { await refresh() }
        .task(id: phase) {
            guard phase == .active else { return }
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .quickLookPreview($preview)
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files):
                run("Uploading files") {
                    let api = try model.client(for: account)
                    for file in files {
                        try Task.checkCancellation()
                        let access = file.startAccessingSecurityScopedResource()
                        defer { if access { file.stopAccessingSecurityScopedResource() } }
                        try await api.upload(repo: repo.id, directory: path, file: file)
                    }
                    await refresh()
                }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $prompt) { prompt in
            NamePrompt(title: prompt.entry == nil ? "New folder" : "Rename", initial: prompt.entry?.name ?? "") { name in
                run(prompt.entry == nil ? "Creating folder" : "Renaming") {
                    let api = try model.client(for: account)
                    if let entry = prompt.entry { try await api.rename(repo: repo.id, path: entry.path(in: path), isDirectory: entry.isDirectory, to: name) }
                    else { try await api.createDirectory(repo: repo.id, path: (path.hasSuffix("/") ? path : path + "/") + name) }
                    await refresh()
                }
            }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { ShareLink(item: shareURL) { Label("Share link", systemImage: "square.and.arrow.up") }.padding(40) }
        }
        .confirmationDialog("Delete \(deleteEntry?.name ?? "")?", isPresented: Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let entry = deleteEntry else { return }
                run("Deleting") { try await model.client(for: account).delete(repo: repo.id, path: entry.path(in: path), isDirectory: entry.isDirectory); await refresh() }
            }
        } message: { Text("The server will move this item to library trash.") }
        .onDisappear { operation?.cancel() }
        #if os(macOS)
        .sheet(item: Binding(get: { SyncController.shared.showSync }, set: { SyncController.shared.showSync = $0 })) { library in
            SyncLibrarySheet(model: model, account: account, repo: library)
        }
        #endif
    }

    private func row(_ entry: DirectoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? .blue : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).foregroundStyle(.primary)
                if !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let mtime = entry.mtime { Text(Date(timeIntervalSince1970: mtime), style: .date).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4).contentShape(Rectangle())
    }

    private func refresh() async {
        do { await state.refresh(api: try model.client(for: account), account: account, repo: repo.id, path: path) }
        catch { state.error = error.localizedDescription }
    }

    private func run(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard operationLabel == nil else { return }
        operationLabel = label
        operation = Task {
            defer { operationLabel = nil; operation = nil }
            do { try await action() }
            catch { if !Task.isCancelled { model.errorMessage = error.localizedDescription } }
        }
    }

    private func download(_ entry: DirectoryEntry) {
        let fullPath = entry.path(in: path)
        let destination = LocalFiles.cacheURL(account: account, repo: repo.id, path: fullPath)
        run("Downloading \(entry.name)") {
            do { try await model.client(for: account).download(repo: repo.id, path: fullPath, destination: destination) }
            catch {
                guard !Task.isCancelled, FileManager.default.fileExists(atPath: destination.path) else { throw error }
                state.error = "Showing the cached copy. \(error.localizedDescription)"
            }
            if !Task.isCancelled { preview = destination }
        }
    }
}

struct NamePrompt: View {
    let title: String
    let action: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    init(title: String, initial: String, action: @escaping (String) -> Void) { self.title = title; self.action = action; _name = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            Form { TextField("Name", text: $name) }.formStyle(.grouped).navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { action(name); dismiss() }.disabled(name.isEmpty || name == "." || name == ".." || name.contains("/"))
                    }
                }
        }.frame(minWidth: 300, minHeight: 180)
    }
}

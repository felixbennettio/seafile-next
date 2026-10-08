import SwiftUI
import SeafileCore
import UniformTypeIdentifiers
import QuickLook
#if os(macOS)
import AppKit
#endif

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
        .onOpenURL { url in Task { await model.openLocalLink(url) } }
        .sheet(item: $model.location) { location in NavigationStack { RepositoryView(model: model, account: location.account, repo: location.repo, path: location.path, initialFile: location.filename) }.frame(minWidth: 680, minHeight: 480) }
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
            MacFileEditor.shared.start(model: model)
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
                        NavigationLink { ServerSearchView(model: model, account: account) } label: { Label("Search server", systemImage: "magnifyingglass") }
                        NavigationLink { ServerActivityView(model: model, account: account) } label: { Label("Activity", systemImage: "clock") }
                        NavigationLink { EditedFilesView() } label: { Label("Edited files", systemImage: "pencil.and.outline") }
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
        Button("Settings", systemImage: "gearshape") { showPreferences = true }.accessibilityIdentifier("settings.open")
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
    #if os(macOS)
    @State private var createLibrary = false
    @State private var shareLibrary: Repository?
    @State private var detailLibrary: Repository?
    @State private var leaveLibrary: Repository?
    @State private var sortByDate = DesktopPreferences.load().sortLibrariesByModification
    #endif
    private var filtered: [Repository] {
        model.repositories.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted {
            #if os(macOS)
            if sortByDate, $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            #endif
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        List {
            if let error = model.listingError { Text(error).font(.callout).foregroundStyle(.secondary) }
            #if os(macOS)
            ForEach([("repo", "My libraries"), ("srepo", "Shared with me"), ("grepo", "Group libraries")], id: \.0) { kind, title in
                Section(title) { ForEach(filtered.filter { $0.type == kind || (kind == "repo" && !["srepo", "grepo"].contains($0.type)) }) { repo in libraryRow(repo) } }
            }
            #else
            ForEach(filtered) { repo in libraryRow(repo) }
            #endif
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
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.loading)
            #if os(macOS)
            Button("New library", systemImage: "plus") { createLibrary = true }
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                Button("Name") { sortByDate = false; saveSort() }
                Button("Last modified") { sortByDate = true; saveSort() }
            }
            NavigationLink { ServerSearchView(model: model, account: account) } label: { Label("Search server", systemImage: "magnifyingglass") }
            #endif
        }
        .refreshable { await model.refresh() }
        .task(id: phase) {
            guard phase == .active else { return }
            repeat {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        #if os(macOS)
        .sheet(isPresented: $createLibrary) { CreateLibrarySheet(model: model, account: account) }
        .sheet(item: $shareLibrary) { repo in MacShareSheet(model: model, account: account, repo: repo, path: "/", directory: true) }
        .sheet(item: $detailLibrary) { repo in
            VStack(alignment: .leading, spacing: 12) {
                Text(repo.name).font(.title2); Text(repo.description ?? "")
                Text(repo.id).textSelection(.enabled); Text(repo.owner ?? account.email)
                Text(ByteCountFormatter.string(fromByteCount: repo.size, countStyle: .file))
                Text(repo.encrypted ? "Encrypted" : "Unencrypted"); Text(repo.writable ? "Read and write" : "Read only")
                Button("Done") { detailLibrary = nil }
            }.padding(24).frame(minWidth: 400)
        }
        .sheet(item: Binding(get: { SyncController.shared.showSync }, set: { SyncController.shared.showSync = $0 })) { library in SyncLibrarySheet(model: model, account: account, repo: library) }
        .confirmationDialog("Leave this shared library?", isPresented: Binding(get: { leaveLibrary != nil }, set: { if !$0 { leaveLibrary = nil } })) {
            Button("Leave library", role: .destructive) { if let repo = leaveLibrary { Task { do { try await model.client(for: account).leaveSharedRepository(repo: repo.id, owner: repo.owner ?? ""); await model.refresh() } catch { model.errorMessage = error.localizedDescription } } } }
        }
        #endif
    }
    #if os(macOS)
    private func saveSort() { var settings = DesktopPreferences.load(); settings.sortLibrariesByModification = sortByDate; try? settings.save() }
    #endif
    private func libraryRow(_ repo: Repository) -> some View {

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
                #if os(macOS)
                .contextMenu {
                    Button("Sync library") { SyncController.shared.showSync = repo }
                    Button("Share library") { shareLibrary = repo }
                    Button("Library details") { detailLibrary = repo }
                    Button("Open on server") { Task { do { NSWorkspace.shared.open(try await model.client(for: account).authenticatedWebURL(next: account.endpoint.url.path + "library/" + repo.id + "/")) } catch { model.errorMessage = error.localizedDescription } } }
                    if repo.type == "srepo", repo.owner != nil, repo.owner != account.email { Button("Leave shared library", role: .destructive) { leaveLibrary = repo } }
                }
                #endif
    }
}

struct RepositoryView: View {
    var model: AppModel
    let account: ServerAccount
    let repo: Repository
    var path: String = "/"
    var initialFile: String? = nil
    @State private var unlocked = false
    @State private var password = ""
    @State private var unlocking = false
    @State private var error: String?
    var body: some View {
        if !repo.encrypted || unlocked {
            DirectoryView(model: model, account: account, repo: repo, path: path, initialFile: initialFile)
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
    var initialFile: String? = nil
    @State private var openedInitialFile = false
    @State private var state = DirectoryModel()
    @State private var query = ""
    @State private var preview: URL?
    @State private var shareURL: URL?
    @State private var prompt: FilePrompt?
    @State private var deleteEntry: DirectoryEntry?
    @State private var showImport = false
    @State private var operation: Task<Void, Never>?
    @State private var operationLabel: String?
    @State private var selectedEntries: Set<String> = []
    #if os(macOS)
    @State private var fileAction: FileActionRequest?
    @State private var shareAction: ShareActionRequest?
    @State private var deleteSelection = false
    #endif
    @Environment(\.scenePhase) private var phase
    var title: String { path == "/" ? repo.name : (path as NSString).lastPathComponent }

    var body: some View {
        List(selection: $selectedEntries) {
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
                .tag(entry.id)
                .contextMenu {
                    if !entry.isDirectory { Button("Preview", systemImage: "doc") { download(entry) } }
                    #if os(macOS)
                    if !entry.isDirectory { Button("Open in default app") { run("Opening file") { try await MacFileEditor.shared.open(model: model, account: account, repo: repo, entry: entry, path: entry.path(in: path)) } } }
                    Button("Download / Save as") { saveAs(entry) }
                    Button("Copy") { MacFileClipboard.shared.store(account: account, repo: repo, parent: path, entries: [entry], cut: false) }
                    if repo.writable { Button("Cut") { MacFileClipboard.shared.store(account: account, repo: repo, parent: path, entries: [entry], cut: true) } }
                    Button("Copy to…") { fileAction = FileActionRequest(entries: [entry], move: false) }.disabled(repo.encrypted)
                    Button("Share…") { shareAction = ShareActionRequest(path: entry.path(in: path), directory: entry.isDirectory) }
                    if repo.writable {
                        Button("Move to…") { fileAction = FileActionRequest(entries: [entry], move: true) }.disabled(repo.encrypted)
                        if !entry.isDirectory {
                            Button(entry.lockedByMe ? "Unlock file" : "Lock file") { run("Updating file lock") { try await model.client(for: account).lock(repo: repo.id, path: entry.path(in: path), locked: !entry.lockedByMe); await refresh() } }.disabled(entry.locked && !entry.lockedByMe)
                        }
                        if entry.isDirectory { Button("Sync this folder") { syncSubfolder(entry) }.disabled(repo.encrypted) }
                    }
                    #endif
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
            NavigationLink { ServerSearchView(model: model, account: account, repo: repo) } label: { Label("Search library", systemImage: "magnifyingglass") }
            if !selectedEntries.isEmpty {
                Menu("Selected items") {
                    Button("Copy") { copySelected(cut: false) }.keyboardShortcut("c")
                    Button("Copy to…") { fileAction = FileActionRequest(entries: selected, move: false) }.disabled(repo.encrypted)
                    if repo.writable {
                        Button("Cut") { copySelected(cut: true) }.keyboardShortcut("x")
                        Button("Move to…") { fileAction = FileActionRequest(entries: selected, move: true) }.disabled(repo.encrypted)
                        Button("Delete selected items", role: .destructive) { deleteSelection = true }
                    }
                }
            }
            if repo.writable {
                Button("Paste", systemImage: "doc.on.clipboard") { paste() }.keyboardShortcut("v").disabled(MacFileClipboard.shared.accountID != account.id || repo.encrypted)
            }
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
                        try await api.uploadTree(repo: repo.id, directory: path, item: file)
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
        .sheet(item: $fileAction) { request in FileDestinationSheet(model: model, account: account, source: repo, sourcePath: path, request: request) { Task { await refresh() } } }
        .sheet(item: $shareAction) { request in MacShareSheet(model: model, account: account, repo: repo, path: request.path, directory: request.directory) }
        .confirmationDialog("Delete selected items?", isPresented: $deleteSelection) {
            Button("Delete selected items", role: .destructive) { let items = selected; run("Deleting items") { for entry in items { try await model.client(for: account).delete(repo: repo.id, path: entry.path(in: path), isDirectory: entry.isDirectory) }; selectedEntries = []; await refresh() } }
        }
        #endif
    }

    #if os(macOS)
    private var selected: [DirectoryEntry] { state.entries.filter { selectedEntries.contains($0.id) } }
    private func copySelected(cut: Bool) { MacFileClipboard.shared.store(account: account, repo: repo, parent: path, entries: selected, cut: cut) }
    private func paste() {
        guard let source = MacFileClipboard.shared.repo, MacFileClipboard.shared.accountID == account.id else { return }
        let parent = MacFileClipboard.shared.parent, items = MacFileClipboard.shared.entries, move = MacFileClipboard.shared.cut
        run(move ? "Moving items" : "Copying items") {
            let api = try model.client(for: account)
            guard source.id != repo.id || parent != path else { throw SeafileError.local("Choose a different destination folder.") }
            for entry in items { try await api.copyMove(repo: source.id, parent: parent, entry: entry, destinationRepo: repo.id, destinationPath: path, move: move) }
            if move { MacFileClipboard.shared.clear() }
            await refresh()
        }
    }
    private func saveAs(_ entry: DirectoryEntry) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name; panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            run("Downloading \(entry.name)") {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await model.client(for: account).downloadTree(repo: repo.id, path: entry.path(in: path), destination: url, directory: entry.isDirectory)
            }
        }
    }
    private func syncSubfolder(_ entry: DirectoryEntry) {
        run("Preparing folder sync") {
            let id = try await model.client(for: account).subfolderRepository(repo: repo.id, path: entry.path(in: path), name: entry.name)
            let value = try JSONDecoder().decode(Repository.self, from: JSONSerialization.data(withJSONObject: ["id": id, "name": entry.name, "permission": repo.permission, "type": "repo"]))
            SyncController.shared.showSync = value
        }
    }
    #endif

    private func row(_ entry: DirectoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? .blue : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).foregroundStyle(.primary)
                if !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if entry.locked { Image(systemName: "lock.fill").help(entry.lockOwner ?? "Locked") }
            if let mtime = entry.mtime { Text(Date(timeIntervalSince1970: mtime), style: .date).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4).contentShape(Rectangle())
    }

    private func refresh() async {
        do {
            await state.refresh(api: try model.client(for: account), account: account, repo: repo.id, path: path)
            if !openedInitialFile, let initialFile, let entry = state.entries.first(where: { $0.name == initialFile && !$0.isDirectory }) { openedInitialFile = true; download(entry) }
        }
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

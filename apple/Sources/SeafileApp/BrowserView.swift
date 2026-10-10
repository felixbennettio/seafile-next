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
    private enum Page: Hashable { case files, starred, transfers, accounts }
    @State private var page: Page = .files
    #endif
    var body: some View {
        browser
        .sheet(isPresented: $model.showLogin) { LoginView(model: model) }
        .sheet(isPresented: $showPreferences) { PreferencesView(model: model) }
        #if os(macOS)
        .sheet(isPresented: Binding(get: { MacUpdateController.shared.presented }, set: { MacUpdateController.shared.presented = $0 })) { MacUpdateView() }
        #if !APPSTORE
        .sheet(item: $model.finderShare) { share in ShareManagementSheet(model: model, account: share.account, repo: share.repo, path: share.path, directory: share.directory) }
        #endif
        .sheet(item: $model.location) { location in NavigationStack { RepositoryView(model: model, account: location.account, repo: location.repo, path: location.path, initialFile: location.filename) }.frame(minWidth: 680, minHeight: 480) }
        .sheet(item: Binding(get: { SyncController.shared.deletionConfirmations.first }, set: { _ in })) { confirmation in
            SyncDeletionSheet(model: model, confirmation: confirmation)
        }
        #endif
        .alert("seafile-next", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onAppear { Task { await model.restoreFileIntegration() } }
        #if os(macOS)
        .onAppear { Task {
            #if DEBUG
            if model.uiFixture != nil { return }
            #endif
            #if !APPSTORE
            MacFinderBridge.shared.start(model: model)
            #endif
            MacFileEditor.shared.start(model: model)
            SyncController.shared.use(account: model.account)
            await SyncController.shared.start()
        } }
        #else
        .onAppear { model.backgroundWork.sceneChanged(phase) }
        .onChange(of: phase) { _, value in model.backgroundWork.sceneChanged(value) }
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
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: Page.transfers) { NavigationStack { TransfersView(model: model) } }
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
                        NavigationLink { WikiView(model: model, account: account).id(account.id) } label: { Label("Wikis", systemImage: "book") }.accessibilityIdentifier("wiki.sidebar")
                        NavigationLink { MacServerStatusView(model: model) } label: { Label("Server status", systemImage: "network") }
                        NavigationLink { EditedFilesView() } label: { Label("Edited files", systemImage: "pencil.and.outline") }
                    }
                }
                NavigationLink { TransfersView(model: model) } label: { Label("Transfers", systemImage: "arrow.up.arrow.down") }.accessibilityIdentifier("transfers.sidebar")
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
    @State private var createLibrary = false
    @State private var shareLibrary: Repository?
    @State private var detailLibrary: Repository?
    @State private var leaveLibrary: Repository?
    @State private var deleteLibrary: Repository?
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @State private var syncInterval: SyncedLibrary?
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
            #else
            Menu("Browse", systemImage: "ellipsis.circle") {
                Button("New library", systemImage: "plus") { createLibrary = true }
                NavigationLink { ServerSearchView(model: model, account: account) } label: { Label("Search server", systemImage: "magnifyingglass") }
                NavigationLink { ServerActivityView(model: model, account: account) } label: { Label("Activity", systemImage: "clock") }
                NavigationLink { WikiView(model: model, account: account).id(account.id) } label: { Label("Wikis", systemImage: "book") }.accessibilityIdentifier("wiki.browse")
                NavigationLink { MobileDraftsView(model: model, account: account) } label: { Label("Text drafts", systemImage: "pencil.and.outline") }
            }.accessibilityIdentifier("libraries.browse")
            #endif
        }
        .refreshable { await model.refresh() }
        .onAppear { Task { await model.refresh() } }
        .task(id: phase) {
            guard phase == .active else { return }
            repeat {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        #if os(macOS)
        .sheet(item: $syncInterval) { library in SyncIntervalSheet(model: model, library: library) }
        .sheet(item: Binding(get: { SyncController.shared.showSync }, set: { SyncController.shared.showSync = $0 })) { library in SyncLibrarySheet(model: model, account: account, repo: library) }
        #endif
        .sheet(isPresented: $createLibrary) { CreateLibrarySheet(model: model, account: account) }
        .sheet(item: $shareLibrary) { repo in ShareManagementSheet(model: model, account: account, repo: repo, path: "/", directory: true) }
        .sheet(item: $detailLibrary) { repo in
            VStack(alignment: .leading, spacing: 12) {
                Text(repo.name).font(.title2); Text(repo.description ?? "")
                Text(repo.id).textSelection(.enabled); Text(repo.owner ?? account.email)
                Text(ByteCountFormatter.string(fromByteCount: repo.size, countStyle: .file))
                Text(repo.encrypted ? "Encrypted" : "Unencrypted"); Text(repo.writable ? "Read and write" : "Read only")
                Button("Done") { detailLibrary = nil }
            }.padding(24)
            #if os(macOS)
            .frame(minWidth: 400)
            #endif
        }
        .confirmationDialog("Leave this shared library?", isPresented: Binding(get: { leaveLibrary != nil }, set: { if !$0 { leaveLibrary = nil } })) {
            Button("Leave library", role: .destructive) { if let repo = leaveLibrary { Task { do { try await model.client(for: account).leaveSharedRepository(repo: repo.id, owner: repo.owner ?? ""); await model.refresh() } catch { model.errorMessage = error.localizedDescription } } } }
        }
        .confirmationDialog("Delete library \(deleteLibrary?.name ?? "")?", isPresented: Binding(get: { deleteLibrary != nil }, set: { if !$0 { deleteLibrary = nil } }), titleVisibility: .visible) {
            Button("Delete library", role: .destructive) { if let repo = deleteLibrary { removeLibrary(repo) } }
        } message: { Text("This deletes the entire library and every file it contains from the server.") }
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
                .accessibilityIdentifier("library.\(repo.id)")
                .contextMenu {
                    #if os(macOS)
                    if let library = SyncController.shared.libraries.first(where: { $0.id == repo.id }) {
                        Button("Open local folder") { NSWorkspace.shared.open(URL(fileURLWithPath: library.folder)) }
                        Button("Sync now") { Task { do { try await SyncController.shared.syncNow(library) } catch { model.errorMessage = error.localizedDescription } } }
                        Button(library.autoSync ? "Disable auto sync" : "Enable auto sync") { Task { do { try await SyncController.shared.setAutoSync(!library.autoSync, for: library) } catch { model.errorMessage = error.localizedDescription } } }
                        Button("Set sync interval") { syncInterval = library }
                    } else { Button("Sync library") { SyncController.shared.showSync = repo } }
                    if let task = SyncController.shared.cloneTasks.first(where: { $0.id == repo.id && !["done", "canceled"].contains($0.state) }) {
                        Button("Cancel download") { Task { do { try await SyncController.shared.cancel(task) } catch { model.errorMessage = error.localizedDescription } } }
                    }
                    #endif
                    Button("Share library") { shareLibrary = repo }
                    Button("Library details") { detailLibrary = repo }
                    Button("Open on server") { Task { do { openURL(try await model.client(for: account).authenticatedWebURL(next: account.endpoint.url.path + "library/" + repo.id + "/")) } catch { model.errorMessage = error.localizedDescription } } }
                    if repo.type == "srepo", repo.owner != nil, repo.owner != account.email { Button("Leave shared library", role: .destructive) { leaveLibrary = repo } }
                    if repo.type == "repo", repo.owner == nil || repo.owner == account.email { Button("Delete library", role: .destructive) { deleteLibrary = repo } }
                }
    }
    private func removeLibrary(_ repo: Repository) {
        #if os(iOS)
        do {
            if let settings = try model.photoBackup.settings(account), settings.enabled, settings.repository == repo.id {
                model.errorMessage = "Turn off this library's photo backup before deleting it."; return
            }
        } catch { model.errorMessage = error.localizedDescription; return }
        #endif
        do {
            guard !(try model.textDrafts.get().drafts(account: account.id)).contains(where: { $0.repository == repo.id && $0.changed }) else { model.errorMessage = "Upload, export or discard this library's text drafts before deleting it."; return }
        } catch { model.errorMessage = error.localizedDescription; return }
        guard !model.transfers.hasPendingUploads(accountID: account.id), !model.transfers.hasActiveTransfers(accountID: account.id) else {
            model.errorMessage = "Finish or export this account's pending transfers before deleting a library."; return
        }
        #if os(macOS)
        guard !SyncController.shared.libraries.contains(where: { $0.id == repo.id }) else { model.errorMessage = "Unsync this library before deleting it from the server. Your local folder will be kept."; return }
        guard !MacFileEditor.shared.hasChanges(account: account) else { model.errorMessage = "Upload or export the pending local edits before deleting a library."; return }
        #endif
        model.beginFileAction(account)
        Task {
            defer { model.endFileAction(account) }
            do { try await model.client(for: account).deleteRepository(repo: repo.id); await model.refresh() }
            catch { model.errorMessage = error.localizedDescription }
        }
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
    var newFile = false
}

struct DirectoryView: View {
    var model: AppModel
    let account: ServerAccount
    let repo: Repository
    private let initialPath: String
    @State private var currentPath: String
    @State private var backward: [String] = []
    @State private var forward: [String] = []
    var path: String {
        #if os(macOS)
        currentPath
        #else
        initialPath
        #endif
    }
    var initialFile: String? = nil
    @State private var openedInitialFile = false
    @State private var state = DirectoryModel()
    @State private var query = ""
    @State private var preview: URL?
    @State private var shareURL: URL?
    @State private var prompt: FilePrompt?
    @State private var createdName: String?
    @State private var deleteEntry: DirectoryEntry?
    @State private var showImport = false
    @State private var importFolder = false
    @State private var updateEntry: DirectoryEntry?
    @State private var operation: Task<Void, Never>?
    @State private var operationLabel: String?
    @State private var previewTransfer: UUID?
    @State private var previewWaiter: Task<Void, Never>?
    @State private var previewRequest = UUID()
    #if os(iOS)
    @State private var textEdit: TextEditRequest?
    @State private var media: MobileMediaRequest?
    #endif
    @State private var visible = false
    @State private var selectedEntries: Set<String> = []
    @AppStorage("directory.sort") private var sort = "name"
    @AppStorage("directory.descending") private var descending = false
    @State private var fileAction: FileActionRequest?
    @State private var shareAction: ShareActionRequest?
    @State private var deleteAction: FileActionRequest?
    @State private var serverDocument: ServerDocument?
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    #endif
    @Environment(\.scenePhase) private var phase
    init(model: AppModel, account: ServerAccount, repo: Repository, path: String, initialFile: String? = nil) {
        self.model = model; self.account = account; self.repo = repo; self.initialPath = path; self.initialFile = initialFile
        _currentPath = State(initialValue: path)
    }
    var title: String { path == "/" ? repo.name : (path as NSString).lastPathComponent }
    private var visibleEntries: [DirectoryEntry] {
        state.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            let comparison: ComparisonResult
            switch sort {
            case "size" where left.size != right.size: comparison = left.size < right.size ? .orderedAscending : .orderedDescending
            case "mtime" where (left.mtime ?? 0) != (right.mtime ?? 0): comparison = (left.mtime ?? 0) < (right.mtime ?? 0) ? .orderedAscending : .orderedDescending
            case "type" where (left.name as NSString).pathExtension != (right.name as NSString).pathExtension:
                comparison = (left.name as NSString).pathExtension.localizedStandardCompare((right.name as NSString).pathExtension)
            default: comparison = left.name.localizedStandardCompare(right.name)
            }
            return descending ? comparison == .orderedDescending : comparison == .orderedAscending
        }
    }
    private var sortMenu: some View {
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
            Picker("Sort by", selection: $sort) {
                Text("Name").tag("name"); Text("Size").tag("size")
                Text("Type").tag("type"); Text("Last modified").tag("mtime")
            }
            Toggle("Descending", isOn: $descending)
        }
    }

    var body: some View {
        List(selection: $selectedEntries) {
            if let error = state.error { Text(error).foregroundStyle(.secondary).font(.callout) }
            if let createdName { Text("Created \(createdName)").font(.callout).accessibilityIdentifier("directory.createdFile") }
            ForEach(visibleEntries) { entry in
                Group {
                    #if os(macOS)
                    row(entry).accessibilityElement(children: .combine)
                        .accessibilityIdentifier(entry.isDirectory ? "directory.\(entry.path(in: path))" : "file.\(entry.path(in: path))")
                        .onTapGesture(count: 2) {
                            if entry.isDirectory { navigate(entry.path(in: path)) }
                            else { run("Opening file") { try await MacFileEditor.shared.open(model: model, account: account, repo: repo, entry: entry, path: entry.path(in: path)) } }
                        }
                    #else
                    if editMode.isEditing {
                        row(entry).accessibilityElement(children: .combine)
                            .accessibilityIdentifier("selection.\(entry.path(in: path))")
                    } else if entry.isDirectory {
                        NavigationLink { DirectoryView(model: model, account: account, repo: repo, path: entry.path(in: path)) } label: { row(entry) }
                    } else {
                        Button { download(entry) } label: { row(entry) }.buttonStyle(.plain)
                            .accessibilityIdentifier("file.\(entry.path(in: path))")
                    }
                    #endif
                }
                .tag(entry.id)
                .contextMenu {
                    if !entry.isDirectory { Button("Preview", systemImage: "doc") { download(entry) } }
                    if !entry.isDirectory, ["sdoc", "md", "markdown", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp"].contains((entry.name as NSString).pathExtension.lowercased()) {
                        Button("Open collaborative editor", systemImage: "person.2") {
                            do {
                                serverDocument = ServerDocument(title: entry.name, url: try ServerDocumentSession.fileURL(repo: repo.id, path: entry.path(in: path), endpoint: account.endpoint, editing: repo.writable && (!entry.locked || entry.lockedByMe)))
                            } catch { model.errorMessage = documentError(error) }
                        }.accessibilityIdentifier("document.openEditor")
                    }
                    #if os(macOS)
                    if !entry.isDirectory { Button("Open in default app") { run("Opening file") { try await MacFileEditor.shared.open(model: model, account: account, repo: repo, entry: entry, path: entry.path(in: path)) } } }
                    Button("Download / Save as") { saveAs(entry) }
                    Button("Copy") { MacFileClipboard.shared.store(account: account, repo: repo, parent: path, entries: [entry], cut: false) }
                    if repo.writable { Button("Cut") { MacFileClipboard.shared.store(account: account, repo: repo, parent: path, entries: [entry], cut: true) } }
                    #endif
                    Button("Copy to…") { fileAction = FileActionRequest(entries: [entry], move: false) }.disabled(repo.encrypted)
                    Button("Share…") { shareAction = ShareActionRequest(path: entry.path(in: path), directory: entry.isDirectory) }
                    if repo.writable {
                        Button("Move to…") { fileAction = FileActionRequest(entries: [entry], move: true) }.disabled(repo.encrypted)
                        if !entry.isDirectory {
                            #if os(iOS)
                            if MobileTextEditor.supports(entry.name) {
                                Button("Edit text") { textEdit = TextEditRequest(repository: repo.id, path: entry.path(in: path)) }.disabled(entry.locked && !entry.lockedByMe)
                            }
                            #endif
                            Button(entry.lockedByMe ? "Unlock file" : "Lock file") { run("Updating file lock") { try await model.client(for: account).lock(repo: repo.id, path: entry.path(in: path), locked: !entry.lockedByMe); await refresh() } }.disabled(entry.locked && !entry.lockedByMe)
                        }
                        #if os(macOS)
                        if entry.isDirectory { Button("Sync this folder") { syncSubfolder(entry) }.disabled(repo.encrypted) }
                        #endif
                    }
                    Button("Create share link", systemImage: "square.and.arrow.up") {
                        run("Creating share link") { shareURL = try await model.client(for: account).shareLink(repo: repo.id, path: entry.path(in: path)) }
                    }
                    Button("Star", systemImage: "star") { run("Starring") { try await model.client(for: account).setStarred(repo: repo.id, path: entry.path(in: path), starred: true) } }
                    #if os(macOS)
                    if !entry.isDirectory {
                        if let cache = cachedURL(entry) {
                            Button("Open local cache folder") { NSWorkspace.shared.activateFileViewerSelecting([cache]) }
                            Button("Local version Save as…") { saveCached(entry) }
                            Button("Delete local version") { do { try FileManager.default.removeItem(at: cache) } catch { model.errorMessage = error.localizedDescription } }
                        }
                        if repo.writable { Button("Update from local file…") { updateEntry = entry; importFolder = false; showImport = true } }
                    }
                    #endif
                    if repo.writable {
                        Button("Rename", systemImage: "pencil") { prompt = FilePrompt(entry: entry) }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteEntry = entry }
                    }
                }
            }
        }
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            guard repo.writable, operationLabel == nil, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            queueUploads(urls, parent: path, target: nil)
            return true
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Button("Back", systemImage: "chevron.left") { goBack() }.disabled(backward.isEmpty || operationLabel != nil).keyboardShortcut("[", modifiers: .command)
                Button("Forward", systemImage: "chevron.right") { goForward() }.disabled(forward.isEmpty || operationLabel != nil).keyboardShortcut("]", modifiers: .command)
                Button("Home", systemImage: "house") { navigate("/") }.disabled(path == "/" || operationLabel != nil)
                Menu {
                    Button(repo.name) { navigate("/") }
                    ForEach(Array(path.split(separator: "/").enumerated()), id: \.offset) { part in
                        Button(String(part.element)) { navigate("/" + path.split(separator: "/").prefix(part.offset + 1).joined(separator: "/")) }
                    }
                } label: { Text(path == "/" ? repo.name : path).lineLimit(1).truncationMode(.middle) }
                .disabled(operationLabel != nil)
                Spacer()
            }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
        }
        #endif
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Find a file")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(state.loading)
            #if os(macOS)
            sortMenu
            if repo.writable {
                Button("New folder", systemImage: "folder.badge.plus") { prompt = FilePrompt() }
                Button("New file", systemImage: "doc.badge.plus") { prompt = FilePrompt(newFile: true) }.accessibilityIdentifier("directory.newFile")
                Button("Upload files", systemImage: "arrow.up.doc") { importFolder = false; updateEntry = nil; showImport = true }
                #if os(macOS)
                Button("Upload a directory", systemImage: "folder.badge.arrow.up") { importFolder = true; updateEntry = nil; showImport = true }
                #endif
            }
            NavigationLink { ServerSearchView(model: model, account: account, repo: repo) } label: { Label("Search library", systemImage: "magnifyingglass") }
                .accessibilityIdentifier("directory.searchLibrary")
            #else
            Menu("Folder actions", systemImage: "ellipsis.circle") {
                sortMenu
                NavigationLink { ServerSearchView(model: model, account: account, repo: repo) } label: { Label("Search library", systemImage: "magnifyingglass") }
                if repo.writable {
                    Button("New folder", systemImage: "folder.badge.plus") { prompt = FilePrompt() }
                    Button("New file", systemImage: "doc.badge.plus") { prompt = FilePrompt(newFile: true) }.accessibilityIdentifier("directory.newFile")
                    Button("Upload files", systemImage: "arrow.up.doc") { importFolder = false; updateEntry = nil; showImport = true }
                }
            }.accessibilityIdentifier("directory.actions")
            Button(editMode.isEditing ? "Done" : "Select") {
                if editMode.isEditing { editMode = .inactive; selectedEntries.removeAll() }
                else { editMode = .active }
            }.accessibilityIdentifier("directory.select")
            #endif
            #if os(macOS)
            Button("Sync library", systemImage: "arrow.triangle.2.circlepath") { SyncController.shared.showSync = repo }
            #endif
            #if os(macOS)
            if !selected.isEmpty {
                Menu("Selected items") {
                    #if os(macOS)
                    Button("Copy") { copySelected(cut: false) }.keyboardShortcut("c")
                    #endif
                    Button("Download selected items") { downloadSelected() }
                    Button("Copy to…") { fileAction = FileActionRequest(entries: selected, move: false) }.disabled(repo.encrypted)
                    if repo.writable {
                        #if os(macOS)
                        Button("Cut") { copySelected(cut: true) }.keyboardShortcut("x")
                        #endif
                        Button("Move to…") { fileAction = FileActionRequest(entries: selected, move: true) }.disabled(repo.encrypted)
                        Button("Delete selected items", role: .destructive) { deleteAction = FileActionRequest(entries: selected, move: false) }
                    }
                }
                .accessibilityIdentifier("directory.selectedActions")
            }
            #endif
            #if os(macOS)
            if repo.writable {
                Button("Paste", systemImage: "doc.on.clipboard") { paste() }.keyboardShortcut("v").disabled(MacFileClipboard.shared.accountID != account.id || repo.encrypted)
            }
            #endif
        }
        #if os(iOS)
        .environment(\.editMode, $editMode)
        #endif
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
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
            if editMode.isEditing && !selected.isEmpty {
                HStack {
                    Text("\(selected.count) selected").font(.callout)
                    Spacer()
                    Menu("Selected items") {
                        Button("Download selected items") { downloadSelected() }
                        Button("Copy to…") { fileAction = FileActionRequest(entries: selected, move: false) }.disabled(repo.encrypted)
                        if repo.writable {
                            Button("Move to…") { fileAction = FileActionRequest(entries: selected, move: true) }.disabled(repo.encrypted)
                            Button("Delete selected items", role: .destructive) { deleteAction = FileActionRequest(entries: selected, move: false) }
                        }
                    }.accessibilityIdentifier("directory.selectedActions")
                }.padding(12).background(.bar)
            }
            #endif
            if let id = previewTransfer {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloading preview…")
                    Spacer()
                    Button("Cancel") { model.transfers.cancel(id) }
                }.padding(12).background(.bar)
            }
        }
        .onAppear { visible = true }
        .onChange(of: path, initial: true) { _, _ in stopPreviewWaiting(); Task { await refresh() } }
        .onChange(of: model.transfers.revision) { _, _ in Task { await refresh() } }
        .task(id: path + String(describing: phase)) {
            guard phase == .active else { return }
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .quickLookPreview($preview)
        .sheet(item: $serverDocument) { document in ServerDocumentView(model: model, account: account, document: document) }
        .fileImporter(isPresented: $showImport, allowedContentTypes: importFolder ? [.folder] : [.item], allowsMultipleSelection: updateEntry == nil && !importFolder) { result in
            switch result {
            case .success(let files):
                queueUploads(files, parent: path, target: updateEntry)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $prompt) { prompt in
            NamePrompt(title: prompt.newFile ? "New file" : prompt.entry == nil ? "New folder" : "Rename", initial: prompt.entry?.name ?? "") { name in
                run(prompt.newFile ? "Creating file" : prompt.entry == nil ? "Creating folder" : "Renaming") {
                    let api = try model.client(for: account)
                    if let entry = prompt.entry { try await api.rename(repo: repo.id, path: entry.path(in: path), isDirectory: entry.isDirectory, to: name) }
                    else if prompt.newFile { createdName = try await api.createFile(repo: repo.id, parent: path, name: name) }
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
        .onDisappear { visible = false; stopPreviewWaiting(); operation?.cancel() }
        #if os(macOS)
        .sheet(item: Binding(get: { SyncController.shared.showSync }, set: { SyncController.shared.showSync = $0 })) { library in
            SyncLibrarySheet(model: model, account: account, repo: library)
        }
        .onKeyPress(.space) { if let entry = selected.first, !entry.isDirectory { download(entry); return .handled }; return .ignored }
        #endif
        .sheet(item: $fileAction) { request in FileDestinationSheet(model: model, account: account, source: repo, sourcePath: path, request: request) { Task { await refresh() } } }
        .sheet(item: $shareAction) { request in ShareManagementSheet(model: model, account: account, repo: repo, path: request.path, directory: request.directory) }
        .sheet(item: $deleteAction) { request in
            BatchDeleteSheet(model: model, account: account, repo: repo, parent: path, entries: request.entries) { Task { await refresh() } }
        }
        #if os(iOS)
        .sheet(item: $textEdit) { request in MobileTextEditor(model: model, account: account, request: request) }
        .sheet(item: $media) { request in MobileMediaView(model: model, account: account, repository: repo, request: request) }
        #endif
    }

    private var selected: [DirectoryEntry] { state.entries.filter { selectedEntries.contains($0.id) } }
    private func downloadSelected() {
        do {
            for entry in selected { try model.transfers.enqueueDownload(accountID: account.id, repository: repo.id, path: entry.path(in: path), directory: entry.isDirectory) }
            selectedEntries.removeAll()
            #if os(iOS)
            editMode = .inactive
            #endif
        } catch { model.errorMessage = error.localizedDescription }
    }

    #if os(macOS)
    private func navigate(_ destination: String) {
        guard destination != path, operationLabel == nil else { return }
        backward.append(path); forward.removeAll(); changeDirectory(destination)
    }
    private func goBack() {
        guard let previous = backward.popLast() else { return }
        forward.append(path); changeDirectory(previous)
    }
    private func goForward() {
        guard let next = forward.popLast() else { return }
        backward.append(path); changeDirectory(next)
    }
    private func changeDirectory(_ destination: String) {
        selectedEntries.removeAll(); query = ""; state = DirectoryModel(); currentPath = destination
    }
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
    private func saveCached(_ entry: DirectoryEntry) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name; panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                guard let source = cachedURL(entry) else { throw SeafileError.local("The local copy is no longer available.") }
                guard source.standardizedFileURL != destination.standardizedFileURL else { return }
                if FileManager.default.fileExists(atPath: destination.path) { try Data(contentsOf: source, options: .mappedIfSafe).write(to: destination, options: .atomic) }
                else { try FileManager.default.copyItem(at: source, to: destination) }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
    private func saveAs(_ entry: DirectoryEntry) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name; panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            let fullPath = entry.path(in: path)
            Task {
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let id = try model.transfers.enqueueDownload(accountID: account.id, repository: repo.id, path: fullPath, directory: entry.isDirectory)
                    let source = try await model.transfers.result(for: id)
                    try await TransferExportFiles.copy(source, to: url, directory: entry.isDirectory)
                } catch { model.errorMessage = error.localizedDescription }
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
            #if os(macOS)
            MacFileThumbnail(model: model, account: account, repo: repo, entry: entry, path: entry.path(in: path))
            #else
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? .blue : .secondary).font(.title3)
            #endif
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
        let listing = state
        do {
            await listing.refresh(api: try model.client(for: account), account: account, repo: repo.id, path: path)
            if state === listing, listing.error == nil { selectedEntries.formIntersection(Set(listing.entries.map(\.id))) }
            if state === listing, !openedInitialFile, let initialFile, let entry = listing.entries.first(where: { $0.name == initialFile && !$0.isDirectory }) { openedInitialFile = true; download(entry) }
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
        stopPreviewWaiting()
        #if os(iOS)
        if MobileMediaView.supports(entry.name) {
            let items = visibleEntries.filter { !$0.isDirectory && MobileMediaView.supports($0.name) }
            guard !items.isEmpty else { return }
            media = MobileMediaRequest(entries: items, parent: path, initial: entry.name)
            return
        }
        #endif
        let ticket = previewRequest
        let fullPath = entry.path(in: path)
        let folder = path
        let generation = model.previewGeneration
        do {
            let id = try model.transfers.enqueueDownload(accountID: account.id, repository: repo.id, path: fullPath)
            previewTransfer = id
            previewWaiter = Task {
                do {
                    let destination = try await model.transfers.result(for: id)
                    if visible, generation == model.previewGeneration, previewRequest == ticket, path == folder, model.selectedAccountID == account.id { preview = destination }
                } catch is CancellationError { }
                catch let error as URLError where error.code == .cancelled { }
                catch {
                    if visible, generation == model.previewGeneration, previewRequest == ticket, path == folder, model.selectedAccountID == account.id {
                        let old = LocalFiles.cacheURL(account: account, repo: repo.id, path: fullPath)
                        if let cached = model.transfers.cachedDownload(accountID: account.id, repository: repo.id, path: fullPath) ?? (FileManager.default.fileExists(atPath: old.path) ? old : nil) {
                            state.error = "Showing the cached copy. \(error.localizedDescription)"; preview = cached
                        } else { model.errorMessage = error.localizedDescription }
                    }
                }
                if previewRequest == ticket { previewTransfer = nil; previewWaiter = nil }
            }
        } catch { model.errorMessage = error.localizedDescription }
    }
    private func stopPreviewWaiting() {
        previewRequest = UUID(); previewWaiter?.cancel(); previewWaiter = nil; previewTransfer = nil
    }

    private func cachedURL(_ entry: DirectoryEntry) -> URL? {
        let fullPath = entry.path(in: path)
        let old = LocalFiles.cacheURL(account: account, repo: repo.id, path: fullPath)
        return model.transfers.cachedDownload(accountID: account.id, repository: repo.id, path: fullPath) ?? (FileManager.default.fileExists(atPath: old.path) ? old : nil)
    }

    private func queueUploads(_ files: [URL], parent: String, target: DirectoryEntry?) {
        Task {
            do {
                for file in files {
                    let access = file.startAccessingSecurityScopedResource()
                    defer { if access { file.stopAccessingSecurityScopedResource() } }
                    try await model.transfers.enqueueUpload(accountID: account.id, repository: repo.id, parent: parent, source: file, name: target?.name, replace: target != nil)
                }
            }
            catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

struct NamePrompt: View {
    let title: LocalizedStringKey
    let action: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    init(title: LocalizedStringKey, initial: String, action: @escaping (String) -> Void) { self.title = title; self.action = action; _name = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            Form { TextField("Name", text: $name).textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).accessibilityIdentifier("namePrompt.name") }.formStyle(.grouped).navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { action(name); dismiss() }.disabled(name.isEmpty || name == "." || name == ".." || name.contains("/")).accessibilityIdentifier("namePrompt.save")
                    }
                }
        }.frame(minWidth: 300, minHeight: 180)
    }
}

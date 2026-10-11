#if os(iOS)
import SwiftUI
import Observation
import LocalAuthentication
import SeafileCore
import QuickLook

@MainActor @Observable final class ShareComposerModel {
    typealias Client = (ServerAccount) throws -> SeafileAPI
    let store: SharedImportStore
    var share: SharedImport?
    var accounts: [ServerAccount] = []
    var selected: ServerAccount?
    var repositories: [Repository] = []
    var repository: Repository?
    var directory = "/"
    var loading = false
    var sending = false
    var locked: Bool
    var error: String?
    var partialInputs = false
    var finishedFiles = 0
    var completed = false
    private let accountsLoader: () throws -> [ServerAccount]
    private let clientFactory: Client
    private let providers: [NSItemProvider]
    private let existing: UUID?
    private let authentication: () async throws -> Bool
    private var task: Task<Void, Never>?
    private var initialized = false
    private var nextProvider = 0
    private var authenticationGeneration = 0
    init(store: SharedImportStore, providers: [NSItemProvider] = [], existing: UUID? = nil,
         requiresAuthentication: Bool, accounts: @escaping () throws -> [ServerAccount],
         client: @escaping Client, authentication: @escaping () async throws -> Bool = {
             let context = LAContext()
             return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock your files and account settings."))
         }) {
        self.store = store; self.providers = providers; self.existing = existing
        locked = requiresAuthentication; accountsLoader = accounts; clientFactory = client; self.authentication = authentication
    }
    func start() async { if !locked { await prepare() } }
    func unlock() async {
        guard !loading else { return }; loading = true; error = nil
        let generation = authenticationGeneration
        do { if try await authentication(), generation == authenticationGeneration { locked = false } }
        catch { self.error = error.localizedDescription }
        loading = false
        if !locked { await prepare() }
    }
    private func prepare() async {
        guard !initialized, !locked else { return }
        initialized = true; loading = true; defer { loading = false }
        do {
            accounts = try accountsLoader()
            let id = try existing ?? share?.id ?? store.create()
            let inputLease: SharedImportStore.Lease?
            if existing == nil, nextProvider < providers.count { inputLease = try store.uploadLease(id) }
            else { inputLease = nil }
            defer { withExtendedLifetime(inputLease) {} }
            share = try store.snapshot(id)
            if existing == nil {
                while nextProvider < providers.count {
                    try Task.checkCancellation()
                    guard !locked else { return }
                    do { try await ShareInputLoader.load(providers[nextProvider], store: store, id: id) }
                    catch { partialInputs = true }
                    nextProvider += 1
                }
            }
            share = try store.snapshot(id)
            if let accountID = share?.accountID {
                selected = accounts.first { $0.id == accountID }
                directory = share?.directory ?? "/"
                if let selected {
                    repositories = try await clientFactory(selected).repositories()
                    repository = repositories.first { $0.id == share?.repository }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func choose(_ account: ServerAccount) async {
        guard share?.accountID == nil, !loading, !locked else { return }
        selected = account; repository = nil; repositories = []; directory = "/"
        loading = true; error = nil; defer { loading = false }
        do { repositories = try await clientFactory(account).repositories() }
        catch { self.error = error.localizedDescription }
    }
    func client() throws -> SeafileAPI {
        guard !locked, let selected else { throw SeafileError.local("Choose an account first.") }
        return try clientFactory(selected)
    }
    func unlockLibrary(_ repo: Repository, password: String) async {
        loading = true; defer { loading = false }
        do { try await client().unlock(repo: repo.id, password: password); repository = repo; directory = "/"; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func upload(retryUncertain: Bool = false) {
        guard !sending, !locked, let selected, let repository, repository.writable, let share, !share.files.isEmpty else { return }
        sending = true; error = nil
        task = Task {
            defer { sending = false; task = nil; self.share = try? store.snapshot(share.id) }
            do {
                if share.accountID == nil { try store.assign(share.id, accountID: selected.id, repository: repository.id, directory: directory) }
                try await SharedImportUploader.upload(share.id, store: store, client: client(), retryUncertain: retryUncertain) { done, _ in self.finishedFiles = done }
                completed = true
            } catch { self.error = error.localizedDescription }
        }
    }
    func stop() async { task?.cancel(); await task?.value }
    func verify(_ file: SharedImport.File) async {
        guard !sending, !loading, !locked, let share else { return }
        loading = true; error = nil; defer { loading = false; self.share = try? store.snapshot(share.id) }
        do {
            let confirmed = try await SharedImportUploader.verify(file.id, in: share.id, store: store, client: client())
            if !confirmed { error = String(localized: "No identical server copy was found. Your local file is preserved.") }
        } catch { self.error = error.localizedDescription }
    }
    func close() async {
        await stop()
        if let id = share?.id, let share = try? store.snapshot(id), share.accountID == nil { try? store.remove(id) }
    }
    func hostEnteredBackground() {
        task?.cancel()
        authenticationGeneration += 1
        if SharedAppSecurity.requiresAuthentication { locked = true; accounts = []; selected = nil; repositories = []; repository = nil; initialized = false }
    }
}

struct ShareComposerView: View {
    @State var model: ShareComposerModel
    let close: () -> Void
    @State private var chooseFolder = false
    @State private var preview: URL?
    @State private var encrypted: Repository?
    @State private var password = ""
    @State private var retry = false
    var body: some View {
        NavigationStack {
            List {
                if model.locked {
                    Section { Label("Your files are locked", systemImage: "lock.shield"); Button("Unlock") { Task { await model.unlock() } }.accessibilityIdentifier("share.unlock") }
                } else if model.completed {
                    Section { Label("Shared files uploaded", systemImage: "checkmark.circle").accessibilityIdentifier("share.completed") }
                } else {
                    if let share = model.share {
                        Section("Files to share") {
                            ForEach(share.files) { file in
                                HStack {
                                    VStack(alignment: .leading) { Text(file.name); Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if file.state == .completed { Image(systemName: "checkmark.circle") }
                                    else {
                                        Button("Preview") { preview = try? model.store.fileURL(file, in: share.id) }.disabled(model.sending)
                                        if file.state == .uncertain || file.state == .sending {
                                            Button("Check server copy") { Task { await model.verify(file) } }.disabled(model.sending || model.loading).accessibilityIdentifier("share.verify.\(file.name)")
                                        }
                                    }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if model.partialInputs { Text("Some shared items could not be read. Only the listed files will be uploaded.").foregroundStyle(.orange) }
                    Section("Account") {
                        if model.accounts.isEmpty { Text("Open seafile-next and sign in before sharing files.") }
                        ForEach(model.accounts) { account in
                            Button { Task { await model.choose(account) } } label: {
                                HStack { Text(account.name); Spacer(); if model.selected?.id == account.id { Image(systemName: "checkmark") } }
                            }.disabled(model.loading || model.sending || model.share?.accountID != nil).accessibilityIdentifier("share.account.\(account.name)")
                        }
                    }
                    if model.selected != nil {
                        Section("Library") {
                            ForEach(model.repositories) { repo in
                                Button {
                                    if repo.encrypted { encrypted = repo }
                                    else { model.repository = repo; model.directory = "/" }
                                } label: {
                                    HStack { Label(repo.name, systemImage: repo.encrypted ? "lock.folder" : "folder"); Spacer(); if model.repository?.id == repo.id { Image(systemName: "checkmark") } }
                                }.disabled(!repo.writable || model.loading || model.sending || model.share?.accountID != nil).accessibilityIdentifier("share.library.\(repo.name)")
                            }
                        }
                    }
                    if model.repository != nil {
                        Section("Destination") {
                            Text(model.directory)
                            Button("Choose folder") { chooseFolder = true }.disabled(model.sending || model.share?.accountID != nil).accessibilityIdentifier("share.folder")
                        }
                    }
                    if model.sending { ProgressView("Uploading shared files…"); Text("\(model.finishedFiles) / \(model.share?.files.count ?? 0)") }
                    if model.share?.files.contains(where: { $0.state == .uncertain || $0.state == .sending }) == true, !model.sending {
                        Text("Check the server before retrying an interrupted upload. A repeated send may create another copy.").foregroundStyle(.secondary)
                        Button("Retry after checking the server") { retry = true }.accessibilityIdentifier("share.retryUncertain")
                    }
                }
                if model.loading { ProgressView() }
                if let error = model.error { Text(LocalizedStringKey(error)).foregroundStyle(.red).accessibilityIdentifier("share.error") }
            }.safeAreaInset(edge: .bottom) {
                if !model.locked, !model.completed {
                    HStack {
                        Text("\(model.share?.files.count ?? 0)").accessibilityIdentifier("share.inputCount")
                        Image(systemName: "doc.on.doc").accessibilityHidden(true)
                        Spacer()
                        Button("Save to Seafile") { model.upload() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.sending || model.repository == nil || model.share?.files.isEmpty != false || model.loading)
                            .accessibilityIdentifier("share.save")
                    }.padding().background(.bar)
                }
            }.navigationTitle("Save to Seafile")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.completed ? LocalizedStringKey("Done") : LocalizedStringKey("Close")) { Task { await model.close(); close() } }.accessibilityIdentifier("share.close") } }
                .task { await model.start() }
                .onChange(of: model.locked) { _, locked in
                    if locked { preview = nil; chooseFolder = false; encrypted = nil; password = ""; retry = false }
                }
                .quickLookPreview($preview)
                .sheet(isPresented: $chooseFolder) {
                    if let repo = model.repository {
                        NavigationStack { ShareFolderPicker(model: model, repo: repo.id, path: "/") { model.directory = $0; chooseFolder = false } }
                    }
                }
                .alert("Library password", isPresented: Binding(get: { encrypted != nil }, set: { if !$0 { encrypted = nil; password = "" } })) {
                    SecureField("Password", text: $password)
                    Button("Unlock") { if let repo = encrypted { let value = password; password = ""; encrypted = nil; Task { await model.unlockLibrary(repo, password: value) } } }
                    Button("Cancel", role: .cancel) { encrypted = nil; password = "" }
                }
                .confirmationDialog("Retry the interrupted uploads?", isPresented: $retry, titleVisibility: .visible) {
                    Button("I checked the server; retry") { model.upload(retryUncertain: true) }.accessibilityIdentifier("share.confirmRetry")
                } message: { Text("Completed files are skipped. A file accepted by the server before its response was lost may be uploaded again under a new name.") }
        }
    }
}

private struct ShareFolderPicker: View {
    let model: ShareComposerModel
    let repo: String
    let path: String
    let choose: (String) -> Void
    @State private var entries: [DirectoryEntry] = []
    @State private var error: String?
    var body: some View {
        List {
            Button("Use this folder") { choose(path) }.accessibilityIdentifier("share.useFolder")
            ForEach(entries.filter(\.isDirectory)) { entry in
                let next = (path.hasSuffix("/") ? path : path + "/") + entry.name + "/"
                NavigationLink(entry.name) { ShareFolderPicker(model: model, repo: repo, path: next, choose: choose) }
            }
            if let error { Text(LocalizedStringKey(error)).foregroundStyle(.red); Button("Retry") { Task { await load() } } }
        }.navigationTitle(path == "/" ? String(localized: "Choose folder") : (path as NSString).lastPathComponent).task { await load() }
    }
    private func load() async {
        do { entries = try await model.client().directory(repo: repo, path: path); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
#endif

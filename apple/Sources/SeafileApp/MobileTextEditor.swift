#if os(iOS)
import SwiftUI
import SeafileCore
import UniformTypeIdentifiers

struct TextEditRequest: Identifiable { let id = UUID(); let repository: String, path: String }
struct DraftDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MobileTextEditor: View {
    var model: AppModel
    let account: ServerAccount, request: TextEditRequest
    @State private var draft: TextDraft?
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var conflict = false
    @State private var export = false
    @State private var copyName = false
    @State private var holdingAccount = false
    @Environment(\.dismiss) private var dismiss
    private var name: String { (request.path as NSString).lastPathComponent }
    private var repository: Repository? { model.repositories.first { $0.id == request.repository } }
    static func supports(_ name: String) -> Bool {
        ["txt", "md", "markdown", "csv", "json", "yaml", "yml", "xml", "log", "ini", "conf", "swift", "py", "c", "h", "js", "ts", "css", "html"].contains((name as NSString).pathExtension.lowercased())
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error { Text(error).foregroundStyle(.red).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                if conflict { Text("This file changed on the server. Save a copy or export your draft to keep both versions.").padding(12) }
                if repository?.writable != true { Text("This library is unavailable or read only. You can export the draft.").padding(12) }
                if draft != nil {
                    TextEditor(text: Binding(get: { draft?.text ?? "" }, set: edit))
                        .font(.system(.body, design: .monospaced)).padding(8).disabled(working)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("editor.text")
                }
                if loading || working { ProgressView(loading ? "Loading text" : "Saving text").padding() }
            }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }
                            .disabled(working || draft?.changed != true || repository?.writable != true || conflict)
                            .accessibilityIdentifier("editor.save")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Menu("Draft actions") {
                            Button("Export draft") { export = true }
                            Button("Save a copy") { copyName = true }.disabled(repository?.writable != true)
                        }.disabled(draft == nil || working)
                    }
                }
        }.interactiveDismissDisabled(working)
            .onAppear { if !holdingAccount { model.beginFileAction(account); holdingAccount = true } }
            .onDisappear { if holdingAccount { model.endFileAction(account); holdingAccount = false } }
            .task { await load() }
            .fileExporter(isPresented: $export, document: DraftDocument(data: draft?.data ?? Data()), contentType: .plainText, defaultFilename: name) { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
            .sheet(isPresented: $copyName) {
                NamePrompt(title: "Save a copy", initial: (name as NSString).deletingPathExtension + " copy." + (name as NSString).pathExtension) { name in Task { await save(copy: name) } }
            }
    }
    private func edit(_ text: String) {
        guard !working, var value = draft else { return }
        value.text = text; value.modifiedAt = Date()
        guard value.data.count <= TextDraftStore.maximumBytes, !text.contains("\0") else { error = "The editor supports UTF-8 text up to 2 MB."; return }
        draft = value
        do { try model.textDrafts.get().save(value); error = nil }
        catch { self.error = "Could not save the draft on this device. Export it before closing. " + error.localizedDescription }
    }
    private func remoteData() async throws -> Data {
        let api = try model.client(for: account)
        let entries = try await api.directory(repo: request.repository, path: (request.path as NSString).deletingLastPathComponent)
        guard let entry = entries.first(where: { !$0.isDirectory && $0.name == name }) else { throw SeafileError.local("This file is no longer available. Your draft is kept on this device.") }
        guard entry.size <= TextDraftStore.maximumBytes else { throw SeafileError.local("The editor supports files up to 2 MB.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await api.download(repo: request.repository, path: request.path, destination: temporary)
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= TextDraftStore.maximumBytes else { throw SeafileError.local("The editor supports files up to 2 MB.") }
        return try Data(contentsOf: temporary)
    }
    private func load() async {
        defer { loading = false }
        do {
            let store = try model.textDrafts.get()
            if let previous = try store.load(account: account.id, repository: request.repository, path: request.path) {
                if previous.changed { draft = previous; return }
                try store.remove(previous)
            }
            let data = try await remoteData()
            try Task.checkCancellation()
            draft = try store.create(account: account.id, repository: request.repository, path: request.path, data: data)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func save(copy: String? = nil) async {
        guard !working, let draft, repository?.writable == true else { return }
        let filename = copy ?? name
        guard !filename.isEmpty, ![".", ".."].contains(filename), !filename.contains("/"), !filename.contains("\0") else { error = "Enter a valid file name."; return }
        guard copy == nil || filename != name else { error = "Use another name to keep both versions."; return }
        working = true; error = nil; model.beginFileAction(account)
        defer { working = false; model.endFileAction(account) }
        do {
            let store = try model.textDrafts.get(); try store.save(draft)
            if copy == nil {
                let remote = try await remoteData()
                if draft.alreadyUploaded(remote) { try store.remove(draft); dismiss(); return }
                guard draft.remoteMatchesBaseline(remote) else { conflict = true; return }
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let snapshot = folder.appendingPathComponent(filename)
            try draft.data.write(to: snapshot, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            let id = try await model.transfers.enqueueUpload(accountID: account.id, repository: request.repository,
                parent: (request.path as NSString).deletingLastPathComponent, source: snapshot, replace: copy == nil)
            _ = try await model.transfers.result(for: id)
            try store.remove(draft); dismiss()
        } catch { self.error = error.localizedDescription + " Your draft is kept on this device." }
    }
}

struct MobileDraftsView: View {
    var model: AppModel
    let account: ServerAccount
    @State private var drafts: [TextDraft] = []
    @State private var selected: TextEditRequest?
    @State private var discard: TextDraft?
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(drafts) { draft in
                Button { selected = TextEditRequest(repository: draft.repository, path: draft.path) } label: {
                    VStack(alignment: .leading) {
                        Label((draft.path as NSString).lastPathComponent, systemImage: "pencil.and.outline")
                        Text(draft.path).font(.caption).foregroundStyle(.secondary)
                    }
                }.contextMenu { Button("Discard draft", role: .destructive) { discard = draft } }
            }
        }.navigationTitle("Text drafts").task { load() }
            .overlay { if drafts.isEmpty && error == nil { ContentUnavailableView("No text drafts", systemImage: "pencil.and.outline") } }
            .sheet(item: $selected, onDismiss: { load() }) { request in MobileTextEditor(model: model, account: account, request: request) }
            .confirmationDialog("Discard local changes?", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }), titleVisibility: .visible) {
                Button("Discard draft", role: .destructive) {
                    if let discard { do { try model.textDrafts.get().remove(discard); load() } catch { self.error = error.localizedDescription } }
                }
            } message: { Text("The server version is preserved. Only this device's text edits are discarded.") }
    }
    private func load() {
        do { drafts = try model.textDrafts.get().drafts(account: account.id).filter(\.changed); error = nil }
        catch { self.error = "Could not read the draft history. The files have been preserved. " + error.localizedDescription }
    }
}
#endif

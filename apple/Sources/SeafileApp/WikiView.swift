import SwiftUI
import SeafileCore

struct ServerDocument: Identifiable {
    let id = UUID()
    let title: String, url: URL
}

struct WikiView: View {
    var model: AppModel
    let account: ServerAccount
    @State private var catalog: WikiCatalog?
    @State private var loading = false
    @State private var error: String?
    @State private var prompt: WikiPrompt?
    @State private var deletion: Wiki?
    @State private var unpublishing: Wiki?
    @State private var document: ServerDocument?
    @State private var generation = UUID()
    private struct WikiPrompt: Identifiable {
        let id = UUID()
        var wiki: Wiki?
        var publishing = false
    }
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("wiki.error") }
            if let catalog {
                ForEach(catalog.warnings, id: \.self) { Text($0).foregroundStyle(.secondary) }
                Section("My wikis") { ForEach(catalog.wikis.filter { $0.kind == "mine" }) { row($0) } }
                Section("Shared wikis") { ForEach(catalog.wikis.filter { $0.kind != "mine" }) { row($0) } }
                ForEach(catalog.groups) { group in Section(group.name) { ForEach(group.wikis) { row($0) } } }
                Section("Older wikis") { ForEach(catalog.legacy) { row($0) } }
                if catalog.wikis.isEmpty && catalog.groups.allSatisfy({ $0.wikis.isEmpty }) && catalog.legacy.isEmpty && catalog.warnings.isEmpty {
                    Text("No wikis").foregroundStyle(.secondary)
                }
            }
            if loading { ProgressView("Loading wikis") }
        }
        .navigationTitle("Wikis")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
            if catalog?.modernAvailable == true {
                Button("New wiki", systemImage: "plus") { prompt = WikiPrompt() }.disabled(loading).accessibilityIdentifier("wiki.create")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onDisappear { generation = UUID(); loading = false }
        .sheet(item: $prompt) { value in
            if value.publishing, let wiki = value.wiki {
                WikiPublishSheet { suffix in mutate { try await model.client(for: account).publishWiki(id: wiki.wikiID, suffix: suffix) } }
            } else {
                NamePrompt(title: value.wiki == nil ? "New wiki" : "Rename wiki", initial: value.wiki?.name ?? "") { name in
                    mutate {
                        let api = try model.client(for: account)
                        if let wiki = value.wiki { try await api.renameWiki(id: wiki.wikiID, name: name) }
                        else { try await api.createWiki(name: name) }
                    }
                }
            }
        }
        .sheet(item: $document) { item in ServerDocumentView(model: model, account: account, document: item) }
        .confirmationDialog("Delete wiki?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let wiki = deletion else { return }; deletion = nil
                guard canDelete(wiki) else { return }
                mutate { try await model.client(for: account).deleteWiki(id: wiki.wikiID) }
            }
        } message: { Text("This deletes the wiki and its library from the server.") }
        .confirmationDialog("Unpublish wiki?", isPresented: Binding(get: { unpublishing != nil }, set: { if !$0 { unpublishing = nil } }), titleVisibility: .visible) {
            Button("Unpublish", role: .destructive) {
                guard let wiki = unpublishing else { return }; unpublishing = nil
                mutate { try await model.client(for: account).unpublishWiki(id: wiki.wikiID) }
            }
        } message: { Text("The public address will stop serving this wiki.") }
    }
    private func row(_ wiki: Wiki) -> some View {
        HStack {
            Button {
                do { document = ServerDocument(title: wiki.name, url: try ServerDocumentSession.wikiURL(wiki, endpoint: account.endpoint)) }
                catch { self.error = documentError(error) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(wiki.name, systemImage: "book")
                    if wiki.published || wiki.legacy { Text("Published").font(.caption).foregroundStyle(.secondary) }
                    if wiki.legacy, let owner = wiki.ownerName { Text(owner).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("wiki.open.\(wiki.id)")
                .accessibilityValue(wiki.published || wiki.legacy ? Text("Published") : Text("Private"))
            if !wiki.legacy {
                NavigationLink {
                    WikiPagesView(model: model, account: account, wiki: wiki)
                } label: { Label("Pages and comments", systemImage: "text.bubble") }
                    .accessibilityIdentifier("wiki.pages.\(wiki.wikiID)")
            }
            if wiki.canManage {
                Menu("Wiki actions", systemImage: "ellipsis.circle") {
                    Button("Rename wiki") { prompt = WikiPrompt(wiki: wiki) }.accessibilityIdentifier("wiki.rename")
                    if wiki.published { Button("Unpublish") { unpublishing = wiki }.accessibilityIdentifier("wiki.unpublish") }
                    else { Button("Publish wiki") { prompt = WikiPrompt(wiki: wiki, publishing: true) }.accessibilityIdentifier("wiki.publish") }
                    Button("Delete wiki", role: .destructive) { deletion = wiki }.accessibilityIdentifier("wiki.delete")
                }.disabled(loading).accessibilityIdentifier("wiki.actions.\(wiki.id)")
            }
        }.accessibilityElement(children: .contain)
    }
    private func load() async {
        guard !loading else { return }
        let ticket = UUID(); generation = ticket; loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let result = try await model.client(for: account).wikiCatalog()
            try Task.checkCancellation()
            guard generation == ticket, model.selectedAccountID == account.id else { return }
            catalog = result; error = nil
        } catch is CancellationError { }
        catch { if generation == ticket { self.error = documentError(error) } }
    }
    private func mutate(_ action: @escaping @MainActor () async throws -> Void) {
        guard !loading else { return }
        loading = true; error = nil; model.beginFileAction(account)
        Task {
            defer { model.endFileAction(account) }
            var failure: String?
            do { try await action() } catch { failure = documentError(error) }
            // A lost response may follow a successful write. Refresh the state,
            // never replay the mutation automatically, and keep its error visible.
            loading = false; await load(); if let failure { error = failure }
        }
    }
    private func canDelete(_ wiki: Wiki) -> Bool {
        guard !model.transfers.hasPendingUploads(accountID: account.id), !model.transfers.hasActiveTransfers(accountID: account.id) else {
            error = "Finish or export this account's pending transfers before deleting a library."; return false
        }
        do {
            guard !(try model.textDrafts.get().drafts(account: account.id)).contains(where: { $0.repository == wiki.repoID && $0.changed }) else {
                error = "Upload, export or discard this library's text drafts before deleting it."; return false
            }
        } catch { self.error = documentError(error); return false }
        #if os(macOS)
        guard !SyncController.shared.libraries.contains(where: { $0.id == wiki.repoID }), !MacFileEditor.shared.hasChanges(account: account) else {
            error = "Unsync this library and upload or export local edits before deleting its wiki."; return false
        }
        #else
        do {
            if let settings = try model.photoBackup.settings(account), settings.enabled, settings.repository == wiki.repoID {
                error = "Turn off this library's photo backup before deleting it."; return false
            }
        } catch { self.error = documentError(error); return false }
        #endif
        return true
    }
}

private struct WikiPublishSheet: View {
    let action: (String) -> Void
    @State private var suffix = ""
    @Environment(\.dismiss) private var dismiss
    private var validSuffix: Bool {
        let value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^[A-Za-z0-9-]{5,30}$"#, options: .regularExpression) != nil
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Public address suffix", text: $suffix).textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).accessibilityIdentifier("wiki.suffix")
                Text("Publishing makes this wiki available to anyone with its address. Use 5–30 letters, numbers or hyphens.").font(.caption)
            }.formStyle(.grouped).navigationTitle("Publish wiki")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Publish") { action(suffix); dismiss() }.disabled(!validSuffix).accessibilityIdentifier("wiki.confirmPublish") }
                }
        }.frame(minWidth: 300, minHeight: 240)
    }
}

/// Only stable error categories reach these controls; never echo a response
/// body, redirect URL, token or NSError userInfo from a collaborative session.
func documentError(_ error: Error) -> String {
    if case SeafileError.server(let status, _) = error { return "The server could not complete this request (\(status)). Refresh and check the result before trying again." }
    return "The document request could not be completed. Check your connection and try again."
}

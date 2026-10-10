import SwiftUI
import SeafileCore

struct WikiPagesView: View {
    var model: AppModel
    let account: ServerAccount, wiki: Wiki
    @State private var pages: [WikiPage] = []
    @State private var loading = false
    @State private var error: String?
    @State private var document: ServerDocument?
    @State private var comments: WikiPage?
    @State private var generation = UUID()
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(pages) { page in
                HStack {
                    Button {
                        do { document = ServerDocument(title: page.name, url: try account.endpoint.api("wikis/\(wiki.wikiID)/\(page.id)/")) }
                        catch { self.error = documentError(error) }
                    } label: { Label(page.name, systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    Button("Comments", systemImage: "text.bubble") { comments = page }.buttonStyle(.borderless).accessibilityIdentifier("comments.open.\(page.id)")
                }
            }
            if loading { ProgressView("Loading pages") }
            if pages.isEmpty && !loading && error == nil { Text("No pages") }
        }.navigationTitle(wiki.name)
            .task { await load() }.refreshable { await load() }
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
            .onDisappear { generation = UUID(); loading = false }
            .sheet(item: $document) { item in ServerDocumentView(model: model, account: account, document: item) }
            .sheet(item: $comments) { page in DocumentCommentsView(model: model, account: account, wiki: wiki, page: page) }
    }
    private func load() async {
        guard !loading else { return }
        let ticket = UUID(); generation = ticket; loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let result = try await model.client(for: account).wikiPages(id: wiki.wikiID)
            try Task.checkCancellation()
            guard generation == ticket, model.selectedAccountID == account.id else { return }
            pages = result; error = nil
        } catch is CancellationError { }
        catch { if generation == ticket { self.error = documentError(error) } }
    }
}

struct DocumentCommentsView: View {
    var model: AppModel
    let account: ServerAccount, wiki: Wiki, page: WikiPage
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [DocumentComment] = []
    @State private var pageNumber = 0
    @State private var more = false
    @State private var loading = false
    @State private var working = false
    @State private var error: String?
    @State private var text = ""
    @State private var filter = "all"
    @State private var replying: DocumentComment?
    @State private var editing: DocumentComment?
    private struct ReplyTarget { let comment: Int; let reply: DocumentReply }
    @State private var editingReply: ReplyTarget?
    @State private var deletingReply: ReplyTarget?
    @State private var deletion: DocumentComment?
    @State private var closing = false
    @State private var cancellingComposer = false
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Comments", selection: $filter) { Text("All comments").tag("all"); Text("Open comments").tag("open"); Text("Resolved comments").tag("resolved") }.disabled(working)
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("comments.error") }
                    if comments.isEmpty && !loading && error == nil { Text("No comments") }
                }
                ForEach(comments) { comment in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(comment.user_name ?? String(localized: "Member")).font(.headline)
                            Text(CommentText.plain(comment.comment)).textSelection(.enabled)
                            if comment.resolved { Label("Resolved", systemImage: "checkmark.circle").font(.caption) }
                            if let date = comment.created_at { Text(date).font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(comment.replies ?? []) { reply in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reply.user_name ?? String(localized: "Member")).font(.caption).foregroundStyle(.secondary)
                                Text(CommentText.plain(reply.reply))
                                if wiki.writable, reply.user_email?.caseInsensitiveCompare(account.email) == .orderedSame {
                                    HStack {
                                        if CommentText.canEdit(reply.reply) {
                                            Button("Edit reply") { editingReply = ReplyTarget(comment: comment.id, reply: reply); replying = nil; editing = nil; text = CommentText.plain(reply.reply) }.disabled(!text.isEmpty)
                                        }
                                        Button("Delete reply", role: .destructive) { deletingReply = ReplyTarget(comment: comment.id, reply: reply) }
                                    }.buttonStyle(.borderless).disabled(working || loading)
                                }
                            }.padding(.leading, 16)
                        }
                        if wiki.writable {
                            HStack {
                                Button("Reply") { replying = comment; editing = nil; editingReply = nil }.disabled(!text.isEmpty).accessibilityIdentifier("comments.reply.\(comment.id)")
                                Button {
                                    mutate { try await model.client(for: account).resolveDocumentComment(repo: wiki.repoID, document: page.documentID, comment: comment.id, resolved: !comment.resolved) }
                                } label: {
                                    if comment.resolved { Text("Reopen") } else { Text("Resolve") }
                                }.accessibilityIdentifier("comments.resolve.\(comment.id)")
                                if comment.user_email?.caseInsensitiveCompare(account.email) == .orderedSame {
                                    if CommentText.canEdit(comment.comment) { Button("Edit") { editing = comment; replying = nil; editingReply = nil; text = CommentText.plain(comment.comment) }.disabled(!text.isEmpty) }
                                    Button("Delete", role: .destructive) { deletion = comment }.accessibilityIdentifier("comments.delete.\(comment.id)")
                                }
                            }.buttonStyle(.borderless).disabled(working || loading)
                        }
                    }
                }
                if loading { ProgressView("Loading comments") }
                if more { Button("Load more") { Task { await load(reset: false) } }.disabled(loading || working) }
                if wiki.writable {
                    Section {
                        TextEditor(text: $text).frame(minHeight: 100).disabled(working).accessibilityIdentifier("comments.text")
                        if editing != nil || editingReply != nil || replying != nil {
                            Button("Cancel editing") { if text.isEmpty { clearComposer() } else { cancellingComposer = true } }.disabled(working)
                        }
                        Button("Send") {
                            do { _ = try CommentText.html(text) }
                            catch { self.error = String(localized: "Enter a comment of up to 64 KB."); return }
                            let submitted = text, replyID = replying?.id, editID = editing?.id, editedReply = editingReply
                            mutate(clearComposer: true) {
                                let api = try model.client(for: account)
                                if let editedReply { try await api.editDocumentReply(repo: wiki.repoID, document: page.documentID, comment: editedReply.comment, reply: editedReply.reply.id, text: submitted) }
                                else if let editID { try await api.editDocumentComment(repo: wiki.repoID, document: page.documentID, comment: editID, text: submitted) }
                                else if let replyID { try await api.replyToDocumentComment(repo: wiki.repoID, document: page.documentID, comment: replyID, text: submitted) }
                                else { try await api.addDocumentComment(repo: wiki.repoID, document: page.documentID, text: submitted) }
                            }
                        }.disabled(working || loading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("comments.send")
                    } header: {
                        if editingReply != nil { Text("Edit reply") }
                        else if editing != nil { Text("Edit comment") }
                        else if replying != nil { Text("Reply") }
                        else { Text("New comment") }
                    }
                }
                Text("Mentions, images and formatted comments are available in the document editor.").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Comments")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { if text.isEmpty { dismiss() } else { closing = true } }.disabled(working) }
                    ToolbarItem(placement: .primaryAction) { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading || working) }
                }
                .task(id: filter) { generation = UUID(); loading = false; await load() }
                .refreshable { await load() }
                .confirmationDialog("Discard this comment?", isPresented: $closing, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
                .confirmationDialog("Discard this comment?", isPresented: $cancellingComposer, titleVisibility: .visible) { Button("Discard", role: .destructive) { clearComposer() } }
                .confirmationDialog("Delete comment?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { guard let comment = deletion else { return }; deletion = nil; mutate { try await model.client(for: account).deleteDocumentComment(repo: wiki.repoID, document: page.documentID, comment: comment.id) } }
                }
                .confirmationDialog("Delete reply?", isPresented: Binding(get: { deletingReply != nil }, set: { if !$0 { deletingReply = nil } }), titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { guard let target = deletingReply else { return }; deletingReply = nil; mutate { try await model.client(for: account).deleteDocumentReply(repo: wiki.repoID, document: page.documentID, comment: target.comment, reply: target.reply.id) } }
                }
        }.interactiveDismissDisabled(working || !text.isEmpty)
            .onAppear { model.beginFileAction(account) }.onDisappear { generation = UUID(); model.endFileAction(account) }
            .onChange(of: model.selectedAccountID) { _, id in if id != account.id { dismiss() } }
            #if os(macOS)
            .frame(minWidth: 600, minHeight: 500)
            #endif
    }
    private func load(reset: Bool = true) async {
        guard !loading else { return }
        let ticket = UUID(); generation = ticket; loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let requested = reset ? 1 : pageNumber + 1
            let result = try await model.client(for: account).documentComments(repo: wiki.repoID, document: page.documentID, page: requested, resolved: filter == "all" ? nil : filter == "resolved")
            try Task.checkCancellation()
            guard generation == ticket, model.selectedAccountID == account.id else { return }
            if reset { comments = result.comments } else { comments += result.comments.filter { entry in !comments.contains(where: { $0.id == entry.id }) } }
            pageNumber = requested; more = result.comments.count == 25; error = nil
        } catch is CancellationError { }
        catch { if generation == ticket { self.error = documentError(error) } }
    }
    private func mutate(clearComposer: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard !working, !loading, model.selectedAccountID == account.id else { return }
        working = true
        Task {
            defer { working = false }
            var failure: String?
            do { try await action(); if clearComposer { self.clearComposer() } }
            catch { failure = String(localized: "The server response was not received. Refresh and check whether the change was saved before submitting it again.") }
            // The server may have accepted a mutation before its response was
            // lost. Refresh once and preserve the input; never replay the write.
            await load()
            if let failure { error = failure }
        }
    }
    private func clearComposer() { text = ""; replying = nil; editing = nil; editingReply = nil }
}

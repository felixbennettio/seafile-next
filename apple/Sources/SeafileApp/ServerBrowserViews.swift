import SwiftUI
import SeafileCore

struct ServerSearchView: View {
    var model: AppModel
    let account: ServerAccount
    var repo: Repository? = nil
    @State private var query = ""
    @State private var scope = ""
    @State private var info: ServerInfo?
    @State private var featureLoading = false
    @State private var results: [FileSearchItem] = []
    @State private var page = 1
    @State private var more = false
    @State private var searched = false
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var searchTask: Task<Void, Never>?
    private var advanced: Bool { info?.supportsAdvancedSearch == true }
    private var ready: Bool { info != nil && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (advanced || !scope.isEmpty) }

    var body: some View {
        List {
            Section {
                if let repo { Label(repo.name, systemImage: "externaldrive") }
                else {
                    Picker("Library", selection: $scope) {
                        if advanced { Text("All libraries").tag("") }
                        ForEach(model.repositories) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("search.library")
                }
                if info != nil && !advanced {
                    Text("Search file and folder names within the selected library.").font(.caption).foregroundStyle(.secondary)
                }
                if featureLoading { ProgressView("Checking search availability") }
                if info == nil && !featureLoading {
                    Button("Try again") { Task { await loadFeatures() } }
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            Section {
                ForEach(results) { result in
                    if let repository = model.repositories.first(where: { $0.id == result.repo_id }) {
                        NavigationLink {
                            RepositoryView(model: model, account: account, repo: repository,
                                path: result.is_dir ? result.fullpath : (result.fullpath as NSString).deletingLastPathComponent,
                                initialFile: result.is_dir ? nil : result.name)
                        } label: { resultLabel(result, library: repository.name) }
                            .accessibilityIdentifier("search.result.\(result.fullpath)")
                    } else {
                        resultLabel(result, library: "This library is no longer available.")
                    }
                }
                if searched && results.isEmpty && !loading && error == nil { Text("No matching files or folders") }
                if loading { ProgressView("Searching") }
                if more { Button("Load more") { search(next: true) }.disabled(loading) }
            }
        }
        .navigationTitle(repo.map { "Search in \($0.name)" } ?? "Search server")
        .searchable(text: $query, prompt: "Search files and folders")
        .onSubmit(of: .search) { search() }
        .toolbar {
            Button("Search", systemImage: "magnifyingglass") { search() }
                .disabled(!ready || loading).accessibilityIdentifier("search.submit")
        }
        .task { scope = repo?.id ?? scope; if info == nil { await loadFeatures() } }
        .onChange(of: query) { _, _ in invalidate(clear: true) }
        .onChange(of: scope) { _, _ in invalidate(clear: true) }
        .onDisappear { invalidate(clear: false) }
    }
    private func resultLabel(_ item: FileSearchItem, library: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.name, systemImage: item.is_dir ? "folder" : "doc")
            Text(library + " · " + item.fullpath).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func loadFeatures() async {
        guard !featureLoading else { return }
        featureLoading = true
        defer { featureLoading = false }
        do {
            let result = try await model.client(for: account).serverInfo()
            try Task.checkCancellation()
            guard model.selectedAccountID == account.id else { return }
            info = result; error = nil
            if !result.supportsAdvancedSearch && scope.isEmpty { scope = repo?.id ?? model.repositories.first?.id ?? "" }
        } catch is CancellationError { }
        catch { error = error.localizedDescription }
    }
    private func invalidate(clear: Bool) {
        generation = UUID(); searchTask?.cancel(); searchTask = nil; loading = false
        if clear { results = []; page = 1; more = false; searched = false; error = nil }
    }
    private func search(next: Bool = false) {
        guard ready, !loading else { return }
        let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedScope = scope, requestedPage = next ? page + 1 : 1, useAdvanced = advanced
        let ticket = UUID(); generation = ticket
        loading = true; error = nil
        searchTask = Task {
            defer { if generation == ticket { loading = false; searchTask = nil } }
            do {
                let api = try model.client(for: account)
                let response: FileSearchPage
                if useAdvanced { response = try await api.search(requestedQuery, repo: requestedScope.isEmpty ? nil : requestedScope, page: requestedPage) }
                else { response = try await api.searchInLibrary(requestedQuery, repo: requestedScope) }
                try Task.checkCancellation()
                guard generation == ticket, model.selectedAccountID == account.id else { return }
                if next { results += response.results.filter { item in !results.contains { $0.id == item.id } } }
                else { results = response.results }
                page = requestedPage; more = response.has_more; searched = true
            } catch is CancellationError { }
            catch { if generation == ticket { error = error.localizedDescription } }
        }
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
    @State private var generation = UUID()
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(events) { event in
                NavigationLink { CommitChangesView(model: model, account: account, event: event) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.repo_name).font(.headline)
                        Text(activityLabel(event) + (event.name.flatMap { $0.isEmpty ? nil : $0 }.map { " · " + $0 } ?? ""))
                        Text((event.author_name ?? "") + " · " + event.time).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("activity.event.\(event.commit_id ?? event.id)")
            }
            if page > 0 && events.isEmpty && error == nil { Text("No recent activity") }
            if more { Button("Load more") { Task { await load() } }.disabled(loading) }
            if loading { ProgressView("Loading activity") }
        }.navigationTitle("Activity").task { if page == 0 { await load() } }
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(reset: true) } }.disabled(loading) }
            .refreshable { await load(reset: true) }
            .onDisappear { generation = UUID(); loading = false }
    }
    private func load(reset: Bool = false) async {
        guard !loading else { return }
        let ticket = UUID(); generation = ticket; loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let requestedPage = reset ? 1 : page + 1
            let response = try await model.client(for: account).activities(page: requestedPage)
            try Task.checkCancellation()
            guard generation == ticket, model.selectedAccountID == account.id else { return }
            if reset { events = response } else { events += response.filter { event in !events.contains { $0.id == event.id } } }
            page = requestedPage; more = !response.isEmpty; error = nil
        } catch is CancellationError { }
        catch { if generation == ticket { error = error.localizedDescription } }
    }
}

private func activityLabel(_ event: RemoteActivity) -> String {
    switch event.op_type {
    case "create", "add": return String(localized: "Added")
    case "edit", "modify": return String(localized: "Edited")
    case "delete": return String(localized: "Deleted")
    case "move": return String(localized: "Moved")
    case "rename": return String(localized: "Renamed")
    case "recover", "revert": return String(localized: "Restored")
    case "publish": return String(localized: "Published")
    case "clean-up-trash": return String(localized: "Emptied trash")
    default: return event.op_type.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

private struct CommitChangesView: View {
    var model: AppModel
    let account: ServerAccount
    let event: RemoteActivity
    @State private var changes: [(String, String)] = []
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        List {
            Text(event.repo_name).font(.headline)
            Text(activityLabel(event) + " · " + event.time)
            if let repository = model.repositories.first(where: { $0.id == event.repo_id }) {
                NavigationLink("Open library") { RepositoryView(model: model, account: account, repo: repository) }
            }
            ForEach(Array(changes.enumerated()), id: \.offset) { item in
                VStack(alignment: .leading) {
                    Text(item.element.0).font(.caption).foregroundStyle(.secondary)
                    Text(item.element.1).textSelection(.enabled)
                }
            }
            if loading { ProgressView("Loading changes") }
            else if changes.isEmpty && error == nil { Text("No file change details are available for this event.") }
            if let error { Text(error).foregroundStyle(.secondary) }
        }.navigationTitle("Change details").task {
            guard let commit = event.commit_id, !commit.isEmpty else { return }
            loading = true
            defer { loading = false }
            do {
                let result = try await model.client(for: account).commitChanges(repo: event.repo_id, commit: commit).items
                try Task.checkCancellation()
                guard model.selectedAccountID == account.id else { return }
                changes = result
            } catch is CancellationError { }
            catch { error = error.localizedDescription }
        }
    }
}

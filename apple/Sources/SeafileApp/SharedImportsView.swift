#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import SeafileCore

struct SharedImportsSection: View {
    let model: AppModel
    @State private var imports: [SharedImport] = []
    @State private var error: String?
    @State private var selected: SharedImport?
    @State private var deleting: SharedImport?
    var body: some View {
        Section("Shared from other apps") {
            ForEach(imports) { share in
                VStack(alignment: .leading, spacing: 8) {
                    Text(share.files.map(\.name).joined(separator: ", ")).font(.headline).lineLimit(2)
                    Text(share.completed ? "Completed" : "Local copies preserved").foregroundStyle(.secondary)
                    if let directory = share.directory { Text(directory).font(.caption) }
                    HStack {
                        if !share.completed { Button("Open shared files") { selected = share }.accessibilityIdentifier("share.inbox.open") }
                        ForEach(share.files.filter { $0.state != .completed }) { file in
                            if let store = try? model.sharedImports.get(), let url = try? store.fileURL(file, in: share.id) {
                                ShareLink(item: url) { Label("Export local copy", systemImage: "square.and.arrow.up") }
                            }
                        }
                        Button("Remove", role: .destructive) { deleting = share }
                    }.buttonStyle(.bordered)
                }.padding(.vertical, 6)
            }
            if let error { Text(error).foregroundStyle(.red); Button("Retry") { reload() } }
        }.task {
            while !Task.isCancelled {
                reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .sheet(item: $selected, onDismiss: reload) { share in
            if let store = try? model.sharedImports.get() {
                ShareComposerView(model: ShareComposerModel(store: store, existing: share.id, requiresAuthentication: false,
                    accounts: { model.accounts }, client: { try model.client(for: $0) })) { selected = nil }
            }
        }
        .confirmationDialog("Remove shared files and their local copies?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let deleting { do { try model.sharedImports.get().remove(deleting.id) } catch { self.error = error.localizedDescription } }
                deleting = nil; reload()
            }
        } message: { Text("Server files are kept. Export unfinished uploads before removing their preserved local copies.") }
    }
    private func reload() {
        do { imports = try model.sharedImports.get().list().filter { !$0.files.isEmpty }; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
struct ShareFixtureView: View {
    let model: AppModel
    let close: () -> Void
    let locked: Bool
    @State private var composer: ShareComposerModel?
    @State private var error: String?
    var body: some View {
        Group {
            if let composer { ShareComposerView(model: composer, close: close) }
            else if let error { Text(error) }
            else { ProgressView() }
        }.task {
            do {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("shared-fixture.txt")
                try Data("Actual shared file contents\n".utf8).write(to: file)
                let provider = NSItemProvider(); provider.suggestedName = "shared-fixture.txt"
                provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all) { completion in
                    completion(file, false, nil); return nil
                }
                let text = NSItemProvider(object: "Shared text fixture" as NSString)
                let link = NSItemProvider(object: URL(string: "https://example.invalid/shared")! as NSURL)
                composer = ShareComposerModel(store: try model.sharedImports.get(), providers: [provider, text, link], requiresAuthentication: locked,
                    accounts: { model.accounts }, client: { try model.client(for: $0) }, authentication: { true })
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
#endif

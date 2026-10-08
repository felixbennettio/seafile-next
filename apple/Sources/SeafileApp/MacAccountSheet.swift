#if os(macOS)
import SwiftUI
import SeafileCore

struct MacAccountSheet: View {
    var model: AppModel
    let account: ServerAccount
    @State private var alias: String
    @State private var server: String
    @State private var info: AccountInfo?
    @State private var error: String?
    @State private var working = false
    @State private var login = false
    @State private var logout = false
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, account: ServerAccount) {
        self.model = model; self.account = account
        _alias = State(initialValue: account.alias ?? "")
        _server = State(initialValue: account.endpoint.url.absoluteString)
    }
    var body: some View {
        NavigationStack {
            Form {
                Text(account.email).font(.headline)
                PreferenceInput("Account name") { TextField("Account name", text: $alias).labelsHidden() }
                PreferenceInput("Server address") { TextField("Server address", text: $server).labelsHidden() }
                if let info, let usage = info.usage {
                    Text("Used: \(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file))")
                    if let total = info.total, total > 0 { ProgressView(value: Double(usage), total: Double(total)); Text("Quota: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))") }
                }
                Button("Sign in again") { login = true }
                Button("Log out this device") { logout = true }
                Button("Set up default library") { run { _ = try await model.client(for: account).defaultRepository(create: true); await model.refresh() } }
                if let error { Text(error).foregroundStyle(.secondary) }
                if working { ProgressView() }
            }.formStyle(.grouped).navigationTitle("Account settings")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { run { try await model.update(account, alias: alias, server: server); dismiss() } }.disabled(working || (try? ServerEndpoint(server)) == nil) }
                }
        }.frame(width: 520, height: 510)
            .task { do { info = try await model.client(for: account).accountInfo() } catch { self.error = error.localizedDescription } }
            .sheet(isPresented: $login) { LoginView(model: model, account: account) }
            .confirmationDialog("Log out this device?", isPresented: $logout) {
                Button("Log out") { run { try await model.logout(account) } }
            } message: { Text("Synced local folders and local edits are preserved.") }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { working = true; Task { defer { working = false }; do { try await operation(); error = nil } catch { self.error = error.localizedDescription } } }
}
#endif

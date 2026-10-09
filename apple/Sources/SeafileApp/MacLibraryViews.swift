import SwiftUI
import SeafileCore

struct CreateLibrarySheet: View {
    var model: AppModel
    let account: ServerAccount
    @State private var name = ""
    @State private var description = ""
    @State private var encrypted = false
    @State private var password = ""
    @State private var repeatedPassword = ""
    #if os(macOS)
    @State private var localFolder: URL?
    @State private var importing = false
    #endif
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                ActionInput("Name") { TextField("Library name", text: $name).labelsHidden().accessibilityIdentifier("library.createName") }
                ActionInput("Description") { TextField("Library description", text: $description).labelsHidden() }
                Toggle("Encrypted library", isOn: $encrypted)
                if encrypted {
                    ActionInput("Library password") { SecureField("Library password", text: $password).labelsHidden() }
                    ActionInput("Repeat password") { SecureField("Repeat password", text: $repeatedPassword).labelsHidden() }
                    #if os(macOS)
                    Text("The encryption keys are generated on this Mac. Keep the password safe; it cannot be recovered.").font(.caption).foregroundStyle(.secondary)
                    #else
                    Text("The server creates the encrypted library using this password. Keep it safe; it cannot be recovered.").font(.caption).foregroundStyle(.secondary)
                    #endif
                }
                #if os(macOS)
                Button(localFolder.map { "Sync folder: \($0.path)" } ?? "Create from an existing local folder") { importing = true }
                if localFolder != nil { Button("Create without a local folder") { localFolder = nil } }
                #endif
                if let error { Text(error).foregroundStyle(.red) }
                if working { ProgressView("Creating library") }
            }.formStyle(.grouped).navigationTitle("New library")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await create() } }.disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (encrypted && (password.isEmpty || password != repeatedPassword))).accessibilityIdentifier("library.createConfirm") }
                }
        }
        .interactiveDismissDisabled(working)
        #if os(macOS)
        .frame(width: 520, height: 510)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                switch result { case .success(let folder): localFolder = folder; if name.isEmpty { name = folder.lastPathComponent }; case .failure(let error): self.error = error.localizedDescription }
            }
        #endif
    }
    private func create() async {
        guard !working else { return }
        working = true; error = nil; model.beginFileAction(account)
        defer { working = false; model.endFileAction(account) }
        do {
            let api = try model.client(for: account)
            var fields: [String: String] = [:]
            if encrypted {
                #if os(macOS)
                fields = try await SyncController.shared.encryptionFields(api: api, password: password)
                #else
                fields = ["passwd": password]
                #endif
            }
            let id = try await api.createRepository(name: name, description: description, encryption: fields)
            await model.refresh()
            #if os(macOS)
            if let localFolder, let repo = model.repositories.first(where: { $0.id == id }) {
                try await SyncController.shared.clone(repo: repo, account: account, api: api, folder: localFolder, password: password, existing: true)
            }
            #else
            _ = id
            #endif
            password = ""; repeatedPassword = ""; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

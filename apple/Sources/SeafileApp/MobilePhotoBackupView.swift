#if os(iOS)
import SwiftUI
import Photos
import SeafileCore

struct MobilePhotoBackupView: View {
    var model: AppModel
    let account: ServerAccount
    @State private var settings = PhotoBackupSettings(repository: "", path: "/")
    @State private var libraries: [Repository] = []
    @State private var destination = false
    @State private var error: String?
    @State private var retry = false
    @State private var albums: [BackupAlbum] = []
    @Environment(\.dismiss) private var dismiss
    private var backup: MobilePhotoBackup { model.photoBackup }
    var body: some View {
        NavigationStack {
            Form {
                Section("Photo access") {
                    Text(accessDescription)
                    if ![.authorized, .limited].contains(backup.access) {
                        Button("Allow photo access") { Task { _ = await backup.requestAccess(); loadAlbums() } }.accessibilityIdentifier("backup.photoAccess")
                    }
                    if backup.access == .denied || backup.access == .restricted {
                        Button("Open system settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }
                }
                Section("Destination") {
                    Button {
                        destination = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(libraries.first { $0.id == settings.repository }?.name ?? "Choose a library and folder")
                            Text(settings.path).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(backup.running).accessibilityIdentifier("backup.destination")
                    Text("Backups keep the original photo and video resources. Live Photos include a separate paired video. Distinct photos and edited versions use distinct names.").font(.caption)
                }
                Section("Backup options") {
                    Toggle("Enable photo backup", isOn: Binding(get: { settings.enabled }, set: { setEnabled($0) }))
                        .disabled(backup.running || settings.repository.isEmpty || ![.authorized, .limited].contains(backup.access))
                        .accessibilityIdentifier("backup.enabled")
                    Toggle("Wi-Fi only", isOn: $settings.wifiOnly).accessibilityIdentifier("backup.wifi")
                    Toggle("Include videos", isOn: $settings.includeVideos).accessibilityIdentifier("backup.videos")
                    Toggle("Include Live Photo videos", isOn: $settings.includeLivePhotoVideo)
                    Text("With Wi-Fi only enabled, cellular, expensive and Low Data Mode connections are excluded. Keep the app open for this version's backups; system background transfer is still being migrated.").font(.caption).foregroundStyle(.secondary)
                    Button("Save options") { persist() }.disabled(backup.running || settings.repository.isEmpty)
                }.disabled(backup.running)
                if !albums.isEmpty {
                    Section("Albums") {
                        Toggle("All accessible photos", isOn: Binding(get: { settings.albums.isEmpty }, set: { all in
                            if all { settings.albums = [] } else if let first = albums.first { settings.albums = [first.id] }
                        }))
                        if !settings.albums.isEmpty {
                            ForEach(albums) { album in
                                Toggle(album.name, isOn: Binding(get: { settings.albums.contains(album.id) }, set: { selected in
                                    if selected { settings.albums.append(album.id) }
                                    else if settings.albums.count > 1 { settings.albums.removeAll { $0 == album.id } }
                                }))
                            }
                        }
                        Text("Save options after changing the album selection. Limited Photos access backs up only the photos you have allowed.").font(.caption)
                    }.disabled(backup.running)
                }
                Section("Status") {
                    Text(backup.status).accessibilityIdentifier("backup.status")
                    Text("\(backup.completed(account)) resources backed up").accessibilityIdentifier("backup.completed")
                    if let error = error ?? backup.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("backup.error") }
                    if backup.running { Button("Stop backup") { backup.stop() } }
                    else {
                        Button("Back up now") { persist(); if error == nil { backup.wake(byUser: true) } }
                            .disabled(!settings.enabled).accessibilityIdentifier("backup.run")
                        Button("Check and retry failed backups") { retry = true }.disabled(!settings.enabled)
                    }
                    Text("Stopping or losing a connection preserves upload records and local copies. Failed uploads wait for your check before they can be sent again.").font(.caption)
                }
            }.navigationTitle("Photo backup").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.task {
            do {
                settings = try backup.settings(account) ?? settings
                libraries = try await model.client(for: account).repositories().filter { $0.writable && !$0.encrypted }
                loadAlbums()
            } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $destination) {
            BackupDestinationPicker(model: model, account: account, libraries: libraries, repository: settings.repository, path: settings.path) { repo, path in
                settings.repository = repo; settings.path = path; persist()
            }
        }
        .confirmationDialog("Check and retry failed photo uploads?", isPresented: $retry, titleVisibility: .visible) {
            Button("Check and retry") { persist(); if error == nil { backup.wake(retryFailed: true, byUser: true) } }
        } message: { Text("Existing destination files are verified first. A matching file is kept; a different file is never replaced. Uploads that are still missing may be submitted again.") }
    }
    private var accessDescription: String {
        switch backup.access {
        case .authorized: "All photos are accessible"
        case .limited: "Only your selected photos are accessible"
        case .denied, .restricted: "Photo access is unavailable. Change access in system settings."
        default: "Allow Photos access when you choose to enable backup."
        }
    }
    private func setEnabled(_ value: Bool) { settings.enabled = value; persist() }
    private func persist() {
        do { try backup.configure(account, settings); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func loadAlbums() {
        guard [.authorized, .limited].contains(backup.access) else { albums = []; return }
        #if DEBUG
        if model.uiFixture != nil { albums = []; return }
        #endif
        var result: [BackupAlbum] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { album, _, _ in
            result.append(BackupAlbum(id: album.localIdentifier, name: album.localizedTitle ?? "Album"))
        }
        albums = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
private struct BackupAlbum: Identifiable { let id: String, name: String }

private struct BackupDestinationPicker: View {
    let model: AppModel, account: ServerAccount, libraries: [Repository]
    @State var repository: String
    @State var path: String
    let choose: (String, String) -> Void
    @State private var entries: [DirectoryEntry] = []
    @State private var loading = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker("Library", selection: $repository) { Text("Choose a library").tag(""); ForEach(libraries) { Text($0.name).tag($0.id) } }
                    .accessibilityIdentifier("backup.library")
                    .onChange(of: repository) { _, _ in path = "/" }
                if !repository.isEmpty {
                    Text(path)
                    if path != "/" { Button("Parent folder") { path = (path as NSString).deletingLastPathComponent } }
                    ForEach(entries.filter(\.isDirectory)) { entry in Button(entry.name, systemImage: "folder") { path = entry.path(in: path) } }
                }
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Backup destination").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose this folder") { choose(repository, path); dismiss() }
                        .disabled(repository.isEmpty || loading || error != nil).accessibilityIdentifier("backup.choose")
                }
            }
        }.task(id: repository + ":" + path) {
            loading = true; error = nil; entries = []
            guard !repository.isEmpty else { loading = false; return }
            do {
                let found = try await model.client(for: account).directory(repo: repository, path: path)
                try Task.checkCancellation(); entries = found; loading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
        }.onAppear { if repository.isEmpty { repository = libraries.first?.id ?? "" } }
    }
}
#endif

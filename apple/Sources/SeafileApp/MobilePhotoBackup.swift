#if os(iOS)
import SwiftUI
@preconcurrency import Photos
import Network
import SeafileCore

struct BackupPhotoAsset: Sendable { let id: String, revision: String, video: Bool }
struct BackupPhotoResource: Sendable { let asset: String, kind: Int, filename: String }
@MainActor protocol BackupPhotoSource {
    var access: PHAuthorizationStatus { get }
    func requestAccess() async -> PHAuthorizationStatus
    func assets(videos: Bool, albums: [String]) -> [BackupPhotoAsset]
    func resources(asset: String, liveVideo: Bool) -> [BackupPhotoResource]
    func export(_ resource: BackupPhotoResource, to destination: URL, network: Bool) async throws
}
private struct PhotoLibrarySource: BackupPhotoSource {
    var access: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    func requestAccess() async -> PHAuthorizationStatus { await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
    func assets(videos: Bool, albums: [String]) -> [BackupPhotoAsset] {
        let options = PHFetchOptions()
        options.predicate = videos ? NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var result: [BackupPhotoAsset] = [], seen = Set<String>()
        func append(_ assets: PHFetchResult<PHAsset>) {
            assets.enumerateObjects { asset, _, _ in
                if seen.insert(asset.localIdentifier).inserted {
                    result.append(BackupPhotoAsset(id: asset.localIdentifier,
                        revision: String((asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970), video: asset.mediaType == .video))
                }
            }
        }
        if albums.isEmpty { append(PHAsset.fetchAssets(with: options)) }
        else {
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albums, options: nil).enumerateObjects { collection, _, _ in
                append(PHAsset.fetchAssets(in: collection, options: options))
            }
        }
        return result
    }
    func resources(asset id: String, liveVideo: Bool) -> [BackupPhotoResource] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return [] }
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the current full-size representation after an edit. Use only
        // public PhotoKit properties; never the old KVC filename/fileSize APIs.
        let primary = asset.mediaType == .video
            ? resources.first { $0.type == .fullSizeVideo } ?? resources.first { $0.type == .video }
            : resources.first { $0.type == .fullSizePhoto } ?? resources.first { $0.type == .photo }
        var selected = primary.map { [$0] } ?? []
        if liveVideo, asset.mediaSubtypes.contains(.photoLive),
           let paired = resources.first(where: { $0.type == .fullSizePairedVideo }) ?? resources.first(where: { $0.type == .pairedVideo }) { selected.append(paired) }
        return selected.map { BackupPhotoResource(asset: id, kind: $0.type.rawValue, filename: $0.originalFilename) }
    }
    func export(_ reference: BackupPhotoResource, to destination: URL, network: Bool) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [reference.asset], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type.rawValue == reference.kind && $0.originalFilename == reference.filename }) else {
            throw SeafileError.local("This photo is no longer accessible. Its upload history is preserved.")
        }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = network
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

private final class BackupPhotoObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let changed: @Sendable () -> Void
    init(changed: @escaping @Sendable () -> Void) { self.changed = changed }
    func photoLibraryDidChange(_ changeInstance: PHChange) { changed() }
}

@MainActor @Observable final class MobilePhotoBackup {
    private weak var model: AppModel?
    @ObservationIgnored private let history: Result<PhotoBackupHistory, Error>
    @ObservationIgnored private let source: any BackupPhotoSource
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var observer: BackupPhotoObserver?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeTransfer: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var wifi = false
    var running = false
    private var authorization: PHAuthorizationStatus = .notDetermined
    var status = "Photo backup is off"
    var error: String?
    init(model: AppModel) {
        self.model = model
        let root: URL
        #if DEBUG
        if model.uiFixture != nil {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("seafile-photo-fixture-" + UUID().uuidString)
            source = ProcessInfo.processInfo.arguments.contains("--ui-test-real-photos") ? PhotoLibrarySource() : FixturePhotoSource()
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/PhotoBackup")
            source = PhotoLibrarySource()
        }
        #else
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/PhotoBackup")
        source = PhotoLibrarySource()
        #endif
        history = Result { try PhotoBackupHistory(root: root) }
        authorization = source.access
        if case .failure(let failure) = history { error = "Photo backup history could not be opened. Its files are preserved. " + failure.localizedDescription }
    }
    var access: PHAuthorizationStatus { authorization }
    func settings(_ account: ServerAccount) throws -> PhotoBackupSettings? { try history.get().settings(account: account.id) }
    func completed(_ account: ServerAccount) -> Int {
        guard let store = try? history.get(), let settings = store.settings(account: account.id) else { return 0 }
        return (try? store.completedCount(account: account.id, settings: settings)) ?? 0
    }
    func requestAccess() async -> PHAuthorizationStatus {
        authorization = await source.requestAccess(); startIfNeeded(); return authorization
    }
    func configure(_ account: ServerAccount, _ settings: PhotoBackupSettings) throws {
        guard !running else { throw SeafileError.local("Stop photo backup before changing its settings.") }
        if settings.enabled { guard [.authorized, .limited].contains(access) else { throw SeafileError.local("Allow access to Photos to enable backup.") } }
        try history.get().configure(account: account.id, settings: settings)
        paused = false; error = nil
        startIfNeeded(); wake()
    }
    func requireDisabled(_ account: ServerAccount) throws {
        guard try settings(account)?.enabled != true else { throw SeafileError.local("Turn off photo backup before changing or removing this account.") }
    }
    func remove(_ account: ServerAccount) throws { try requireDisabled(account); try history.get().remove(account: account.id) }
    func foregroundChanged(_ active: Bool) {
        foreground = active; authorization = source.access; startIfNeeded()
        if active { wake() } else { stop(pausedByUser: false) }
    }
    private func startIfNeeded() {
        #if DEBUG
        if model?.uiFixture != nil { connected = true; wifi = true; return }
        #endif
        if observer == nil, [.authorized, .limited].contains(access) {
            let observer = BackupPhotoObserver { [weak self] in Task { @MainActor in self?.wake() } }
            self.observer = observer; PHPhotoLibrary.shared().register(observer)
        }
        guard !started else { return }; started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) && !path.isExpensive && !path.isConstrained
            Task { @MainActor in
                guard let self else { return }; self.connected = connected; self.wifi = wifi
                if !connected || !wifi, let id = self.activeTransfer,
                   self.model?.transfers.transfers.first(where: { $0.id == id })?.wifiOnly == true { self.stop(pausedByUser: false) }
                self.wake()
            }
        }
        monitor.start(queue: DispatchQueue(label: "seafile.photo-network"))
    }
    func stop(pausedByUser: Bool = true) {
        if pausedByUser { paused = true }
        task?.cancel()
        if let activeTransfer { model?.transfers.cancel(activeTransfer) }
        status = pausedByUser ? "Photo backup paused" : "Open the app to continue photo backup"
    }
    func wake(retryFailed: Bool = false, byUser: Bool = false) {
        if byUser { paused = false }
        guard foreground, !paused, !running, let model, case .success(let store) = history else { return }
        let accounts = model.accounts.filter { store.settings(account: $0.id)?.enabled == true }
        guard !accounts.isEmpty else { status = "Photo backup is off"; return }
        guard [.authorized, .limited].contains(access) else { error = "Allow access to Photos in Settings to continue backup."; return }
        guard connected else { status = "Waiting for a network connection"; return }
        running = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if Task.isCancelled, let id = self.activeTransfer { model.transfers.cancel(id) }
                self.running = false; self.task = nil; self.activeTransfer = nil
            }
            do {
                for account in accounts {
                    guard let settings = store.settings(account: account.id), settings.enabled else { continue }
                    if settings.wifiOnly && !self.wifi { self.status = "Waiting for Wi-Fi without data restrictions"; continue }
                    model.beginFileAction(account)
                    do { try await self.scan(account, settings: settings, retryFailed: retryFailed) }
                    catch { model.endFileAction(account); throw error }
                    model.endFileAction(account)
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; self.status = "Photo backup needs attention" }
            }
        }
    }
    private func scan(_ account: ServerAccount, settings: PhotoBackupSettings, retryFailed: Bool) async throws {
        guard let model else { return }
        let store = try history.get(), api = try model.client(for: account, wifiOnly: settings.wifiOnly)
        let libraries = try await api.repositories()
        guard let repo = libraries.first(where: { $0.id == settings.repository }), repo.writable, !repo.encrypted else {
            throw SeafileError.local("Select an available, writable, unencrypted library for photo backup.")
        }
        _ = try await api.directory(repo: settings.repository, path: settings.path)
        let assets = source.assets(videos: settings.includeVideos, albums: settings.albums)
        for (index, asset) in assets.enumerated() {
            try checkNetwork(settings)
            status = "Checking photo \(index + 1) of \(assets.count)"
            let resources = source.resources(asset: asset.id, liveVideo: settings.includeLivePhotoVideo)
            guard !resources.isEmpty else { throw SeafileError.local("A selected photo is no longer accessible. Check your Photos selection before continuing.") }
            for resource in resources {
                try checkNetwork(settings)
                let kind = String(resource.kind) + ":" + resource.filename
                let key = PhotoBackupRecord.key(accountID: account.id, repository: settings.repository, path: settings.path,
                    asset: asset.id, revision: asset.revision, resource: kind)
                if try store.record(key)?.completed == true { continue }
                if let record = try store.record(key) {
                    // Recover the tiny crash window between queue persistence
                    // and attaching its ID to the photo history. Never enqueue
                    // another write while an identical snapshot is pending.
                    let transfer = record.transferID ?? model.transfers.transfers.last(where: {
                        $0.accountID == account.id && $0.repository == settings.repository && $0.path == settings.path && $0.name == record.filename && $0.direction == .upload
                    })?.id
                    if let transfer {
                        if record.transferID == nil { try store.submitted(record.id, transfer: transfer) }
                        try await resume(record, transfer: transfer, api: api, retryFailed: retryFailed); continue
                    }
                    if try await confirmRemote(record, api: api) { continue }
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seafile-photo-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                let exported = folder.appendingPathComponent("resource")
                try await source.export(resource, to: exported, network: !settings.wifiOnly || wifi)
                try checkNetwork(settings)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exported.path)
                let hash = try await Task.detached(priority: .utility) { try PhotoBackupFiles.digest(file: exported) }.value
                let filename = try PhotoBackupFiles.filename(original: resource.filename, asset: asset.id, digest: hash.hash)
                let staged = folder.appendingPathComponent(filename); try FileManager.default.moveItem(at: exported, to: staged)
                let record = PhotoBackupRecord(accountID: account.id, repository: settings.repository, path: settings.path,
                    asset: asset.id, revision: asset.revision, resource: kind, filename: filename, digest: hash.hash, size: hash.size)
                try store.prepare(record)
                if try await confirmRemote(record, api: api) { continue }
                try checkNetwork(settings)
                status = "Backing up " + resource.filename
                let transfer = try await model.transfers.enqueueUpload(accountID: account.id, repository: settings.repository, parent: settings.path,
                    source: staged, replace: false, wifiOnly: settings.wifiOnly)
                do { try store.submitted(record.id, transfer: transfer) }
                catch { model.transfers.cancel(transfer); throw error }
                activeTransfer = transfer
                _ = try await model.transfers.result(for: transfer); activeTransfer = nil
                guard try await confirmRemote(record, api: api, verifyBytes: false) else { throw SeafileError.local("The server did not confirm this photo's filename. Check its destination before retrying.") }
            }
            await Task.yield()
        }
        status = "Photo backup is up to date"
    }
    private func checkNetwork(_ settings: PhotoBackupSettings) throws {
        try Task.checkCancellation()
        guard foreground, connected, !settings.wifiOnly || wifi else { throw SeafileError.local("Photo backup is waiting for an allowed network. Existing upload results are preserved.") }
    }
    private func resume(_ record: PhotoBackupRecord, transfer: UUID, api: SeafileAPI, retryFailed: Bool) async throws {
        guard let model else { return }
        guard let item = model.transfers.transfers.first(where: { $0.id == transfer }) else {
            if try await confirmRemote(record, api: api) { return }
            throw SeafileError.local("A photo upload record has no matching transfer. Check its destination before importing the photo again.")
        }
        if item.state == .completed {
            if try await confirmRemote(record, api: api, verifyBytes: false) { return }
            throw SeafileError.local("A completed photo upload is missing from its destination. The backup record is preserved.")
        }
        if !item.active {
            if try await confirmRemote(record, api: api) { return }
            guard retryFailed else { throw SeafileError.local("A photo upload stopped without a confirmed result. Check and retry failed backups to continue. Your photo and local upload copy are preserved.") }
            try model.transfers.retry(transfer)
        }
        activeTransfer = transfer
        _ = try await model.transfers.result(for: transfer); activeTransfer = nil
        guard try await confirmRemote(record, api: api, verifyBytes: false) else { throw SeafileError.invalidResponse }
    }
    private func confirmRemote(_ record: PhotoBackupRecord, api: SeafileAPI, verifyBytes: Bool = true) async throws -> Bool {
        let path = (record.path == "/" ? "" : record.path) + "/" + record.filename
        guard let entry = try await api.fileDetails(repo: record.repository, path: path) else { return false }
        guard entry.size == record.size else { throw SeafileError.local("The destination already contains a different file with this photo's name. It will not be overwritten.") }
        // A confirmed successful queue upload already has the server's HTTP
        // acknowledgement. Avoid downloading every large video again. Only
        // an uncertain/pre-existing result needs an actual byte comparison.
        if !verifyBytes { try history.get().confirm(record.id, digest: record.digest, size: record.size); return true }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await api.download(repo: record.repository, path: path, destination: temporary)
        let hash = try await Task.detached(priority: .utility) { try PhotoBackupFiles.digest(file: temporary) }.value
        try history.get().confirm(record.id, digest: hash.hash, size: hash.size)
        return true
    }
}

#if DEBUG
private struct FixturePhotoSource: BackupPhotoSource {
    var access: PHAuthorizationStatus { .authorized }
    func requestAccess() async -> PHAuthorizationStatus { .authorized }
    func assets(videos: Bool, albums: [String]) -> [BackupPhotoAsset] {
        [BackupPhotoAsset(id: "fixture-photo", revision: "1", video: false)] + (videos ? [BackupPhotoAsset(id: "fixture-video", revision: "1", video: true)] : [])
    }
    func resources(asset: String, liveVideo: Bool) -> [BackupPhotoResource] {
        asset == "fixture-video" ? [BackupPhotoResource(asset: asset, kind: 2, filename: "clip.mov")]
            : [BackupPhotoResource(asset: asset, kind: 1, filename: "IMG_0001.heic")] + (liveVideo ? [BackupPhotoResource(asset: asset, kind: 9, filename: "IMG_0001.mov")] : [])
    }
    func export(_ resource: BackupPhotoResource, to destination: URL, network: Bool) async throws {
        try Data(("Photo backup fixture " + resource.filename).utf8).write(to: destination)
    }
}
#endif
#endif

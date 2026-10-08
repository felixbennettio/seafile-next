import Foundation
import FileProvider
import UniformTypeIdentifiers
import SeafileCore

private struct Locator: Codable {
    var id: String
    var parent: String
    var repo: String
    var path: String
    var name: String
    var folder: Bool
    var writable: Bool
    var size: Int64
    var version: String
}

private final class LocatorStore {
    private let lock = NSRecursiveLock()
    private var records: [String: Locator]
    private let key: String
    init(domain: String) {
        key = "locators." + domain
        records = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Locator].self, from: $0) } ?? [:]
    }
    func get(_ id: String) -> Locator? { lock.lock(); defer { lock.unlock() }; return records[id] }
    func save(_ item: Locator) {
        lock.lock(); defer { lock.unlock() }
        records[item.id] = item
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }
    func rename(_ item: Locator, from oldPath: String) {
        lock.lock(); defer { lock.unlock() }
        if item.folder {
            for (id, var child) in records where child.repo == item.repo && child.path.hasPrefix(oldPath + "/") {
                child.path = item.path + child.path.dropFirst(oldPath.count)
                records[id] = child
            }
        }
        save(item)
    }
    func id(repo: String, path: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return records.values.first { $0.repo == repo && $0.path == path }?.id ?? UUID().uuidString
    }
}

private final class ProviderItem: NSObject, NSFileProviderItem {
    let location: Locator
    init(_ location: Locator) { self.location = location }
    var itemIdentifier: NSFileProviderItemIdentifier { .init(location.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .init(location.parent) }
    var filename: String { location.name }
    var contentType: UTType { location.folder ? .folder : UTType(filenameExtension: (location.name as NSString).pathExtension) ?? .data }
    var documentSize: NSNumber? { location.folder ? nil : NSNumber(value: location.size) }
    var itemVersion: NSFileProviderItemVersion { .init(contentVersion: Data(location.version.utf8), metadataVersion: Data((location.path + location.version).utf8)) }
    var capabilities: NSFileProviderItemCapabilities {
        var value: NSFileProviderItemCapabilities = location.folder ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        if location.writable {
            if location.folder { value.insert(.allowsAddingSubItems) }
            else { value.insert(.allowsWriting) }
            if location.path != "/" { value.formUnion([.allowsRenaming, .allowsDeleting]) }
        }
        return value
    }
}

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let store: LocatorStore
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        store = LocatorStore(domain: domain.identifier.rawValue)
        super.init()
    }
    func invalidate() {}
    private func connection() throws -> (ServerAccount, SeafileAPI) {
        guard let account = try SharedAccounts.read().first(where: { $0.id.uuidString == domain.identifier.rawValue }),
              let token = try CredentialStore.token(for: account) else { throw NSFileProviderError(.notAuthenticated) }
        return (account, SeafileAPI(endpoint: account.endpoint, token: token))
    }
    private func mapped(_ error: Error) -> Error {
        if let error = error as? SeafileError {
            if case .server(let code, _) = error {
                if code == 401 { return NSFileProviderError(.notAuthenticated) }
                if code == 404 { return NSFileProviderError(.noSuchItem) }
                if code == 403 { return CocoaError(.fileReadNoPermission) }
            }
        }
        if error is URLError { return NSFileProviderError(.serverUnreachable) }
        return error
    }
    private func operation(_ action: @escaping () async -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task { await action(); progress.completedUnitCount = 1 }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
    private func childPath(_ name: String, in directory: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw SeafileError.unsafeFilename }
        return (directory.hasSuffix("/") ? directory : directory + "/") + name
    }
    fileprivate func children(_ identifier: NSFileProviderItemIdentifier) async throws -> [NSFileProviderItem] {
        let (_, api) = try connection()
        if identifier == .rootContainer || identifier == .workingSet {
            return try await api.repositories().map { repo in
                let location = Locator(id: "repo:" + repo.id, parent: NSFileProviderItemIdentifier.rootContainer.rawValue, repo: repo.id, path: "/", name: repo.name, folder: true, writable: repo.writable, size: 0, version: repo.name)
                store.save(location)
                return ProviderItem(location)
            }
        }
        guard let parent = store.get(identifier.rawValue), parent.folder else { throw NSFileProviderError(.noSuchItem) }
        return try await api.directory(repo: parent.repo, path: parent.path).map { entry in
            let path = entry.path(in: parent.path)
            let location = Locator(id: store.id(repo: parent.repo, path: path), parent: parent.id, repo: parent.repo, path: path, name: entry.name, folder: entry.isDirectory, writable: parent.writable, size: entry.size, version: entry.objectID ?? String(entry.mtime ?? 0))
            store.save(location)
            return ProviderItem(location)
        }
    }
    private func current(_ identifier: NSFileProviderItemIdentifier) async throws -> ProviderItem {
        if identifier == .rootContainer {
            return ProviderItem(Locator(id: identifier.rawValue, parent: identifier.rawValue, repo: "", path: "/", name: domain.displayName, folder: true, writable: false, size: 0, version: "1"))
        }
        guard let location = store.get(identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
        let items = try await children(.init(location.parent))
        guard let result = items.first(where: { $0.itemIdentifier == identifier }) as? ProviderItem else { throw NSFileProviderError(.noSuchItem) }
        return result
    }
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        operation { do { completionHandler(try await self.current(identifier), nil) } catch { completionHandler(nil, self.mapped(error)) } }
    }
    func fetchContents(for identifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        operation {
            do {
                let item = try await self.current(identifier)
                let (_, api) = try self.connection()
                guard let manager = NSFileProviderManager(for: self.domain) else { throw NSFileProviderError(.providerNotFound) }
                let root = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
                let destination = root.appendingPathComponent(item.filename)
                try await api.download(repo: item.location.repo, path: item.location.path, destination: destination)
                completionHandler(destination, item, nil)
            } catch { completionHandler(nil, nil, self.mapped(error)) }
        }
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        operation {
            do {
                guard let parent = self.store.get(itemTemplate.parentItemIdentifier.rawValue), parent.writable else { throw CocoaError(.fileWriteNoPermission) }
                let (_, api) = try self.connection()
                let existing = try await self.children(itemTemplate.parentItemIdentifier)
                guard !existing.contains(where: { $0.filename == itemTemplate.filename }) else { throw NSFileProviderError(.filenameCollision) }
                let path = try self.childPath(itemTemplate.filename, in: parent.path)
                if (itemTemplate.contentType?.conforms(to: .folder) ?? false) { try await api.createDirectory(repo: parent.repo, path: path) }
                else {
                    guard let contents else { throw CocoaError(.fileReadUnknown) }
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: root) }
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let renamed = root.appendingPathComponent(itemTemplate.filename)
                    try FileManager.default.copyItem(at: contents, to: renamed)
                    try await api.upload(repo: parent.repo, directory: parent.path, file: renamed, replace: false)
                }
                let items = try await self.children(itemTemplate.parentItemIdentifier)
                guard let result = items.first(where: { $0.filename == itemTemplate.filename }) else { throw NSFileProviderError(.noSuchItem) }
                completionHandler(result, [], false, nil)
            } catch { completionHandler(nil, [], false, self.mapped(error)) }
        }
    }
    func modifyItem(_ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        operation {
            do {
                let previous = try await self.current(item.itemIdentifier)
                guard previous.location.writable else { throw CocoaError(.fileWriteNoPermission) }
                guard previous.itemVersion.contentVersion == baseVersion.contentVersion else { throw NSFileProviderError(.cannotSynchronize) }
                guard !changedFields.contains(.parentItemIdentifier) || previous.parentItemIdentifier == item.parentItemIdentifier else { throw NSFileProviderError(.cannotSynchronize) }
                let (_, api) = try self.connection()
                var updated = previous.location
                if changedFields.contains(.filename), item.filename != previous.filename {
                    let path = try self.childPath(item.filename, in: (updated.path as NSString).deletingLastPathComponent)
                    let siblings = try await self.children(previous.parentItemIdentifier)
                    guard !siblings.contains(where: { $0.filename == item.filename && $0.itemIdentifier != item.itemIdentifier }) else { throw NSFileProviderError(.filenameCollision) }
                    try await api.rename(repo: updated.repo, path: updated.path, isDirectory: updated.folder, to: item.filename)
                    let oldPath = updated.path
                    updated.path = path
                    updated.name = item.filename
                    self.store.rename(updated, from: oldPath)
                }
                if changedFields.contains(.contents), let contents {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: root) }
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let named = root.appendingPathComponent(updated.name)
                    try FileManager.default.copyItem(at: contents, to: named)
                    try await api.upload(repo: updated.repo, directory: (updated.path as NSString).deletingLastPathComponent, file: named, replace: true)
                }
                completionHandler(try await self.current(.init(updated.id)), changedFields.subtracting([.filename, .contents]), false, nil)
            } catch { completionHandler(nil, changedFields, false, self.mapped(error)) }
        }
    }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        operation {
            do {
                let item = try await self.current(identifier)
                guard item.location.writable, item.location.path != "/" else { throw CocoaError(.fileWriteNoPermission) }
                guard item.itemVersion.contentVersion == baseVersion.contentVersion else { throw NSFileProviderError(.cannotSynchronize) }
                let (_, api) = try self.connection()
                try await api.delete(repo: item.location.repo, path: item.location.path, isDirectory: item.location.folder)
                completionHandler(nil)
            } catch { completionHandler(self.mapped(error)) }
        }
    }
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        ProviderEnumerator(provider: self, identifier: containerItemIdentifier)
    }
}

private final class ProviderEnumerator: NSObject, NSFileProviderEnumerator {
    let provider: FileProviderExtension
    let identifier: NSFileProviderItemIdentifier
    private var task: Task<Void, Never>?
    init(provider: FileProviderExtension, identifier: NSFileProviderItemIdentifier) { self.provider = provider; self.identifier = identifier }
    func invalidate() { task?.cancel() }
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        task = Task {
            do {
                let items = try await provider.children(identifier)
                try Task.checkCancellation()
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch { observer.finishEnumeratingWithError(error) }
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        // A server without change cursors must rescan instead of claiming an
        // empty change set and leaving the Files app stale.
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) { completionHandler(.init(Data("seafile-next-v1".utf8))) }
}

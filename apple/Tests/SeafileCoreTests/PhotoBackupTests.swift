import Foundation
import Testing
@testable import SeafileCore

@Test @MainActor func photoBackupHistoryPreservesUncertainWritesAndScopesCompletedResources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try PhotoBackupHistory(root: root), account = UUID()
    var settings = PhotoBackupSettings(repository: "repo", path: "/手机相册 + &")
    settings.enabled = true; try history.configure(account: account, settings: settings)
    let bytes = Data("original photo bytes".utf8), digest = PhotoBackupFiles.digest(bytes)
    let record = PhotoBackupRecord(accountID: account, repository: settings.repository, path: settings.path,
        asset: "asset/identifier", revision: "123", resource: "photo", filename: "IMG_0001.heic", digest: digest, size: Int64(bytes.count))
    try history.prepare(record); let transfer = UUID(); try history.submitted(record.id, transfer: transfer)
    let restarted = try PhotoBackupHistory(root: root)
    #expect(try restarted.record(record.id)?.transferID == transfer)
    #expect(try restarted.record(record.id)?.completed == false)
    #expect(try restarted.records(account: UUID(), settings: settings).isEmpty)
    #expect(throws: Error.self) { try restarted.confirm(record.id, digest: PhotoBackupFiles.digest(Data("different".utf8)), size: record.size) }
    #expect(throws: Error.self) { try restarted.remove(account: account) }
    try restarted.confirm(record.id, digest: digest, size: record.size)
    #expect(try PhotoBackupHistory(root: root).record(record.id)?.completed == true)
    var other = settings; other.path = "/new folder"
    #expect(try restarted.records(account: account, settings: other).isEmpty)
    #expect(PhotoBackupRecord.key(accountID: account, repository: "repo", path: settings.path, asset: "asset/identifier", revision: "124", resource: "photo") != record.id)
}

@Test @MainActor func damagedPhotoBackupHistoryAndLinksAreNotOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID()
    var history: PhotoBackupHistory? = try PhotoBackupHistory(root: root)
    try history?.configure(account: account, settings: PhotoBackupSettings(repository: "repo", path: "/"))
    let file = root.appendingPathComponent("photo-backup.sqlite"), corrupt = Data("broken history".utf8)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    history = nil // Close and checkpoint the WAL before damaging the database.
    try corrupt.write(to: file)
    #expect(throws: Error.self) { try PhotoBackupHistory(root: root) }
    #expect(try Data(contentsOf: file) == corrupt)
    try FileManager.default.removeItem(at: file)
    history = try PhotoBackupHistory(root: root)
    let outside = root.appendingPathComponent("outside"); try Data("keep".utf8).write(to: outside)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    #expect(throws: Error.self) { try history?.configure(account: account, settings: PhotoBackupSettings(repository: "repo", path: "/changed")) }
    #expect(try Data(contentsOf: outside) == Data("keep".utf8))
}

@Test func photoResourceNamesAndStreamingHashesKeepDifferentCamerasAndEditedVersionsSeparate() throws {
    let first = PhotoBackupFiles.digest(Data("one".utf8)), second = PhotoBackupFiles.digest(Data("two".utf8))
    let name = try PhotoBackupFiles.filename(original: "IMG_0001.HEIC", asset: "camera one", digest: first)
    #expect(name.hasSuffix(".heic"))
    #expect(name != (try PhotoBackupFiles.filename(original: "IMG_0001.HEIC", asset: "camera two", digest: first)))
    #expect(name != (try PhotoBackupFiles.filename(original: "IMG_0001.HEIC", asset: "camera one", digest: second)))
    #expect(throws: Error.self) { try PhotoBackupFiles.filename(original: "../bad.jpg", asset: "one", digest: first) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let bytes = Data(repeating: 17, count: 3 * 1024 * 1024 + 31); try bytes.write(to: file)
    let hash = try PhotoBackupFiles.digest(file: file)
    #expect(hash.hash == PhotoBackupFiles.digest(bytes) && hash.size == Int64(bytes.count))
}

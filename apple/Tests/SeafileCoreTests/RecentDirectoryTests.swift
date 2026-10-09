import Foundation
import Testing
@testable import SeafileCore

@Test func destinationsRespectFolderBoundariesAndLibraryIdentity() throws {
    let folder = try JSONDecoder().decode(DirectoryEntry.self, from: Data(#"{"name":"Projects","type":"dir"}"#.utf8))
    func allowed(_ target: String, repo: String = "source") -> Bool {
        RemoteDirectoryPath.allowsDestination(sourceRepo: "source", sourceParent: "/", entries: [folder], destinationRepo: repo, destinationPath: target)
    }
    #expect(!allowed("/") && !allowed("/Projects/") && !allowed("/Projects/subfolder"))
    #expect(allowed("/Projects-other") && allowed("/Projects/subfolder", repo: "different"))
    #expect(!allowed("/Projects/../Other") && !allowed("relative"))
    #expect(try RemoteDirectoryPath.canonical("//空间 + &///Folder/") == "/空间 + &/Folder")
}

@Test func recentDirectoriesArePersistentDeduplicatedBoundedAndAccountScoped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecentDirectoryStore(directory: root), first = UUID(), second = UUID()
    for index in 0..<25 { try await store.record(account: first, repo: "repo", path: "/Folder\(index)") }
    try await store.record(account: second, repo: "repo", path: "/Another account")
    try await store.record(account: first, repo: "repo", path: "/Folder24/")
    let restored = try RecentDirectoryStore(directory: root)
    let recent = await restored.directories(for: first)
    #expect(recent.count == 20 && recent.first?.path == "/Folder24")
    #expect(recent.filter { $0.path == "/Folder24" }.count == 1)
    #expect(await restored.directories(for: second).count == 1)
    try await restored.remove(account: first)
    #expect(await restored.directories(for: first).isEmpty)
    #expect(await restored.directories(for: second).count == 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("recent-directories.json").path)[.posixPermissions] as! Int
    #expect(permissions == 0o600)
}

@Test func corruptRecentHistoryAndSymlinksArePreservedAndNeverOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("recent-directories.json"), original = Data("unreadable history".utf8)
    try original.write(to: file)
    #expect(throws: (any Error).self) { try RecentDirectoryStore(directory: root) }
    #expect(try Data(contentsOf: file) == original)
    try FileManager.default.removeItem(at: file)
    let target = root.appendingPathComponent("preserved"); try original.write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: SeafileError.self) { try RecentDirectoryStore(directory: root) }
    #expect(try Data(contentsOf: target) == original)
}

import Foundation
import Testing
@testable import SeafileCore

@Test @MainActor func textDraftPreservesUnicodeBOMLineEndingsAndUnuploadedChangesAcrossRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID(), store = try TextDraftStore(root: root)
    let original = Data([0xef, 0xbb, 0xbf]) + Data("空间 + &\r\nsecond line\r\n".utf8)
    var draft = try store.create(account: account, repository: "repo", path: "/空间 + &/notes.md", data: original)
    #expect(!draft.changed && draft.data == original)
    draft.text += "new line\r\n"; try store.save(draft)
    let restarted = try TextDraftStore(root: root)
    let loaded = try restarted.load(account: account, repository: "repo", path: draft.path)
    let restored = try #require(loaded)
    #expect(restored.changed && restored.text == draft.text && restored.baseline == original)
    #expect(try store.load(account: UUID(), repository: "repo", path: draft.path) == nil)
    #expect(try store.drafts(account: account).count == 1)
    #expect(throws: SeafileError.self) { try store.clearUnedited(account: account) }
    #expect(restored.alreadyUploaded(draft.data) && !restored.remoteMatchesBaseline(draft.data))
    #expect(restored.remoteMatchesBaseline(original) && !restored.alreadyUploaded(original))
    #expect(!restored.remoteMatchesBaseline(Data("someone else's edit".utf8)))
}

@Test @MainActor func malformedAndLinkedDraftFilesArePreservedInsteadOfOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID(), store = try TextDraftStore(root: root)
    let draft = try store.create(account: account, repository: "repo", path: "/notes.txt", data: Data("original".utf8))
    let file = try #require(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(account.uuidString), includingPropertiesForKeys: nil).first)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    let corrupt = Data("incomplete draft".utf8); try corrupt.write(to: file)
    #expect(throws: Error.self) { try store.save(draft) }
    #expect(try Data(contentsOf: file) == corrupt)
    #expect(throws: Error.self) { try store.clearUnedited(account: account) }
    try FileManager.default.removeItem(at: file)
    let outside = root.appendingPathComponent("outside"); try Data("untouched".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    #expect(throws: Error.self) { try store.save(draft) }
    #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
}

@Test @MainActor func editorRejectsBinaryOversizedAndUnsafeRemotePaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TextDraftStore(root: root), account = UUID()
    for data in [Data([0xff, 0xfe]), Data([0x41, 0]), Data(repeating: 65, count: TextDraftStore.maximumBytes + 1)] {
        #expect(throws: Error.self) { try store.create(account: account, repository: "repo", path: "/file.txt", data: data) }
    }
    for path in ["/../file.txt", "file.txt", "/"] {
        #expect(throws: Error.self) { try store.create(account: account, repository: "repo", path: path, data: Data("text".utf8)) }
    }
    #expect(try store.drafts(account: account).isEmpty)
}

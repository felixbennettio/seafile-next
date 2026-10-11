import Foundation
import Testing
@testable import SeafileCore

private struct ShareTestFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-test-" + UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Test func sharingPreservesProviderFilesAfterTheirTemporaryURLExpires() throws {
    let folder = try ShareTestFolder(); defer { folder.remove() }
    let store = try SharedImportStore(root: folder.url.appendingPathComponent("inbox")), id = try store.create()
    let source = folder.url.appendingPathComponent("source.txt")
    try Data("actual shared file".utf8).write(to: source)
    let file = try store.addFile(source, name: "Notes.txt", to: id)
    try FileManager.default.removeItem(at: source)
    #expect(try Data(contentsOf: store.fileURL(file, in: id)) == Data("actual shared file".utf8))
    let restored = try SharedImportStore(root: folder.url.appendingPathComponent("inbox"))
    #expect(try restored.list().first?.files.first?.name == "Notes.txt")
    let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL(file, in: id).path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
}

@Test func sharingKeepsDuplicateNamesAsSeparateInputsAndRejectsTraversal() throws {
    let folder = try ShareTestFolder(); defer { folder.remove() }
    let store = try SharedImportStore(root: folder.url.appendingPathComponent("inbox")), id = try store.create()
    let a = try store.addData(Data("one".utf8), name: "Note.txt", to: id)
    let b = try store.addData(Data("two".utf8), name: "Note.txt", to: id)
    #expect(a.id != b.id)
    #expect(try Data(contentsOf: store.fileURL(a, in: id)) != Data(contentsOf: store.fileURL(b, in: id)))
    for name in ["../token", ".", "..", "a/b", "a\\b", "a\nfile"] {
        #expect(throws: (any Error).self) { try store.addData(Data(), name: name, to: id) }
    }
    #expect(try store.snapshot(id).files.count == 2)
}

@Test func sharedImportRejectsLinksAndDoesNotOverwriteDamagedHistory() throws {
    let folder = try ShareTestFolder(); defer { folder.remove() }
    let root = folder.url.appendingPathComponent("inbox"), store = try SharedImportStore(root: root), id = try store.create()
    let source = folder.url.appendingPathComponent("source.txt"), link = folder.url.appendingPathComponent("link.txt")
    try Data("keep".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: (any Error).self) { try store.addFile(link, name: "link.txt", to: id) }
    let manifest = root.appendingPathComponent(id.uuidString).appendingPathComponent("share.json")
    let damaged = Data("incomplete history".utf8); try damaged.write(to: manifest)
    #expect(throws: (any Error).self) { try store.addFile(source, name: "source.txt", to: id) }
    #expect(try Data(contentsOf: manifest) == damaged)
}

@Test func sharedImportLeasePreventsTwoProcessesFromSendingOrDeletingTheSameFiles() throws {
    let folder = try ShareTestFolder(); defer { folder.remove() }
    let root = folder.url.appendingPathComponent("inbox"), store = try SharedImportStore(root: root), id = try store.create()
    let other = try SharedImportStore(root: root)
    do {
        let lease = try store.uploadLease(id)
        #expect(throws: (any Error).self) { try other.uploadLease(id) }
        #expect(throws: (any Error).self) { try other.remove(id) }
        #expect(try other.snapshot(id).id == id)
        withExtendedLifetime(lease) {}
    }
    try other.remove(id)
    #expect(try store.list().isEmpty)
}

private actor ShareTestTransport: HTTPTransport {
    var uploads: [String] = []
    var fail = false
    var remote = Data()
    func setFail(_ value: Bool) { fail = value }
    func setRemote(_ value: Data) { remote = value }
    func sent() -> [String] { uploads }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body: Data
        if request.url!.absoluteString.contains("/file/detail/") {
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "p" }!.value!
            body = try JSONSerialization.data(withJSONObject: ["name": (path as NSString).lastPathComponent, "type": "file", "size": remote.count])
        } else { body = Data("\"https://share.test/upload\"".utf8) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try remote.write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) {
        let body = try String(contentsOf: file, encoding: .utf8); uploads.append(body)
        if fail { throw URLError(.networkConnectionLost) }
        return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test @MainActor func uncertainSharedFilesAreConfirmedOnlyWhenServerContentMatches() async throws {
    let folder = try ShareTestFolder(); defer { folder.remove() }
    let store = try SharedImportStore(root: folder.url.appendingPathComponent("inbox")), id = try store.create()
    let file = try store.addData(Data("same".utf8), name: "Shared.txt", to: id)
    try store.assign(id, accountID: UUID(), repository: "repo", directory: "/")
    try store.setState(.uncertain, fileID: file.id, in: id)
    let transport = ShareTestTransport(), client = SeafileAPI(endpoint: try ServerEndpoint("https://share.test/seafile"), token: "fixture", transport: transport)
    await transport.setRemote(Data("diff".utf8))
    #expect(try await !SharedImportUploader.verify(file.id, in: id, store: store, client: client))
    #expect(try store.snapshot(id).files.first?.state == .uncertain)
    #expect(try Data(contentsOf: store.fileURL(file, in: id)) == Data("same".utf8))
    await transport.setRemote(Data("same".utf8))
    #expect(try await SharedImportUploader.verify(file.id, in: id, store: store, client: client))
    #expect(try store.snapshot(id).completed)
    #expect(await transport.sent().isEmpty)
}

@Test @MainActor func sharedImportUploadKeepsCompletedReceiptsAndNeverAutomaticallyReplaysUncertainWrites() async throws {
    let folder = try ShareTestFolder(); defer { folder.remove() }
    let store = try SharedImportStore(root: folder.url.appendingPathComponent("inbox")), id = try store.create()
    let a = try store.addData(Data("first".utf8), name: "First.txt", to: id)
    let b = try store.addData(Data("second".utf8), name: "Second.txt", to: id)
    try store.assign(id, accountID: UUID(), repository: "repo", directory: "/Selected/")
    let transport = ShareTestTransport(), client = SeafileAPI(endpoint: try ServerEndpoint("https://share.test/seafile/"), token: "fixture", transport: transport)
    try store.setState(.completed, fileID: a.id, in: id)
    await transport.setFail(true)
    await #expect(throws: (any Error).self) { try await SharedImportUploader.upload(id, store: store, client: client) }
    #expect(try store.snapshot(id).files[1].state == .uncertain)
    #expect(try Data(contentsOf: store.fileURL(b, in: id)) == Data("second".utf8))
    await transport.setFail(false)
    await #expect(throws: (any Error).self) { try await SharedImportUploader.upload(id, store: store, client: client) }
    #expect(await transport.sent().count == 1)
    try await SharedImportUploader.upload(id, store: store, client: client, retryUncertain: true)
    #expect(await transport.sent().count == 2)
    #expect(try store.snapshot(id).completed)
    #expect(throws: (any Error).self) { try store.fileURL(b, in: id) }
    #expect(await transport.sent().allSatisfy { $0.contains("Second.txt") && !$0.contains("First.txt") && $0.contains("\r\n0\r\n") })
}

@Test @MainActor func shareProcessTerminationLeavesAnUncertainReceiptAndAllowsUnsentFilesToContinue() async throws {
    let folder = try ShareTestFolder(); defer { folder.remove() }
    let store = try SharedImportStore(root: folder.url.appendingPathComponent("inbox")), id = try store.create()
    let a = try store.addData(Data("old".utf8), name: "Old.txt", to: id)
    _ = try store.addData(Data("new".utf8), name: "New.txt", to: id)
    try store.assign(id, accountID: UUID(), repository: "repo", directory: "/")
    try store.setState(.sending, fileID: a.id, in: id)
    let transport = ShareTestTransport(), client = SeafileAPI(endpoint: try ServerEndpoint("https://share.test"), token: "fixture", transport: transport)
    await #expect(throws: (any Error).self) { try await SharedImportUploader.upload(id, store: store, client: client) }
    #expect(try store.snapshot(id).files.map(\.state) == [.uncertain, .completed])
    #expect(await transport.sent().count == 1)
    #expect(await transport.sent().first?.contains("New.txt") == true)
}

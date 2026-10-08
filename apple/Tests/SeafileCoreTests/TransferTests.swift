import Foundation
import Testing
@testable import SeafileCore

private actor TransferHTTP: HTTPTransport {
    private(set) var uploads: [Data] = []
    private(set) var downloads = 0
    var uploadFailure: Bool
    let delay: Duration
    init(uploadFailure: Bool = false, delay: Duration = .zero) { self.uploadFailure = uploadFailure; self.delay = delay }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let value = request.url!.path.hasSuffix("/upload-link/") ? #""https://fixture.invalid/upload""# : #""https://fixture.invalid/download""#
        return (Data(value.utf8), response(request))
    }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) {
        uploads.append(try Data(contentsOf: file))
        if uploadFailure { throw URLError(.networkConnectionLost) }
        try await Task.sleep(for: delay)
        return (Data("[]".utf8), response(request))
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        downloads += 1
        try await Task.sleep(for: delay)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("downloaded content".utf8).write(to: file)
        return (file, response(request))
    }
    private func response(_ request: URLRequest) -> HTTPURLResponse { HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)! }
}

@MainActor private func fixtureQueue(_ root: URL, http: TransferHTTP) throws -> FileTransferQueue {
    let queue = try FileTransferQueue(root: root)
    let endpoint = try ServerEndpoint("https://fixture.invalid/seafile/")
    queue.start { _, _ in SeafileAPI(endpoint: endpoint, token: "private-test-token", transport: http) }
    return queue
}

@Test @MainActor func queuedUploadUsesAPrivateSnapshotAndRetainsItAfterUncertainFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("original.txt")
    try Data("original content".utf8).write(to: source)
    let account = UUID(), queue = try FileTransferQueue(root: root.appendingPathComponent("queue"))
    let id = try await queue.enqueueUpload(accountID: account, repository: "repo", parent: "/folder/", source: source)
    try Data("changed after import".utf8).write(to: source)
    let http = TransferHTTP(uploadFailure: true)
    let endpoint = try ServerEndpoint("https://fixture.invalid/")
    queue.start { _, _ in SeafileAPI(endpoint: endpoint, token: "private-test-token", transport: http) }
    await #expect(throws: URLError.self) { try await queue.result(for: id) }
    let transfer = try #require(queue.transfers.first)
    #expect(transfer.state == .failed)
    #expect(transfer.error?.contains("Check the server") == true)
    let preserved = try #require(queue.localCopy(of: transfer))
    #expect(try String(contentsOf: preserved, encoding: .utf8) == "original content")
    #expect(try FileManager.default.attributesOfItem(atPath: preserved.path)[.posixPermissions] as? Int == 0o600)
    #expect(queue.hasPendingUploads(accountID: account))
    #expect(await http.uploads.count == 1)
    let manifest = try String(contentsOf: root.appendingPathComponent("queue/transfers.json"), encoding: .utf8)
    #expect(!manifest.contains("private-test-token"))
    #expect(!manifest.contains("https://fixture.invalid/upload"))
    let restored = try fixtureQueue(root.appendingPathComponent("queue"), http: http)
    #expect(restored.transfers.first?.state == .failed)
    #expect(await http.uploads.count == 1)
}

@Test @MainActor func restartingNeverAutomaticallyReplaysAnUploadThatWasRunning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.txt")
    try Data("preserved".utf8).write(to: source)
    let queueRoot = root.appendingPathComponent("queue"), queue = try FileTransferQueue(root: queueRoot)
    let id = try await queue.enqueueUpload(accountID: UUID(), repository: "repo", parent: "/", source: source)
    var stored = queue.transfers
    stored[0].state = .running
    try JSONEncoder().encode(stored).write(to: queueRoot.appendingPathComponent("transfers.json"))
    let http = TransferHTTP(), restored = try fixtureQueue(queueRoot, http: http)
    #expect(restored.transfers[0].state == .failed)
    #expect(restored.transfers[0].error?.contains("Check the server") == true)
    #expect(await http.uploads.isEmpty)
    try restored.retry(id)
    _ = try await restored.result(for: id)
    #expect(restored.transfers[0].state == .completed)
    #expect(await http.uploads.count == 1)
    #expect(restored.localCopy(of: restored.transfers[0]) == nil)
}

@Test @MainActor func transferQueueLimitsConcurrencyAndJoinsAnExistingDownload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let http = TransferHTTP(delay: .milliseconds(250)), queue = try fixtureQueue(root, http: http), account = UUID()
    let first = try queue.enqueueDownload(accountID: account, repository: "repo", path: "/first.txt")
    #expect(try queue.enqueueDownload(accountID: account, repository: "repo", path: "/first.txt") == first)
    let second = try queue.enqueueDownload(accountID: account, repository: "repo", path: "/second.txt")
    let third = try queue.enqueueDownload(accountID: account, repository: "repo", path: "/third.txt")
    #expect(queue.transfers.filter { $0.state == .running }.count == 2)
    #expect(queue.transfers.last?.state == .queued)
    let destination = try await queue.result(for: first)
    _ = try await queue.result(for: second)
    _ = try await queue.result(for: third)
    #expect(await http.downloads == 3)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "downloaded content")
    #expect(queue.cachedDownload(accountID: account, repository: "repo", path: "/first.txt") == destination)
    let restored = try FileTransferQueue(root: root)
    #expect(restored.transfers.allSatisfy { $0.state == .completed })
    #expect(restored.cachedDownload(accountID: account, repository: "repo", path: "/first.txt") == destination)
    try restored.clearDownloads(accountID: UUID())
    #expect(restored.transfers.count == 3)
    try restored.clearDownloads(accountID: account)
    #expect(restored.transfers.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test @MainActor func cancelledDownloadCanBeRetriedWithoutReplayingAnyUpload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let http = TransferHTTP(delay: .milliseconds(100)), queue = try fixtureQueue(root, http: http)
    let id = try queue.enqueueDownload(accountID: UUID(), repository: "repo", path: "/file.txt")
    queue.cancel(id)
    await #expect(throws: CancellationError.self) { try await queue.result(for: id) }
    #expect(queue.transfers[0].state == .cancelled)
    try queue.retry(id)
    #expect(throws: SeafileError.self) { try queue.clearDownloads(accountID: queue.transfers[0].accountID) }
    let destination = try await queue.result(for: id)
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(queue.transfers[0].state == .completed)
    try queue.remove(id)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(queue.transfers.isEmpty)
}

@Test @MainActor func unsafeUploadInputsNeverEnterTheQueue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = try FileTransferQueue(root: root.appendingPathComponent("queue"))
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
    await #expect(throws: SeafileError.self) { try await queue.enqueueUpload(accountID: UUID(), repository: "repo", parent: "/", source: link) }
    #expect(throws: SeafileError.self) { try queue.enqueueDownload(accountID: UUID(), repository: "repo", path: "/../") }
    #expect(queue.transfers.isEmpty)
    #expect(queue.preparingUploads == 0)
}

@Test @MainActor func unreadableTransferHistoryIsNeverOverwrittenByNewTransfers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = root.appendingPathComponent("transfers.json"), original = Data("incomplete history".utf8)
    try original.write(to: manifest)
    #expect(throws: Error.self) { try FileTransferQueue(root: root) }
    let disabled = FileTransferQueue(unavailableRoot: root, error: "History could not be read")
    #expect(throws: SeafileError.self) { try disabled.enqueueDownload(accountID: UUID(), repository: "repo", path: "/file.txt") }
    #expect(try Data(contentsOf: manifest) == original)
}

#if os(macOS)
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [(Int64, Int64)] = []
    func record(_ done: Int64, _ total: Int64) { lock.withLock { readings.append((done, total)) } }
    var last: (Int64, Int64)? { lock.withLock { readings.last } }
}

@Test func realURLSessionTransfersReportProgressAndKeepTheAsyncDownloadFile() async throws {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", "-c", #"""
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        size=2*1024*1024
        self.send_response(200); self.send_header('Content-Length', str(size)); self.end_headers()
        for _ in range(size//65536): self.wfile.write(b'x'*65536); self.wfile.flush()
    def do_POST(self):
        remaining=int(self.headers['Content-Length'])
        while remaining:
            data=self.rfile.read(min(remaining,65536)); remaining-=len(data)
        self.send_response(200); self.send_header('Content-Length','2'); self.end_headers(); self.wfile.write(b'[]')
server=HTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],flush=True)
server.serve_forever()
"""#]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
    let port = try #require(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    var settings = ClientNetworkSettings(); settings.proxy = .none
    let downloadProgress = ProgressRecorder(), uploadProgress = ProgressRecorder()
    let url = URL(string: "http://127.0.0.1:\(port)/file")!
    let transport = URLSessionTransport(settings: settings, progress: downloadProgress.record)
    let (file, response) = try await transport.download(for: URLRequest(url: url))
    defer { try? FileManager.default.removeItem(at: file) }
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(try Data(contentsOf: file).count == 2 * 1024 * 1024)
    let downloaded = try #require(downloadProgress.last)
    #expect(downloaded.0 == 2097152)
    #expect(downloaded.1 == 2097152)
    var request = URLRequest(url: url); request.httpMethod = "POST"
    let upload = URLSessionTransport(settings: settings, progress: uploadProgress.record)
    let (body, _) = try await upload.upload(for: request, from: file)
    #expect(body == Data("[]".utf8))
    let uploaded = try #require(uploadProgress.last)
    #expect(uploaded.0 == 2097152)
}
#endif

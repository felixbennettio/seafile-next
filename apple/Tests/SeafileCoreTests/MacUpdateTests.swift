#if os(macOS)
import Foundation
import Testing
@testable import SeafileCore

private actor UpdateHTTP: HTTPTransport {
    var replies: [Data]
    let downloadBody: Data
    var requests: [URLRequest] = []
    init(_ replies: [Data] = [], body: Data = Data()) { self.replies = replies; downloadBody = body }
    func data(for request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        return (replies.removeFirst(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) throws -> (URL, URLResponse) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try downloadBody.write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func upload(for request: URLRequest, from file: URL) async throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}

private func releaseReplies(foreign: Bool = false) throws -> [Data] {
    let base = "https://github.com/felixbennettio/seafile-next/releases/"
    let file = "seafile-next-v1.0.0-macos-arm64-direct.zip"
    return try [
        ["tag_name": "v1.0.0", "html_url": base + "tag/v1.0.0", "assets": [
            ["name": "release-manifest.json", "size": 1024, "browser_download_url": base + "download/v1.0.0/release-manifest.json"],
            ["name": file, "size": 3, "browser_download_url": foreign ? "https://foreign.invalid/" + file : base + "download/v1.0.0/" + file]]],
        ["version": "1.0.0", "source": String(repeating: "c", count: 40), "packages": [["platform": "macos", "file": file, "sha256": String(repeating: "a", count: 64), "bytes": 3, "build": ["buildCommit": String(repeating: "b", count: 40)]]]]
    ].map { try JSONSerialization.data(withJSONObject: $0) }
}

@Test func updatesCompareTheActualMacBuildAndRejectForeignDownloadURLs() async throws {
    let http = UpdateHTTP(try releaseReplies())
    let update = try await MacUpdates(transport: http).latest(version: "1.0.0", revision: String(repeating: "c", count: 40))
    #expect(update?.sourceRevision == String(repeating: "b", count: 40))
    #expect(update?.bytes == 3)
    let requests = await http.requests
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    let current = UpdateHTTP(try releaseReplies())
    #expect(try await MacUpdates(transport: current).latest(version: "1.0.0", revision: String(repeating: "b", count: 40)) == nil)
    let foreign = UpdateHTTP(try releaseReplies(foreign: true))
    await #expect(throws: SeafileError.self) { try await MacUpdates(transport: foreign).latest(version: "1.0.0", revision: nil) }
}

@Test func aCorruptedUpdateFailsBeforeExtractionOrInstallation() async throws {
    let http = UpdateHTTP(try releaseReplies(), body: Data("bad".utf8))
    let updates = MacUpdates(transport: http)
    let update = try #require(await updates.latest(version: "0.9.0", revision: nil))
    await #expect(throws: SeafileError.self) { try await updates.download(update) }
}

@Test func anUnsignedReplacementNeverMovesTheInstalledApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("new.app"), existing = root.appendingPathComponent("existing.app")
    defer { try? FileManager.default.removeItem(at: root) }
    for app in [source, existing] {
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "io.felixbennett.seafile.direct", "CFBundlePackageType": "APPL", "SeafileSourceRevision": String(repeating: "b", count: 40)]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
    let marker = existing.appendingPathComponent("Contents/original.txt")
    try Data("original app".utf8).write(to: marker)
    #expect(throws: SeafileError.self) { try DirectMacInstaller.install(source, over: existing, revision: String(repeating: "b", count: 40)) }
    #expect(try Data(contentsOf: marker) == Data("original app".utf8))
}

@Test func aVerifiedReplacementInstallsAndKeepsThePreviousApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("new.app"), existing = root.appendingPathComponent("existing.app")
    let revision = String(repeating: "b", count: 40)
    defer { try? FileManager.default.removeItem(at: root) }
    for (app, marker) in [(source, "new application"), (existing, "previous application")] {
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A copied system executable is signed only in this temporary bundle;
        // neither installed apps nor the sync daemon are launched or replaced.
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = ["CFBundleIdentifier": "io.felixbennett.seafile.direct", "CFBundlePackageType": "APPL", "CFBundleExecutable": "fixture", "CFBundleVersion": "1", "SeafileSourceRevision": revision]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("Resources/marker.txt"))
        try DirectMacInstaller.command("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    }
    #expect(throws: SeafileError.self) { try DirectMacInstaller.install(source, over: existing, revision: String(repeating: "c", count: 40)) }
    #expect(try String(contentsOf: existing.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) == "previous application")
    let backup = try DirectMacInstaller.install(source, over: existing, revision: revision)
    #expect(try String(contentsOf: existing.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) == "new application")
    #expect(try String(contentsOf: backup.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) == "previous application")
    try DirectMacInstaller.validate(existing, revision: revision)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".seafile-next-install-") }.isEmpty)
}
#endif

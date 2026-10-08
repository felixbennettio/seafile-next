#if os(macOS)
import Foundation
import CryptoKit

public struct DirectMacUpdate: Sendable {
    public let version: String, sourceRevision: String, sha256: String
    public let downloadURL: URL, releaseURL: URL
    public let bytes: Int64
}

public actor MacUpdates {
    private let transport: any HTTPTransport
    public init(transport: (any HTTPTransport)? = nil) {
        if let transport { self.transport = transport; return }
        var network = ClientNetworkSettings.load()
        // A self-signed Seafile server opt-in never disables update trust.
        network.verifyCertificates = true
        self.transport = RetryingHTTPTransport(transport: URLSessionTransport(settings: network))
    }
    public func latest(version: String, revision: String?) async throws -> DirectMacUpdate? {
        struct Asset: Decodable { let name: String, browser_download_url: URL, size: Int64 }
        struct Release: Decodable { let tag_name: String, html_url: URL, assets: [Asset] }
        struct Build: Decodable { let buildCommit: String }
        struct Package: Decodable { let platform: String, file: String, sha256: String, bytes: Int64, build: Build? }
        struct Manifest: Decodable { let version: String, source: String, packages: [Package] }
        let latestURL = URL(string: "https://api.github.com/repos/felixbennettio/seafile-next/releases/latest")!
        let release = try JSONDecoder().decode(Release.self, from: await data(latestURL))
        guard release.tag_name.hasPrefix("v"), Self.version(String(release.tag_name.dropFirst())) != nil,
              release.html_url.absoluteString == "https://github.com/felixbennettio/seafile-next/releases/tag/" + release.tag_name,
              let manifestAsset = release.assets.first(where: { $0.name == "release-manifest.json" }),
              Self.isReleaseAsset(manifestAsset.browser_download_url, tag: release.tag_name, name: manifestAsset.name) else { throw SeafileError.invalidResponse }
        let manifest = try JSONDecoder().decode(Manifest.self, from: await data(manifestAsset.browser_download_url))
        guard "v" + manifest.version == release.tag_name,
              let package = manifest.packages.first(where: { $0.platform == "macos" }),
              package.file.hasSuffix("macos-arm64-direct.zip"),
              let asset = release.assets.first(where: { $0.name == package.file }),
              asset.size == package.bytes, package.bytes > 0,
              Self.isReleaseAsset(asset.browser_download_url, tag: release.tag_name, name: package.file),
              package.sha256.count == 64, package.sha256.allSatisfy(\.isHexDigit) else { throw SeafileError.invalidResponse }
        let source = package.build?.buildCommit ?? manifest.source
        guard source.count == 40, source.allSatisfy(\.isHexDigit), let current = Self.version(version), let latest = Self.version(manifest.version) else { throw SeafileError.invalidResponse }
        if latest.lexicographicallyPrecedes(current) { return nil }
        if latest == current, revision == source { return nil }
        return DirectMacUpdate(version: manifest.version, sourceRevision: source, sha256: package.sha256.lowercased(), downloadURL: asset.browser_download_url, releaseURL: release.html_url, bytes: package.bytes)
    }
    public func download(_ update: DirectMacUpdate) async throws -> URL {
        let (file, response) = try await transport.download(for: URLRequest(url: update.downloadURL))
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(update.bytes),
              try Self.digest(file) == update.sha256 else { throw SeafileError.local("The update did not match its published checksum. The installed app is unchanged.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seafile-next-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let zip = folder.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: file, to: zip)
            let entries = try DirectMacInstaller.command("/usr/bin/tar", ["-t", "-f", zip.path]).split(separator: "\n")
            guard !entries.isEmpty, entries.allSatisfy({ name in
                !name.hasPrefix("/") && !name.split(separator: "/").contains("..") &&
                (name == "seafile-next.app/" || name.hasPrefix("seafile-next.app/") || name.hasPrefix("__MACOSX/"))
            }) else { throw SeafileError.local("The update archive contains unexpected files.") }
            // libarchive refuses extraction through symlinks or outside this
            // private directory. Signature validation follows extraction.
            _ = try DirectMacInstaller.command("/usr/bin/tar", ["--safe-writes", "-x", "-f", zip.path, "-C", folder.path])
            let app = folder.appendingPathComponent("seafile-next.app")
            try DirectMacInstaller.validate(app, revision: update.sourceRevision)
            return app
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    private func data(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2 * 1024 * 1024 else { throw SeafileError.invalidResponse }
        return data
    }
    private static func version(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }; return numbers.count == 3 ? numbers : nil
    }
    private static func isReleaseAsset(_ url: URL, tag: String, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
            url.path == "/felixbennettio/seafile-next/releases/download/" + tag + "/" + name
    }
    private static func digest(_ file: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
        var hash = SHA256()
        while let bytes = try reader.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DirectMacInstaller {
    public static func validate(_ app: URL, revision: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "io.felixbennett.seafile.direct",
              bundle.object(forInfoDictionaryKey: "SeafileSourceRevision") as? String == revision,
              (try app.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw SeafileError.local("This package is not the expected Seafile Next update.") }
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
    public static func install(_ source: URL, over destination: URL, revision: String) throws -> URL {
        try validate(source, revision: revision)
        guard destination.pathExtension == "app", Bundle(url: destination)?.bundleIdentifier == "io.felixbennett.seafile.direct", source != destination,
              (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw SeafileError.local("This app location cannot be updated automatically. Move the downloaded app into Applications using Finder.") }
        let parent = destination.deletingLastPathComponent()
        let installing = parent.appendingPathComponent(".seafile-next-install-" + UUID().uuidString + ".app")
        let backup = parent.appendingPathComponent(".seafile-next-previous-" + UUID().uuidString + ".app")
        try FileManager.default.copyItem(at: source, to: installing)
        do { try validate(installing, revision: revision) } catch { try? FileManager.default.removeItem(at: installing); throw error }
        do {
            try FileManager.default.moveItem(at: destination, to: backup)
            do { try FileManager.default.moveItem(at: installing, to: destination) }
            catch { try FileManager.default.moveItem(at: backup, to: destination); throw error }
        } catch { try? FileManager.default.removeItem(at: installing); throw error }
        return backup
    }
    @discardableResult public static func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SeafileError.local("The update could not be verified or installed. The previous app is preserved.") }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif

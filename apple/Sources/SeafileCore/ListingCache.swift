import Foundation
import CryptoKit

/// Account-isolated cached listings keep downloaded files reachable offline.
public enum ListingCache {
    private static func location(account: ServerAccount, key: String) -> URL {
        let root = LocalFiles.cacheURL(account: account, repo: "listing", path: "/index.json").deletingLastPathComponent()
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash + ".json")
    }
    public static func read<T: Decodable>(_ type: T.Type, account: ServerAccount, key: String) -> T? {
        guard let data = try? Data(contentsOf: location(account: account, key: key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    public static func write<T: Encodable>(_ value: T, account: ServerAccount, key: String) throws {
        let file = location(account: account, key: key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

import Foundation
import Security
import CryptoKit

public enum CredentialStore {
    private static let service = "io.felixbennett.seafile.accounts"
    public static func token(for account: ServerAccount) throws -> String? {
        var query = base(account.id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound, SharedAccounts.accessGroup != nil {
            // Upgrade accounts created before the Files extension used a
            // shared access group, without asking users to sign in again.
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) {
                try save(token, for: account)
            }
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw error(status) }
        return token
    }
    public static func save(_ token: String, for account: ServerAccount) throws {
        var query = base(account.id)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base(account.id) as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw error(status) }
    }
    public static func delete(_ account: ServerAccount) throws {
        var query = base(account.id)
        // Also remove any copy left in the app's original default group.
        query.removeValue(forKey: kSecAttrAccessGroup as String)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private static func base(_ id: UUID) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        if let group = SharedAccounts.accessGroup { query[kSecAttrAccessGroup as String] = group }
        return query
    }
    private static func error(_ status: OSStatus) -> SeafileError { .local(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)") }
}

public enum LocalFiles {
    public static func cacheURL(account: ServerAccount, repo: String, path: String) -> URL {
        let digest = SHA256.hash(data: Data((repo + ":" + path).utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next", isDirectory: true)
        return root.appendingPathComponent(account.id.uuidString).appendingPathComponent(digest).appendingPathComponent((path as NSString).lastPathComponent)
    }
    public static func clearCache(account: ServerAccount) throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next").appendingPathComponent(account.id.uuidString)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

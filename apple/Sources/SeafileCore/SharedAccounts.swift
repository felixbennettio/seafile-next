import Foundation
import Security

/// A shared keychain catalogue gives the Files extension account metadata;
/// passwords and access tokens never enter UserDefaults or an app-group file.
public enum SharedAccounts {
    public static var accessGroup: String? {
        guard Bundle.main.object(forInfoDictionaryKey: "SeafileSharedCredentials") as? Bool == true else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "SeafileKeychainGroup") as? String
    }
    private static var query: [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.felixbennett.seafile.catalogue", kSecAttrAccount as String: "accounts"]
        if let accessGroup { value[kSecAttrAccessGroup as String] = accessGroup }
        return value
    }
    public static func read() throws -> [ServerAccount] {
        var value = query
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw SeafileError.local("Open seafile-next and sign in to connect Files.") }
        return try JSONDecoder().decode([ServerAccount].self, from: data)
    }
    public static func write(_ accounts: [ServerAccount]) throws {
        guard accessGroup != nil else { return }
        let data = try JSONEncoder().encode(accounts)
        var values = query
        values[kSecValueData as String] = data
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(values as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else { throw SeafileError.local("Could not update the Files account catalogue.") }
        } else if status != errSecSuccess { throw SeafileError.local("Could not share this account with Files.") }
    }
}

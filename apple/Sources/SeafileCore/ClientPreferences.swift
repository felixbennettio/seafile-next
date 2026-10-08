import Foundation
import Security

public struct ClientNetworkSettings: Codable, Equatable, Sendable {
    public enum Proxy: String, Codable, CaseIterable, Sendable { case system, none, http, socks5 }
    public var proxy = Proxy.system
    public var host = ""
    public var port = 8080
    public var username = ""
    public var password = ""
    public var verifyCertificates = true
    public init() {}

    public func validate() throws {
        if proxy == .http || proxy == .socks5 {
            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !host.contains("/"), !host.contains("\n"), (1...65535).contains(port) else {
                throw SeafileError.local("Enter a proxy host and a port between 1 and 65535.")
            }
        }
    }

    public var proxyDictionary: [AnyHashable: Any]? {
        switch proxy {
        case .system: return nil
        case .none: return [:]
        case .http: return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                           "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        case .socks5: return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port]
        }
    }

    // Shared with the File Provider, including proxy credentials. Nothing is
    // written to UserDefaults or an app-group file in plain text.
    public static func load() -> Self {
        guard let data = try? PrivateSettings.read("network"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save() throws {
        try validate()
        try PrivateSettings.write(JSONEncoder().encode(self), name: "network")
    }
}

private enum PrivateSettings {
    static func query(_ name: String) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.felixbennett.seafile.preferences", kSecAttrAccount as String: name]
        if let group = SharedAccounts.accessGroup { value[kSecAttrAccessGroup as String] = group }
        return value
    }
    static func read(_ name: String) throws -> Data? {
        var value = query(name)
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SeafileError.local("Could not read saved network settings.") }
        return result as? Data
    }
    static func write(_ data: Data, name: String) throws {
        var value = query(name)
        value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(value as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else {
                throw SeafileError.local("Could not save network settings.")
            }
        } else if status != errSecSuccess { throw SeafileError.local("Could not save network settings.") }
    }
}

#if os(macOS)
public struct DesktopPreferences: Codable, Equatable, Sendable {
    public var hideDockIcon = false
    public var hideMainWindowWhenStarted = false
    public var notifySync = true
    public var downloadLimit = 0
    public var uploadLimit = 0
    public var allowInvalidWorktree = false
    public var allowRepoNotFoundOnServer = false
    public var syncExtraTempFile = false
    public var ignoreSymlinks = false
    public var hideWindowsIncompatibility = true
    public var deleteConfirmThreshold = 500
    public var syncWithExistingFolder = false
    public var finderIntegration = true
    public var computerName = Host.current().localizedName ?? "Mac"
    public var language = ""
    public var sortLibrariesByModification = false
    public init() {}

    public static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "desktopPreferences"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save() throws { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "desktopPreferences") }

    public var daemonStrings: [String: String] {
        ["notify_sync": notifySync ? "on" : "off", "client_name": computerName,
         "allow_invalid_worktree": allowInvalidWorktree ? "true" : "false",
         "allow_repo_not_found_on_server": allowRepoNotFoundOnServer ? "true" : "false",
         "sync_extra_temp_file": syncExtraTempFile ? "true" : "false",
         "ignore_symlinks": ignoreSymlinks ? "true" : "false",
         "hide_windows_incompatible_path_notification": hideWindowsIncompatibility ? "true" : "false"]
    }
}
#endif

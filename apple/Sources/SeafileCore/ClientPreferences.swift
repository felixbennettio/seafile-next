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
    private enum CodingKeys: String, CodingKey { case proxy, host, port, username, password, verifyCertificates }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        proxy = try values.decodeIfPresent(Proxy.self, forKey: .proxy) ?? proxy
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? host
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? username
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? password
        verifyCertificates = try values.decodeIfPresent(Bool.self, forKey: .verifyCertificates) ?? verifyCertificates
    }

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
    private enum CodingKeys: String, CodingKey {
        case hideDockIcon, hideMainWindowWhenStarted, notifySync, downloadLimit, uploadLimit
        case allowInvalidWorktree, allowRepoNotFoundOnServer, syncExtraTempFile, ignoreSymlinks
        case hideWindowsIncompatibility, deleteConfirmThreshold, syncWithExistingFolder, finderIntegration
        case computerName, language, sortLibrariesByModification
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hideDockIcon = try values.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? hideDockIcon
        hideMainWindowWhenStarted = try values.decodeIfPresent(Bool.self, forKey: .hideMainWindowWhenStarted) ?? hideMainWindowWhenStarted
        notifySync = try values.decodeIfPresent(Bool.self, forKey: .notifySync) ?? notifySync
        downloadLimit = try values.decodeIfPresent(Int.self, forKey: .downloadLimit) ?? downloadLimit
        uploadLimit = try values.decodeIfPresent(Int.self, forKey: .uploadLimit) ?? uploadLimit
        allowInvalidWorktree = try values.decodeIfPresent(Bool.self, forKey: .allowInvalidWorktree) ?? allowInvalidWorktree
        allowRepoNotFoundOnServer = try values.decodeIfPresent(Bool.self, forKey: .allowRepoNotFoundOnServer) ?? allowRepoNotFoundOnServer
        syncExtraTempFile = try values.decodeIfPresent(Bool.self, forKey: .syncExtraTempFile) ?? syncExtraTempFile
        ignoreSymlinks = try values.decodeIfPresent(Bool.self, forKey: .ignoreSymlinks) ?? ignoreSymlinks
        hideWindowsIncompatibility = try values.decodeIfPresent(Bool.self, forKey: .hideWindowsIncompatibility) ?? hideWindowsIncompatibility
        deleteConfirmThreshold = try values.decodeIfPresent(Int.self, forKey: .deleteConfirmThreshold) ?? deleteConfirmThreshold
        syncWithExistingFolder = try values.decodeIfPresent(Bool.self, forKey: .syncWithExistingFolder) ?? syncWithExistingFolder
        finderIntegration = try values.decodeIfPresent(Bool.self, forKey: .finderIntegration) ?? finderIntegration
        computerName = try values.decodeIfPresent(String.self, forKey: .computerName) ?? computerName
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? language
        sortLibrariesByModification = try values.decodeIfPresent(Bool.self, forKey: .sortLibrariesByModification) ?? sortLibrariesByModification
    }

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

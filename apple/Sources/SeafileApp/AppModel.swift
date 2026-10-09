import SwiftUI
import Observation
import SeafileCore
#if os(macOS)
import AppKit
#endif

struct BrowserLocation: Identifiable {
    let id = UUID()
    let account: ServerAccount, repo: Repository
    let path: String
    let filename: String?
}

@MainActor @Observable
final class AppModel {
    var accounts: [ServerAccount] = []
    var selectedAccountID: UUID?
    var repositories: [Repository] = []
    var listingError: String?
    var loading = false
    var errorMessage: String?
    var fileIntegrationWarning: String?
    var showLogin = false
    var location: BrowserLocation?
    var previewGeneration = 0
    private var fileActions: [UUID: Int] = [:]
    func beginFileAction(_ account: ServerAccount) { fileActions[account.id, default: 0] += 1 }
    func endFileAction(_ account: ServerAccount) { fileActions[account.id] = max(0, fileActions[account.id, default: 0] - 1) }
    #if os(macOS) && !APPSTORE
    var finderShare: FinderShareRequest?
    #endif
    private var generation = 0
    private let defaults = UserDefaults.standard
    #if os(iOS)
    @ObservationIgnored lazy var photoBackup = MobilePhotoBackup(model: self)
    #endif
    @ObservationIgnored lazy var textDrafts: Result<TextDraftStore, Error> = Result {
        let root: URL
        #if DEBUG
        if uiFixture != nil { root = FileManager.default.temporaryDirectory.appendingPathComponent("seafile-ui-drafts-" + UUID().uuidString) }
        else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/TextDrafts") }
        #else
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/TextDrafts")
        #endif
        return try TextDraftStore(root: root)
    }
    @ObservationIgnored lazy var recentDirectories: Result<RecentDirectoryStore, Error> = Result {
        let root: URL
        #if DEBUG
        if uiFixture != nil { root = FileManager.default.temporaryDirectory.appendingPathComponent("seafile-ui-recents-" + UUID().uuidString) }
        else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/RecentFolders") }
        #else
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/RecentFolders")
        #endif
        return try RecentDirectoryStore(directory: root)
    }
    @ObservationIgnored lazy var transfers: FileTransferQueue = {
        let root: URL
        #if DEBUG
        if uiFixture != nil { root = FileManager.default.temporaryDirectory.appendingPathComponent("seafile-ui-transfers-" + UUID().uuidString) }
        else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/Transfers") }
        #else
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("seafile-next/Transfers")
        #endif
        let queue: FileTransferQueue
        do { queue = try FileTransferQueue(root: root) }
        catch {
            errorMessage = "The saved transfer history could not be opened. Its files are preserved. \(error.localizedDescription)"
            queue = FileTransferQueue(unavailableRoot: root, error: error.localizedDescription)
        }
        queue.start(wifiClientFactory: { [weak self] id, progress in
            guard let self, let account = self.accounts.first(where: { $0.id == id }) else { throw SeafileError.local("Sign in to this transfer's account first.") }
            return try self.client(for: account, progress: progress, wifiOnly: true)
        }) { [weak self] id, progress in
            guard let self, let account = self.accounts.first(where: { $0.id == id }) else { throw SeafileError.local("Sign in to this transfer's account first.") }
            return try self.client(for: account, progress: progress)
        }
        return queue
    }()
    #if DEBUG
    let uiFixture = UITestFixture.fromLaunchArguments()
    #endif
    var account: ServerAccount? { accounts.first { $0.id == selectedAccountID } }

    init() {
        #if DEBUG
        if let uiFixture {
            accounts = uiFixture.accounts
            selectedAccountID = accounts.first?.id
            Task { [weak self] in await self?.refresh() }
            return
        }
        #endif
        if let data = defaults.data(forKey: "accounts") {
            do { accounts = try JSONDecoder().decode([ServerAccount].self, from: data) }
            catch { errorMessage = "Saved accounts could not be read: \(error.localizedDescription)" }
        }
        selectedAccountID = defaults.string(forKey: "selectedAccount").flatMap(UUID.init(uuidString:)) ?? accounts.first?.id
        if let account { repositories = ListingCache.read([Repository].self, account: account, key: "repositories") ?? [] }
        if ProcessInfo.processInfo.arguments.contains("--seafile-next-update-failed") { errorMessage = "The update could not be installed. The previous app and local files are preserved." }
        Task { [weak self] in
            guard let self else { return }
            _ = self.transfers
            await self.refresh()
        }
    }

    #if os(macOS)
    func openLocalLink(_ url: URL) async {
        guard url.scheme == "seafile", url.host == "openfile", let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let repoID = query.first(where: { $0.name == "repo_id" })?.value,
              let path = query.first(where: { $0.name == "path" })?.value, path.hasPrefix("/"),
              !path.components(separatedBy: "/").contains(".."), !path.contains("\0") else { errorMessage = "This Seafile file link is invalid."; return }
        if let synced = SyncController.shared.libraries.first(where: { $0.id == repoID }) {
            let file = URL(fileURLWithPath: synced.folder).appendingPathComponent(String(path.dropFirst()))
            if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file); return }
        }
        for account in accounts {
            do {
                let repos = try await client(for: account).repositories()
                if let repo = repos.first(where: { $0.id == repoID }) {
                    select(account); repositories = repos
                    location = BrowserLocation(account: account, repo: repo, path: path.hasSuffix("/") ? path : (path as NSString).deletingLastPathComponent,
                        filename: path.hasSuffix("/") ? nil : (path as NSString).lastPathComponent)
                    return
                }
            } catch { continue }
        }
        errorMessage = "This library is unavailable. Sign in to its account first."
    }
    #endif

    func client(for account: ServerAccount, progress: (@Sendable (Int64, Int64) -> Void)? = nil, wifiOnly: Bool = false) throws -> SeafileAPI {
        #if DEBUG
        if let uiFixture { return SeafileAPI(endpoint: account.endpoint, token: "fixture", transport: uiFixture) }
        #endif
        guard let token = try CredentialStore.token(for: account) else {
            throw SeafileError.local("Sign in again to this account.")
        }
        if progress != nil || wifiOnly { return SeafileAPI(endpoint: account.endpoint, token: token, transport: RetryingHTTPTransport(transport: URLSessionTransport(wifiOnly: wifiOnly, progress: progress))) }
        return SeafileAPI(endpoint: account.endpoint, token: token)
    }

    func restoreFileIntegration() async {
        #if DEBUG
        if uiFixture != nil { return }
        #endif
        do {
            // Reconnect accounts saved before the Files integration was added.
            // Reading credentials migrates their old default Keychain group.
            for account in accounts { _ = try CredentialStore.token(for: account) }
            try SharedAccounts.write(accounts)
            for account in accounts { try await FileIntegration.connect(account) }
        } catch { fileIntegrationWarning = error.localizedDescription }
    }

    func select(_ account: ServerAccount) {
        previewGeneration += 1
        generation += 1
        selectedAccountID = account.id
        #if DEBUG
        if uiFixture == nil { defaults.set(account.id.uuidString, forKey: "selectedAccount") }
        #else
        defaults.set(account.id.uuidString, forKey: "selectedAccount")
        #endif
        repositories = ListingCache.read([Repository].self, account: account, key: "repositories") ?? []
        listingError = nil
        loading = false
        #if os(macOS)
        SyncController.shared.use(account: account)
        #endif
    }

    func signIn(server: String, email: String, password: String, otp: String) async throws {
        let endpoint = try ServerEndpoint(server)
        let token = try await loginClient(endpoint: endpoint).authenticate(username: email, password: password, otp: otp, device: BrowserSignIn.device())
        try await finishSignIn(endpoint: endpoint, token: token, loginName: email)
    }

    func finishSignIn(endpoint: ServerEndpoint, token: String, loginName: String) async throws {
        let profile = try await loginClient(endpoint: endpoint, token: token).accountInfo()
        try Task.checkCancellation()
        let existing = accounts.first { $0.endpoint == endpoint && ($0.email == profile.email || $0.email == loginName) }
        let account = ServerAccount(id: existing?.id ?? UUID(), endpoint: endpoint, email: profile.email, name: profile.name, alias: existing?.alias)
        #if DEBUG
        if uiFixture != nil {
            if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
            else { accounts.append(account) }
            select(account)
            await refresh()
            return
        }
        #endif
        try CredentialStore.save(token, for: account)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
        else { accounts.append(account) }
        defaults.set(try JSONEncoder().encode(accounts), forKey: "accounts")
        select(account)
        do { try SharedAccounts.write(accounts); try await FileIntegration.connect(account); fileIntegrationWarning = nil }
        catch { fileIntegrationWarning = error.localizedDescription }
        await refresh()
    }

    private func loginClient(endpoint: ServerEndpoint, token: String? = nil) -> SeafileAPI {
        #if DEBUG
        if let uiFixture { return SeafileAPI(endpoint: endpoint, token: token, transport: uiFixture) }
        #endif
        return SeafileAPI(endpoint: endpoint, token: token)
    }

    func update(_ account: ServerAccount, alias: String, server: String) async throws {
        let endpoint = try ServerEndpoint(server)
        #if os(iOS)
        if endpoint != account.endpoint { try photoBackup.requireDisabled(account) }
        #endif
        if endpoint != account.endpoint, transfers.hasActiveTransfers(accountID: account.id) { throw SeafileError.local("Finish or cancel this account's transfers before changing its server address.") }
        var updated = ServerAccount(id: account.id, endpoint: endpoint, email: account.email, name: account.name,
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : alias)
        if endpoint != account.endpoint {
            guard let token = try CredentialStore.token(for: account) else { throw SeafileError.local("Sign in before changing the server address.") }
            let profile = try await SeafileAPI(endpoint: endpoint, token: token).accountInfo()
            guard profile.email == account.email else { throw SeafileError.local("The new server address belongs to a different account.") }
            #if os(macOS)
            try await SyncController.shared.updateServerAddress(from: account.endpoint.url, to: endpoint.url)
            #endif
            updated.name = updated.alias ?? profile.name ?? profile.email
        } else { updated.name = updated.alias ?? account.email }
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = updated
        defaults.set(try JSONEncoder().encode(accounts), forKey: "accounts")
        try SharedAccounts.write(accounts)
        if selectedAccountID == account.id { select(updated); await refresh() }
    }

    func clearCache(_ account: ServerAccount) throws {
        try transfers.clearDownloads(accountID: account.id)
        try LocalFiles.clearCache(account: account)
    }

    func logout(_ account: ServerAccount) async throws {
        #if os(iOS)
        try photoBackup.requireDisabled(account)
        #endif
        guard fileActions[account.id, default: 0] == 0 else { throw SeafileError.local("Wait for this account's file operations to finish before signing out.") }
        guard !transfers.hasActiveTransfers(accountID: account.id) else { throw SeafileError.local("Finish or cancel this account's transfers before signing out.") }
        try await client(for: account).logoutDevice()
        #if os(macOS)
        try await SyncController.shared.disconnect(account)
        #endif
        try await FileIntegration.disconnect(account)
        try CredentialStore.delete(account)
        if selectedAccountID == account.id { repositories = []; listingError = "Sign in again to this account." }
    }

    func remove(_ account: ServerAccount) async throws {
        #if os(iOS)
        try photoBackup.requireDisabled(account)
        #endif
        guard fileActions[account.id, default: 0] == 0 else { throw SeafileError.local("Wait for this account's file operations to finish before removing it.") }
        guard !transfers.hasPendingUploads(accountID: account.id), !transfers.hasActiveTransfers(accountID: account.id) else { throw SeafileError.local("Finish, export or remove this account's pending uploads in Transfers before removing the account.") }
        guard !(try textDrafts.get().drafts(account: account.id)).contains(where: \.changed) else { throw SeafileError.local("Upload, export or discard your text drafts before removing this account.") }
        #if os(macOS)
        guard !MacFileEditor.shared.hasChanges(account: account) else { throw SeafileError.local("Upload or export the pending local edits before removing this account.") }
        try await SyncController.shared.disconnect(account)
        #endif
        try await FileIntegration.disconnect(account)
        #if os(iOS)
        try photoBackup.remove(account)
        #endif
        try textDrafts.get().clearUnedited(account: account.id)
        if case .success(let recent) = recentDirectories { try await recent.remove(account: account.id) }
        try CredentialStore.delete(account)
        try LocalFiles.clearCache(account: account)
        for transfer in transfers.transfers where transfer.accountID == account.id { try transfers.remove(transfer.id) }
        accounts.removeAll { $0.id == account.id }
        try SharedAccounts.write(accounts)
        defaults.set(try JSONEncoder().encode(accounts), forKey: "accounts")
        generation += 1
        if selectedAccountID == account.id {
            selectedAccountID = accounts.first?.id
            defaults.set(selectedAccountID?.uuidString, forKey: "selectedAccount")
            repositories = self.account.flatMap { ListingCache.read([Repository].self, account: $0, key: "repositories") } ?? []
            listingError = nil
            loading = false
        }
    }

    func refresh() async {
        guard let account, !loading else { return }
        generation += 1
        let request = generation
        loading = true
        defer { if request == generation { loading = false } }
        do {
            let result = try await client(for: account).repositories()
            guard !Task.isCancelled, request == generation, selectedAccountID == account.id else { return }
            repositories = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            listingError = nil
            try ListingCache.write(repositories, account: account, key: "repositories")
        } catch {
            if !Task.isCancelled, request == generation { listingError = error.localizedDescription }
        }
    }
}

@MainActor @Observable
final class DirectoryModel {
    var entries: [DirectoryEntry] = []
    var loading = false
    var error: String?
    var lastUpdated: Date?
    private var generation = 0

    func refresh(api: SeafileAPI, account: ServerAccount, repo: String, path: String) async {
        guard !loading else { return }
        if lastUpdated == nil, entries.isEmpty { entries = ListingCache.read([DirectoryEntry].self, account: account, key: repo + ":" + path) ?? [] }
        generation += 1
        let request = generation
        loading = true
        defer { if request == generation { loading = false } }
        do {
            let result = try await api.directory(repo: repo, path: path)
            guard !Task.isCancelled, generation == request else { return }
            entries = result
            error = nil
            lastUpdated = Date()
            try ListingCache.write(entries, account: account, key: repo + ":" + path)
        } catch {
            if !Task.isCancelled, generation == request { self.error = error.localizedDescription }
        }
    }
}

import SwiftUI
import Observation
import SeafileCore

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
    private var generation = 0
    private let defaults = UserDefaults.standard
    #if DEBUG
    let uiFixture = UITestFixture.fromLaunchArguments()
    #endif
    var account: ServerAccount? { accounts.first { $0.id == selectedAccountID } }

    init() {
        #if DEBUG
        if let uiFixture {
            accounts = uiFixture.accounts
            selectedAccountID = accounts.first?.id
            return
        }
        #endif
        if let data = defaults.data(forKey: "accounts") {
            do { accounts = try JSONDecoder().decode([ServerAccount].self, from: data) }
            catch { errorMessage = "Saved accounts could not be read: \(error.localizedDescription)" }
        }
        selectedAccountID = defaults.string(forKey: "selectedAccount").flatMap(UUID.init(uuidString:)) ?? accounts.first?.id
        if let account { repositories = ListingCache.read([Repository].self, account: account, key: "repositories") ?? [] }
    }

    func client(for account: ServerAccount) throws -> SeafileAPI {
        #if DEBUG
        if let uiFixture { return SeafileAPI(endpoint: account.endpoint, token: "fixture", transport: uiFixture) }
        #endif
        guard let token = try CredentialStore.token(for: account) else {
            throw SeafileError.local("Sign in again to this account.")
        }
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
        let token = try await loginClient(endpoint: endpoint).authenticate(username: email, password: password, otp: otp)
        try await finishSignIn(endpoint: endpoint, token: token, loginName: email)
    }

    func finishSignIn(endpoint: ServerEndpoint, token: String, loginName: String) async throws {
        let profile = try await loginClient(endpoint: endpoint, token: token).accountInfo()
        try Task.checkCancellation()
        let existing = accounts.first { $0.endpoint == endpoint && ($0.email == profile.email || $0.email == loginName) }
        let account = ServerAccount(id: existing?.id ?? UUID(), endpoint: endpoint, email: profile.email, name: profile.name)
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

    func remove(_ account: ServerAccount) async throws {
        #if os(macOS)
        try await SyncController.shared.disconnect(account)
        #endif
        try await FileIntegration.disconnect(account)
        try CredentialStore.delete(account)
        try LocalFiles.clearCache(account: account)
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

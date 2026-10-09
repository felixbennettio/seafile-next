import SwiftUI
import SeafileCore
#if os(macOS)
import ServiceManagement
#endif

struct LoginView: View {
    var model: AppModel
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var loading = false
    @State private var error: String?
    @State private var browser = BrowserSignIn()
    @State private var signingIn: Task<Void, Never>?
    @State private var usingSSO = false
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, account: ServerAccount? = nil) {
        self.model = model
        _server = State(initialValue: account?.endpoint.url.absoluteString ?? "")
        _email = State(initialValue: account?.email ?? "")
    }
    private var serverInput: some View {
        LoginInput("Server address") {
            TextField("Server address", text: $server, prompt: Text("Enter your server address"))
                .accessibilityIdentifier("login.server")
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                #endif
        }
    }
    @ViewBuilder private var credentials: some View {
        LoginInput("Email or username") {
            TextField("Email or username", text: $email, prompt: Text("Enter your email or username"))
                .accessibilityIdentifier("login.email")
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                #endif
        }
        LoginInput("Password") {
            SecureField("Password", text: $password, prompt: Text("Enter your password")).accessibilityIdentifier("login.password")
        }
        LoginInput("Two-factor code (optional)") {
            TextField("Two-factor code", text: $otp, prompt: Text("Enter a code if required")).accessibilityIdentifier("login.otp")
        }
    }
    private var sso: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Sign in with SSO", systemImage: "person.badge.key") {
                usingSSO = true
                startSignIn {
                    let endpoint = try ServerEndpoint(server)
                    let identity = try await browser.authenticate(endpoint: endpoint, api: model.loginClient(endpoint: endpoint))
                    try await model.finishSignIn(endpoint: endpoint, token: identity.apiToken, loginName: identity.username)
                }
            }.disabled((try? ServerEndpoint(server)) == nil || loading).accessibilityIdentifier("login.sso")
            Text("Sign in with OIDC or SAML in your default browser. Older servers use a separate sign-in window. After confirming the client login, return to seafile-next to open your files.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var status: some View {
        if let error { Text(error).foregroundStyle(.red) }
        if loading {
            ProgressView(usingSSO ? "Waiting for browser sign-in" : "Signing in")
            if usingSSO { Text("After confirming sign-in in the browser, return to this app. You can cancel here to start over.").font(.caption) }
        }
    }
    var body: some View {
        NavigationStack {
            Group {
                #if os(macOS)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("Your server") {
                            VStack(alignment: .leading, spacing: 8) {
                                serverInput
                                Text("Include the full path if Seafile runs below a domain path.").font(.caption).foregroundStyle(.secondary)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        GroupBox { sso.padding(8) }
                        GroupBox("Account") { VStack(alignment: .leading, spacing: 4) { credentials }.padding(8) }
                        status
                    }.padding(20)
                }
                #else
                Form {
                    Section("Your server") {
                        serverInput
                        Text("Include the full path if Seafile runs below a domain path.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section { sso }
                    Section("Account") { credentials }
                    status
                }.formStyle(.grouped)
                #endif
            }
            .navigationTitle("Add account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { signingIn?.cancel(); browser.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") {
                        usingSSO = false
                        startSignIn { try await model.signIn(server: server, email: email, password: password, otp: otp) }
                    }.disabled(server.isEmpty || email.isEmpty || password.isEmpty || loading).accessibilityIdentifier("login.passwordSignIn")
                }
            }
        }.sheet(item: $browser.legacyRequest, onDismiss: { browser.cancel() }) { request in
            LegacySignInView(request: request) { result in browser.completeLegacy(request.id, result: result) }
        }.onDisappear { signingIn?.cancel(); browser.cancel() }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 560, minHeight: 500, idealHeight: 560)
            #endif
    }

    private func startSignIn(_ action: @escaping @MainActor () async throws -> Void) {
        loading = true
        error = nil
        signingIn = Task {
            defer { loading = false; signingIn = nil }
            do { try await action(); try Task.checkCancellation(); password = ""; otp = ""; dismiss() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct LoginInput<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
    }
}

struct PreferencesView: View {
    var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var removeAccount: ServerAccount?
    #if os(iOS)
    @State private var backupAccount: ServerAccount?
    #endif
    #if os(macOS)
    @State private var loginStatus = SMAppService.mainApp.status
    #endif
    var body: some View {
        #if os(macOS)
        MacPreferencesView(model: model)
        #else
        Form {
            Section("seafile-next") {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                #if APPSTORE
                Text("App Store / TestFlight edition")
                #else
                Text("Direct distribution edition")
                #endif
            }
            #if os(macOS)
            Section("Startup") {
                Toggle("Start seafile-next at login", isOn: Binding(get: { loginStatus == .enabled }, set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginStatus = SMAppService.mainApp.status
                        if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    } catch { model.errorMessage = error.localizedDescription; loginStatus = SMAppService.mainApp.status }
                }))
                if loginStatus == .requiresApproval {
                    Button("Approve in Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    Text("macOS requires approval before this app can start at login.").font(.caption)
                }
            }.onAppear { loginStatus = SMAppService.mainApp.status }
                .onChange(of: phase) { _, phase in if phase == .active { loginStatus = SMAppService.mainApp.status } }
            #endif
            Section("Accounts") {
                ForEach(model.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) { Text(account.email); Text(account.endpoint.url.absoluteString).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Clear cache") { do { try model.clearCache(account) } catch { model.errorMessage = error.localizedDescription } }
                        Button("Remove", role: .destructive) { removeAccount = account }
                    }
                }
            }
            Section("Security") {
                Toggle("Lock this app", isOn: Binding(get: { MobileAppLock.shared.state.enabled }, set: { value in Task { await MobileAppLock.shared.setEnabled(value) } }))
                    .disabled(MobileAppLock.shared.authenticating)
                Text("Unlock with Face ID, Touch ID or your device passcode. The app locks when it enters the background.").font(.caption)
                Text("This locks Seafile Next. Access through the Files app uses your device's security settings.").font(.caption).foregroundStyle(.secondary)
                if MobileAppLock.shared.state.enabled { Button("Lock now") { MobileAppLock.shared.lock() } }
                if let error = MobileAppLock.shared.error { Text(error).foregroundStyle(.red) }
            }
            Section("Photo backup") {
                ForEach(model.accounts) { account in
                    Button(account.name) { backupAccount = account }.accessibilityIdentifier("backup.account.\(account.email)")
                }
            }
            if let warning = model.fileIntegrationWarning {
                Section("Files integration") { Text(warning).font(.callout).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
            .sheet(item: $backupAccount) { account in MobilePhotoBackupView(model: model, account: account) }
            .confirmationDialog("Remove account?", isPresented: Binding(get: { removeAccount != nil }, set: { if !$0 { removeAccount = nil } })) {
                Button("Remove", role: .destructive) {
                    if let account = removeAccount { Task { do { try await model.remove(account) } catch { model.errorMessage = error.localizedDescription } } }
                }
            } message: { Text("Server files are preserved. This device's credentials and cached files are removed.") }
        #endif
    }
}

struct StarredView: View {
    var model: AppModel
    let account: ServerAccount
    @State private var items: [StarredItem] = []
    @State private var preview: URL?
    @State private var loading = false
    @State private var opening = false
    @State private var openingTask: Task<Void, Never>?
    @State private var openingTicket: UUID?
    @State private var visible = false
    @State private var unstar: StarredItem?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        List(items) { item in
            Group {
                if item.isDirectory, !item.deleted {
                    NavigationLink { StarredDirectoryView(model: model, account: account, item: item) } label: { row(item) }
                } else {
                    Button { open(item) } label: { row(item) }.buttonStyle(.plain).disabled(item.deleted || opening)
                }
            }
            .accessibilityIdentifier("starred.\(item.path)")
            // Keep mutation actions outside the preview button. Automatic
            // buttons in one List HStack can both fire when a row is tapped.
            .contextMenu { Button("Unstar", systemImage: "star.slash") { unstar = item } }
            .swipeActions { Button("Unstar", systemImage: "star.slash") { unstar = item }.tint(.orange) }
        }.navigationTitle("Starred").quickLookPreview($preview)
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading) }
            .overlay {
                if loading || opening { ProgressView() }
                else if items.isEmpty { ContentUnavailableView("No starred items", systemImage: "star") }
            }
            .task { await refresh() }.refreshable { await refresh() }
            .onAppear { visible = true; model.previewGeneration += 1 }
            .onDisappear { visible = false; openingTask?.cancel(); openingTask = nil; openingTicket = nil; opening = false }
            .onChange(of: phase) { _, value in if value == .active { Task { await refresh() } } }
            .confirmationDialog("Remove from Starred?", isPresented: Binding(get: { unstar != nil }, set: { if !$0 { unstar = nil } })) {
                if let item = unstar {
                    Button("Unstar", role: .destructive) {
                        unstar = nil
                        Task {
                            do { try await model.client(for: account).setStarred(repo: item.repo, path: item.path, starred: false); await refresh() }
                            catch { model.errorMessage = error.localizedDescription }
                        }
                    }
                }
            } message: { Text("The file or folder stays on the server.") }
    }
    private func row(_ item: StarredItem) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(item.name)
                Text(item.deleted ? "Item no longer available" : item.repositoryName).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: item.isDirectory ? "folder" : "doc") }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
    private func open(_ item: StarredItem) {
        guard !item.deleted, !opening else { return }
        opening = true
        let ticket = UUID(); openingTicket = ticket
        let generation = model.previewGeneration
        openingTask = Task {
            defer { if openingTicket == ticket { opening = false; openingTask = nil } }
            do {
                let id = try model.transfers.enqueueDownload(accountID: account.id, repository: item.repo, path: item.path)
                let destination = try await model.transfers.result(for: id)
                if visible, generation == model.previewGeneration, openingTicket == ticket, model.selectedAccountID == account.id { preview = destination }
            } catch { if visible, generation == model.previewGeneration, !Task.isCancelled { model.errorMessage = error.localizedDescription } }
        }
    }
    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.client(for: account).starredItems()
            guard !Task.isCancelled else { return }
            items = result
        }
        catch { if !Task.isCancelled { model.errorMessage = error.localizedDescription } }
    }
}

private struct StarredDirectoryView: View {
    var model: AppModel
    let account: ServerAccount
    let item: StarredItem
    @State private var repository: Repository?
    @State private var error: String?
    var body: some View {
        Group {
            if let repository { RepositoryView(model: model, account: account, repo: repository, path: item.path) }
            else if let error { ContentUnavailableView("Could not open folder", systemImage: "folder.badge.questionmark", description: Text(error)) }
            else { ProgressView("Loading folder") }
        }.task {
            do {
                let repositories = try await model.client(for: account).repositories()
                try Task.checkCancellation()
                guard let repository = repositories.first(where: { $0.id == item.repo }) else { throw SeafileError.local("This library is no longer available to your account.") }
                self.repository = repository
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

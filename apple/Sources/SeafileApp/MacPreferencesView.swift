#if os(macOS)
import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import SeafileCore
#if !APPSTORE
import FinderSync
#endif

struct MacPreferencesView: View {
    var model: AppModel
    var standaloneWindow = false
    private enum Page: Hashable { case basic, advanced, language, network, accounts, about }
    @State private var page: Page = .basic
    @State private var settings = DesktopPreferences()
    @State private var network = ClientNetworkSettings()
    @State private var windowReference = SettingsWindowReference()
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var saving = false
    @State private var message: String?
    @State private var manageAccount: ServerAccount?
    @State private var removeAccount: ServerAccount?
    @State private var confirmUntrusted = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                preferencePage { basicSettings }.tabItem { Text("Basic") }.tag(Page.basic)
                preferencePage { advancedSettings }.tabItem { Text("Advanced") }.tag(Page.advanced)
                preferencePage { languageSettings }.tabItem { Text("Language") }.tag(Page.language)
                preferencePage { networkSettings }.tabItem { Text("Network") }.tag(Page.network)
                preferencePage { accountSettings }.tabItem { Text("Accounts") }.tag(Page.accounts)
                preferencePage { aboutSettings }.tabItem { Text("About") }.tag(Page.about)
            }.toggleStyle(.checkbox).padding(16).disabled(saving)
            Divider()
            HStack(spacing: 10) {
                if let message { Text(message).font(.callout).foregroundStyle(.red).lineLimit(2).accessibilityIdentifier("settings.error") }
                if saving { ProgressView().controlSize(.small).accessibilityLabel("Saving settings") }
                Spacer(minLength: 8)
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).disabled(saving)
                    .accessibilityIdentifier("settings.cancel")
                Button("Save settings") { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(saving)
                    .accessibilityIdentifier("settings.save")
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 660, height: 500)
            .background(SettingsWindowReader(reference: windowReference).frame(width: 0, height: 0))
            .interactiveDismissDisabled(saving)
            .onAppear { load() }
            .onChange(of: phase) { _, phase in if phase == .active { loginStatus = SMAppService.mainApp.status } }
            .alert("Disable certificate verification?", isPresented: $confirmUntrusted) {
                Button("Keep verification", role: .cancel) {}
                Button("Disable verification", role: .destructive) { network.verifyCertificates = false }
            } message: { Text("Connections to your Seafile servers will accept untrusted certificates. Only use this for a server whose certificate you have independently verified.") }
            .sheet(item: $manageAccount) { account in MacAccountSheet(model: model, account: account) }
            .confirmationDialog("Remove account?", isPresented: Binding(get: { removeAccount != nil }, set: { if !$0 { removeAccount = nil } })) {
                Button("Remove", role: .destructive) {
                    guard let account = removeAccount else { return }
                    Task { do { try await model.remove(account) } catch { message = error.localizedDescription } }
                }
            } message: { Text("Server files are preserved. This device's credentials and cached files are removed.") }
    }

    private func preferencePage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 10, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(18) }
    }

    private var basicSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Start seafile-next at login", isOn: Binding(get: { loginStatus == .enabled }, set: { enabled in setAutoStart(enabled) }))
                .accessibilityIdentifier("settings.autoStart")
            if loginStatus == .requiresApproval {
                Button("Approve in Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
            Toggle("Hide seafile-next icon from the Dock", isOn: $settings.hideDockIcon)
                .accessibilityIdentifier("settings.hideDock")
            Toggle("Hide main window when started", isOn: $settings.hideMainWindowWhenStarted)
            Toggle("Show sync notifications", isOn: $settings.notifySync)
            Toggle("Sync temporary files", isOn: $settings.syncExtraTempFile)
            Toggle("Ignore symbolic links", isOn: $settings.ignoreSymlinks)
            Toggle("Hide Windows incompatible path notifications", isOn: $settings.hideWindowsIncompatibility)
            Toggle("Files and Finder integration", isOn: $settings.finderIntegration)
            LabeledContent("Computer name") {
                TextField("Computer name", text: $settings.computerName).labelsHidden().textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading).frame(width: 280).accessibilityIdentifier("settings.computerName")
            }
            HStack(alignment: .top, spacing: 18) {
                PreferenceInput("Download limit (KiB/s, 0 = unlimited)") {
                    TextField("Download limit", value: $settings.downloadLimit, format: .number.grouping(.never)).labelsHidden()
                }
                PreferenceInput("Upload limit (KiB/s, 0 = unlimited)") {
                    TextField("Upload limit", value: $settings.uploadLimit, format: .number.grouping(.never)).labelsHidden()
                }
            }
            #if !FILES_PROVIDER
            HStack {
                Button("Enable Finder extension") { FIFinderSyncController.showExtensionManagementInterface() }
                Button("Open synced folders in Finder") { SyncController.shared.revealRoot() }
            }
            #endif
        }
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Language", selection: $settings.language) {
                Text("System language").tag("")
                ForEach(Bundle.main.localizations.filter { $0 != "Base" }.sorted(), id: \.self) { language in
                    Text(Locale.current.localizedString(forLanguageCode: language) ?? language).tag(language)
                }
            }
            Text("A language change takes effect after restarting the app.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enable syncing with an existing folder", isOn: $settings.syncWithExistingFolder)
            Toggle("Keep syncing when a local folder is temporarily unavailable", isOn: $settings.allowInvalidWorktree)
            Toggle("Keep a library when it is not found on the server", isOn: $settings.allowRepoNotFoundOnServer)
            Toggle("Verify server certificates", isOn: Binding(get: { network.verifyCertificates }, set: { enabled in
                if enabled { network.verifyCertificates = true } else { confirmUntrusted = true }
            }))
            PreferenceInput("Confirm deletions above this number of files") {
                TextField("Deletion confirmation threshold", value: $settings.deleteConfirmThreshold, format: .number.grouping(.never)).labelsHidden()
            }
        }
    }

    private var networkSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Proxy", selection: $network.proxy) {
                Text("System proxy").tag(ClientNetworkSettings.Proxy.system)
                Text("None").tag(ClientNetworkSettings.Proxy.none)
                Text("HTTP proxy").tag(ClientNetworkSettings.Proxy.http)
                Text("SOCKS5 proxy").tag(ClientNetworkSettings.Proxy.socks5)
            }.accessibilityIdentifier("settings.proxy")
            if network.proxy == .http || network.proxy == .socks5 {
                PreferenceInput("Host") { TextField("Proxy host", text: $network.host).labelsHidden().accessibilityIdentifier("settings.proxyHost") }
                PreferenceInput("Port") { TextField("Proxy port", value: $network.port, format: .number.grouping(.never)).labelsHidden() }
                PreferenceInput("Username (optional)") { TextField("Proxy username", text: $network.username).labelsHidden() }
                PreferenceInput("Password (optional)") { SecureField("Proxy password", text: $network.password).labelsHidden() }
            }
        }
    }

    private var accountSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(model.accounts) { account in
                VStack(alignment: .leading, spacing: 8) {
                    Text(account.name).font(.headline)
                    Text(account.email).foregroundStyle(.secondary)
                    Text(verbatim: account.endpoint.url.absoluteString).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Account settings") { manageAccount = account }
                        Button("Clear cache") { do { try model.clearCache(account) } catch { message = error.localizedDescription } }
                        Button("Remove account", role: .destructive) { removeAccount = account }
                    }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
            #if APPSTORE
            Text("App Store / TestFlight edition")
            #else
            Text("Direct distribution edition")
            #endif
            Button("Check for updates") { MacUpdateController.shared.presented = true; Task { await MacUpdateController.shared.check() } }
            #if !APPSTORE
            Toggle("Automatically check for updates", isOn: Binding(get: { MacUpdateController.shared.automatic }, set: { MacUpdateController.shared.automatic = $0 }))
            #endif
            Button("Open logs folder") { SyncController.shared.revealLogs() }
            Button("Online help") { NSWorkspace.shared.open(URL(string: "https://help.seafile.com/syncing_client/")!) }
            if let warning = model.fileIntegrationWarning { Text(warning).foregroundStyle(.secondary) }
        }
    }


    private func load() {
        #if DEBUG
        if model.uiFixture != nil {
            settings = DesktopPreferences(); settings.computerName = "Fixture Mac"
            network = ClientNetworkSettings()
            return
        }
        #endif
        settings = DesktopPreferences.load()
        network = ClientNetworkSettings.load()
    }

    private func close() {
        if standaloneWindow { windowReference.window?.performClose(nil) }
        else { dismiss() }
    }

    private func setAutoStart(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
            if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { message = error.localizedDescription; loginStatus = SMAppService.mainApp.status }
    }

    private func save() async {
        saving = true
        message = nil
        defer { saving = false }
        do {
            try network.validate()
            guard settings.uploadLimit >= 0, settings.downloadLimit >= 0, settings.uploadLimit <= Int(Int32.max) / 1024, settings.downloadLimit <= Int(Int32.max) / 1024, (0...Int(Int32.max)).contains(settings.deleteConfirmThreshold),
                  !settings.computerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SeafileError.local("Enter a computer name and nonnegative limits.")
            }
            #if DEBUG
            if model.uiFixture != nil { close(); return }
            #endif
            await SyncController.shared.start()
            try await SyncController.shared.apply(settings: settings, network: network)
            try network.save()
            try settings.save()
            _ = RetryingHTTPTransport.shared.freshConnection()
            NSApp.setActivationPolicy(settings.hideDockIcon ? .accessory : .regular)
            if let window = NSApp.keyWindow { window.orderFrontRegardless() }
            if settings.language.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([settings.language], forKey: "AppleLanguages") }
            if settings.notifySync { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            for account in model.accounts {
                if settings.finderIntegration { try await FileIntegration.connect(account) }
                else { try await FileIntegration.disconnect(account) }
            }
            close()
        } catch { message = error.localizedDescription }
    }
}

// Capture only the window hosting these preferences. Saving a Settings scene
// must close that window, while a preferences sheet uses SwiftUI dismissal.
@MainActor private final class SettingsWindowReference { weak var window: NSWindow? }
private struct SettingsWindowReader: NSViewRepresentable {
    let reference: SettingsWindowReference
    func makeNSView(context: Context) -> Reader { Reader(reference: reference) }
    func updateNSView(_ nsView: Reader, context: Context) {}
    final class Reader: NSView {
        let reference: SettingsWindowReference
        init(reference: SettingsWindowReference) { self.reference = reference; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reference.window = window }
    }
}

struct PreferenceInput<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content.textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
    }
}
#endif

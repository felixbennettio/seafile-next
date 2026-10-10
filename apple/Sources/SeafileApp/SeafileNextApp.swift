import SwiftUI
import SeafileCore
#if os(macOS)
import AppKit
#endif

@main
struct SeafileNextApp: App {
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    #if os(macOS)
    private var hideAtLaunch: Bool {
        #if DEBUG
        if model.uiFixture != nil { return false }
        #endif
        return DesktopPreferences.load().hideMainWindowWhenStarted
    }
    #endif
    init() {
        #if os(macOS)
        MacUpdateController.finishInstallIfRequested()
        #endif
    }
    var body: some Scene {
        #if os(macOS)
        Window("seafile-next", id: "browser") { BrowserView(model: model).frame(minWidth: 780, minHeight: 520) }
            .defaultLaunchBehavior(hideAtLaunch ? .suppressed : .presented)
        Window("Sync status", id: "sync") { SyncView(model: model).frame(minWidth: 700, minHeight: 480) }
            .defaultLaunchBehavior(.suppressed)
        Window("Transfers", id: "transfers") { NavigationStack { TransfersView(model: model) }.frame(minWidth: 600, minHeight: 420) }
            .defaultLaunchBehavior(.suppressed)
        Settings { MacPreferencesView(model: model, standaloneWindow: true) }
        MenuBarExtra { MenuBarView(model: model) } label: { StartupMenuIcon(model: model, showBrowser: !hideAtLaunch) }
        #else
        WindowGroup("seafile-next") { BrowserView(model: model).background(AppPrivacyWindow().frame(width: 0, height: 0)) }
        #endif
    }
}

#if os(macOS)
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if UITestFixture.fromLaunchArguments() != nil { return }
        #endif
        let settings = DesktopPreferences.load()
        NSApp.setActivationPolicy(settings.hideDockIcon ? .accessory : .regular)
        if settings.hideMainWindowWhenStarted {
            DispatchQueue.main.async { NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.orderOut(nil) } }
        }
        Task { await SyncController.shared.start() }
    }
    func application(_ application: NSApplication, open urls: [URL]) { MacURLRouter.shared.pending += urls }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { SyncController.shared.stop() }
}

@MainActor @Observable final class MacURLRouter {
    static let shared = MacURLRouter()
    var pending: [URL] = []
}

struct StartupMenuIcon: View {
    var model: AppModel
    let showBrowser: Bool
    @State private var presented = false
    @Environment(\.openWindow) private var openWindow
    private var symbol: String {
        let sync = SyncController.shared
        return sync.paused ? "pause.circle" : !sync.errors.isEmpty ? "exclamationmark.icloud" : sync.downloadRate + sync.uploadRate > 0 ? "arrow.triangle.2.circlepath.icloud" : "cloud"
    }
    var body: some View {
        Image(systemName: symbol).accessibilityLabel("seafile-next")
            .onChange(of: MacURLRouter.shared.pending, initial: true) { _, urls in
                guard !urls.isEmpty else { return }
                MacURLRouter.shared.pending = []
                openWindow(id: "browser")
                Task {
                    for url in urls {
                        #if !APPSTORE
                        if url.scheme == "seafile-next-direct", url.host == "finder" { await MacFinderBridge.shared.handle(url, model: model); continue }
                        #endif
                        await model.openLocalLink(url)
                    }
                }
            }
            .task {
                #if !APPSTORE
                #if DEBUG
                if model.uiFixture == nil { MacFinderBridge.shared.start(model: model) }
                #else
                MacFinderBridge.shared.start(model: model)
                #endif
                #endif
                #if DEBUG
                if model.uiFixture == nil { MacUpdateController.shared.start() }
                #else
                MacUpdateController.shared.start()
                #endif
                guard showBrowser, !presented else { return }
                presented = true
                openWindow(id: "browser")
            }
    }
}

struct MenuBarView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open seafile-next") { openWindow(id: "browser"); NSApp.activate(ignoringOtherApps: true) }
        Text(SyncController.shared.status)
        Button("Sync status and download tasks") { openWindow(id: "sync"); NSApp.activate(ignoringOtherApps: true) }
        Button("File transfers") { openWindow(id: "transfers"); NSApp.activate(ignoringOtherApps: true) }
        Button("Show file sync errors") { SyncController.shared.showErrors = true; openWindow(id: "sync"); NSApp.activate(ignoringOtherApps: true) }
        Button("Open sync folder") { SyncController.shared.revealRoot() }
        Button("Open logs folder") { SyncController.shared.revealLogs() }
        Button(SyncController.shared.paused ? "Resume syncing" : "Pause syncing") {
            Task { do { try await SyncController.shared.togglePause() } catch { model.errorMessage = error.localizedDescription } }
        }
        Button("Check for updates") { openWindow(id: "browser"); MacUpdateController.shared.presented = true; Task { await MacUpdateController.shared.check() } }
        SettingsLink()
        Divider()
        Button("Quit seafile-next") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif

extension View {
    @ViewBuilder func nextGlass() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) { self.glassEffect(.regular, in: .rect(cornerRadius: 18)) }
        else { self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) }
    }
}

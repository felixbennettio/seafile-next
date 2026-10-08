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
    var body: some Scene {
        WindowGroup("seafile-next", id: "browser") {
            BrowserView(model: model)
                #if os(macOS)
                .frame(minWidth: 780, minHeight: 520)
                #endif
        }
        #if os(macOS)
        Settings { PreferencesView(model: model) }
        MenuBarExtra("seafile-next", systemImage: "cloud") { MenuBarView(model: model) }
        #endif
    }
}

#if os(macOS)
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { SyncController.shared.stop() }
}

struct MenuBarView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open seafile-next") { openWindow(id: "browser"); NSApp.activate(ignoringOtherApps: true) }
        Text(SyncController.shared.status)
        Button(SyncController.shared.paused ? "Resume syncing" : "Pause syncing") {
            Task { do { try await SyncController.shared.togglePause() } catch { model.errorMessage = error.localizedDescription } }
        }
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

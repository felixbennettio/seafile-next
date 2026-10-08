#if os(macOS)
import SwiftUI
import AppKit
import UserNotifications
import Darwin
import SeafileCore

@MainActor @Observable final class MacUpdateController {
    static let shared = MacUpdateController()
    var presented = false
    var working = false
    var update: DirectMacUpdate?
    var prepared: URL?
    var message: String?
    private var monitor: Task<Void, Never>?
    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "automaticUpdateChecks") }
    }
    func start() {
        #if !APPSTORE
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
                if self.automatic, Date().timeIntervalSince(last) > 24 * 3600 { await self.check() }
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
            }
        }
        #endif
    }
    func check() async {
        guard !working else { return }; working = true
        defer { working = false }
        #if APPSTORE
        message = "App Store and TestFlight manage updates for this edition."
        #else
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
            let revision = Bundle.main.object(forInfoDictionaryKey: "SeafileSourceRevision") as? String
            update = try await MacUpdates().latest(version: version, revision: revision)
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            message = update == nil ? "You have the latest version." : "An update is available."
            if update != nil, !presented {
                let content = UNMutableNotificationContent(); content.title = "seafile-next"; content.body = "An update is available."
                try? await UNUserNotificationCenter.current().add(.init(identifier: "seafile-next-update", content: content, trigger: nil))
            }
        } catch { message = error.localizedDescription }
        #endif
    }
    func download() async {
        guard !working, let update else { return }; working = true
        defer { working = false }
        do { prepared = try await MacUpdates().download(update); message = "Update downloaded and verified." }
        catch { message = error.localizedDescription }
    }
    func install() throws {
        guard let prepared, let update, let executable = Bundle(url: prepared)?.executableURL else { throw SeafileError.invalidResponse }
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            NSWorkspace.shared.activateFileViewerSelecting([prepared])
            throw SeafileError.local("Move the downloaded app into Applications using Finder to complete the update.")
        }
        // The verified new binary waits until the running app and its sync
        // engine stop. It keeps the old app as a rollback copy.
        let helper = Process(); helper.executableURL = executable
        helper.arguments = ["--seafile-next-install-update", String(ProcessInfo.processInfo.processIdentifier), destination.path, update.sourceRevision]
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
        NSApp.terminate(nil)
    }
    static func finishInstallIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count == 5, arguments[1] == "--seafile-next-install-update" else { return }
        guard let parent = pid_t(arguments[2]), parent > 1 else { Darwin.exit(1) }
        let destination = URL(fileURLWithPath: arguments[3])
        do {
            for _ in 0..<300 {
                if Darwin.kill(parent, 0) != 0, errno == ESRCH { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard Darwin.kill(parent, 0) != 0, errno == ESRCH else { Darwin.exit(1) }
            Thread.sleep(forTimeInterval: 0.5)
            _ = try DirectMacInstaller.install(Bundle.main.bundleURL, over: destination, revision: arguments[4])
            try DirectMacInstaller.command("/usr/bin/open", [destination.path])
            Darwin.exit(0)
        } catch {
            try? DirectMacInstaller.command("/usr/bin/open", [destination.path, "--args", "--seafile-next-update-failed"])
            Darwin.exit(1)
        }
    }
}

struct MacUpdateView: View {
    @State private var confirmInstall = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Software update").font(.title2)
            if let update = MacUpdateController.shared.update {
                Text("Seafile Next \(update.version)")
                Text(ByteCountFormatter.string(fromByteCount: update.bytes, countStyle: .file)).foregroundStyle(.secondary)
                Link("Release notes", destination: update.releaseURL)
                if let app = MacUpdateController.shared.prepared {
                    Button("Install and restart") { confirmInstall = true }.buttonStyle(.borderedProminent)
                    Button("Show downloaded app") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                } else { Button("Download update") { Task { await MacUpdateController.shared.download() } }.disabled(MacUpdateController.shared.working) }
            }
            if let message = MacUpdateController.shared.message { Text(message).textSelection(.enabled) }
            if MacUpdateController.shared.working { ProgressView() }
            #if APPSTORE
            Button("Open TestFlight") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/TestFlight.app")) }
            #else
            Toggle("Automatically check for updates", isOn: Binding(get: { MacUpdateController.shared.automatic }, set: { MacUpdateController.shared.automatic = $0 }))
            Button("Check for updates") { Task { await MacUpdateController.shared.check() } }.disabled(MacUpdateController.shared.working)
            #endif
            Button("Done") { dismiss() }
        }.padding(24).frame(width: 450)
            .confirmationDialog("Install the update and restart seafile-next?", isPresented: $confirmInstall) {
                Button("Install and restart") { do { try MacUpdateController.shared.install() } catch { MacUpdateController.shared.message = error.localizedDescription } }
            } message: { Text("Syncing pauses during the restart. Local files and pending edits are preserved.") }
    }
}
#endif

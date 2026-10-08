import CryptoKit
import Observation
import SeafileCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor @Observable
final class BrowserSignIn {
    private var generation = UUID()

    func authenticate(endpoint: ServerEndpoint) async throws -> SSOIdentity {
        let generation = UUID()
        self.generation = generation
        let api = SeafileAPI(endpoint: endpoint)
        let challenge: SSOChallenge
        do { challenge = try await api.beginSSO(device: Self.device(), preferSSO: true) }
        catch let error as URLError where [.networkConnectionLost, .timedOut, .secureConnectionFailed].contains(error.code) {
            // If the single-use visit lost its response, create a new nonce
            // on the recovered connection instead of reopening the old link.
            try await Task.sleep(for: .milliseconds(400))
            challenge = try await api.beginSSO(device: Self.device(), preferSSO: true)
        }
        try Task.checkCancellation()
        // Seafile's nonce protocol has no app URL callback. Use the actual
        // default browser, including its IdP sessions, passkeys and app links.
        // On iOS polling resumes when the user returns to this app. Identity
        // always comes from the server's nonce API, never a browser/app URL.
        #if os(iOS)
        let opened = await UIApplication.shared.open(challenge.browserURL)
        #else
        let opened = NSWorkspace.shared.open(challenge.browserURL)
        #endif
        guard opened else { throw SeafileError.local("The sign-in browser could not be opened. Check your default browser and try again.") }
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            do {
                if let identity = try await api.checkSSO(challenge) { return identity }
            } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
                // Keep the pending sign-in while a mobile connection changes.
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw SeafileError.local("Browser sign-in timed out. Start sign-in again.")
    }

    func cancel() {
        generation = UUID()
    }

    static func device() -> SSODevice {
        let defaults = UserDefaults.standard
        let installationID = defaults.string(forKey: "ssoDeviceID") ?? UUID().uuidString
        defaults.set(installationID, forKey: "ssoDeviceID")
        #if os(iOS)
        let id = installationID
        let platform = "ios", name = UIDevice.current.name, systemVersion = UIDevice.current.systemVersion
        #else
        // Seafile requires a 36-character UUID for iOS and a 40-character
        // peer identifier for desktop clients. Hash an installation UUID;
        // never expose a hardware identifier.
        let id = SHA256.hash(data: Data(installationID.utf8)).prefix(20).map { String(format: "%02x", $0) }.joined()
        let platform = "mac", name = DesktopPreferences.load().computerName, systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        return SSODevice(platform: platform, identifier: id, name: name,
                         clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0", systemVersion: systemVersion)
    }
}

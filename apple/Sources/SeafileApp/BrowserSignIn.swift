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
    var legacyRequest: LegacySignInRequest?
    @ObservationIgnored private var legacyContinuation: CheckedContinuation<SSOIdentity, Error>?
    @ObservationIgnored private var legacyPendingID: UUID?

    func authenticate(endpoint: ServerEndpoint, api suppliedAPI: SeafileAPI? = nil) async throws -> SSOIdentity {
        cancel()
        let generation = UUID()
        self.generation = generation
        let api = suppliedAPI ?? SeafileAPI(endpoint: endpoint)
        let info = try await api.serverInfo()
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        if !info.supportsBrowserSSO {
            let request = LegacySignInRequest(id: generation, endpoint: endpoint, url: try LegacySSO.loginURL(endpoint: endpoint, device: Self.device()))
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    legacyContinuation = continuation
                    legacyPendingID = request.id
                    legacyRequest = request
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.completeLegacy(request.id, result: .failure(CancellationError())) }
            }
        }
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
        if let id = legacyPendingID { completeLegacy(id, result: .failure(CancellationError())) }
        generation = UUID()
    }

    func completeLegacy(_ id: UUID, result: Result<SSOIdentity, Error>) {
        guard legacyPendingID == id, generation == id else { return }
        let continuation = legacyContinuation
        legacyContinuation = nil; legacyPendingID = nil; legacyRequest = nil
        continuation?.resume(with: result)
    }

    static func device() -> SSODevice {
        let defaults = UserDefaults.standard
        let savedID = defaults.string(forKey: "ssoDeviceID")
        let installationID = savedID.flatMap { UUID(uuidString: $0) == nil ? nil : $0 } ?? UUID().uuidString
        defaults.set(installationID, forKey: "ssoDeviceID")
        #if os(iOS)
        let platform = "ios", name = UIDevice.current.name
        #else
        let platform = "mac", name = DesktopPreferences.load().computerName
        #endif
        return SSODevice.apple(platform: platform, installationID: installationID, name: name,
                         clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                         operatingSystem: ProcessInfo.processInfo.operatingSystemVersion)
    }
}

struct LegacySignInRequest: Identifiable {
    let id: UUID
    let endpoint: ServerEndpoint
    let url: URL
}

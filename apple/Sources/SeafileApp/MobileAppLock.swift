#if os(iOS)
import SwiftUI
import UIKit
import LocalAuthentication
import Observation
import SeafileCore

@MainActor @Observable final class MobileAppLock {
    static let shared = MobileAppLock()
    private(set) var state: AppLockState
    private(set) var authenticating = false
    var error: String?
    private let defaults: UserDefaults
    private var context: LAContext?
    private var observers: [NSObjectProtocol] = []
    private var windows: [UUID: PrivacyWindow] = [:]
    private let fixture: Bool
    private init() {
        #if DEBUG
        fixture = UITestFixture.fromLaunchArguments() != nil
        #else
        fixture = false
        #endif
        defaults = fixture ? UserDefaults(suiteName: "seafile-ui-security-" + UUID().uuidString)! : .standard
        var enabled = defaults.bool(forKey: "appLockEnabled")
        #if DEBUG
        if fixture && ProcessInfo.processInfo.arguments.contains("--ui-test-app-lock") { enabled = true }
        #endif
        state = AppLockState(enabled: enabled)
        for (name, phase) in [(UIApplication.willResignActiveNotification, AppLockState.Phase.inactive), (UIApplication.didEnterBackgroundNotification, .background), (UIApplication.didBecomeActiveNotification, .active)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changePhase(phase) }
            })
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didActivateNotification, UIScene.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let scene = notification.object as? UIWindowScene else { return }
                    for window in self.windows.values { window.sceneChanged(scene, active: notification.name == UIScene.didActivateNotification) }
                    if notification.name == UIScene.didEnterBackgroundNotification {
                        self.state.lock(); self.context?.invalidate(); self.error = nil
                    }
                    self.refreshWindows()
                }
            })
        }
    }
    func register(_ window: UIWindow) -> UUID {
        let id = UUID(); windows[id] = PrivacyWindow(base: window, model: self)
        refreshWindows(); return id
    }
    func unregister(_ id: UUID) { windows.removeValue(forKey: id)?.remove() }
    private func refreshWindows() { for window in windows.values { window.update(visible: state.needsShield, enabled: state.enabled) } }
    private func changePhase(_ phase: AppLockState.Phase) {
        state.changePhase(phase)
        if phase == .background { context?.invalidate(); error = nil }
        refreshWindows()
    }
    func lock() { state.lock(); context?.invalidate(); refreshWindows() }
    func unlock() async { await authenticate(changingEnabled: nil) }
    func setEnabled(_ enabled: Bool) async { await authenticate(changingEnabled: enabled) }
    private func authenticate(changingEnabled value: Bool?) async {
        guard !authenticating else { return }
        authenticating = true; error = nil
        let generation = state.generation
        defer { authenticating = false; context = nil }
        do {
            let success: Bool
            #if DEBUG
            if fixture { success = true }
            else { success = try await verifyDeviceOwner() }
            #else
            success = try await verifyDeviceOwner()
            #endif
            guard success, state.acceptsAuthentication(generation) else { return }
            if let value {
                state.setEnabled(value); defaults.set(value, forKey: "appLockEnabled")
            } else { state.unlock(authenticatedAt: generation) }
            refreshWindows()
        } catch { self.error = error.localizedDescription }
    }
    private func verifyDeviceOwner() async throws -> Bool {
        let context = LAContext(); self.context = context
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? NSError(domain: "SeafileAppLock", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set up a device passcode to use app lock."])
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock your files and account settings."))
    }
}

@MainActor private final class PrivacyWindow {
    private weak var base: UIWindow?
    private let window: UIWindow?
    private var wasVisible = false
    private var sceneActive: Bool
    init(base: UIWindow, model: MobileAppLock) {
        self.base = base
        sceneActive = base.windowScene?.activationState == .foregroundActive
        if let scene = base.windowScene {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: AppLockScreen(model: model))
            window.backgroundColor = .systemBackground
            window.isHidden = true; self.window = window
        } else { window = nil }
    }
    func sceneChanged(_ scene: UIWindowScene, active: Bool) { if base?.windowScene === scene { sceneActive = active } }
    func update(visible: Bool, enabled: Bool) {
        let visible = visible || (enabled && !sceneActive)
        guard visible != wasVisible else { return }
        wasVisible = visible
        base?.accessibilityElementsHidden = visible
        if visible { base?.endEditing(true); window?.makeKeyAndVisible() }
        else { window?.isHidden = true; base?.makeKey() }
    }
    func remove() { window?.isHidden = true; base?.accessibilityElementsHidden = false }
}

private struct AppLockScreen: View {
    var model: MobileAppLock
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield").font(.system(size: 52)).foregroundStyle(.tint)
            Text("seafile-next").font(.largeTitle.bold())
            if model.state.locked {
                Text("Your files are locked").accessibilityIdentifier("security.locked")
                Button("Unlock") { Task { await model.unlock() } }.buttonStyle(.borderedProminent)
                    .disabled(model.authenticating).accessibilityIdentifier("security.unlock")
                if let error = model.error { Text(error).foregroundStyle(.secondary) }
            }
            if model.authenticating { ProgressView() }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }
}

// A separate scene window covers sheets, Quick Look and the app-switcher
// snapshot as well as the root view. A root SwiftUI overlay cannot cover sheets.
struct AppPrivacyWindow: UIViewRepresentable {
    func makeUIView(context: Context) -> PrivacyAttachment { PrivacyAttachment() }
    func updateUIView(_ uiView: PrivacyAttachment, context: Context) { }
    static func dismantleUIView(_ uiView: PrivacyAttachment, coordinator: ()) { uiView.detach() }
    final class PrivacyAttachment: UIView {
        private var id: UUID?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            if let window { id = MobileAppLock.shared.register(window) }
        }
        func detach() { if let id { MobileAppLock.shared.unregister(id); self.id = nil } }
    }
}
#endif

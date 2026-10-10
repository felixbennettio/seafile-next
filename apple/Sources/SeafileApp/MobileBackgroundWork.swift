#if os(iOS)
import UIKit
import SwiftUI
import SeafileCore

@MainActor private final class MobileBackgroundHost: BackgroundExecutionHost {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> Int? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Seafile file transfers") {
            MainActor.assumeIsolated { expiration() }
        }
        return identifier == .invalid ? nil : identifier.rawValue
    }
    func end(_ identifier: Int) { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier)) }
}

@MainActor final class MobileBackgroundWork {
    private weak var model: AppModel?
    private var monitor: Task<Void, Never>?
    private lazy var lease = BackgroundExecutionLease(host: MobileBackgroundHost()) { [weak self] allowed in
        guard let model = self?.model else { return }
        model.transfers.setExecutionAllowed(allowed)
        model.photoBackup.executionAllowedChanged(allowed)
    }
    init(model: AppModel) { self.model = model }
    private var hasWork: Bool {
        guard let model else { return false }
        return model.photoBackup.running || model.transfers.preparingUploads > 0 || model.transfers.transfers.contains { $0.active }
    }
    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            monitor?.cancel(); monitor = nil
            lease.setForeground(true, hasWork: hasWork)
            model?.photoBackup.executionAllowedChanged(true)
        case .background:
            lease.setForeground(false, hasWork: hasWork)
            monitor?.cancel()
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.lease.executionAllowed else { return }
                    self.lease.workChanged(self.hasWork)
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        default: break // Control Centre or a permission sheet must not cancel work.
        }
    }
}
#endif

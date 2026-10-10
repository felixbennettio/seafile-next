import Foundation

/// A finite OS grant for existing work, never a perpetual background loop.
@MainActor public protocol BackgroundExecutionHost: AnyObject {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> Int?
    func end(_ identifier: Int)
}

@MainActor public final class BackgroundExecutionLease {
    private let host: any BackgroundExecutionHost
    private let changed: @MainActor (Bool) -> Void
    private var identifier: Int?
    private var generation = 0
    private var foreground = true
    private var expired = false
    public private(set) var executionAllowed = true

    public init(host: any BackgroundExecutionHost, changed: @escaping @MainActor (Bool) -> Void) {
        self.host = host; self.changed = changed
    }

    public func setForeground(_ active: Bool, hasWork: Bool) {
        foreground = active
        if active {
            generation += 1; expired = false
            release(); allow(true)
        } else { workChanged(hasWork) }
    }

    public func workChanged(_ hasWork: Bool) {
        guard !foreground else { return }
        guard hasWork, !expired else { release(); allow(false); return }
        guard identifier == nil else { return }
        generation += 1
        let request = generation
        let grant = host.begin { [weak self] in self?.expire(request) }
        // An OS may refuse the request or expire it before returning its ID.
        guard !expired, request == generation, let grant else {
            if let grant { host.end(grant) }
            expired = true; allow(false); return
        }
        identifier = grant; allow(true)
    }

    private func expire(_ request: Int) {
        guard !foreground, request == generation, !expired else { return }
        expired = true; release(); allow(false)
    }
    private func allow(_ value: Bool) {
        guard executionAllowed != value else { return }
        executionAllowed = value; changed(value)
    }
    private func release() {
        guard let identifier else { return }
        self.identifier = nil; host.end(identifier)
    }
}

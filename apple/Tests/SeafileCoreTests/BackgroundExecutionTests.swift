import Foundation
import Testing
@testable import SeafileCore

@MainActor private final class BackgroundHostFixture: BackgroundExecutionHost {
    var requests = 0
    var ended: [Int] = []
    var denied = false
    var expiresImmediately = false
    var expiration: (@MainActor @Sendable () -> Void)?
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> Int? {
        requests += 1; self.expiration = expiration
        if expiresImmediately { expiration() }
        return denied ? nil : requests
    }
    func end(_ identifier: Int) { ended.append(identifier) }
}

@Test @MainActor func backgroundWorkContinuesUntilExpirationWithoutRenewingExpiredTime() {
    let host = BackgroundHostFixture()
    var allowed: [Bool] = []
    let lease = BackgroundExecutionLease(host: host) { allowed.append($0) }
    lease.setForeground(false, hasWork: true)
    lease.workChanged(true)
    #expect(host.requests == 1)
    #expect(lease.executionAllowed)
    host.expiration?(); host.expiration?()
    lease.workChanged(true)
    #expect(host.requests == 1)
    #expect(host.ended == [1])
    #expect(allowed == [false])
    lease.setForeground(true, hasWork: true)
    #expect(allowed == [false, true])
    lease.setForeground(false, hasWork: true)
    #expect(host.requests == 2)
}

@Test @MainActor func completedWorkReleasesItsGrantAndStaleExpirationCannotStopForegroundWork() {
    let host = BackgroundHostFixture(), lease = BackgroundExecutionLease(host: host) { _ in }
    lease.setForeground(false, hasWork: false)
    #expect(host.requests == 0)
    lease.setForeground(true, hasWork: false)
    lease.setForeground(false, hasWork: true)
    let stale = host.expiration
    lease.workChanged(false)
    #expect(host.ended == [1])
    lease.setForeground(true, hasWork: true)
    stale?()
    #expect(lease.executionAllowed)
    #expect(host.ended == [1])
}

@Test @MainActor func deniedAndImmediatelyExpiredGrantsPauseWorkAndReleaseOnlyOnce() {
    for immediate in [false, true] {
        let host = BackgroundHostFixture()
        host.denied = !immediate; host.expiresImmediately = immediate
        let lease = BackgroundExecutionLease(host: host) { _ in }
        lease.setForeground(false, hasWork: true)
        lease.workChanged(true)
        #expect(!lease.executionAllowed)
        #expect(host.requests == 1)
        #expect(host.ended == (immediate ? [1] : []))
    }
}

@Test @MainActor func returningBeforeExpirationKeepsTransfersAllowedAndReleasesBackgroundTime() {
    let host = BackgroundHostFixture(), lease = BackgroundExecutionLease(host: host) { _ in }
    lease.setForeground(false, hasWork: true)
    let expiration = host.expiration
    lease.setForeground(true, hasWork: true)
    expiration?()
    #expect(lease.executionAllowed)
    #expect(host.ended == [1])
}

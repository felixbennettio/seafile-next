import Testing
@testable import SeafileCore

@Test func backgroundAndRelaunchRequireNewAuthentication() {
    var state = AppLockState(enabled: true)
    #expect(state.needsShield)
    let unlocked = state.unlock(authenticatedAt: state.generation)
    #expect(unlocked)
    #expect(!state.needsShield)
    let oldAuthentication = state.generation
    state.changePhase(.background)
    #expect(state.needsShield && state.locked)
    state.changePhase(.active)
    let stale = state.unlock(authenticatedAt: oldAuthentication)
    #expect(!stale)
    #expect(state.needsShield)
    #expect(AppLockState(enabled: true).needsShield)
}

@Test func SystemAuthenticationPromptDoesNotExposeContentWhileInactive() {
    var state = AppLockState(enabled: true)
    let authentication = state.generation
    state.changePhase(.inactive)
    let unlocked = state.unlock(authenticatedAt: authentication)
    #expect(unlocked)
    #expect(state.needsShield)
    state.changePhase(.active)
    #expect(!state.needsShield)
    state.changePhase(.inactive)
    #expect(state.needsShield && !state.locked)
    state.changePhase(.active)
    #expect(!state.needsShield)
}

@Test func ManualLockRejectsAnOlderSuccessfulAuthentication() {
    var state = AppLockState(enabled: true)
    let authentication = state.generation
    state.lock()
    let stale = state.unlock(authenticatedAt: authentication)
    #expect(!stale)
    #expect(state.needsShield)
    let unlocked = state.unlock(authenticatedAt: state.generation)
    #expect(unlocked)
    state.setEnabled(false)
    state.changePhase(.background)
    #expect(!state.needsShield)
}

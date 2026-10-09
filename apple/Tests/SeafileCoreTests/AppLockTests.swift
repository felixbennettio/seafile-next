import Testing
@testable import SeafileCore

@Test func backgroundAndRelaunchRequireNewAuthentication() {
    var state = AppLockState(enabled: true)
    #expect(state.needsShield)
    #expect(state.unlock(authenticatedAt: state.generation))
    #expect(!state.needsShield)
    let oldAuthentication = state.generation
    state.changePhase(.background)
    #expect(state.needsShield && state.locked)
    state.changePhase(.active)
    #expect(!state.unlock(authenticatedAt: oldAuthentication))
    #expect(state.needsShield)
    #expect(AppLockState(enabled: true).needsShield)
}

@Test func SystemAuthenticationPromptDoesNotExposeContentWhileInactive() {
    var state = AppLockState(enabled: true)
    let authentication = state.generation
    state.changePhase(.inactive)
    #expect(state.unlock(authenticatedAt: authentication))
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
    #expect(!state.unlock(authenticatedAt: authentication))
    #expect(state.needsShield)
    #expect(state.unlock(authenticatedAt: state.generation))
    state.setEnabled(false)
    state.changePhase(.background)
    #expect(!state.needsShield)
}

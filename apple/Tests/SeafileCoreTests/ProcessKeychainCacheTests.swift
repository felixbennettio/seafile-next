import Foundation
import Testing
@testable import SeafileCore

@Test func repeatedRequestsAndConcurrentPollsReadEachCredentialOnlyOnce() throws {
    let cache = ProcessKeychainCache()
    let first = Data("test-only-account-a".utf8), second = Data("test-only-account-b".utf8)
    let lock = NSLock()
    nonisolated(unsafe) var reads = 0
    nonisolated(unsafe) var failures = 0
    DispatchQueue.concurrentPerform(iterations: 30) { _ in
        do {
            let value = try cache.read("account-a") { lock.withLock { reads += 1 }; return first }
            if value != first { lock.withLock { failures += 1 } }
        } catch { lock.withLock { failures += 1 } }
    }
    #expect(reads == 1 && failures == 0)
    #expect(try cache.read("account-b") { second } == second)
    #expect(try cache.read("account-a") { nil } == first)
}

@Test func cancellingKeychainAccessDoesNotCauseAnotherAutomaticDialog() {
    let cache = ProcessKeychainCache()
    var dialogs = 0
    for _ in 0..<10 {
        #expect(throws: Error.self) {
            try cache.read("network") { dialogs += 1; throw SeafileError.local("Fixture authorization cancelled") }
        }
    }
    #expect(dialogs == 1)
}

@Test func explicitSignInAndSignOutReplaceCachedCredentialsAndDeniedReads() throws {
    let cache = ProcessKeychainCache()
    #expect(throws: Error.self) { try cache.read("account") { throw SeafileError.local("Fixture denial") } }
    let token = Data("test-only-new-token".utf8)
    var writes = 0
    try cache.write("account", data: token) { writes += 1 }
    #expect(try cache.read("account") { nil } == token)
    #expect(throws: Error.self) {
        try cache.write("account", data: nil) { throw SeafileError.local("Fixture rejected update") }
    }
    #expect(try cache.read("account") { nil } == token)
    try cache.write("account", data: nil) { writes += 1 }
    #expect(try cache.read("account") { token } == nil)
    #expect(writes == 2)
}

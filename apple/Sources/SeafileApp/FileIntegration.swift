import Foundation
#if FILES_PROVIDER
import FileProvider
#endif
import SeafileCore

@MainActor enum FileIntegration {
    static func connect(_ account: ServerAccount) async throws {
        #if FILES_PROVIDER
        let domain = NSFileProviderDomain(identifier: .init(account.id.uuidString), displayName: account.name + " — " + (account.endpoint.url.host ?? "Seafile"))
        // Restoring an existing account must not register its domain again.
        let domains = try await NSFileProviderManager.domains()
        if domains.contains(where: { $0.identifier == domain.identifier }) { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #endif
    }
    static func disconnect(_ account: ServerAccount) async throws {
        #if FILES_PROVIDER
        let domain = NSFileProviderDomain(identifier: .init(account.id.uuidString), displayName: account.name)
        let domains = try await NSFileProviderManager.domains()
        if !domains.contains(where: { $0.identifier == domain.identifier }) { return }
        #if os(macOS)
        // macOS can detach the domain while preserving downloaded user files.
        _ = try await NSFileProviderManager.remove(domain, mode: .preserveDownloadedUserData)
        #else
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #endif
        #endif
    }
}

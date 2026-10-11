import Foundation

/// The direct Mac edition uses the file-based keychain. Its access dialog must
/// not be retriggered by every API client, TLS challenge or sync poll. Serialize
/// first access and remember both success and denial until an explicit write.
/// Values stay in process memory; this cache never writes to disk or logs.
final class ProcessKeychainCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Result<Data?, Error>] = [:]

    func read(_ key: String, load: () throws -> Data?) throws -> Data? {
        try lock.withLock {
            if let value = values[key] { return try value.get() }
            let value = Result { try load() }
            values[key] = value
            return try value.get()
        }
    }

    func write(_ key: String, data: Data?, persist: () throws -> Void) throws {
        try lock.withLock {
            // Keep the prior value if a Keychain update is rejected.
            try persist()
            values[key] = .success(data)
        }
    }

    static var directMac: Bool {
        #if os(macOS)
        return SharedAccounts.accessGroup == nil
        #else
        return false
        #endif
    }
}

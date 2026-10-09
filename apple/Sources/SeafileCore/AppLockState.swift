import Foundation

public struct AppLockState: Sendable {
    public enum Phase: Sendable { case active, inactive, background }
    public private(set) var enabled: Bool
    public private(set) var locked: Bool
    public private(set) var phase: Phase = .active
    public private(set) var generation = 0
    public init(enabled: Bool) { self.enabled = enabled; locked = enabled }
    public var needsShield: Bool { enabled && (locked || phase != .active) }
    public mutating func changePhase(_ phase: Phase) {
        self.phase = phase
        if phase == .background { lock() }
    }
    public mutating func lock() { generation += 1; locked = enabled }
    public func acceptsAuthentication(_ token: Int) -> Bool { token == generation && phase != .background }
    @discardableResult public mutating func unlock(authenticatedAt token: Int) -> Bool {
        guard enabled, acceptsAuthentication(token) else { return false }
        locked = false; return true
    }
    public mutating func setEnabled(_ value: Bool) { enabled = value; locked = false; generation += 1 }
}

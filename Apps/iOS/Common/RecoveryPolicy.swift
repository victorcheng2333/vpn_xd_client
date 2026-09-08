import Foundation
import Darwin

/// Persisted before each cold authentication attempt. Network resume inside an existing session doesn't consume it.
struct RecoveryPolicy: Codable {
    /// Thrown when the five-minute budget is spent. Rate limiting is temporary: the provider waits and
    /// retries by itself; it never becomes a persisted block and never disables system On Demand.
    struct Cooldown: Error {
        let retryAt: Date
    }
    var blockedReason: String?
    var attempts: [Date] = []

    /// CONNECT 401 after successful login invalidates the session, not the saved credentials.
    /// Renew that session within the same persisted cold-attempt budget.
    static func requiresCredentialCheck(result: Int, authenticationFailed: Bool, authenticationCompleted: Bool) -> Bool {
        authenticationFailed || (result == -Int(EPERM) && !authenticationCompleted)
    }

    mutating func begin(now: Date) throws {
        if let reason = blockedReason { throw ConfigurationError.invalid(reason) }
        attempts = attempts.filter { now.timeIntervalSince($0) < 300 }
        guard attempts.count < 3 else {
            // A transient network or session failure must not turn into a credential block.
            throw Cooldown(retryAt: attempts.min()!.addingTimeInterval(300))
        }
        attempts.append(now)
    }
    mutating func connected(now: Date) {
        // Keep the short-term history, so rapid connect/crash loops cannot reset the budget.
        attempts = attempts.filter { now.timeIntervalSince($0) < 300 }
    }
}

struct DiagnosticSnapshot: Codable {
    var qualityStorageIssue: String?
    var phase = "尚未连接"
    var address = "—"
    var transport = "—"
    var updatedAt = Date()
    var events: [String] = []
    var packetsToTunnel: UInt64 = 0
    var packetsFromTunnel: UInt64 = 0
    var droppedPackets: UInt64 = 0
}

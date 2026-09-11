import Foundation

/// Used only on the provider queue. Live observations do not advance the durable
/// checkpoint, and failed writes remain eligible for a later retry.
struct DiagnosticPersistence {
    static let checkpointInterval: TimeInterval = 60
    private var saved: DiagnosticSnapshot?
    private var checkpointUptime: TimeInterval?

    @discardableResult
    mutating func save(_ snapshot: DiagnosticSnapshot, checkpoint: Bool = false,
                       uptime: TimeInterval, write: (DiagnosticSnapshot) throws -> Void) rethrows -> Bool {
        if var previous = saved {
            // Sampling the same state at a later time must not dirty the file.
            previous.updatedAt = snapshot.updatedAt
            guard previous != snapshot else { return false }
        }
        if checkpoint, let checkpointUptime, uptime - checkpointUptime < Self.checkpointInterval { return false }
        try write(snapshot)
        saved = snapshot
        // Events may flush between checkpoints, but must not postpone the next
        // regular observation by another full interval.
        if checkpoint || checkpointUptime == nil { checkpointUptime = uptime }
        return true
    }
}

/// Cache fallback cannot overwrite a live reply, but a slow current reply may
/// improve the fallback. Starting a refresh invalidates all previous callbacks.
struct DiagnosticRequestGate {
    private var serial = 0
    private var deliveredLive = false
    private var deliveredFallback = false

    mutating func begin() -> Int {
        serial += 1
        deliveredLive = false
        deliveredFallback = false
        return serial
    }

    mutating func accept(_ request: Int, fallback: Bool = false) -> Bool {
        guard request == serial, !deliveredLive else { return false }
        if fallback {
            guard !deliveredFallback else { return false }
            deliveredFallback = true
        } else { deliveredLive = true }
        return true
    }
}

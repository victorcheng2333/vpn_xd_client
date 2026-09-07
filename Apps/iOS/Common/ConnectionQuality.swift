import Foundation
import Darwin

/// Persisted monotonic timestamps remain comparable across extension restarts on the same boot.
struct QualityInstant: Codable, Equatable {
    var date: Date
    var continuous: Double
    var boot: Int64?

    static func now() -> Self {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        let seconds = Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1e9
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let ok = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0
        return Self(date: Date(), continuous: seconds, boot: ok ? Int64(bootTime.tv_sec) : nil)
    }

    func elapsed(to end: Self) -> Double? {
        guard let boot, boot == end.boot, end.continuous >= continuous else { return nil }
        return end.continuous - continuous
    }
}

/// Written only by the main app, before explicit connect or disconnect. Never controls the tunnel.
struct QualityIntent: Codable {
    struct Stop: Codable { var id: UUID; var at: QualityInstant }
    var id = UUID()
    var enabled = true
    var changedAt: QualityInstant? = .now()
    var previousStop: Stop?
}

enum QualityReason: String, Codable {
    case network, transport, sessionExpired, providerRestart, wake
    case authentication, certificate, configuration, retryLimit, timeout
    case user, system, replaced
}

struct QualityEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case connectionStarted, connectionSucceeded, connectionFailed, connectionCancelled
        case recoveryStarted, recoverySucceeded, recoveryFailed, recoveryCancelled, disconnected
    }
    var id = UUID()
    var session: UUID
    var date: Date
    var kind: Kind
    var reason: QualityReason?
    var duration: Double?
}

struct ConnectionQuality: Codable, Equatable {
    struct Session: Codable, Equatable {
        enum Phase: String, Codable { case connecting, connected, recovering }
        var id: UUID
        var phase: Phase
        var started: QualityInstant
        var connectedAt: QualityInstant?
        var recoveryAt: QualityInstant?
        var recoveryReason: QualityReason?
    }
    struct Issue: Codable, Equatable {
        var reason: QualityReason
        var date: Date
    }
    var version = 1
    var events: [QualityEvent] = []
    var session: Session?
    var issue: Issue?
    var incomplete = false

    /// A system restart belongs to the existing user connection. Never call it a crash.
    mutating func providerStarted(intent: QualityIntent?, at now: QualityInstant) {
        prune(at: now.date)
        if let previous = intent?.previousStop, session?.id == previous.id {
            stop(reason: .user, at: previous.at)
        }
        if let intent, !intent.enabled, session?.id == intent.id {
            stop(reason: .user, at: intent.changedAt ?? now)
        }
        let id = intent.map { $0.enabled ? $0.id : UUID() } ?? session?.id ?? UUID()
        if session?.id == id {
            if session?.phase == .connected {
                recover(reason: .providerRestart, at: now, startKnown: false)
            }
            return
        }
        stop(reason: .replaced, at: now)
        session = Session(id: id, phase: .connecting, started: now)
        issue = nil
        append(.connectionStarted, at: now)
    }

    mutating func connected(at now: QualityInstant) {
        guard let current = session, current.phase != .connected else { return }
        switch current.phase {
        case .connecting:
            append(.connectionSucceeded, duration: current.started.elapsed(to: now), at: now)
        case .recovering:
            append(.recoverySucceeded, reason: current.recoveryReason,
                   duration: current.recoveryAt?.elapsed(to: now), at: now)
        case .connected: break
        }
        session?.phase = .connected
        session?.connectedAt = now
        session?.recoveryAt = nil
        session?.recoveryReason = nil
        issue = nil
    }

    mutating func recover(reason: QualityReason, at now: QualityInstant, startKnown: Bool = true) {
        guard session != nil else { return }
        if session?.phase == .connected {
            session?.phase = .recovering
            session?.connectedAt = nil
            session?.recoveryAt = startKnown ? now : nil
            session?.recoveryReason = reason
            append(.recoveryStarted, reason: reason, at: now)
        }
        issue = Issue(reason: reason, date: now.date)
    }

    mutating func networkAvailable(_ available: Bool, at now: QualityInstant) {
        if !available { recover(reason: .network, at: now) }
        else if issue?.reason == .network { issue = nil }
    }

    mutating func fail(reason: QualityReason, at now: QualityInstant) {
        guard let current = session else { return }
        if current.phase == .connected { recover(reason: reason, at: now, startKnown: false) }
        if session?.phase == .connecting {
            append(.connectionFailed, reason: reason, duration: current.started.elapsed(to: now), at: now)
        } else {
            append(.recoveryFailed, reason: reason, duration: session?.recoveryAt?.elapsed(to: now), at: now)
        }
        session = nil
        issue = Issue(reason: reason, date: now.date)
    }

    mutating func stop(reason: QualityReason, at now: QualityInstant) {
        guard let current = session else { return }
        switch current.phase {
        case .connecting: append(.connectionCancelled, reason: reason, at: now)
        case .recovering: append(.recoveryCancelled, reason: reason, at: now)
        case .connected: append(.disconnected, reason: reason, at: now)
        }
        session = nil
        issue = nil
    }

    /// The provider can be terminated before stopTunnel is delivered. The app's explicit pause
    /// still cancels pending accounting in the read-only display; it never becomes a failure.
    func display(intent: QualityIntent?, at now: QualityInstant) -> Self {
        var result = self
        if let intent, !intent.enabled, result.session?.id == intent.id {
            result.stop(reason: .user, at: intent.changedAt ?? now)
        }
        result.prune(at: now.date)
        return result
    }

    private mutating func append(_ kind: QualityEvent.Kind, reason: QualityReason? = nil,
                                 duration: Double? = nil, at now: QualityInstant) {
        guard let session else { return }
        events.append(QualityEvent(session: session.id, date: now.date, kind: kind, reason: reason, duration: duration))
        prune(at: now.date)
    }

    mutating func prune(at date: Date) {
        events.removeAll { $0.date < date.addingTimeInterval(-86400) }
        if events.count > 2048 { events = Array(events.suffix(2048)); incomplete = true }
    }

    func count(_ kind: QualityEvent.Kind, at date: Date) -> Int {
        events.filter { $0.kind == kind && $0.date >= date.addingTimeInterval(-86400) && $0.date <= date }.count
    }

    func lastRecovery(at date: Date) -> QualityEvent? {
        events.last { [.recoverySucceeded, .recoveryFailed].contains($0.kind) &&
            $0.date >= date.addingTimeInterval(-86400) && $0.date <= date }
    }
}

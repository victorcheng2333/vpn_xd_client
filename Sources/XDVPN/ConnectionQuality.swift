import Foundation

/// A closed vocabulary, suitable for aggregation without parsing translated log text.
/// Durations use a monotonic clock and include offline/sleep waiting in the episode.
struct QualityEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case attemptStarted, attemptSucceeded, attemptFailed, attemptCancelled
        case recoveryStarted, recoverySucceeded, recoveryFailed, recoveryCancelled
        // Ends metric accounting. Actual process exit/cleanup is still only
        // confirmed by the helper's stopped event, which remains in the log.
        case observationEnded, uncleanExit
    }
    enum Reason: String, Codable {
        case user, appQuit, networkChange, offline, sleep, transport, recoveryTimeout
        case helperUnavailable, preparation, authentication, certificate, networkConfiguration, helperFailure
    }
    let id: UUID
    let timestamp: TimeInterval // Unix seconds; enclosing log also carries UTC text.
    let connection: String
    let kind: Kind
    let reason: Reason?
    let durationMS: Double?

    init(kind: Kind, connection: String, reason: Reason? = nil, durationMS: Double? = nil, date: Date = Date()) {
        id = UUID(); timestamp = date.timeIntervalSince1970; self.connection = connection
        self.kind = kind; self.reason = reason; self.durationMS = durationMS
    }
    var isFailure: Bool { [.attemptFailed, .recoveryFailed, .uncleanExit].contains(kind) }
}

struct ConnectionQuality {
    private var connection = ""
    private var attempt: ContinuousClock.Instant?
    private var recovery: ContinuousClock.Instant?
    private var recoveryReason: QualityEvent.Reason?
    private var established = false

    mutating func begin(connection: String, now: ContinuousClock.Instant = .now) -> [QualityEvent] {
        self.connection = connection; attempt = now; recovery = nil; established = false
        return [event(.attemptStarted)]
    }

    mutating func connected(canRecover: Bool = true, now: ContinuousClock.Instant = .now) -> [QualityEvent] {
        var events: [QualityEvent] = []
        if let attempt {
            events.append(event(.attemptSucceeded, duration: elapsed(attempt, now)))
            self.attempt = nil; established = true
        }
        if let recovery, canRecover {
            events.append(event(.recoverySucceeded, reason: recoveryReason, duration: elapsed(recovery, now)))
            self.recovery = nil
        }
        return events
    }

    mutating func recovering(reason: QualityEvent.Reason, now: ContinuousClock.Instant = .now) -> [QualityEvent] {
        guard established, recovery == nil else { return [] }
        recovery = now; recoveryReason = reason
        return [event(.recoveryStarted, reason: reason)]
    }

    mutating func end(reason: QualityEvent.Reason, cancelled: Bool, now: ContinuousClock.Instant = .now) -> [QualityEvent] {
        var events: [QualityEvent] = []
        if let attempt {
            events.append(event(cancelled ? .attemptCancelled : .attemptFailed, reason: reason, duration: elapsed(attempt, now)))
            self.attempt = nil
        }
        if let recovery {
            events.append(event(cancelled ? .recoveryCancelled : .recoveryFailed, reason: reason, duration: elapsed(recovery, now)))
            self.recovery = nil
        }
        if established {
            events.append(event(.observationEnded, reason: reason)); established = false
        }
        return events
    }

    private func event(_ kind: QualityEvent.Kind, reason: QualityEvent.Reason? = nil, duration: Double? = nil) -> QualityEvent {
        QualityEvent(kind: kind, connection: connection, reason: reason, durationMS: duration)
    }
    private func elapsed(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: end).components
        return max(0, Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }
}

/// All figures describe retained, completed observations, never a fleet SLA.
struct QualitySnapshot {
    struct Alert: Identifiable {
        let id: String
        let title: String
        let detail: String
    }
    let events: [QualityEvent]
    let now: Date
    init(events: [QualityEvent], now: Date = Date()) {
        self.now = now
        let lower = now.addingTimeInterval(-86400).timeIntervalSince1970
        self.events = events.filter { $0.timestamp >= lower && $0.timestamp <= now.timeIntervalSince1970 }
    }
    var successes: Int { count(.attemptSucceeded) }
    var failures: Int { count(.attemptFailed) }
    var cancelled: Int { count(.attemptCancelled) }
    var successRate: Double? {
        let completed = successes + failures
        return completed == 0 ? nil : Double(successes) / Double(completed)
    }
    var connectionP95: Double? {
        let values = events.filter { $0.kind == .attemptSucceeded }.compactMap(\.durationMS).sorted()
        guard !values.isEmpty else { return nil }
        return values[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)] / 1000
    }
    var recoveries: Int { count(.recoveryStarted) }
    var recovered: Int { count(.recoverySucceeded) }
    var recoveryFailures: Int { count(.recoveryFailed) }
    var uncleanExits: Int { count(.uncleanExit) }
    private func count(_ kind: QualityEvent.Kind) -> Int { events.filter { $0.kind == kind }.count }

    var alerts: [Alert] {
        let recent = events.filter { $0.timestamp >= now.addingTimeInterval(-600).timeIntervalSince1970 }
        var alerts: [Alert] = []
        let completed = recent.filter { [.attemptSucceeded, .attemptFailed].contains($0.kind) }
        if completed.count >= 5 {
            let rate = Double(completed.filter { $0.kind == .attemptSucceeded }.count) / Double(completed.count)
            if rate < 0.8 { alerts.append(.init(id: "success-rate", title: "连接成功率偏低", detail: "近 10 分钟至少 5 次完成尝试，成功率低于 80%；用户取消不计入。")) }
        }
        let lastThree = completed.suffix(3)
        if lastThree.count == 3 && lastThree.allSatisfy({ $0.kind == .attemptFailed }) {
            alerts.append(.init(id: "consecutive-failures", title: "连续连接失败", detail: "近 10 分钟最后 3 次完成尝试均失败，请查看连接日志。"))
        }
        var recovering = Set<String>(), interruptions = 0
        // Count an interrupted episode once even if its process then exits.
        // Use the wider history to recognize episodes begun before this window.
        for event in events {
            let inWindow = event.timestamp >= now.addingTimeInterval(-600).timeIntervalSince1970
            switch event.kind {
            case .recoveryStarted:
                recovering.insert(event.connection)
                if inWindow && event.reason == .transport { interruptions += 1 }
            case .recoverySucceeded, .recoveryCancelled:
                recovering.remove(event.connection)
            case .observationEnded:
                if inWindow && !recovering.contains(event.connection) && [.transport, .helperUnavailable].contains(event.reason) {
                    interruptions += 1
                }
                recovering.remove(event.connection)
            default: break
            }
        }
        if interruptions >= 3 {
            alerts.append(.init(id: "unstable-tunnel", title: "隧道频繁中断", detail: "近 10 分钟至少 3 次引擎报告中断或意外结束；主动切网、离线和睡眠恢复不计入。"))
        }
        if uncleanExits > 0 {
            alerts.append(.init(id: "unclean-exit", title: "检测到未正常结束的应用会话", detail: "近 24 小时发现上次会话缺少退出记录。可能是崩溃、强制退出或断电，尚未确认原因。"))
        }
        return alerts
    }
}

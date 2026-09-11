import XCTest
@testable import XDVPN

final class ConnectionQualityTests: XCTestCase {
    func testAttemptAndRecoveryAreCountedOnceAndUseMonotonicDurations() {
        var quality = ConnectionQuality()
        let start = ContinuousClock.now
        XCTAssertEqual(quality.begin(connection: "attempt", now: start).map(\.kind), [.attemptStarted])
        let connected = quality.connected(now: start.advanced(by: .milliseconds(1250)))
        XCTAssertEqual(connected.first?.durationMS, 1250)
        XCTAssertTrue(quality.connected().isEmpty)
        XCTAssertEqual(quality.recovering(reason: .transport, now: start.advanced(by: .seconds(2))).count, 1)
        XCTAssertTrue(quality.recovering(reason: .networkChange).isEmpty)
        let recovered = quality.connected(now: start.advanced(by: .seconds(4)))
        XCTAssertEqual(recovered.map(\.kind), [.recoverySucceeded])
        XCTAssertEqual(recovered.first?.durationMS, 2000)
        XCTAssertEqual(recovered.first?.reason, .transport)
        XCTAssertEqual(quality.end(reason: .user, cancelled: true).map(\.kind), [.observationEnded])
        XCTAssertTrue(quality.end(reason: .transport, cancelled: false).isEmpty)
    }

    func testDuplicateConnectedMessagesWhileOfflineDoNotCompleteOrRestartRecovery() {
        var quality = ConnectionQuality()
        _ = quality.begin(connection: "attempt")
        _ = quality.connected()
        _ = quality.recovering(reason: .offline)
        for _ in 0..<10 {
            XCTAssertTrue(quality.connected(canRecover: false).isEmpty)
            XCTAssertTrue(quality.recovering(reason: .offline).isEmpty)
        }
        XCTAssertEqual(quality.connected().map(\.kind), [.recoverySucceeded])
    }

    func testCancellationDoesNotBecomeFailureAndRecoveryFailureDoesNotAddLoginFailure() {
        var quality = ConnectionQuality()
        _ = quality.begin(connection: "cancelled")
        XCTAssertEqual(quality.end(reason: .offline, cancelled: true).map(\.kind), [.attemptCancelled])
        XCTAssertTrue(quality.end(reason: .transport, cancelled: false).isEmpty)
        _ = quality.begin(connection: "established")
        _ = quality.connected()
        _ = quality.recovering(reason: .networkChange)
        XCTAssertEqual(quality.end(reason: .recoveryTimeout, cancelled: false).map(\.kind), [.recoveryFailed, .observationEnded])
    }

    func testEmptyWindowCancellationAndP95Denominator() {
        let now = Date()
        XCTAssertNil(QualitySnapshot(events: []).successRate)
        XCTAssertTrue(QualitySnapshot(events: []).alerts.isEmpty)
        let events = [
            QualityEvent(kind: .attemptSucceeded, connection: "a", durationMS: 1000, date: now),
            QualityEvent(kind: .attemptSucceeded, connection: "b", durationMS: 3000, date: now),
            QualityEvent(kind: .attemptFailed, connection: "c", date: now),
            QualityEvent(kind: .attemptCancelled, connection: "d", date: now),
            QualityEvent(kind: .attemptStarted, connection: "pending", date: now),
            QualityEvent(kind: .attemptFailed, connection: "old", date: now.addingTimeInterval(-86401)),
            QualityEvent(kind: .attemptFailed, connection: "future", date: now.addingTimeInterval(1))
        ]
        let snapshot = QualitySnapshot(events: events, now: now)
        XCTAssertEqual(snapshot.successRate!, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.connectionP95, 3)
        XCTAssertEqual(snapshot.cancelled, 1)
        XCTAssertTrue(snapshot.alerts.isEmpty)
    }

    func testFailureAlertsRequireSamplesAndExpire() {
        let now = Date()
        var events = (0..<3).map { QualityEvent(kind: .attemptFailed, connection: "\($0)", date: now) }
        XCTAssertEqual(QualitySnapshot(events: events, now: now).alerts.map(\.id), ["consecutive-failures"])
        events += (3..<5).map { QualityEvent(kind: .attemptSucceeded, connection: "\($0)", date: now) }
        XCTAssertEqual(QualitySnapshot(events: events, now: now).alerts.map(\.id), ["success-rate"])
        XCTAssertTrue(QualitySnapshot(events: events, now: now.addingTimeInterval(601)).alerts.isEmpty)
    }

    func testRecoveryFollowedByExitIsOneInterruptionAndPlannedChangesDoNotAlert() {
        let now = Date()
        var events: [QualityEvent] = []
        for index in 0..<2 {
            let connection = "\(index)"
            events += [QualityEvent(kind: .recoveryStarted, connection: connection, reason: .transport, date: now),
                       QualityEvent(kind: .recoveryFailed, connection: connection, reason: .transport, date: now),
                       QualityEvent(kind: .observationEnded, connection: connection, reason: .transport, date: now)]
        }
        for reason in [QualityEvent.Reason.networkChange, .offline, .sleep] {
            events.append(QualityEvent(kind: .recoveryStarted, connection: reason.rawValue, reason: reason, date: now))
        }
        XCTAssertTrue(QualitySnapshot(events: events, now: now).alerts.isEmpty)
        events.append(QualityEvent(kind: .observationEnded, connection: "direct-exit", reason: .helperUnavailable, date: now))
        XCTAssertEqual(QualitySnapshot(events: events, now: now).alerts.map(\.id), ["unstable-tunnel"])
    }

    func testAlertScheduleIsIdleWithoutHistoryAndSkipsExpiredHistory() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertNil(QualitySnapshot.nextAlertRefresh(events: [], now: now))
        let old = QualityEvent(kind: .uncleanExit, connection: "", date: now.addingTimeInterval(-86401))
        XCTAssertNil(QualitySnapshot.nextAlertRefresh(events: [old], now: now))
        let current = QualityEvent(kind: .attemptSucceeded, connection: "a", date: now)
        XCTAssertEqual(QualitySnapshot.nextAlertRefresh(events: [current], now: now), now.addingTimeInterval(601))
    }

    func testAlertScheduleExpiresInclusiveWindowsAndHandlesFutureEvents() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let events = (0..<3).map { QualityEvent(kind: .attemptFailed, connection: "\($0)", date: now.addingTimeInterval(-600)) }
        XCTAssertEqual(QualitySnapshot(events: events, now: now).alerts.map(\.id), ["consecutive-failures"])
        let next = try XCTUnwrap(QualitySnapshot.nextAlertRefresh(events: events, now: now))
        XCTAssertEqual(next, now.addingTimeInterval(1))
        XCTAssertTrue(QualitySnapshot(events: events, now: next).alerts.isEmpty)
        let future = QualityEvent(kind: .uncleanExit, connection: "", date: now.addingTimeInterval(30))
        let entry = try XCTUnwrap(QualitySnapshot.nextAlertRefresh(events: [future], now: now))
        XCTAssertTrue(QualitySnapshot(events: [future], now: now).alerts.isEmpty)
        XCTAssertEqual(entry, now.addingTimeInterval(31))
        XCTAssertEqual(QualitySnapshot(events: [future], now: entry).alerts.map(\.id), ["unclean-exit"])
        XCTAssertEqual(QualitySnapshot.nextAlertRefresh(events: [future], now: now.addingTimeInterval(-30)), entry)
    }

    func testWindowExpiryCanTriggerAnAlertWithoutNewEvents() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        var events = (0..<4).map { QualityEvent(kind: .attemptSucceeded, connection: "old-\($0)", date: now.addingTimeInterval(-599)) }
        events += (0..<4).map { QualityEvent(kind: .attemptSucceeded, connection: "success-\($0)", date: now.addingTimeInterval(-100)) }
        events += (0..<2).map { QualityEvent(kind: .attemptFailed, connection: "failure-\($0)", date: now.addingTimeInterval(-100)) }
        // Removing older successes crosses 80% even with no incoming events.
        XCTAssertTrue(QualitySnapshot(events: events, now: now).alerts.isEmpty)
        let next = try XCTUnwrap(QualitySnapshot.nextAlertRefresh(events: events, now: now))
        XCTAssertEqual(QualitySnapshot(events: events, now: next).alerts.map(\.id), ["success-rate"])
    }

    func testWiderEpisodeHistoryAndUncleanExitScheduleTheir24HourExpiry() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let start = QualityEvent(kind: .recoveryStarted, connection: "old", reason: .transport, date: now.addingTimeInterval(-86399))
        let events = [start] + ["old", "b", "c"].map {
            QualityEvent(kind: .observationEnded, connection: $0, reason: .transport, date: now.addingTimeInterval(-100))
        }
        XCTAssertTrue(QualitySnapshot(events: events, now: now).alerts.isEmpty)
        let next = try XCTUnwrap(QualitySnapshot.nextAlertRefresh(events: events, now: now))
        XCTAssertEqual(next, now.addingTimeInterval(2))
        XCTAssertEqual(QualitySnapshot(events: events, now: next).alerts.map(\.id), ["unstable-tunnel"])
        let unclean = QualityEvent(kind: .uncleanExit, connection: "", date: Date(timeIntervalSince1970: start.timestamp))
        XCTAssertEqual(QualitySnapshot.nextAlertRefresh(events: [unclean], now: now), next)
        XCTAssertTrue(QualitySnapshot(events: [unclean], now: next).alerts.isEmpty)
    }
}

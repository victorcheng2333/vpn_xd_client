import XCTest
import VPNCore
@testable import XDVPN

@MainActor private final class FakeHelper: HelperControlling {
    var onEvent: ((HelperEvent) -> Void)?
    var onClose: (() -> Void)?
    var isReady = false
    var commands: [HelperCommand] = []
    var commandTimes: [(HelperCommand.Kind, ContinuousClock.Instant)] = []
    var shutdownCount = 0
    var delayAuthorization = false
    var authorization: CheckedContinuation<Void, Never>?
    func prepare() async throws {
        if delayAuthorization { await withCheckedContinuation { authorization = $0 } }
        isReady = true
    }
    func send(_ command: HelperCommand) throws {
        commands.append(command); commandTimes.append((command.kind, .now))
    }
    func shutdown() { isReady = false; shutdownCount += 1 }
}

@MainActor final class VPNModelTests: XCTestCase {
    private var helper: FakeHelper!
    private var model: VPNModel!
    private var defaults: UserDefaults!
    private var suite: String!
    private var passwords: [String: String] = [:]
    private var credentials: CredentialAccess!

    override func setUp() async throws {
        suite = "com.xd.vpn.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        helper = FakeHelper()
        credentials = CredentialAccess(
            contains: { [unowned self] in self.passwords[$0] != nil },
            read: { [unowned self] key in
                guard let value = self.passwords[key] else { throw VPNError.unavailable("missing password") }
                return value
            },
            save: { [unowned self] in self.passwords[$1] = $0 },
            delete: { [unowned self] in self.passwords.removeValue(forKey: $0) }
        )
        model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials, startMonitoring: false,
                         recoveryDelay: .milliseconds(20), recoveryTimeout: .milliseconds(200),
                         recoveryCooldown: .milliseconds(150), engineLocator: { "/fake/openconnect" })
        try model.save(VPNProfile(username: "alice"), password: "unit-test-password")
    }

    override func tearDown() async throws {
        model.disconnect()
        helper.authorization?.resume(); helper.authorization = nil
        defaults.removePersistentDomain(forName: suite)
        model = nil; helper = nil; defaults = nil; passwords.removeAll()
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Timed out waiting for asynchronous state", file: file, line: line)
    }

    private func letConnectRun(file: StaticString = #filePath, line: UInt = #line) async {
        // yield() does not guarantee that a lower-priority task runs on CI.
        for _ in 0..<10 { await Task.yield() }
        await waitUntil(file: file, line: line) {
            model.isQuitting || model.state != .authorizing || (helper.delayAuthorization && helper.authorization != nil)
        }
    }

    private func letRecoveryRun() async {
        try? await Task.sleep(for: .milliseconds(50))
        await letConnectRun()
    }

    func testQualityTracksCancelledAttemptAndPreservesConnectionIDUntilCleanup() async {
        model.connect(); await letConnectRun()
        let connection = model.qualityEvents.first?.connection
        model.disconnect()
        helper.onEvent?(.init(.stopped, "stopped", retryable: true))
        XCTAssertEqual(model.qualityEvents.map(\.kind), [.attemptStarted, .attemptCancelled])
        XCTAssertTrue(model.qualityEvents.allSatisfy { $0.connection == connection })
        model.connect(); await letConnectRun()
        XCTAssertNotEqual(model.qualityEvents.last?.connection, connection)
    }

    func testEngineDiagnosticsPersistErrnoAndRouteDetailsWithoutChangingConnectionState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xdvpn-engine-log-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = RollingActivityLog(directory: folder)
        model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials, startMonitoring: false,
                         resumeAutomatically: false, activityLog: log, engineLocator: { "/fake/openconnect" })
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        let state = model.state, commands = helper.commands.count
        let error = EngineDiagnostic(source: .openconnect, code: "transport.addressUnavailable", phase: "reconnect",
                                     processID: 42424, errorNumber: 49, level: .error)
        helper.onEvent?(.init(.info, "Failed to connect: Can't assign requested address", diagnostic: error))
        helper.onEvent?(.init(.info, "XDVPN route change verified source=192.168.124.36 gateway=192.168.124.1",
            diagnostic: .init(source: .route, code: "route.operation", phase: "reconnect", processID: 42424)))
        XCTAssertEqual(model.state, state)
        XCTAssertEqual(helper.commands.count, commands)
        XCTAssertTrue(model.entries.contains { $0.isError && $0.message.contains("assign requested address") })
        log.flush()
        let rows = try Data(contentsOf: folder.appendingPathComponent("activity.jsonl")).split(separator: 10).map {
            try JSONDecoder().decode(RollingActivityLog.Record.self, from: Data($0))
        }
        XCTAssertEqual(rows.first { $0.event == error.code }?.diagnostic, error)
        XCTAssertTrue(rows.contains { $0.diagnostic?.source == .route && $0.message.contains("192.168.124.36") })
        helper.onEvent?(.init(.stopped, "stopped"))
        await withCheckedContinuation { continuation in model.quit { continuation.resume() } }
        log.flush()
    }

    func testQualityOfflineMessagesAreDeduplicatedAndRecoveryIsNotAnotherLogin() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.networkChanged(false)
        for _ in 0..<5 { helper.onEvent?(.init(.connected, "late connected")) }
        XCTAssertEqual(model.qualityEvents.filter { $0.kind == .recoveryStarted }.count, 1)
        XCTAssertEqual(model.qualityEvents.filter { $0.kind == .recoverySucceeded }.count, 0)
        model.networkChanged(true); await letRecoveryRun()
        helper.onEvent?(.init(.reconnecting, "recovering"))
        helper.onEvent?(.init(.connected, "recovered"))
        XCTAssertEqual(model.qualityEvents.filter { $0.kind == .attemptSucceeded }.count, 1)
        XCTAssertEqual(model.qualityEvents.filter { $0.kind == .recoverySucceeded }.count, 1)
        XCTAssertEqual(model.qualityEvents.first { $0.kind == .recoveryStarted }?.reason, .offline)
    }

    func testQualityFailureCategoryAndAlertDeduplicationAndResolution() async {
        for _ in 0..<3 {
            model.connect(); await letConnectRun()
            helper.onEvent?(EngineOutput.event(for: "login failed")!)
            helper.onEvent?(.init(.stopped, "stopped"))
        }
        XCTAssertEqual(model.qualityEvents.filter { $0.kind == .attemptFailed }.count, 3)
        XCTAssertTrue(model.qualityEvents.filter { $0.kind == .attemptFailed }.allSatisfy { $0.reason == .authentication })
        let triggered = model.entries.filter { $0.message.contains("连续连接失败：") }.count
        XCTAssertEqual(triggered, 1)
        model.refreshQualityAlerts(); model.refreshQualityAlerts()
        XCTAssertEqual(model.entries.filter { $0.message.contains("连续连接失败：") }.count, 1)
        model.refreshQualityAlerts(now: Date().addingTimeInterval(601))
        XCTAssertEqual(model.entries.filter { $0.message.contains("本地告警已解除") }.count, 1)
    }

    func testQualityHistoryLoadsAcrossLaunchesAndOnlyMissingQuitProducesExitHint() async throws {
        for clean in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xdvpn-quality-relaunch-" + UUID().uuidString)
            let previous = RollingActivityLog(directory: folder)
            let sample = QualityEvent(kind: .attemptSucceeded, connection: "previous-attempt", durationMS: 2000)
            previous.append("sample", date: Date(), source: .quality, event: "quality.attemptSucceeded", state: "connected",
                            connection: sample.connection, autoConnect: false, isError: false, quality: sample)
            if clean {
                previous.append("quit", date: Date(), source: .lifecycle, event: "app.quitting", state: "connected",
                                connection: sample.connection, autoConnect: false, isError: false)
            }
            previous.flush()
            let next = RollingActivityLog(directory: folder)
            model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials, startMonitoring: false,
                             resumeAutomatically: false, activityLog: next, engineLocator: { "/fake/openconnect" })
            for _ in 0..<100 {
                if model.qualityHistoryLoaded { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(model.qualityHistoryLoaded)
            XCTAssertEqual(model.qualityEvents.first, sample)
            XCTAssertEqual(model.qualityEvents.filter { $0.kind == .uncleanExit }.count, clean ? 0 : 1)
            await withCheckedContinuation { continuation in model.quit { continuation.resume() } }
            next.flush()
            let lines = try Data(contentsOf: folder.appendingPathComponent("activity.jsonl")).split(separator: 10)
            let last = try JSONDecoder().decode(RollingActivityLog.Record.self, from: Data(try XCTUnwrap(lines.last)))
            XCTAssertEqual(last.event, "app.quitting")
            try FileManager.default.removeItem(at: folder)
        }
    }

    func testRepeatedUnchangedLinkEventsAcrossRecoveryWindowsNeverReconnect() async {
        let values: NSDictionary = ["State:/Network/Interface/en0/Link": ["Active": true],
            "State:/Network/Interface/en0/IPv4": ["Addresses": ["192.168.1.8"], "Router": "192.168.1.1"]]
        for auto in [false, true] {
            model.setAutoConnect(auto); model.connect(); await letConnectRun()
            helper.onEvent?(.init(.connected, "connected"))
            let count = helper.commands.count
            let monitor = PhysicalNetworkMonitor(initialSnapshot: values) { [unowned self] in model.physicalNetworkObserved($0) }
            // Advance beyond both the injected debounce and cooldown repeatedly.
            // Debouncing a burst is not sufficient to satisfy this regression.
            for _ in 0..<20 {
                monitor.observe(values, source: .wifiLink)
                monitor.observe(values, source: .configuration)
                monitor.observe(values, source: .wifiPower)
                await letRecoveryRun()
            }
            XCTAssertEqual(helper.commands.count, count)
            XCTAssertEqual(model.state, .connected)
            XCTAssertNil(model.issue)
            monitor.observe(values, source: .wifiSSID)
            await letRecoveryRun()
            XCTAssertEqual(helper.commands.count, count + 1)
            XCTAssertEqual(helper.commands.last?.kind, .reconnect)
            helper.onEvent?(.init(.connected, "restored"))
            model.disconnect(); helper.onEvent?(.init(.stopped, "stopped"))
        }
    }

    func testPhysicalDiagnosticsPersistReasonsWithoutCredentialsAndFlushOnQuit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xdvpn-model-log-" + UUID().uuidString)
        let log = RollingActivityLog(directory: folder)
        defer { log.flush(); try? FileManager.default.removeItem(at: folder) }
        model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials, startMonitoring: false,
            recoveryDelay: .milliseconds(20), recoveryTimeout: .seconds(1), activityLog: log, engineLocator: { "/fake/openconnect" })
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "VPN 隧道已建立。"))
        var values: [String: [String: Any]] = ["State:/Network/Interface/en0/Link": ["Active": true],
            "State:/Network/Interface/en0/IPv4": ["Addresses": ["192.168.1.8"], "Router": "192.168.1.1"]]
        let monitor = PhysicalNetworkMonitor(initialSnapshot: values as NSDictionary) { [unowned self] in model.physicalNetworkObserved($0) }
        monitor.observe(values as NSDictionary, source: .wifiLink)
        values["State:/Network/Interface/en0/IPv4"]?["Router"] = "192.168.1.254"
        monitor.observe(values as NSDictionary, source: .wifiLink)
        monitor.observe(values as NSDictionary, source: .configuration)
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.map(\.kind), [.connect, .reconnect])
        helper.onEvent?(.init(.info, "DTLS 加密通道已就绪。"))
        await withCheckedContinuation { continuation in model.quit { continuation.resume() } }
        let data = try Data(contentsOf: folder.appendingPathComponent("activity.jsonl"))
        let rows = try data.split(separator: 10).map { try JSONDecoder().decode(RollingActivityLog.Record.self, from: Data($0)) }
        XCTAssertTrue(rows.contains { $0.event == "notification.ignored" })
        XCTAssertEqual(rows.filter { $0.event == "reconnect.requested" }.count, 1)
        XCTAssertTrue(rows.contains { $0.event == "reconnect.requested" && $0.message.contains("en0/IPv4/Router") })
        XCTAssertTrue(rows.contains { $0.source == .helper && $0.message.contains("DTLS") })
        XCTAssertEqual(rows.last?.event, "app.quitting")
        let text = String(decoding: data, as: UTF8.self)
        for privateValue in ["unit-test-password", "alice", "vpn.xindong.com", "192.168.1.8", "192.168.1.254"] {
            XCTAssertFalse(text.contains(privateValue), privateValue)
        }
    }

    func testLogWriteFailureDoesNotBreakConnectionOrInMemoryActivity() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("xdvpn-log-file-" + UUID().uuidString)
        try Data("not a directory".utf8).write(to: path)
        let log = RollingActivityLog(directory: path)
        defer { log.flush(); try? FileManager.default.removeItem(at: path) }
        model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials, startMonitoring: false,
                         activityLog: log, engineLocator: { "/fake/openconnect" })
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        log.flush(); await letRecoveryRun()
        XCTAssertEqual(model.state, .connected)
        XCTAssertNil(model.issue)
        XCTAssertNotNil(model.logFileIssue)
        XCTAssertTrue(model.entries.contains { $0.message == "connected" })
    }

    func testOfflinePreservesEstablishedSessionAndDoesNotSendCommandsUntilOnline() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.networkChanged(false)
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        XCTAssertEqual(model.state, .reconnecting)
        XCTAssertFalse(model.canEdit)
        model.networkChanged(false)
        XCTAssertEqual(helper.commands.filter { $0.kind == .disconnect }.count, 0)
        helper.onEvent?(.init(.connected, "late event from old tunnel"))
        XCTAssertEqual(model.state, .reconnecting)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.map(\.kind), [.connect, .reconnect])
    }

    func testUnexpectedExitWhileOfflineWaitsForNetworkAfterHelperCleanup() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.networkChanged(false)
        helper.onEvent?(.init(.stopped, "cleaned", retryable: true))
        XCTAssertEqual(model.state, .waiting)
        model.physicalNetworkChanged(); model.networkChanged(false)
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(helper.commands.map(\.kind), [.connect])
        XCTAssertNil(model.retryAt)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.map(\.kind), [.connect, .connect])
    }

    func testOfflineWithAutoConnectOffPreservesSessionThenCleansIfOnlineRecoveryFails() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.networkChanged(false)
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(helper.commands.map(\.kind), [.connect])
        model.networkChanged(true); model.physicalNetworkChanged(); await letRecoveryRun()
        await waitUntil { model.state == .disconnecting }
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        helper.onEvent?(.init(.stopped, "cleaned"))
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(helper.commands.map(\.kind), [.connect, .reconnect, .disconnect])
        XCTAssertFalse(model.autoConnect)
    }

    func testManualStopWhileOfflineStillRequestsCleanupAndCancelsResume() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.networkChanged(false); model.disconnect()
        helper.onEvent?(.init(.stopped, "cleaned"))
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        XCTAssertTrue(model.autoConnect)
    }

    func testOfflineDuringLoginCleansUpAndResumesManualAttemptWhenOnline() async {
        model.connect(); await letConnectRun()
        model.networkChanged(false)
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        helper.onEvent?(.init(.stopped, "cleaned"))
        XCTAssertEqual(model.state, .waiting)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
        XCTAssertFalse(model.autoConnect)
    }

    func testOfflineDuringAuthorizationCancelsLateLoginUntilOnline() async {
        helper.delayAuthorization = true
        model.connect(); await letConnectRun()
        model.networkChanged(false)
        helper.authorization?.resume(); helper.authorization = nil
        await letConnectRun()
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(model.state, .waiting)
        helper.delayAuthorization = false
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.map(\.kind), [.connect])
    }

    func testOfflineBeforeReadyHelperReceivesConnectDoesNotWaitForNonexistentChild() async {
        helper.isReady = true
        model.connect()
        model.networkChanged(false)
        await letConnectRun()
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(model.state, .waiting)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.map(\.kind), [.connect])
    }

    func testDisablingAutoConnectAfterUnexpectedOfflineExitCancelsPendingResume() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.networkChanged(false)
        helper.onEvent?(.init(.stopped, "cleaned", retryable: true))
        model.setAutoConnect(false)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(helper.commands.map(\.kind), [.connect])
    }

    func testPhysicalReadinessTransitionResumesSessionWithoutGlobalPathEvent() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(online: false)
        XCTAssertFalse(model.networkAvailable)
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        model.physicalNetworkChanged(online: true); await letRecoveryRun()
        XCTAssertTrue(model.networkAvailable)
        XCTAssertEqual(helper.commands.map(\.kind), [.connect, .reconnect])
    }

    private func relaunch(resumeAutomatically: Bool = true) {
        model.quit {}
        helper = FakeHelper()
        model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials, startMonitoring: false,
                         resumeAutomatically: resumeAutomatically, recoveryDelay: .milliseconds(20),
                         engineLocator: { "/fake/openconnect" })
    }

    func testEnablingAutoConnectOnlySavesPreferenceWithoutStartingConnection() async {
        model.setAutoConnect(true)
        await letConnectRun()
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertFalse(helper.isReady)
        model.physicalNetworkChanged(); model.networkChanged(false); model.networkChanged(true)
        model.systemWillSleep(); model.systemDidWake()
        await letRecoveryRun()
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(model.state, .idle)
    }

    func testManualDisconnectStaysStoppedUntilExplicitConnectAndThenRetriesAgain() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.disconnect()
        helper.onEvent?(.init(.stopped, "stopped", retryable: true))
        let count = helper.commands.count
        model.physicalNetworkChanged(); model.networkChanged(false); model.networkChanged(true)
        model.systemWillSleep(); model.systemDidWake()
        await letRecoveryRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.retryAt)
        XCTAssertEqual(helper.commands.count, count)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))

        model.connect(); await letConnectRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
        helper.onEvent?(.init(.stopped, "network failed", retryable: true))
        XCTAssertEqual(model.state, .waiting)
        XCTAssertNotNil(model.retryAt)
        XCTAssertTrue(model.autoConnect)
    }

    func testRelaunchAfterManualDisconnectUsesSavedAutoConnectPreference() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.disconnect()
        helper.onEvent?(.init(.stopped, "stopped"))
        relaunch()
        // Launch schedules a task which then schedules prepare/connect. A fixed
        // number of yields is not evidence that both tasks have run under load.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !helper.commands.contains(where: { $0.kind == .connect }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.autoConnect)
        XCTAssertEqual(model.state, .connecting)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
    }

    func testRelaunchWithAutoConnectOffDoesNotConnect() async {
        model.connect(); await letConnectRun()
        XCTAssertFalse(model.autoConnect)
        XCTAssertFalse(defaults.bool(forKey: "autoConnect"))
        relaunch()
        await letConnectRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(helper.commands.isEmpty)
    }

    func testDisconnectBeforeScheduledStartupConnectionPreventsLateLogin() async {
        model.setAutoConnect(true)
        relaunch()
        model.disconnect()
        await letConnectRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
    }

    func testDisablingPreferenceBeforeScheduledStartupConnectionPreventsLogin() async {
        model.setAutoConnect(true)
        relaunch()
        model.setAutoConnect(false)
        await letConnectRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: "autoConnect"))
    }

    func testStartupResumeOverridePreservesPreferenceWithoutConnecting() async {
        model.setAutoConnect(true)
        relaunch(resumeAutomatically: false)
        await letConnectRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
    }

    func testTogglingPreferenceDuringManualDisconnectDoesNotRestartTunnel() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.disconnect()
        let count = helper.commands.count
        model.setAutoConnect(true)
        model.setAutoConnect(false)
        model.setAutoConnect(true)
        XCTAssertEqual(model.state, .disconnecting)
        helper.onEvent?(.init(.stopped, "stopped", retryable: true))
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.count, count)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
    }

    func testConnectSendsPasswordToHelperAndNeverPreferences() async throws {
        model.connect(); await letConnectRun()
        XCTAssertFalse(model.autoConnect)
        XCTAssertFalse(defaults.bool(forKey: "autoConnect"))
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        XCTAssertEqual(helper.commands.last?.password, "unit-test-password")
        XCTAssertFalse(String(decoding: defaults.data(forKey: "profile")!, as: UTF8.self).contains("unit-test-password"))
        XCTAssertEqual(model.state, .connecting)
        helper.onEvent?(.init(.connected, "connected", address: "10.0.0.1"))
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(model.address, "10.0.0.1")
        XCTAssertNotNil(model.connectedAt)
    }

    func testExplicitDisconnectPreservesAutoConnectAndWaitsForCleanup() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.disconnect()
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        XCTAssertEqual(model.state, .disconnecting)
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        helper.onEvent?(.init(.stopped, "stopped"))
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.retryAt)
    }

    func testDisablingAutoConnectKeepsCurrentTunnel() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        let count = helper.commands.count
        model.setAutoConnect(false)
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(helper.commands.count, count)
    }

    func testRetryableExitSchedulesRecoveryAndManualStopCancelsIt() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.stopped, "network failed", retryable: true))
        XCTAssertEqual(model.state, .waiting)
        XCTAssertNotNil(model.retryAt)
        model.disconnect()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.retryAt)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        let count = helper.commands.count
        try? await Task.sleep(for: .seconds(3.2))
        XCTAssertEqual(helper.commands.count, count)
    }

    func testAuthenticationFailureStopsRetriesWithoutChangingPreferenceOrUnlockingDuringCleanup() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.failure, "bad password"))
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        XCTAssertFalse(model.canEdit)
        XCTAssertEqual(model.state, .disconnecting)
        helper.onEvent?(.init(.stopped, "stopped", retryable: false))
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.issue, "bad password")
        XCTAssertNil(model.retryAt)
        XCTAssertTrue(model.canEdit)
        let count = helper.commands.count
        model.physicalNetworkChanged(); model.networkChanged(false); model.networkChanged(true)
        model.systemDidWake()
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.count, count)
        XCTAssertEqual(model.state, .failed)
    }

    func testWiFiRouteFailureFromExistingHelperRelogsAfterCleanupWithoutBackoff() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        // Version 2 helpers report this as a terminal failure, even on a Wi-Fi
        // switch. The model must recognize the recovery context independently.
        helper.onEvent?(.init(.failure, "网络接口或路由配置失败，请检查 OpenConnect 与 vpnc-script 安装。"))
        XCTAssertEqual(model.state, .disconnecting)
        XCTAssertFalse(model.canEdit)
        XCTAssertNil(model.issue)
        XCTAssertTrue(model.autoConnect)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        helper.onEvent?(.init(.stopped, "old process cleaned up", retryable: false))
        await letConnectRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
        XCTAssertEqual(model.state, .connecting)
        XCTAssertNil(model.retryAt)
        helper.onEvent?(.init(.connected, "restored"))
        XCTAssertEqual(model.state, .connected)
    }

    private func failRouteDuringWiFiRecovery() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        helper.onEvent?(.init(.failure, EngineOutput.networkConfigurationFailureMessage))
    }

    func testRecoveryRouteFailureWaitsOfflineThenRelogsWhenNetworkReturns() async {
        await failRouteDuringWiFiRecovery()
        model.networkChanged(false)
        helper.onEvent?(.init(.stopped, "cleaned up", retryable: false))
        await letConnectRun()
        XCTAssertEqual(model.state, .waiting)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
        XCTAssertEqual(model.state, .connecting)
    }

    func testManualStopDuringRecoveryFailureCleanupCancelsReloginAndKeepsControlsLocked() async {
        await failRouteDuringWiFiRecovery()
        model.disconnect()
        XCTAssertEqual(model.state, .disconnecting)
        XCTAssertFalse(model.canEdit)
        helper.onEvent?(.init(.stopped, "cleaned up", retryable: false))
        model.physicalNetworkChanged(); model.systemDidWake()
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.autoConnect)
    }

    func testDisablingAutoConnectDuringRecoveryFailureCleanupCancelsRelogin() async {
        await failRouteDuringWiFiRecovery()
        model.setAutoConnect(false)
        XCTAssertEqual(model.state, .disconnecting)
        helper.onEvent?(.init(.stopped, "cleaned up", retryable: false))
        model.physicalNetworkChanged(); model.systemDidWake()
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.autoConnect)
    }

    func testRouteFailureDuringFreshLoginStopsInsteadOfRepeatingBrokenConfiguration() async {
        await failRouteDuringWiFiRecovery()
        helper.onEvent?(.init(.stopped, "cleaned up", retryable: false))
        await letConnectRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
        helper.onEvent?(.init(.failure, EngineOutput.networkConfigurationFailureMessage))
        helper.onEvent?(.init(.stopped, "new login failed", retryable: false))
        model.physicalNetworkChanged(); await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.issue, EngineOutput.networkConfigurationFailureMessage)
        XCTAssertNil(model.retryAt)
        XCTAssertTrue(model.autoConnect)
    }

    func testRouteFailureDuringRecoveryWithAutoConnectOffDoesNotRelogin() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        helper.onEvent?(.init(.failure, EngineOutput.networkConfigurationFailureMessage))
        helper.onEvent?(.init(.stopped, "cleaned up", retryable: false))
        await letConnectRun()
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        XCTAssertFalse(model.autoConnect)
    }

    func testAuthenticationAndCertificateFailuresDuringRecoveryRemainTerminal() async {
        for message in ["登录未完成。请检查账号、密码和认证组；如需验证码或 SSO，请使用公司客户端。",
                        "服务器证书验证失败。请联系 IT 检查证书或企业根证书。"] {
            model.setAutoConnect(true); model.connect(); await letConnectRun()
            helper.onEvent?(.init(.connected, "connected"))
            model.physicalNetworkChanged(); await letRecoveryRun()
            helper.onEvent?(.init(.failure, message))
            helper.onEvent?(.init(.stopped, "stopped", retryable: false))
            let count = helper.commands.count
            model.physicalNetworkChanged(); model.systemDidWake(); await letRecoveryRun()
            XCTAssertEqual(model.state, .failed)
            XCTAssertEqual(model.issue, message)
            XCTAssertEqual(helper.commands.count, count)
            XCTAssertNil(model.retryAt)
        }
    }

    func testRouteFailureDuringDeadlineCleanupDoesNotCancelScheduledRelogin() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        await waitUntil { model.state == .disconnecting }
        XCTAssertEqual(model.state, .disconnecting)
        helper.onEvent?(.init(.failure, EngineOutput.networkConfigurationFailureMessage))
        helper.onEvent?(.init(.stopped, "cleaned up", retryable: false))
        await letConnectRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
        XCTAssertEqual(model.state, .connecting)
    }

    func testOfflineManualConnectContinuesWhenNetworkReturns() async {
        model.networkChanged(false)
        model.connect()
        XCTAssertEqual(model.state, .waiting)
        XCTAssertTrue(helper.commands.isEmpty)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        XCTAssertEqual(model.state, .connecting)
    }

    func testWakeRefreshesExistingTunnelEvenWhenAutomaticLoginIsOff() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        XCTAssertFalse(model.autoConnect)
        model.systemWillSleep()
        XCTAssertEqual(model.state, .reconnecting)
        model.systemDidWake(); await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .reconnect)
        helper.onEvent?(.init(.connected, "restored"))
        XCTAssertEqual(model.state, .connected)
        XCTAssertFalse(model.autoConnect)
    }

    func testCancellationWhileAuthorizationIsOpenCannotStartLateTunnel() async {
        helper.delayAuthorization = true
        model.setAutoConnect(true)
        model.connect(); await letConnectRun()
        XCTAssertEqual(model.state, .authorizing)
        model.disconnect()
        helper.authorization?.resume(); helper.authorization = nil
        await letConnectRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
    }

    func testHelperLossRequiresManualAuthorizationInsteadOfPopupLoop() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onClose?()
        XCTAssertEqual(model.state, .failed)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        XCTAssertNil(model.retryAt)
        let count = helper.commands.count
        model.physicalNetworkChanged(); model.networkChanged(false); model.networkChanged(true)
        model.systemDidWake()
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.count, count)
        XCTAssertEqual(model.state, .failed)
    }

    func testQuitImmediatelyRemovesMenuAndPreservesPreferenceWithoutWaitingForAnEvent() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        var didQuit = false
        model.quit { didQuit = true }
        XCTAssertTrue(didQuit)
        XCTAssertTrue(model.isQuitting)
        XCTAssertEqual(helper.shutdownCount, 1)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        helper.onEvent?(.init(.stopped, "cleaned up"))
        XCTAssertTrue(didQuit)
        XCTAssertFalse(helper.isReady)
        let count = helper.commands.count
        model.physicalNetworkChanged(); model.systemDidWake(); model.networkChanged(true); model.connect()
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.count, count)
    }

    func testWiFiSwitchWithContinuousReachabilityRefreshesSessionOncePerBurst() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        for _ in 0..<8 { model.physicalNetworkChanged() }
        XCTAssertTrue(model.networkAvailable)
        XCTAssertEqual(helper.commands.filter { $0.kind == .reconnect }.count, 0)
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .reconnect }.count, 1)
        XCTAssertEqual(model.state, .reconnecting)
    }

    func testWakeWhileOfflineWaitsForNetworkReadiness() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.systemWillSleep(); model.networkChanged(false); model.systemDidWake()
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .reconnect }.count, 0)
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .reconnect)
    }

    func testNetworkChangeDuringSleepDoesNotReconnectUntilWake() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.systemWillSleep(); model.physicalNetworkChanged()
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        model.systemDidWake(); await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .reconnect)
    }

    func testManualDisconnectCancelsPendingWakeRecovery() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.systemWillSleep(); model.systemDidWake(); model.disconnect()
        helper.onEvent?(.init(.stopped, "stopped"))
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .reconnect }.count, 0)
        XCTAssertEqual(model.state, .idle)
    }

    func testRecoveryDeadlineCleansUpBeforeNewLoginAndIgnoresLateConnectedEvent() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        await waitUntil { model.state == .disconnecting }
        XCTAssertEqual(model.state, .disconnecting)
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        helper.onEvent?(.init(.connected, "late old-session response"))
        XCTAssertEqual(model.state, .disconnecting)
        helper.onEvent?(.init(.stopped, "cleaned up", retryable: false))
        await letConnectRun()
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
    }

    func testSuccessfulRecoveryCancelsNewLoginDeadline() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        helper.onEvent?(.init(.connected, "restored"))
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(helper.commands.last?.kind, .reconnect)
    }

    func testAutoConnectOffCleansStaleTunnelAfterRecoveryDeadlineWithoutRelogin() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        await waitUntil { model.state == .disconnecting }
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        helper.onEvent?(.init(.stopped, "cleaned")); await letRecoveryRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        XCTAssertFalse(model.autoConnect)
    }

    func testNetworkRecoveryBypassesExistingRetryBackoff() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.stopped, "network failed", retryable: true))
        XCTAssertNotNil(model.retryAt)
        model.physicalNetworkChanged(); await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
        XCTAssertNil(model.retryAt)
    }

    func testSpontaneousDeadPeerRecoveryHasDeadlineAndWaitsForCleanupBeforeLogin() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer detected"))
        XCTAssertEqual(model.state, .reconnecting)
        let start = ContinuousClock.now
        await waitUntil { model.state == .disconnecting }
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(200))
        XCTAssertEqual(model.state, .disconnecting)
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        helper.onEvent?(.init(.stopped, "cleaned up")); await letConnectRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
    }

    func testRepeatedDeadPeerAndNetworkEventsCannotPostponeRecoveryDeadline() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer detected"))
        try? await Task.sleep(for: .milliseconds(120))
        helper.onEvent?(.init(.reconnecting, "retry still failing"))
        model.physicalNetworkChanged()
        try? await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(model.state, .disconnecting)
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
    }

    func testCooldownSurvivesQuickRecoveryAndRetainsLatestNetworkChange() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        helper.onEvent?(.init(.connected, "quick recovery"))
        // Queue both notifications before yielding, so scheduler load cannot
        // move the second notification outside the cooldown being tested.
        model.physicalNetworkChanged()
        model.physicalNetworkChanged()
        await waitUntil { helper.commandTimes.filter { $0.0 == .reconnect }.count >= 2 }
        let kicks = helper.commandTimes.filter { $0.0 == .reconnect }.map { $0.1 }
        XCTAssertEqual(kicks.count, 2)
        if kicks.count == 2 { XCTAssertGreaterThanOrEqual(kicks[0].duration(to: kicks[1]), .milliseconds(150)) }
    }

    func testManualDisconnectCancelsCooldownRequestAndNaturalRecoveryDeadline() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        model.physicalNetworkChanged()
        model.disconnect()
        helper.onEvent?(.init(.stopped, "stopped"))
        let count = helper.commands.count
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(helper.commands.count, count)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
    }

    func testNaturalRecoveryPausesOfflineAndOnlyCleansAfterOnlineRecoveryDeadline() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        model.networkChanged(false)
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .reconnect)
        await waitUntil { model.state == .disconnecting }
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        helper.onEvent?(.init(.stopped, "cleaned")); await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
    }

    func testNaturalRecoveryDeadlinePausesDuringSleepAndSuccessfulWakeCancelsIt() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        model.systemWillSleep()
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        model.systemDidWake(); await letRecoveryRun()
        helper.onEvent?(.init(.connected, "restored"))
        try? await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(helper.commands.last?.kind, .reconnect)
    }

    func testEnablingAutoConnectDuringNaturalRecoveryAllowsReloginAfterCleanup() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        model.setAutoConnect(true)
        await waitUntil { model.state == .disconnecting }
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        helper.onEvent?(.init(.stopped, "cleaned")); await letRecoveryRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 2)
    }

    func testDisablingAutoConnectKeepsCleanupDeadlineButCancelsRelogin() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        model.setAutoConnect(false)
        await waitUntil { model.state == .disconnecting }
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        helper.onEvent?(.init(.stopped, "cleaned")); await letRecoveryRun()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
    }

    private func exhaustRetryBackoff() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        for expectedDelay in [3, 6, 12, 24, 48, 60] {
            helper.onEvent?(.init(.stopped, "network failed", retryable: true))
            XCTAssertEqual(model.retryAt!.timeIntervalSinceNow, Double(expectedDelay), accuracy: 0.5)
            if expectedDelay < 60 { model.connect(); await letConnectRun() }
        }
    }

    func testWiFiSwitchResetsAccumulatedBackoffToThreeSeconds() async {
        await exhaustRetryBackoff()
        model.physicalNetworkChanged(); await letRecoveryRun()
        helper.onEvent?(.init(.stopped, "still unreachable", retryable: true))
        XCTAssertEqual(model.retryAt!.timeIntervalSinceNow, 3, accuracy: 0.5)
    }

    func testReachabilityRestorationResetsAccumulatedBackoffToThreeSeconds() async {
        await exhaustRetryBackoff()
        model.networkChanged(false); model.networkChanged(true); await letRecoveryRun()
        helper.onEvent?(.init(.stopped, "still unreachable", retryable: true))
        XCTAssertEqual(model.retryAt!.timeIntervalSinceNow, 3, accuracy: 0.5)
    }

    func testWiFiSwitchDuringInitialLoginWaitsForCleanupBeforeRestart() async {
        model.connect(); await letConnectRun()
        model.physicalNetworkChanged(); await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
        helper.onEvent?(.init(.connecting, "late connecting event"))
        XCTAssertEqual(model.state, .disconnecting)
        helper.onEvent?(.init(.stopped, "old handshake stopped")); await letConnectRun()
        XCTAssertEqual(helper.commands.last?.kind, .connect)
    }

    func testWiFiChangeDuringHelperPreparationCancelsStaleLogin() async {
        helper.delayAuthorization = true
        model.connect(); await letConnectRun()
        let previous = helper.authorization
        helper.delayAuthorization = false
        model.physicalNetworkChanged(); await letRecoveryRun()
        previous?.resume(); helper.authorization = nil
        await letConnectRun()
        XCTAssertEqual(helper.commands.filter { $0.kind == .connect }.count, 1)
        XCTAssertEqual(helper.shutdownCount, 1)
    }

    func testQuitCancelsPendingCredentialReadAfterHelperPreparation() async {
        helper.delayAuthorization = true
        model.connect(); await letConnectRun()
        model.quit {}
        helper.authorization?.resume(); helper.authorization = nil
        await letConnectRun()
        XCTAssertTrue(helper.commands.isEmpty)
    }

    func testChangingAccountRequiresNewPasswordAndDeletesPreviousCredential() throws {
        let old = model.profile!
        XCTAssertThrowsError(try model.save(VPNProfile(username: "bob"), password: ""))
        XCTAssertEqual(model.profile, old)
        try model.save(VPNProfile(username: "bob"), password: "new-password")
        XCTAssertNil(passwords[old.credentialAccount])
        XCTAssertEqual(passwords[model.profile!.credentialAccount], "new-password")
        XCTAssertEqual(passwords.count, 1)
    }

    func testSameProfileBlankPasswordPreservesKeychainEntry() throws {
        var edited = model.profile!
        edited.name = "我的公司"
        try model.save(edited, password: "")
        XCTAssertEqual(passwords[model.profile!.credentialAccount], "unit-test-password")
    }

    func testMissingPasswordPreventsConnectionWithoutChangingPreference() async throws {
        model.setAutoConnect(true)
        try model.forgetPassword()
        XCTAssertFalse(model.hasPassword)
        XCTAssertFalse(model.readyToConnect)
        XCTAssertTrue(passwords.isEmpty)
        model.connect()
        XCTAssertEqual(model.page, .profile)
        relaunch()
        await letConnectRun()
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(model.page, .profile)
        XCTAssertEqual(model.state, .idle)
    }

    func testPreferenceCanBeSavedBeforeVPNIsConfigured() async {
        defaults.removeObject(forKey: "profile")
        relaunch()
        model.setAutoConnect(true)
        await letConnectRun()
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(helper.commands.isEmpty)
    }
}

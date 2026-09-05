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

    private func letConnectRun() async {
        // Advance the MainActor's suspended prepare/connect tasks.
        for _ in 0..<10 { await Task.yield() }
    }

    private func letRecoveryRun() async {
        try? await Task.sleep(for: .milliseconds(50))
        await letConnectRun()
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
        await letConnectRun()
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
        try? await Task.sleep(for: .milliseconds(260))
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
        try? await Task.sleep(for: .milliseconds(250))
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

    func testAutoConnectOffDoesNotLoginAgainAfterRecoveryDeadline() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        model.physicalNetworkChanged(); await letRecoveryRun()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(helper.commands.last?.kind, .reconnect)
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
        try? await Task.sleep(for: .milliseconds(260))
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
        model.physicalNetworkChanged(); await letRecoveryRun()
        model.physicalNetworkChanged()
        try? await Task.sleep(for: .milliseconds(150))
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

    func testNaturalRecoveryDeadlinePausesOfflineAndResumesWithFreshBudget() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        model.networkChanged(false)
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        model.networkChanged(true); await letRecoveryRun()
        XCTAssertEqual(helper.commands.last?.kind, .reconnect)
        try? await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
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

    func testEnablingAutoConnectDuringNaturalRecoveryArmsDeadline() async {
        model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        model.setAutoConnect(true)
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(helper.commands.last?.kind, .disconnect)
    }

    func testDisablingAutoConnectCancelsNaturalRecoveryDeadline() async {
        model.setAutoConnect(true); model.connect(); await letConnectRun()
        helper.onEvent?(.init(.connected, "connected"))
        helper.onEvent?(.init(.reconnecting, "dead peer"))
        model.setAutoConnect(false)
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(helper.commands.last?.kind, .connect)
        XCTAssertEqual(model.state, .reconnecting)
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

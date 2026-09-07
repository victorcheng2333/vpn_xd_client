import XCTest
import VPNCore
@testable import XDVPN

@MainActor private final class SetupHelper: HelperControlling {
    var onEvent: ((HelperEvent) -> Void)?
    var onClose: (() -> Void)?
    var isReady = false
    var failure: Error?
    var commands: [HelperCommand] = []
    func prepare() async throws { if let failure { throw failure }; isReady = true }
    func send(_ command: HelperCommand) throws { commands.append(command) }
    func shutdown() { isReady = false }
}

@MainActor final class ServiceSetupFlowTests: XCTestCase {
    private var model: VPNModel!
    private var helper: SetupHelper!
    private var defaults: UserDefaults!
    private var suite: String!
    private var status: PrivilegeStatus = .notInstalled
    private var installations = 0, migrations = 0, removals = 0
    private var statusRequests = 0
    private var pauseInstall = false
    private var installReply: CheckedContinuation<Void, Never>?

    override func setUp() async throws {
        suite = "com.xd.vpn.setup-tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        helper = SetupHelper()
        let access = PrivilegeAccess(status: { [unowned self] in statusRequests += 1; return status }, install: { [unowned self] in
            installations += 1
            if pauseInstall { await withCheckedContinuation { installReply = $0 } }
            status = .requiresApproval
        }, migrate: { [unowned self] in migrations += 1; status = .ready }, uninstall: { [unowned self] in removals += 1; status = .notInstalled })
        model = makeModel(access)
        try model.save(VPNProfile(username: "test-user"), password: "test-password")
    }
    private func makeModel(_ access: PrivilegeAccess) -> VPNModel {
        VPNModel(defaults: defaults, bridge: helper,
                 credentials: CredentialAccess(contains: { _ in true }, read: { _ in "test-password" }, save: { _, _ in }, delete: { _ in }),
                 startMonitoring: false, resumeAutomatically: false, privileges: access, engineLocator: { "/fake/openconnect" })
    }
    override func tearDown() async throws {
        model.quit {}
        defaults.removePersistentDomain(forName: suite)
        model = nil
    }
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), .now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testFirstConnectionEnablesServiceThenWaitsForApprovalWithoutStartingVPN() async {
        await model.refreshPrivileges()
        XCTAssertEqual(model.connectionButtonTitle, "启用系统服务")
        await model.performConnectionAction()
        XCTAssertEqual(installations, 1)
        XCTAssertEqual(model.page, .connection)
        XCTAssertEqual(model.connectionButtonTitle, "打开系统设置")
        XCTAssertTrue(model.needsServiceAttention)
        XCTAssertTrue(helper.commands.isEmpty)
        status = .ready
        await model.refreshPrivileges() // Same refresh triggered when returning from System Settings.
        XCTAssertFalse(model.needsServiceAttention)
        XCTAssertEqual(model.connectionButtonTitle, "连接 VPN")
        XCTAssertTrue(helper.commands.isEmpty, "Approval alone must not create connection intent")
        await model.performConnectionAction()
        await waitUntil { self.model.state == .connecting }
        XCTAssertEqual(helper.commands.map(\.kind), [.connect])
    }

    func testMigrationIsExplicitAndServiceChangesAreBlockedDuringAConnection() async {
        status = .needsMigration
        await model.refreshPrivileges()
        XCTAssertEqual(migrations, 0)
        XCTAssertEqual(model.connectionButtonTitle, "迁移旧版授权")
        await model.performConnectionAction()
        XCTAssertEqual(migrations, 1)
        XCTAssertEqual(installations, 0)
        await model.performConnectionAction()
        await waitUntil { self.model.state == .connecting }
        status = .needsUpdate
        await model.refreshPrivileges()
        await model.installPrivileges()
        await model.removePrivileges()
        XCTAssertEqual(installations + removals, 0)
        XCTAssertEqual(model.connectionButtonTitle, "取消连接")
        XCTAssertTrue(model.connectionButtonEnabled)
    }

    func testBusyRegistrationCannotBeRepeatedOrStartAConnection() async {
        pauseInstall = true
        await model.refreshPrivileges()
        let operation = Task { await model.performConnectionAction() }
        await waitUntil { self.installReply != nil }
        XCTAssertFalse(model.connectionButtonEnabled)
        await model.performConnectionAction()
        model.connect()
        XCTAssertEqual(installations, 1)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(model.state, .idle)
        installReply?.resume(); installReply = nil
        await operation.value
        XCTAssertTrue(model.connectionButtonEnabled)
    }

    func testPreparationFailureReturnsToConnectionAndApprovalClearsOnlyThatFailure() async {
        helper.failure = VPNError.unavailable("service unavailable")
        status = .requiresApproval
        model.page = .quality
        model.connect()
        await waitUntil { self.model.page == .connection && self.model.state == .failed }
        XCTAssertTrue(model.needsServiceAttention)
        status = .ready
        await model.refreshPrivileges()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.issue)
        XCTAssertTrue(helper.commands.isEmpty)
    }

    func testMissingCredentialsAndInvalidBundleNeverRequestRegistration() async throws {
        try model.forgetPassword()
        await model.refreshPrivileges()
        await model.performConnectionAction()
        XCTAssertEqual(model.page, .profile)
        XCTAssertEqual(installations, 0)
        try model.save(VPNProfile(username: "test-user"), password: "test-password")
        for value in [PrivilegeStatus.invalidSignature, .moveToApplications] {
            status = value
            await model.refreshPrivileges()
            let before = statusRequests
            await model.performConnectionAction()
            XCTAssertEqual(model.page, .connection)
            XCTAssertGreaterThan(statusRequests, before)
            XCTAssertEqual(installations, 0)
        }
    }

    func testOlderStatusResponseCannotOverwriteApprovalRefresh() async {
        var replies: [CheckedContinuation<PrivilegeStatus, Never>] = []
        model.quit {}
        model = makeModel(PrivilegeAccess(status: { await withCheckedContinuation { replies.append($0) } }, install: {}, migrate: {}, uninstall: {}))
        let first = Task { await model.refreshPrivileges() }
        await waitUntil { replies.count == 1 }
        let second = Task { await model.refreshPrivileges() }
        await waitUntil { replies.count == 2 }
        replies[1].resume(returning: .ready); await second.value
        replies[0].resume(returning: .requiresApproval); await first.value
        XCTAssertEqual(model.privilegeStatus, .ready)
    }

    func testAdvancedRemovalPreservesProfilePasswordAndAutoConnectPreference() async {
        status = .ready
        await model.refreshPrivileges()
        model.setAutoConnect(true)
        let profile = model.profile
        await model.removePrivileges()
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(model.privilegeStatus, .notInstalled)
        XCTAssertEqual(model.profile, profile)
        XCTAssertTrue(model.hasPassword)
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
        XCTAssertTrue(helper.commands.isEmpty)
    }
}

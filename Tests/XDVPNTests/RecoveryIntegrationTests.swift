import XCTest
import VPNCore
@testable import XDVPN

/// Exercise the model and the real process engine together. The only replaced
/// parts are privileged transport and OpenConnect itself; no VPN is contacted.
@MainActor private final class EngineBackedHelper: HelperControlling {
    var onEvent: ((HelperEvent) -> Void)?
    var onClose: (() -> Void)?
    var isReady = false
    private let executable: String
    private lazy var engine = TunnelEngine(executable: executable) { [weak self] event in
        Task { @MainActor [weak self] in self?.onEvent?(event) }
    }

    init(executable: String) { self.executable = executable }
    func prepare() async throws { isReady = true }
    func send(_ command: HelperCommand) throws {
        switch command.kind {
        case .connect: engine.start(profile: command.profile!, password: command.password!)
        case .disconnect: engine.stop()
        case .reconnect: engine.reconnect()
        case .shutdown: shutdown()
        }
    }
    func shutdown() { engine.stop(); isReady = false }
}

@MainActor final class RecoveryIntegrationTests: XCTestCase {
    func testOfflinePreservesRealChildUntilNetworkReturnsOrManualDisconnect() async throws {
        let folder = "/private/tmp/xdvpn-offline-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let executable = folder + "/fake-openconnect"
        try """
        #!/bin/sh
        IFS= read -r password
        if [ "$password" != "integration-test" ]; then echo 'Login failed'; exit 1; fi
        if [ -f \(folder)/dns ] || [ -f \(folder)/default-route ]; then
            echo 'Script failed: previous network configuration still owned'; exit 1
        fi
        n=0
        if [ -f \(folder)/count ]; then n=$(/bin/cat \(folder)/count); fi
        n=$((n + 1))
        echo "$n" > \(folder)/count
        echo "$n" > \(folder)/dns
        echo "$n" > \(folder)/default-route
        cleanup() {
            echo "$n" > \(folder)/cleaning
            /bin/sleep 0.15
            /bin/rm \(folder)/dns \(folder)/default-route
            echo "$n" >> \(folder)/cleaned
            exit 0
        }
        trap cleanup INT TERM
        trap 'echo "CSTP reconnected"' USR2
        echo "Configured as 10.8.0.$n, with SSL connected and DTLS in progress"
        while :; do /bin/sleep 0.03; done
        """.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        let suite = "com.xd.vpn.integration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = EngineBackedHelper(executable: executable)
        defer { helper.shutdown() }
        let credentials = CredentialAccess(contains: { _ in true }, read: { _ in "integration-test" }, save: { _, _ in }, delete: { _ in })
        let model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials,
                             startMonitoring: false, recoveryDelay: .milliseconds(20), engineLocator: { executable })
        try model.save(VPNProfile(server: "vpn.example.invalid", username: "test"), password: "")
        model.setAutoConnect(true); model.connect()
        let connected = await waitUntil { model.state == .connected }
        XCTAssertTrue(connected)
        guard connected else { return }
        // Both outages preserve the child; the second has Auto Connect off.
        for autoConnect in [true, false] {
            model.setAutoConnect(autoConnect)
            model.physicalNetworkChanged(online: false)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(model.state, .reconnecting)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/cleaning"))
            XCTAssertEqual(try String(contentsOfFile: folder + "/count", encoding: .utf8), "1\n")
            model.physicalNetworkChanged(online: true)
            let restored = await waitUntil { model.state == .connected }
            XCTAssertTrue(restored)
            XCTAssertEqual(model.address, "10.8.0.1")
        }
        model.physicalNetworkChanged(online: false)
        model.disconnect()
        let stopped = await waitUntil { model.state == .idle }
        XCTAssertTrue(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/dns"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/default-route"))
        model.physicalNetworkChanged(online: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try String(contentsOfFile: folder + "/count", encoding: .utf8), "1\n")
        XCTAssertEqual(try String(contentsOfFile: folder + "/cleaned", encoding: .utf8), "1\n")
    }

    func testDeadPeerDeadlineCleansRealChildBeforeReloginAndManualStopStaysStopped() async throws {
        let folder = "/private/tmp/xdvpn-recovery-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let executable = folder + "/fake-openconnect"
        try """
        #!/bin/sh
        IFS= read -r password
        if [ "$password" != "integration-test" ]; then echo 'Login failed'; exit 1; fi
        n=0
        if [ -f \(folder)/count ]; then n=$(/bin/cat \(folder)/count); fi
        n=$((n + 1))
        echo "$n" > \(folder)/count
        trap 'echo "$n" >> \(folder)/cleaned; exit 0' INT TERM
        echo "Configured as 10.8.0.$n, with SSL connected and DTLS in progress"
        if [ "$n" = 1 ]; then
            /bin/sleep 0.1
            echo 'CSTP Dead Peer Detection detected dead peer!'
        fi
        while :; do /bin/sleep 0.03; done
        """.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        let suite = "com.xd.vpn.integration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = EngineBackedHelper(executable: executable)
        defer { helper.shutdown() }
        let credentials = CredentialAccess(contains: { _ in true }, read: { _ in "integration-test" }, save: { _, _ in }, delete: { _ in })
        // Exercise the production recovery budget; a stale 10-second default
        // would miss the six-second deadline below.
        let model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials,
                             startMonitoring: false, engineLocator: { executable })
        try model.save(VPNProfile(server: "vpn.example.invalid", username: "test"), password: "")
        let startedAt = ContinuousClock.now
        model.setAutoConnect(true)
        model.connect()
        let relogged = await waitUntil { model.state == .connected && model.address == "10.8.0.2" }
        XCTAssertTrue(relogged, "Expected a fresh login after the first child's spontaneous recovery timed out")
        guard relogged else { return }
        XCTAssertGreaterThanOrEqual(startedAt.duration(to: .now), .seconds(3), "Give the existing session its recovery window before starting a fresh login")
        XCTAssertEqual(try String(contentsOfFile: folder + "/cleaned", encoding: .utf8), "1\n")
        model.disconnect()
        let stopped = await waitUntil { model.state == .idle }
        XCTAssertTrue(stopped)
        XCTAssertEqual(try String(contentsOfFile: folder + "/cleaned", encoding: .utf8), "1\n2\n")
        model.physicalNetworkChanged(); model.systemDidWake()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try String(contentsOfFile: folder + "/count", encoding: .utf8), "2\n")
        XCTAssertTrue(model.autoConnect)
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
    }

    func testWiFiScriptFailureCleansRealChildAndRelogsWithoutManualConnect() async throws {
        let folder = "/private/tmp/xdvpn-wifi-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let executable = folder + "/fake-openconnect"
        try """
        #!/bin/sh
        IFS= read -r password
        if [ "$password" != "integration-test" ]; then echo 'Login failed'; exit 1; fi
        n=0
        if [ -f \(folder)/count ]; then n=$(/bin/cat \(folder)/count); fi
        n=$((n + 1))
        echo "$n" > \(folder)/count
        if [ "$n" = 2 ] && [ ! -f \(folder)/cleaned ]; then
            echo 'Login failed'; exit 1
        fi
        cleanup() {
            echo "$n" > \(folder)/cleaning
            /bin/sleep 0.15
            echo "$n" >> \(folder)/cleaned
            exit 0
        }
        trap cleanup INT TERM
        trap 'echo "Script /local/vpnc-script failed"' USR2
        echo "Configured as 10.8.0.$n, with SSL connected and DTLS in progress"
        while :; do /bin/sleep 0.03; done
        """.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        let suite = "com.xd.vpn.integration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = EngineBackedHelper(executable: executable)
        defer { helper.shutdown() }
        let credentials = CredentialAccess(contains: { _ in true }, read: { _ in "integration-test" }, save: { _, _ in }, delete: { _ in })
        let model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials,
                             startMonitoring: false, recoveryDelay: .milliseconds(20), engineLocator: { executable })
        try model.save(VPNProfile(server: "vpn.example.invalid", username: "test"), password: "")
        model.setAutoConnect(true); model.connect()
        let connected = await waitUntil { model.state == .connected }
        XCTAssertTrue(connected)
        guard connected else { return }
        let changedAt = ContinuousClock.now
        model.physicalNetworkChanged()
        let cleaning = await waitUntil { FileManager.default.fileExists(atPath: folder + "/cleaning") }
        XCTAssertTrue(cleaning)
        XCTAssertEqual(model.state, .disconnecting)
        XCTAssertEqual(try String(contentsOfFile: folder + "/count", encoding: .utf8), "1\n")
        let relogged = await waitUntil { model.state == .connected && model.address == "10.8.0.2" }
        XCTAssertTrue(relogged)
        XCTAssertLessThan(changedAt.duration(to: .now), .seconds(3), "Do not wait for the recovery deadline or retry backoff after an explicit failure")
        XCTAssertEqual(try String(contentsOfFile: folder + "/cleaned", encoding: .utf8), "1\n")
        XCTAssertNil(model.issue)
        XCTAssertTrue(model.autoConnect)
        model.disconnect()
        let stopped = await waitUntil { model.state == .idle }
        XCTAssertTrue(stopped)
        model.physicalNetworkChanged(); model.systemDidWake()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try String(contentsOfFile: folder + "/count", encoding: .utf8), "2\n")
        XCTAssertEqual(try String(contentsOfFile: folder + "/cleaned", encoding: .utf8), "1\n2\n")
        XCTAssertTrue(defaults.bool(forKey: "autoConnect"))
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

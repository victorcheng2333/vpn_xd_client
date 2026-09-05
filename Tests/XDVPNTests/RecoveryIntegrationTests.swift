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
        let model = VPNModel(defaults: defaults, bridge: helper, credentials: credentials,
                             startMonitoring: false, recoveryTimeout: .milliseconds(150), engineLocator: { executable })
        try model.save(VPNProfile(server: "vpn.example.invalid", username: "test"), password: "")
        model.setAutoConnect(true)
        let relogged = await waitUntil { model.state == .connected && model.address == "10.8.0.2" }
        XCTAssertTrue(relogged, "Expected a fresh login after the first child's spontaneous recovery timed out")
        guard relogged else { return }
        XCTAssertEqual(try String(contentsOfFile: folder + "/cleaned", encoding: .utf8), "1\n")
        model.disconnect()
        let stopped = await waitUntil { model.state == .idle }
        XCTAssertTrue(stopped)
        XCTAssertEqual(try String(contentsOfFile: folder + "/cleaned", encoding: .utf8), "1\n2\n")
        model.physicalNetworkChanged(); model.systemDidWake()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try String(contentsOfFile: folder + "/count", encoding: .utf8), "2\n")
        XCTAssertFalse(model.autoConnect)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

import AppKit
import Foundation

/// Headless smoke test of the state machine:
///   XDVPN_FAKE_PIDFILE=/tmp/x.pid XDVPN --selftest Support/fake-helper.sh
/// Runs connect → disconnect → auto-reconnect after a drop → auth failure
/// (no retry) against the fake helper, prints PASS/FAIL and exits.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest"), args.count > index + 1 else { return }
        let helper = URL(fileURLWithPath: args[index + 1]).standardizedFileURL.path
        setenv("XDVPN_HELPER_OVERRIDE", helper, 1)
        let pidFile = ProcessInfo.processInfo.environment["XDVPN_FAKE_PIDFILE"] ?? "/tmp/xd-vpn-fake.pid"
        NSApplication.shared.setActivationPolicy(.prohibited)

        let vpn = VPNManager.shared
        vpn.testPasswordOverride = "secret"
        vpn.profile = VPNProfile(server: "vpn.example.com:8443", username: "tester")
        vpn.autoConnect = false
        vpn.start()

        var failures = 0
        func check(_ name: String, timeout: TimeInterval, _ condition: () -> Bool) {
            let ok = wait(timeout, until: condition)
            print("\(ok ? "PASS" : "FAIL")  \(name)  [status: \(vpn.status)]")
            if !ok { failures += 1 }
        }

        check("helper detected", timeout: 5) { vpn.helperStatus.isUsable }
        check("initially disconnected", timeout: 1) { vpn.status == .disconnected }

        vpn.connect()
        check("connect → connected with IP", timeout: 10) { vpn.status == .connected && vpn.assignedIP == "10.8.0.23" }
        check("pid file written by fake openconnect", timeout: 2) { FileManager.default.fileExists(atPath: pidFile) }

        vpn.disconnect()
        check("disconnect → disconnected", timeout: 10) { vpn.status == .disconnected && !vpn.hasActiveSession }

        vpn.autoConnect = true
        check("auto-connect on → connects", timeout: 10) { vpn.status == .connected }

        // Simulate the server dropping the tunnel.
        if let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        } else {
            print("FAIL  could not read fake pid file"); failures += 1
        }
        check("drop → waiting to reconnect", timeout: 5) {
            if case .waitingToReconnect = vpn.status { return true }
            return false
        }
        check("reconnected automatically", timeout: 15) { vpn.status == .connected }

        // Manual disconnect pauses auto-connect instead of fighting the user.
        vpn.disconnect()
        check("manual disconnect pauses auto-connect", timeout: 10) { vpn.status == .disconnected && vpn.autoConnectPaused }
        _ = wait(4) { false }
        check("stays disconnected while paused", timeout: 0.1) { vpn.status == .disconnected }

        // Wrong password must not retry even with auto-connect on.
        vpn.testPasswordOverride = "wrong"
        vpn.connect()
        check("auth failure reported", timeout: 10) { vpn.status == .failed(.authentication) }
        _ = wait(4) { false }
        check("no retry after auth failure", timeout: 0.1) { vpn.status == .failed(.authentication) && !vpn.hasActiveSession }

        vpn.testPasswordOverride = "secret"
        vpn.connect()
        check("recovers after fixing password", timeout: 10) { vpn.status == .connected }
        vpn.disconnect()
        check("final disconnect", timeout: 10) { !vpn.hasActiveSession }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print("--- log ---")
        for entry in vpn.log { print(entry.text) }
        exit(failures == 0 ? 0 : 1)
    }

    private static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

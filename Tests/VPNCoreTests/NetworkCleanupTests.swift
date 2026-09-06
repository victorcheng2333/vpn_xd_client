import XCTest
import Darwin
@testable import VPNCore

private final class TestNetworkStore {
    private let lock = NSLock()
    private var values: [String: [String: Any]] = [:]
    var liveInterface = false
    var refuseRemoval = false
    var interfaceProbe: (() -> Bool)?
    func get(_ key: String) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func put(_ key: String, _ value: [String: Any]?) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    var access: NetworkStateAccess {
        .init(read: { self.get($0) }, write: { self.put($0, $1) }, remove: { keys in
            if self.refuseRemoval { return }
            for key in keys { self.put(key, nil) }
        }, interfaceExists: { _ in self.interfaceProbe?() ?? self.liveInterface })
    }
    func installTunnel() {
        put("State:/Network/Service/utun99999/IPv4", ["InterfaceName": "utun99999", "Addresses": ["10.8.0.2"], "OverridePrimary": 1])
        put("State:/Network/Service/utun99999/DNS", ["ServerAddresses": ["172.24.4.79"]])
    }
}

final class NetworkCleanupTests: XCTestCase {
    private let prefix = "State:/Network/Service/utun99999/"
    private func environment(pid: Int32 = 12345) -> [String: String] {
        ["VPNPID": String(pid), "TUNDEV": "utun99999", "INTERNAL_IP4_ADDRESS": "10.8.0.2", "INTERNAL_IP4_DNS": "172.24.4.79"]
    }
    private func session(_ store: TestNetworkStore) throws -> TunnelNetworkSession {
        try .create(prefix: "/private/tmp/xdvpn-network-test-", owner: geteuid(), state: store.access)
    }
    private func removeFixture(_ session: TunnelNetworkSession) { try? FileManager.default.removeItem(atPath: session.directory) }

    func testOrphanedServiceKeysAreRemovedWithoutDNSOrGatewayAndCleanupIsIdempotent() throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        try session.claim(environment: environment())
        store.installTunnel()
        let wifi = "State:/Network/Service/wifi/DNS", other = "State:/Network/Service/utun7/DNS"
        store.put(wifi, ["ServerAddresses": ["192.168.1.1"]]); store.put(other, ["ServerAddresses": ["10.7.0.1"]])
        XCTAssertEqual(try session.cleanup(processID: 12345), 2)
        XCTAssertNil(store.get(prefix + "IPv4")); XCTAssertNil(store.get(prefix + "DNS")); XCTAssertNil(store.get(prefix + "XDVPN"))
        XCTAssertEqual(store.get(wifi)?["ServerAddresses"] as? [String], ["192.168.1.1"])
        XCTAssertNotNil(store.get(other))
        XCTAssertEqual(try session.cleanup(processID: 12345), 0)
        try session.finish()
    }

    func testPartialConnectAndAlreadyCleanedScriptAreHandled() throws {
        for partial in [true, false] {
            let store = TestNetworkStore(), session = try session(store)
            defer { removeFixture(session) }
            try session.claim(environment: environment())
            if partial { store.put(prefix + "DNS", ["ServerAddresses": ["172.24.4.79"]]) }
            XCTAssertEqual(try session.cleanup(processID: 12345), partial ? 1 : 0)
        }
    }

    func testForeignOwnerChangedAddressDNSAndReusedInterfaceAreNeverDeleted() throws {
        for mutation in 0...4 {
            let store = TestNetworkStore(), session = try session(store)
            defer { removeFixture(session) }
            try session.claim(environment: environment()); store.installTunnel()
            switch mutation {
            case 0: store.put(prefix + "XDVPN", ["SessionID": UUID().uuidString])
            case 1: store.put(prefix + "IPv4", ["InterfaceName": "utun99999", "Addresses": ["10.99.0.1"]])
            case 2: store.put(prefix + "DNS", ["ServerAddresses": ["1.1.1.1"]])
            case 3: store.liveInterface = true
            default: break
            }
            XCTAssertThrowsError(try session.cleanup(processID: mutation == 4 ? 333 : 12345, interfaceWait: 0))
            XCTAssertNotNil(store.get(prefix + "IPv4")); XCTAssertNotNil(store.get(prefix + "DNS"))
        }
    }

    func testClaimRejectsPreexistingStateAndUntrustedInterfaceNames() throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        for name in ["en0", "utun1/../../Global", "utun1\nremove", "utun1\n", "utun", "utun100000"] {
            var env = environment(); env["TUNDEV"] = name
            XCTAssertThrowsError(try session.claim(environment: env))
        }
        store.installTunnel()
        XCTAssertThrowsError(try session.claim(environment: environment()))
        XCTAssertNotNil(store.get(prefix + "IPv4"))
        XCTAssertNil(store.get(prefix + "XDVPN"))
    }

    func testFailedRemovalIsNotReportedAsSuccess() throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        try session.claim(environment: environment()); store.installTunnel()
        store.refuseRemoval = true
        XCTAssertThrowsError(try session.cleanup(processID: 12345))
        XCTAssertNotNil(store.get(prefix + "DNS"))
        store.refuseRemoval = false
        XCTAssertEqual(try session.cleanup(processID: 12345), 2)
    }

    func testUnprivilegedScriptModeAndSymlinkJournalAreRejected() throws {
        if geteuid() != 0 { XCTAssertThrowsError(try TunnelNetworkSession.openForScript(environment: [:])) }
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        try FileManager.default.createSymbolicLink(atPath: session.directory + "/tunnel.json", withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try session.cleanup(processID: 12345))
    }

    func testRecoveryHookWatchdogDoesNotReportFatalErrorOrRemoveLiveSession() throws {
        for reason in [ManagedNetworkScript.Reason.attemptReconnect, .reconnect] {
            let store = TestNetworkStore(), session = try session(store)
            defer { removeFixture(session) }
            try session.claim(environment: environment()); store.installTunnel()
            let executable = session.directory + "/blocked-hook"
            try "#!/bin/sh\n/bin/sleep 10\n".write(toFile: executable, atomically: true, encoding: .utf8)
            chmod(executable, 0o700)
            var diagnostics: [String] = []
            let result = ManagedNetworkScript.execute(reason: reason, session: session, environment: environment(), processID: 12345,
                parentExited: { false }, runScript: {
                    try NetworkScriptRunner.run(executable: executable, environment: ["PATH": "/usr/bin:/bin"], timeout: 0.05)
                }, diagnostic: { diagnostics.append($0) })
            XCTAssertEqual(result, 0, "A nonzero exit would make OpenConnect print Script returned error")
            XCTAssertTrue(diagnostics.contains { $0.contains("hook timeout") })
            XCTAssertEqual(diagnostics.compactMap { EngineOutput.event(for: $0, tunnelConfigured: true)?.kind }, [.info])
            XCTAssertNotNil(store.get(prefix + "IPv4")); XCTAssertNotNil(store.get(prefix + "DNS"))
        }
    }

    func testDisconnectReleasesResolverBeforeScriptAndVerifiesAgainAfterTimeout() throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        try session.claim(environment: environment()); store.installTunnel()
        store.liveInterface = true // OpenConnect invokes disconnect BEFORE closing utun.
        var diagnostics: [String] = []
        let code = ManagedNetworkScript.execute(reason: .disconnect, session: session, environment: environment(), processID: 12345,
            parentExited: { false }, runScript: {
                XCTAssertNil(store.get(self.prefix + "IPv4")); XCTAssertNil(store.get(self.prefix + "DNS"))
                XCTAssertNotNil(store.get(self.prefix + "XDVPN"), "Keep proof of ownership until all script writers exit")
                store.installTunnel() // Also prove that the second pass is real.
                throw NetworkScriptRunner.Failure.timedOut
            }, diagnostic: { diagnostics.append($0) })
        XCTAssertEqual(code, 0)
        XCTAssertNil(store.get(prefix + "DNS")); XCTAssertNil(store.get(prefix + "XDVPN"))
        XCTAssertFalse(diagnostics.contains { EngineOutput.event(for: $0)?.kind == .failure })
        XCTAssertTrue(diagnostics.contains { $0.contains("route and service cleanup verified") })
    }

    func testConnectTimeoutRemainsFailureAndCleansPartialConfiguration() throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        let code = ManagedNetworkScript.execute(reason: .connect, session: session, environment: environment(), processID: 12345,
            parentExited: { false }, runScript: { store.installTunnel(); throw NetworkScriptRunner.Failure.timedOut }, diagnostic: { _ in })
        XCTAssertNotEqual(code, 0)
        XCTAssertNil(store.get(prefix + "IPv4")); XCTAssertNil(store.get(prefix + "DNS"))
    }

    func testNativeCleanupFailureIsFatalEvenDuringManualDisconnect() throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        try session.claim(environment: environment()); store.installTunnel(); store.refuseRemoval = true
        var diagnostics: [String] = []
        let code = ManagedNetworkScript.execute(reason: .disconnect, session: session, environment: environment(), processID: 12345,
            parentExited: { false }, runScript: { throw NetworkScriptRunner.Failure.timedOut }, diagnostic: { diagnostics.append($0) })
        XCTAssertNotEqual(code, 0)
        XCTAssertEqual(diagnostics.compactMap { EngineOutput.event(for: $0)?.kind }, [.failure])
        XCTAssertNotNil(store.get(prefix + "DNS"))
        XCTAssertTrue(session.cleanupFailureMessage().contains("utun99999"))
        XCTAssertTrue(session.cleanupFailureMessage().contains(prefix + "DNS"))
    }

    func testGenuineRecoveryScriptErrorIsNotHidden() throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        try session.claim(environment: environment()); store.installTunnel()
        XCTAssertEqual(ManagedNetworkScript.execute(reason: .reconnect, session: session, environment: environment(), processID: 12345,
            parentExited: { false }, runScript: { 2 }, diagnostic: { _ in }), 2)
    }

    func testClaimConflictHasSpecificDiagnosticAndDoesNotRunScript() throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        store.installTunnel()
        var diagnostics: [String] = []
        XCTAssertNotEqual(ManagedNetworkScript.execute(reason: .connect, session: session, environment: environment(), processID: 12345,
            parentExited: { false }, runScript: { XCTFail("Do not overwrite a conflicting service"); return 0 }, diagnostic: { diagnostics.append($0) }), 0)
        XCTAssertTrue(diagnostics.contains("XDVPN claim conflict utun99999"))
        let event = try XCTUnwrap(diagnostics.compactMap { EngineOutput.event(for: $0) }.first)
        XCTAssertEqual(event.kind, .failure)
        XCTAssertTrue(event.message.contains("utun99999")); XCTAssertFalse(event.message.contains("vpnc-script 安装"))
        XCTAssertNil(EngineOutput.event(for: "XDVPN claim conflict utun1\nsecret"))
    }

    func testDelayedInterfaceDetachIsWaitedForAndOwnershipIsRechecked() throws {
        for changeOwner in [false, true] {
            let store = TestNetworkStore(), session = try session(store)
            defer { removeFixture(session) }
            try session.claim(environment: environment()); store.installTunnel()
            var checks = 0
            store.interfaceProbe = {
                checks += 1
                if changeOwner { store.put(self.prefix + "XDVPN", ["SessionID": UUID().uuidString]) }
                return checks == 1
            }
            if changeOwner {
                XCTAssertThrowsError(try session.cleanup(processID: 12345, interfaceWait: 0.3))
                XCTAssertNotNil(store.get(prefix + "DNS"))
            } else {
                XCTAssertEqual(try session.cleanup(processID: 12345, interfaceWait: 0.3), 2)
                XCTAssertGreaterThan(checks, 1)
            }
        }
    }

    func testStartupRecoverySkipsActiveHelperAndScriptLeasesThenRecoversOrphan() throws {
        let store = TestNetworkStore()
        let folder = "/private/tmp/xdvpn-orphan-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let journalPrefix = folder + "/session-"
        var owner: TunnelNetworkSession? = try .create(prefix: journalPrefix, owner: geteuid(), state: store.access)
        let path = owner!.directory
        try owner!.claim(environment: environment()); store.installTunnel()
        var script: TunnelNetworkSession? = try .init(directory: path, token: String(path.suffix(36)), owner: geteuid(), state: store.access)
        XCTAssertNotNil(script)
        try TunnelNetworkSession.recoverOrphans(prefix: journalPrefix, owner: geteuid(), state: store.access, processAlive: { _ in false })
        XCTAssertNotNil(store.get(prefix + "DNS"))
        owner = nil
        try TunnelNetworkSession.recoverOrphans(prefix: journalPrefix, owner: geteuid(), state: store.access, processAlive: { _ in false })
        XCTAssertNotNil(store.get(prefix + "DNS"), "The script still owns a shared lease")
        script = nil
        try TunnelNetworkSession.recoverOrphans(prefix: journalPrefix, owner: geteuid(), state: store.access, processAlive: { _ in false })
        XCTAssertNil(store.get(prefix + "DNS")); XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testStartupRecoveryRefusesLivePIDOrForeignMarkerAndCanRetryRemovalFailure() throws {
        for mode in ["live-pid", "foreign", "removal"] {
            let store = TestNetworkStore()
            let folder = "/private/tmp/xdvpn-orphan-test-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: folder) }
            let journalPrefix = folder + "/session-"
            var owner: TunnelNetworkSession? = try .create(prefix: journalPrefix, owner: geteuid(), state: store.access)
            try owner!.claim(environment: environment()); store.installTunnel(); owner = nil
            if mode == "foreign" { store.put(prefix + "XDVPN", ["SessionID": UUID().uuidString]) }
            store.refuseRemoval = mode == "removal"
            XCTAssertThrowsError(try TunnelNetworkSession.recoverOrphans(prefix: journalPrefix, owner: geteuid(), state: store.access, processAlive: { _ in mode == "live-pid" })) { error in
                XCTAssertTrue(error.localizedDescription.contains(self.prefix + "DNS"))
            }
            XCTAssertNotNil(store.get(prefix + "DNS"))
            if mode == "removal" {
                store.refuseRemoval = false
                try TunnelNetworkSession.recoverOrphans(prefix: journalPrefix, owner: geteuid(), state: store.access, processAlive: { _ in false })
                XCTAssertNil(store.get(prefix + "DNS"))
            }
        }
    }

    func testLegacyJournalWaitsBeforeRecoveryWithoutCreatingPrematureLease() throws {
        let store = TestNetworkStore()
        let folder = "/private/tmp/xdvpn-orphan-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let journalPrefix = folder + "/session-"
        var owner: TunnelNetworkSession? = try .create(prefix: journalPrefix, owner: geteuid(), state: store.access)
        let path = owner!.directory
        try owner!.claim(environment: environment()); store.installTunnel(); owner = nil
        try FileManager.default.removeItem(atPath: path + "/lease")
        XCTAssertThrowsError(try TunnelNetworkSession.recoverOrphans(prefix: journalPrefix, owner: geteuid(), state: store.access, processAlive: { _ in false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/lease"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: path)
        try TunnelNetworkSession.recoverOrphans(prefix: journalPrefix, owner: geteuid(), state: store.access, processAlive: { _ in false })
        XCTAssertNil(store.get(prefix + "DNS"))
    }

    func testLiveDynamicStoreDistinguishesAbsentKeyWithoutChangingNetwork() throws {
        let live = try NetworkStateAccess.live()
        XCTAssertNil(try live.read("State:/XDVPN/ReadOnlyTest/" + UUID().uuidString))
    }

    func testInstalledVpncDisconnectBlocksBeforeRemovingKeysAndNativeFallbackStillWorks() throws {
        let source = "/opt/homebrew/etc/vpnc/vpnc-script"
        guard FileManager.default.fileExists(atPath: source) else { throw XCTSkip("vpnc-script unavailable") }
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        try session.claim(environment: environment()); store.installTunnel()
        let folder = session.directory
        // Run the installed script's actual logic with isolated files and command
        // doubles. No system routes, resolv.conf, configd keys or hooks are touched.
        let body = try String(contentsOfFile: source, encoding: .utf8)
            .replacingOccurrences(of: "/var/run/vpnc", with: folder + "/vpnc")
            .replacingOccurrences(of: "/etc/resolv.conf", with: folder + "/resolv.conf")
            .replacingOccurrences(of: "HOOKS_DIR=/etc/vpnc", with: "HOOKS_DIR=" + folder + "/hooks")
        let executable = folder + "/vpnc-test"
        try """
        #!/bin/sh
        uname() { if [ "$1" = -s ]; then echo Darwin; else echo 26.0; fi; }
        netstat() { :; }
        ifconfig() { :; }
        networksetup() { :; }
        scutil() { /bin/cat >> \(folder)/scutil-called; }
        route() { echo "$*" > \(folder)/route-blocked; /bin/sleep 30; }
        \(body)
        """.write(toFile: executable, atomically: true, encoding: .utf8)
        chmod(executable, 0o700)
        try FileManager.default.createDirectory(atPath: folder + "/vpnc", withIntermediateDirectories: false)
        try "192.168.1.1\n".write(toFile: folder + "/vpnc/defaultroute.12345", atomically: true, encoding: .utf8)
        try "nameserver 192.168.1.1\n".write(toFile: folder + "/vpnc/resolv.conf-backup.12345", atomically: true, encoding: .utf8)
        var env = environment(); env["reason"] = "disconnect"; env["VPNGATEWAY"] = "192.0.2.1"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        XCTAssertThrowsError(try NetworkScriptRunner.run(executable: executable, environment: env, timeout: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/route-blocked"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/scutil-called"), "The original script has not reached its DNS cleanup")
        XCTAssertEqual(try session.cleanup(processID: 12345), 2)
        XCTAssertNil(store.get(prefix + "IPv4")); XCTAssertNil(store.get(prefix + "DNS"))
    }

    func testEnginePreservesSlowCleanupGrandchildAcrossStopEscalation() throws {
        try exerciseEngine(mode: "slow")
    }

    func testEngineRepairsStateAfterUnexpectedChildExit() throws {
        try exerciseEngine(mode: "crash")
    }

    func testEngineVerifiesFallbackAfterKillingOnlyAnUnresponsiveChild() throws {
        try exerciseEngine(mode: "unresponsive")
    }

    func testEngineCleanupFailureEmitsFailureBeforeStoppedAndBlocksNewLogin() throws {
        try exerciseEngine(mode: "cleanup-failure")
    }

    func testManualDisconnectScriptErrorUsesNativeCleanupWithoutRedFailure() throws {
        try exerciseEngine(mode: "stop-error")
    }

    func testConnectedRequiresCompletedScriptAndVerifiedOwnedNetworkState() throws {
        for mode in ["success", "script-error", "unverified"] {
            let store = TestNetworkStore(), session = try session(store)
            defer { removeFixture(session) }
            let path = "/private/tmp/xdvpn-configured-test-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: path) }
            try """
            #!/usr/bin/python3
            import os, sys, time
            sys.stdin.readline()
            print('Configured as 10.8.0.2, with SSL connected', flush=True)
            print('fixture-before-script', flush=True)
            time.sleep(0.05)
            if '\(mode)' == 'script-error':
                print("Script 'fixture' returned error 1", flush=True)
            else:
                print('fixture-install-state pid=' + str(os.getpid()), flush=True)
                print('XDVPN IPv4 service verified pid=' + str(os.getpid()), flush=True)
            time.sleep(0.05)
            """.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o700)
            let stopped = expectation(description: mode)
            var connections = 0, failures = 0, completionSeen = false
            var messages: [String] = []
            let engine = TunnelEngine(executable: path, networkSessionFactory: { session }) { event in
                messages.append(event.message)
                if event.diagnostic != nil {
                    if event.message == "fixture-before-script" { XCTAssertEqual(connections, 0) }
                    if event.message.hasPrefix("fixture-install-state pid="), mode == "success" {
                        do {
                            let pid = Int32(event.message.split(separator: "=").last!)!
                            try session.claim(environment: self.environment(pid: pid))
                            store.installTunnel()
                        } catch { XCTFail(error.localizedDescription) }
                    }
                    if event.message.hasPrefix("XDVPN IPv4 service verified pid=") { completionSeen = true }
                }
                if event.kind == .connected {
                    XCTAssertTrue(completionSeen)
                    XCTAssertEqual(event.address, "10.8.0.2")
                    connections += 1
                }
                if event.kind == .failure { failures += 1 }
                if event.kind == .stopped { stopped.fulfill() }
            }
            engine.start(profile: .init(username: "fixture"), password: "private-password-for-gate-test")
            wait(for: [stopped], timeout: 4)
            XCTAssertEqual(connections, mode == "success" ? 1 : 0, messages.joined(separator: "\n"))
            XCTAssertNil(store.get(prefix + "IPv4"))
            XCTAssertEqual(failures, mode == "success" ? 0 : 1)
        }
    }

    func testEngineCanRetryFailedCleanupBeforeStartingAnotherTunnel() throws {
        let store = TestNetworkStore()
        let folder = "/private/tmp/xdvpn-retry-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/fake-openconnect"
        try """
        #!/usr/bin/python3
        import os, sys, time
        sys.stdin.readline()
        open('\(folder)/pid', 'w').write(str(os.getpid()))
        print('Configured as 10.8.0.2, with SSL connected', flush=True)
        print('XDVPN IPv4 service verified pid=' + str(os.getpid()), flush=True)
        time.sleep(0.15)
        os._exit(9)
        """.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o700)
        let stops = (1...3).map { expectation(description: "stop \($0)") }
        var current: TunnelNetworkSession!, sessions: [TunnelNetworkSession] = []
        defer { sessions.forEach(removeFixture) }
        var started = 0, stopped = 0
        let engine = TunnelEngine(executable: path, networkSessionFactory: {
            XCTAssertNil(store.get(self.prefix + "DNS"), "Never start a new tunnel over a failed cleanup")
            current = try self.session(store); sessions.append(current)
            return current
        }) { event in
            if event.diagnostic != nil && event.message.hasPrefix("Configured as ") {
                started += 1
                do {
                    let pid = Int32(try String(contentsOfFile: folder + "/pid", encoding: .utf8))!
                    try current.claim(environment: self.environment(pid: pid)); store.installTunnel()
                    if started == 1 { store.refuseRemoval = true }
                } catch { XCTFail(error.localizedDescription) }
            }
            if event.kind == .failure {
                XCTAssertTrue(event.message.contains(self.prefix + "DNS"))
            }
            if event.kind == .stopped { stops[stopped].fulfill(); stopped += 1 }
        }
        let profile = VPNProfile(server: "vpn.example.invalid", username: "test")
        engine.start(profile: profile, password: "fixture")
        wait(for: [stops[0]], timeout: 4)
        engine.start(profile: profile, password: "fixture")
        wait(for: [stops[1]], timeout: 4)
        XCTAssertEqual(started, 1)
        store.refuseRemoval = false
        engine.start(profile: profile, password: "fixture")
        wait(for: [stops[2]], timeout: 4)
        XCTAssertEqual(started, 2); XCTAssertNil(store.get(prefix + "DNS"))
    }

    private func exerciseEngine(mode: String) throws {
        let store = TestNetworkStore(), session = try session(store)
        defer { removeFixture(session) }
        let folder = "/private/tmp/xdvpn-cleanup-process-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/fake-openconnect"
        // Real parent + descendant in the same group, matching OpenConnect's
        // forked script. Cleanup exceeds the injected TERM escalation deadline.
        try """
        #!/usr/bin/python3
        import os, signal, subprocess, sys, time
        sys.stdin.readline()
        open('\(folder)/pid', 'w').write(str(os.getpid()))
        def stop(*_):
            if '\(mode)' == 'unresponsive': return
            if '\(mode)' == 'stop-error': print("Script 'fixture' returned error 1", flush=True)
            child = subprocess.Popen(['/bin/sh', '-c', 'trap "echo killed > \(folder)/grandchild-killed; exit 1" TERM INT; /bin/sleep 0.35; echo done > \(folder)/script-cleaned'])
            child.wait()
            sys.exit(0)
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, lambda *_: None)
        print('Configured as 10.8.0.2, with SSL connected and DTLS in progress', flush=True)
        print('XDVPN IPv4 service verified pid=' + str(os.getpid()), flush=True)
        if '\(mode)' == 'crash':
            time.sleep(0.1)
            os._exit(9)
        while True: time.sleep(0.01)
        """.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o700)
        let connected = expectation(description: "connected"), stopped = expectation(description: "stopped after verification")
        let rejected = mode == "cleanup-failure" ? expectation(description: "next login rejected") : nil
        var failures = 0, stopCount = 0
        let engine = TunnelEngine(executable: path, networkSessionFactory: { session }, stopGrace: 0.08,
                                  killGrace: mode == "unresponsive" ? 0.18 : 2) { event in
            if event.diagnostic != nil && event.message.hasPrefix("Configured as ") {
                do {
                    let pid = Int32(try String(contentsOfFile: folder + "/pid", encoding: .utf8))!
                    try session.claim(environment: self.environment(pid: pid))
                    store.installTunnel()
                    if mode == "cleanup-failure" { store.refuseRemoval = true }
                } catch { XCTFail(error.localizedDescription) }
            }
            if event.kind == .connected { connected.fulfill() }
            if event.kind == .failure { failures += 1 }
            if event.kind == .stopped {
                if mode == "cleanup-failure" {
                    XCTAssertGreaterThan(failures, 0); XCTAssertFalse(event.retryable)
                    XCTAssertNotNil(store.get(self.prefix + "DNS"))
                } else {
                    XCTAssertEqual(failures, 0)
                    XCTAssertNil(store.get(self.prefix + "DNS")); XCTAssertNil(store.get(self.prefix + "IPv4"))
                }
                stopCount += 1
                if stopCount == 1 { stopped.fulfill() } else { rejected?.fulfill() }
            }
        }
        engine.start(profile: VPNProfile(server: "vpn.example.invalid", username: "test"), password: "test-password")
        wait(for: [connected], timeout: 4)
        if mode != "crash" { engine.stop() }
        wait(for: [stopped], timeout: 4)
        if let rejected {
            engine.start(profile: VPNProfile(username: "test"), password: "test-password")
            wait(for: [rejected], timeout: 2)
        }
        if mode == "slow" {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/script-cleaned"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/grandchild-killed"))
        }
    }
}

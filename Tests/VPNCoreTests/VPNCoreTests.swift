import XCTest
@testable import VPNCore
import Darwin

final class VPNCoreTests: XCTestCase {
    func testServerNormalizationAndGroups() throws {
        let p = try VPNProfile(server: " vpn.example.com:8443/staff ", username: " alice ", authGroup: "Employees").validated()
        XCTAssertEqual(p.server, "https://vpn.example.com:8443/staff")
        XCTAssertEqual(p.username, "alice")
        XCTAssertEqual(try VPNProfile(server: "https://[::1]:8443", username: "a").validated().server, "https://[::1]:8443")
    }

    func testRejectsAmbiguousOrUnsafeServers() {
        for server in ["", "http://vpn.example.com", "https://a:b@example.com", "https://example.com?x=1", "https://example.com#x", "--script=/tmp/oops", "vpn.example.com\n--script=x", "vpn.example.com:70000", "vpn.example.com:0", "a b"] {
            XCTAssertThrowsError(try VPNProfile(server: server, username: "alice").validated(), server)
        }
        XCTAssertThrowsError(try VPNProfile(username: "").validated())
    }

    func testArgumentsPreserveLiteralInputWithoutShellOrPassword() throws {
        let user = "alice'; $(touch /tmp/never-execute); --script=oops"
        let args = try OpenConnect.arguments(profile: VPNProfile(username: user, authGroup: "staff group"))
        XCTAssertTrue(args.contains("--user=" + user))
        XCTAssertTrue(args.contains("--authgroup=staff group"))
        XCTAssertTrue(args.contains("--passwd-on-stdin"))
        XCTAssertTrue(args.contains("--non-inter"))
        XCTAssertTrue(args.contains("--csd-wrapper=/usr/bin/false"))
        XCTAssertTrue(args.contains("--cafile=/etc/ssl/cert.pem"))
        XCTAssertTrue(args.contains("--no-system-trust"))
        XCTAssertFalse(args.contains { $0.hasPrefix("--password=") || $0 == "--background" || $0 == "--no-cert-check" })
    }

    func testPasswordMustBeASingleBoundedStdinLine() {
        for bad in ["", "abc\nsecond", "abc\r", "a\0b", String(repeating: "a", count: 4096)] {
            XCTAssertThrowsError(try OpenConnect.validatePassword(bad))
        }
        XCTAssertNoThrow(try OpenConnect.validatePassword("p'a$$word with spaces 中文"))
    }

    func testProfileSerializationNeverContainsPassword() throws {
        let data = try JSONEncoder().encode(VPNProfile(username: "alice"))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["name", "server", "username", "authGroup"])
    }

    func testOutputOnlyReportsEstablishedTunnelAfterConfiguration() {
        XCTAssertNil(EngineOutput.event(for: "SSL negotiation with vpn.example.com"))
        XCTAssertNil(EngineOutput.event(for: "Connected to HTTPS on vpn.example.com"))
        let event = EngineOutput.event(for: "Configured as 10.0.1.2, with SSL connected and DTLS in progress")
        XCTAssertEqual(event?.kind, .connected)
        XCTAssertEqual(event?.address, "10.0.1.2")
        XCTAssertNil(EngineOutput.event(for: "Configured as 10.0.1.2, with SSL disconnected and DTLS disconnected"))
        XCTAssertEqual(EngineOutput.event(for: "CSTP reconnected")?.kind, .connected)
        XCTAssertNil(EngineOutput.event(for: "CSTP connected. DPD 20, Keepalive 30"))
        XCTAssertEqual(EngineOutput.event(for: "CSTP connected. DPD 20, Keepalive 30", tunnelConfigured: true)?.kind, .connected)
        XCTAssertEqual(EngineOutput.event(for: "CSTP Dead Peer Detection detected dead peer!")?.kind, .reconnecting)
    }

    func testCredentialsAndCertificateErrorsStopRetriesAndRawLogsStayPrivate() {
        for line in ["Login failed.", "Server certificate verify failed: issuer is unknown", "Failed to obtain WebVPN cookie", "User input required in non-interactive mode", "Script '/vpnc' failed"] {
            let event = EngineOutput.event(for: line)
            XCTAssertEqual(event?.kind, .failure, line)
            XCTAssertEqual(event?.retryable, false, line)
        }
        for secret in ["COOKIE='secret'", "Password: very-secret", "Set-Cookie: session=secret", "Server form contains confidential data"] {
            XCTAssertNil(EngineOutput.event(for: secret))
        }
    }

    func testRetryBackoffIsBoundedAndResettable() {
        var policy = RetryPolicy()
        XCTAssertEqual((0..<8).map { _ in policy.nextDelay() }, [3, 6, 12, 24, 48, 60, 60, 60])
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 3)
    }

    func testPrivateSocketRoundTripAndPeerUID() throws {
        let dir = "/private/tmp/xdvpn-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let listener = try LocalSocket.listener(path: dir + "/s")
        defer { listener.close() }
        let received = expectation(description: "command received")
        DispatchQueue.global().async {
            do {
                let peer = try listener.accept(expectedUID: getuid(), timeout: 2000)
                defer { peer.close() }
                let command = try peer.receive(HelperCommand.self)
                XCTAssertEqual(command?.password, "p'a$$word\"中")
                XCTAssertEqual(command?.kind, .connect)
                try peer.send(HelperEvent(.ready, "ok"))
            } catch { XCTFail(error.localizedDescription) }
            received.fulfill()
        }
        let client = try LocalSocket.connect(path: dir + "/s", expectedUID: getuid())
        defer { client.close() }
        try client.send(HelperCommand(.connect, profile: VPNProfile(username: "alice"), password: "p'a$$word\"中"))
        XCTAssertEqual(try client.receive(HelperEvent.self)?.kind, .ready)
        wait(for: [received], timeout: 3)
    }

    func testSocketRejectsWrongPeerIdentity() throws {
        let dir = "/private/tmp/xdvpn-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let listener = try LocalSocket.listener(path: dir + "/s")
        defer { listener.close() }
        XCTAssertThrowsError(try LocalSocket.connect(path: dir + "/s", expectedUID: getuid() + 1))
    }

    func testFrameLimitRejectsOversizedMessages() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let first = LocalSocket(descriptor: fds[0]), second = LocalSocket(descriptor: fds[1])
        defer { first.close(); second.close() }
        XCTAssertThrowsError(try first.send(HelperCommand(.connect, password: String(repeating: "x", count: LocalSocket.maxFrame))))
    }

    func testEngineFeedsStdinAndGracefullyStopsOnlyItsChild() throws {
        let dir = "/private/tmp/xdvpn-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/fake-openconnect"
        let body = """
        #!/bin/sh
        IFS= read -r password
        if [ "$password" != "test-password" ]; then echo 'Login failed'; exit 1; fi
        trap 'printf cleaned > \(dir)/cleaned; exit 0' INT TERM
        echo 'Configured as 10.0.0.8, with SSL connected and DTLS in progress'
        while :; do /bin/sleep 0.1; done
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o700)
        let connected = expectation(description: "connected"), stopped = expectation(description: "stopped")
        let engine = TunnelEngine(executable: script) { event in
            if event.kind == .connected { connected.fulfill() }
            if event.kind == .stopped { XCTAssertFalse(event.retryable); stopped.fulfill() }
        }
        engine.start(profile: VPNProfile(username: "alice"), password: "test-password")
        wait(for: [connected], timeout: 4)
        engine.stop()
        wait(for: [stopped], timeout: 4)
        XCTAssertEqual(try String(contentsOfFile: dir + "/cleaned", encoding: .utf8), "cleaned")
    }

    func testEngineAuthenticationFailureIsNotRetried() throws {
        let path = "/private/tmp/xdvpn-test-" + UUID().uuidString
        try "#!/bin/sh\nread -r password\necho 'Login failed'\nexit 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o700)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let stopped = expectation(description: "stopped")
        var failureSeen = false
        let engine = TunnelEngine(executable: path) { event in
            if event.kind == .failure { failureSeen = true }
            if event.kind == .stopped { XCTAssertTrue(failureSeen); XCTAssertFalse(event.retryable); stopped.fulfill() }
        }
        engine.start(profile: VPNProfile(username: "alice"), password: "test-password")
        wait(for: [stopped], timeout: 4)
    }

    func testTransportFailureWithGenericCookieEpilogueRemainsRetryable() throws {
        let path = "/private/tmp/xdvpn-test-" + UUID().uuidString
        try "#!/bin/sh\nread -r password\necho 'Failed to connect to host vpn.example.com'\necho 'Failed to obtain WebVPN cookie'\nexit 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o700)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let stopped = expectation(description: "retryable stop")
        let engine = TunnelEngine(executable: path) { event in
            XCTAssertNotEqual(event.kind, .failure)
            if event.kind == .stopped { XCTAssertTrue(event.retryable); stopped.fulfill() }
        }
        engine.start(profile: VPNProfile(username: "alice"), password: "test-password")
        wait(for: [stopped], timeout: 4)
    }

    func testBundledOpenConnectReportsLoopbackRefusalWithoutPrivilegePrompt() throws {
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["XDVPN_TEST_OPENCONNECT"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        }, "Run bash scripts/test.sh with the built runtime")
        let stopped = expectation(description: "real engine exit")
        let engine = TunnelEngine(executable: executable) { event in
            XCTAssertNotEqual(event.kind, .connected)
            XCTAssertNotEqual(event.kind, .failure)
            if event.kind == .stopped { XCTAssertTrue(event.retryable); stopped.fulfill() }
        }
        // Only the local machine is contacted; this is not a VPN login attempt.
        engine.start(profile: VPNProfile(server: "https://127.0.0.1:1", username: "xdvpn-local-test"), password: "disposable-test-value")
        wait(for: [stopped], timeout: 8)
        engine.stop()
    }
}

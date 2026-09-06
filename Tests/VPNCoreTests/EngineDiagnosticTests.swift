import XCTest
import Darwin
@testable import VPNCore

final class EngineDiagnosticTests: XCTestCase {
    func testEveryEngineLineIncludingUnknownErrorsReachesPersistentLogAndSecretsDoNot() throws {
        let directory = "/private/tmp/xdvpn-diagnostic-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let script = directory + "/engine"
        try """
        #!/bin/sh
        IFS= read -r password
        echo "Failed to connect to 192.0.2.10:8443: Can't assign requested address"
        echo 'DTLS handshake failed: unavailable'
        echo 'Vendor-specific opaque diagnostic xyz'
        echo "echoed-value $password"
        echo 'Cookie: sensitive-cookie-value'
        echo 'Failed to connect to host vpn.example.test'
        exit 1
        """.write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o700)
        let log = HelperDiagnosticLog(directory: directory + "/logs", owner: geteuid())
        let stopped = expectation(description: "stopped after flushed log")
        let engine = TunnelEngine(executable: script) { event in
            do { try log.append(event) } catch { XCTFail("Log was not written: \(error)") }
            if event.kind == .stopped { XCTAssertTrue(event.retryable); stopped.fulfill() }
        }
        engine.start(profile: .init(username: "fixture"), password: "sensitive-password-value")
        wait(for: [stopped], timeout: 5)
        let text = try String(contentsOfFile: directory + "/logs/helper.jsonl", encoding: .utf8)
        XCTAssertTrue(text.contains("Vendor-specific opaque diagnostic xyz"))
        XCTAssertTrue(text.contains("DTLS handshake failed"))
        XCTAssertTrue(text.contains("transport.addressUnavailable"))
        XCTAssertTrue(text.contains("\"errorNumber\":49"))
        XCTAssertTrue(text.contains("process.exited"))
        XCTAssertFalse(text.contains("sensitive-password-value"))
        XCTAssertFalse(text.contains("sensitive-cookie-value"))
        let records = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(records.compactMap { $0["sequence"] as? Int }, Array(1...records.count))
        XCTAssertTrue(records.allSatisfy { $0["timestamp"] != nil })
        let attributes = try FileManager.default.attributesOfItem(atPath: directory + "/logs/helper.jsonl")
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHelperLogRotationRelaunchAndUnsafeTargets() throws {
        let directory = "/private/tmp/xdvpn-diagnostic-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let log = HelperDiagnosticLog(directory: directory, owner: geteuid(), maxBytes: 2048, fileCount: 2)
        for index in 0..<25 { try log.append(.init(.info, "entry-\(index) " + String(repeating: "x", count: 100))) }
        let relaunched = HelperDiagnosticLog(directory: directory, owner: geteuid(), maxBytes: 2048, fileCount: 2)
        try relaunched.append(.init(.stopped, "new helper session"))
        for name in ["helper.jsonl", "helper.1.jsonl"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/" + name))
            XCTAssertLessThanOrEqual(data.count, 2048)
            for line in data.split(separator: 10) { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
        }
        XCTAssertTrue(try String(contentsOfFile: directory + "/helper.jsonl", encoding: .utf8).contains("new helper session"))
        try FileManager.default.removeItem(atPath: directory + "/helper.jsonl")
        let victim = directory + "/victim"; try "untouched".write(toFile: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: directory + "/helper.jsonl", withDestinationPath: victim)
        XCTAssertThrowsError(try log.append(.init(.info, "must not follow symlink")))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "untouched")
    }

    func testRedactionsAreVisibleAndDoNotSwallowSubsequentRouteErrors() {
        var sanitizer = DiagnosticSanitizer(secrets: ["private-password"])
        XCTAssertFalse(sanitizer.sanitize("private-password").contains("private-password"))
        XCTAssertTrue(sanitizer.sanitize("<auth id='x'>").contains("脱敏"))
        XCTAssertTrue(sanitizer.sanitize("hidden auth data").contains("脱敏"))
        XCTAssertTrue(sanitizer.sanitize("XDVPN route delete failed errno=49").contains("errno=49"))
        XCTAssertFalse(sanitizer.sanitize("https://vpn.example/path?ticket=private-value").contains("private-value"))
    }
}

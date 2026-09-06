import XCTest
import Darwin
@testable import VPNCore

final class PrivilegePolicyTests: XCTestCase {
    func testHelperIdentityComesFromSudoAndRejectsArbitraryCommands() throws {
        let args = ["helper", "--session", "/private/tmp/xdvpn-test/control.sock"]
        XCTAssertEqual(try PrivilegePolicy.sessionOwner(arguments: args, environment: ["SUDO_UID": "501"], effectiveUID: 0), 501)
        XCTAssertEqual(PrivilegePolicy.version, "4", "The UI must require phase-aware hooks and retryable cleanup")
        XCTAssertFalse(try PrivilegePolicy.sudoersRule(username: "test_user").contains("--network-script"))
        for (arguments, environment, uid) in [
            (args, ["SUDO_UID": "501"], uid_t(501)),
            (args, [:], uid_t(0)), (args, ["SUDO_UID": "0"], uid_t(0)),
            (args + ["502"], ["SUDO_UID": "501"], uid_t(0)),
            (["helper", "--execute", "/bin/sh"], ["SUDO_UID": "501"], uid_t(0))
        ] {
            XCTAssertThrowsError(try PrivilegePolicy.sessionOwner(arguments: arguments, environment: environment, effectiveUID: uid))
        }
    }

    func testSudoersRejectsUsernameInjection() {
        for username in ["ALL", "a\nALL=(ALL) ALL", "a b", "a,b", "a#", "$(id)", "a:"] {
            // ALL is reserved by sudoers and must not accidentally authorize everyone.
            XCTAssertThrowsError(try PrivilegePolicy.sudoersRule(username: username))
        }
    }

    func testInstalledHelperCannotBeReplacedByUserOwnedExecutableOrSymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("helper").path
        try "test".write(toFile: executable, atomically: true, encoding: .utf8)
        chmod(executable, 0o755)
        XCTAssertFalse(PrivilegePolicy.trustedInstalledHelper(at: executable))
        let link = folder.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr/bin/true")
        XCTAssertFalse(PrivilegePolicy.trustedInstalledHelper(at: link))
    }

    func testSessionLeasePreventsOverlappingTunnelOwnersAndReleasesOnExit() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var first: SessionLease? = try SessionLease(path: path, owner: getuid(), timeout: 0)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try SessionLease(path: path, owner: getuid(), timeout: 0))
        first = nil
        XCTAssertNoThrow(try SessionLease(path: path, owner: getuid(), timeout: 0))
        chmod(path, 0o666)
        XCTAssertThrowsError(try SessionLease(path: path, owner: getuid(), timeout: 0))
    }
}

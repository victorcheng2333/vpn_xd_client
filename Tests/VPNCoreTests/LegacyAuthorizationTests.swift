import XCTest
import Darwin
@testable import VPNCore

final class LegacyAuthorizationTests: XCTestCase {
    private let rule = "private/etc/sudoers.d/xd-vpn-astra"
    private let helper = "Library/PrivilegedHelperTools/com.xd.vpn.helper"
    private let runtime = "Library/PrivilegedHelperTools/com.xd.vpn.openconnect"
    private func fixture(_ check: (URL) throws -> Void) throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("legacy-'$(fixture)-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for directory in ["private/etc/sudoers.d", "private/var/run", "Library/PrivilegedHelperTools/com.xd.vpn.openconnect"] {
            try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        for (path, text) in [(rule, try PrivilegePolicy.sudoersRule(username: "test_user")), (helper, "old helper"), (runtime + "/openconnect", "old engine"), (runtime + "/vpnc-script", "old script")] {
            let url = root.appendingPathComponent(path)
            try text.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o600)
        }
        try check(root)
    }
    func testMigrationWithdrawsOnlyKnownFilesAndPreservesPrivateBackup() throws {
        try fixture { root in
            let unrelated = root.appendingPathComponent("private/etc/sudoers.d/other")
            try "unchanged".write(to: unrelated, atomically: true, encoding: .utf8)
            let migration = LegacyAuthorization(root: root, owner: getuid())
            XCTAssertTrue(migration.isPresent)
            try migration.retire()
            XCTAssertFalse(migration.isPresent)
            XCTAssertEqual(try String(contentsOf: unrelated), "unchanged")
            let base = root.appendingPathComponent("Library/PrivilegedHelperTools/.xdvpn-legacy-backups")
            let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).first)
            XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("com.xd.vpn.helper")), "old helper")
            var info = stat(); XCTAssertEqual(lstat(backup.path, &info), 0); XCTAssertEqual(info.st_mode & 0o077, 0)
            XCTAssertNoThrow(try migration.retire())
        }
    }
    func testFailureAfterWithdrawingRuleRollsBackAllMovedFiles() throws {
        try fixture { root in
            let migration = LegacyAuthorization(root: root, owner: getuid(), beforeMove: { path in
                if path == self.helper { throw VPNError.system("injected failure") }
            })
            XCTAssertThrowsError(try migration.retire())
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(rule)), try PrivilegePolicy.sudoersRule(username: "test_user"))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(helper)), "old helper")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(runtime + "/openconnect")), "old engine")
        }
    }
    func testLiveLegacyLeasePreventsMigration() throws {
        try fixture { root in
            let lease = try SessionLease(path: root.appendingPathComponent("private/var/run/com.xd.vpn.501.lock").path, owner: getuid(), timeout: 0)
            defer { withExtendedLifetime(lease) {} }
            XCTAssertThrowsError(try LegacyAuthorization(root: root, owner: getuid()).retire())
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(rule).path))
        }
    }
    func testUnexpectedSudoersContentIsNeverRemoved() throws {
        try fixture { root in
            try "ALL ALL=(ALL) ALL\n".write(to: root.appendingPathComponent(rule), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try LegacyAuthorization(root: root, owner: getuid()).retire())
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(helper)), "old helper")
        }
    }
    func testProcessStartingDuringMigrationRestoresOldAuthorization() throws {
        try fixture { root in
            var checks = 0
            let migration = LegacyAuthorization(root: root, owner: getuid(), processIsActive: {
                checks += 1; return checks > 1
            })
            XCTAssertThrowsError(try migration.retire())
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(rule)), try PrivilegePolicy.sudoersRule(username: "test_user"))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(helper)), "old helper")
        }
    }
    func testSymlinkHardlinkAndWritableLegacyPathsAreRejectedBeforeAnyChange() throws {
        for kind in ["symlink", "hardlink", "writable"] {
            try fixture { root in
                let target = root.appendingPathComponent(helper), outside = root.appendingPathComponent("other")
                try "preserve".write(to: outside, atomically: true, encoding: .utf8)
                if kind == "writable" { chmod(target.path, 0o666) }
                else {
                    try FileManager.default.removeItem(at: target)
                    if kind == "symlink" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside) }
                    else { XCTAssertEqual(link(outside.path, target.path), 0) }
                }
                XCTAssertThrowsError(try LegacyAuthorization(root: root, owner: getuid()).retire())
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(rule).path))
                XCTAssertEqual(try String(contentsOf: outside), "preserve")
            }
        }
    }
}

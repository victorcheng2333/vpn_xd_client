import XCTest
import CryptoKit
import VPNCore
@testable import XDVPN

final class RuntimeInstallerTests: XCTestCase {
    func testInstallerVerifiesAllPayloadsBeforeReplacingExistingFiles() throws {
        try exercise(corruptScript: true, failPublication: false)
    }

    func testInstallerRestoresPreviousRuntimeAndHelperIfPublicationFails() throws {
        try exercise(corruptScript: false, failPublication: true)
    }

    func testInstallerPublishesCompleteRuntimeFromPathContainingShellCharacters() throws {
        try exercise(corruptScript: false, failPublication: false)
    }

    private func exercise(corruptScript: Bool, failPublication: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xdvpn-install-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("quoted app's $(untrusted)")
        let tools = root.appendingPathComponent("Library/PrivilegedHelperTools")
        let etc = root.appendingPathComponent("etc")
        let runtime = tools.appendingPathComponent("com.xd.vpn.openconnect")
        for directory in [source, runtime, etc.appendingPathComponent("sudoers.d")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let helper = tools.appendingPathComponent("com.xd.vpn.helper"), rule = etc.appendingPathComponent("sudoers.d/xd-vpn-astra")
        try "old helper".write(to: helper, atomically: true, encoding: .utf8)
        try "old rule".write(to: rule, atomically: true, encoding: .utf8)
        try "old runtime".write(to: runtime.appendingPathComponent("openconnect"), atomically: true, encoding: .utf8)
        try "#includedir /private/etc/sudoers.d\n".write(to: etc.appendingPathComponent("sudoers"), atomically: true, encoding: .utf8)
        let fixture = source.appendingPathComponent("fixture.c"), helperSource = source.appendingPathComponent("helper")
        try "int main(void) { return 0; }\n".write(to: fixture, atomically: true, encoding: .utf8)
        for (tool, arguments) in [("/usr/bin/cc", [fixture.path, "-o", helperSource.path]),
                                  ("/usr/bin/codesign", ["--force", "--sign", "-", helperSource.path])] {
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: tool); compiler.arguments = arguments
            compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
            try compiler.run(); compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0)
        }
        let binary = try Data(contentsOf: helperSource)
        try binary.write(to: source.appendingPathComponent("openconnect"))
        let scriptData = Data("#!/bin/sh\nexit 0\n".utf8)
        try scriptData.write(to: source.appendingPathComponent("vpnc-script"))
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let newRule = try PrivilegePolicy.sudoersRule(username: "test_user")
        var script = PrivilegeManager.installScript(source: source.appendingPathComponent("helper").path,
            digest: digest(binary), rule: newRule, runtimeSource: source.path,
            executableDigest: digest(binary), scriptDigest: corruptScript ? String(repeating: "0", count: 64) : digest(scriptData))
        // Run the production transaction against isolated, user-owned destinations.
        // Root ownership enforcement is covered separately by PrivilegePolicyTests.
        script = script.replacingOccurrences(of: "/Library", with: root.path + "/Library")
            .replacingOccurrences(of: "/private/etc", with: etc.path)
            .replacingOccurrences(of: "-o root -g wheel ", with: "")
            .replacingOccurrences(of: "chown root:wheel", with: "chown \(getuid()):\(getgid())")
            .replacingOccurrences(of: "[ \"$(/usr/bin/stat -f %u \"$DIRECTORY\")\" = 0 ]", with: "[ \"$(/usr/bin/stat -f %u \"$DIRECTORY\")\" = \(getuid()) ]")
        if failPublication {
            script = script.replacingOccurrences(of: "/bin/mv -f \"$WORK/rule\" \"$RULE\"", with: "exit 42")
        }
        let scriptURL = root.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if corruptScript || failPublication {
            XCTAssertEqual(process.terminationStatus, corruptScript ? 73 : 42, detail)
            XCTAssertEqual(try String(contentsOf: helper), "old helper")
            XCTAssertEqual(try String(contentsOf: rule), "old rule")
            XCTAssertEqual(try String(contentsOf: runtime.appendingPathComponent("openconnect")), "old runtime")
        } else {
            XCTAssertEqual(process.terminationStatus, 0, detail)
            XCTAssertEqual(try Data(contentsOf: helper), binary)
            XCTAssertEqual(try Data(contentsOf: runtime.appendingPathComponent("openconnect")), binary)
            XCTAssertEqual(try Data(contentsOf: runtime.appendingPathComponent("vpnc-script")), scriptData)
            XCTAssertTrue(try String(contentsOf: rule).contains("test_user ALL=(root)"))
        }
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: tools.path).contains { $0.hasPrefix(".xdvpn-install.") })
    }
}

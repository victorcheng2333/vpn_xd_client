import XCTest
import Darwin
@testable import VPNCore

final class BundledRuntimeTests: XCTestCase {
    func testBundleRequiresBothExecutableAndScriptWithoutHomebrewFallback() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("XD VPN \(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        XCTAssertNil(OpenConnect.bundledExecutable(in: bundle))
        let runtime = bundle.appendingPathComponent(OpenConnect.bundledDirectory)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let binary = runtime.appendingPathComponent("openconnect"), script = runtime.appendingPathComponent("vpnc-script")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        chmod(binary.path, 0o755)
        XCTAssertNil(OpenConnect.bundledExecutable(in: bundle), "An incomplete bundle must not silently use Homebrew")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        XCTAssertEqual(OpenConnect.bundledExecutable(in: bundle), binary.path)
        chmod(binary.path, 0o644)
        XCTAssertNil(OpenConnect.bundledExecutable(in: bundle))
    }

    func testBundleRejectsDirectoryOrSymlinkInPlaceOfRuntimeFiles() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let runtime = bundle.appendingPathComponent(OpenConnect.bundledDirectory)
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("openconnect"), withIntermediateDirectories: true)
        let script = runtime.appendingPathComponent("vpnc-script")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        XCTAssertNil(OpenConnect.bundledExecutable(in: bundle))
        try FileManager.default.removeItem(at: runtime.appendingPathComponent("openconnect"))
        try FileManager.default.createSymbolicLink(at: runtime.appendingPathComponent("openconnect"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertNil(OpenConnect.bundledExecutable(in: bundle))
    }

    func testInstalledRuntimeRequiresProtectedFileAndParentOwnership() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("openconnect")
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        chmod(binary.path, 0o755)
        XCTAssertFalse(PrivilegePolicy.trustedInstalledHelper(at: binary.path))
        XCTAssertTrue(PrivilegePolicy.trustedInstalledHelper(at: "/usr/bin/true"))
    }
}

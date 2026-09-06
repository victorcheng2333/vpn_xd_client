import XCTest
import VPNCore
@testable import XDVPN

final class RuntimeUpgradeTests: XCTestCase {
    func testMatchingRuntimeIsReadyWithoutChangingHelperVersion() throws {
        try withRuntime { bundle, installed in
            XCTAssertEqual(PrivilegeManager.runtimeStatus(bundle: bundle, installedDirectory: installed), .ready)
        }
    }

    func testEngineOrScriptContentChangeRequiresUpgradeEvenWithMatchingSizeAndTimestamp() throws {
        for name in ["openconnect", "vpnc-script"] {
            try withRuntime { bundle, installed in
                let destination = installed.appendingPathComponent(name)
                let timestamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate])
                // The fixture bytes have the same length as the bundled files.
                try "#!/bin/sh\nexit 1\n".write(to: destination, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.modificationDate: timestamp, .posixPermissions: 0o755], ofItemAtPath: destination.path)
                XCTAssertEqual(PrivilegeManager.status(exitCode: 0, version: PrivilegePolicy.version), .ready)
                XCTAssertEqual(PrivilegeManager.runtimeStatus(bundle: bundle, installedDirectory: installed), .needsUpdate, name)
            }
        }
    }

    func testMissingPayloadRequiresRepair() throws {
        for name in ["openconnect", "vpnc-script"] {
            for removeBundled in [false, true] {
                try withRuntime { bundle, installed in
                    let directory = removeBundled ? bundle.appendingPathComponent(OpenConnect.bundledDirectory) : installed
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                    XCTAssertEqual(PrivilegeManager.runtimeStatus(bundle: bundle, installedDirectory: installed), .needsRepair)
                }
            }
        }
    }

    private func withRuntime(_ check: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xdvpn-upgrade-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let bundle = root.appendingPathComponent("XD VPN.app"), installed = root.appendingPathComponent("installed")
        for directory in [bundle.appendingPathComponent(OpenConnect.bundledDirectory), installed] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["openconnect", "vpnc-script"] {
                let file = directory.appendingPathComponent(name)
                try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        try check(bundle, installed)
    }
}

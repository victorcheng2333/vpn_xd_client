import XCTest
import VPNCore
@testable import XDVPN

final class NetworkAndPrivilegeTests: XCTestCase {
    func testVPNRoutesAndVirtualInterfacesDoNotChangePhysicalSnapshot() {
        let original = ["State:/Network/Interface/en0/IPv4": ["Addresses": ["192.168.1.8"], "Router": "192.168.1.1"]] as [String: [String: Any]]
        var changed = original
        changed["State:/Network/Interface/en0/IPv4"]?["AdditionalRoutes"] = [["DestinationAddress": "10.0.0.0"]]
        changed["State:/Network/Interface/utun5/IPv4"] = ["Addresses": ["10.0.0.8"]]
        changed["State:/Network/Global/DNS"] = ["ServerAddresses": ["10.0.0.1"]]
        XCTAssertEqual(PhysicalNetworkMonitor.physicalSnapshot(from: original), PhysicalNetworkMonitor.physicalSnapshot(from: changed))
        changed["State:/Network/Interface/en0/IPv4"]?["Addresses"] = ["192.168.2.8"]
        XCTAssertNotEqual(PhysicalNetworkMonitor.physicalSnapshot(from: original), PhysicalNetworkMonitor.physicalSnapshot(from: changed))
    }

    func testPhysicalLinkDownAndNewGatewayAreObserved() {
        let original: [String: [String: Any]] = ["State:/Network/Interface/en8/Link": ["Active": true], "State:/Network/Interface/en8/IPv4": ["Router": "192.168.1.1"]]
        var changed = original
        changed["State:/Network/Interface/en8/Link"] = ["Active": false]
        XCTAssertNotEqual(PhysicalNetworkMonitor.physicalSnapshot(from: original), PhysicalNetworkMonitor.physicalSnapshot(from: changed))
        changed = original; changed["State:/Network/Interface/en8/IPv4"] = ["Router": "192.168.2.1"]
        XCTAssertNotEqual(PhysicalNetworkMonitor.physicalSnapshot(from: original), PhysicalNetworkMonitor.physicalSnapshot(from: changed))
    }

    func testInstallerScriptAndDedicatedSudoersRuleParseWithoutInstalling() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rule = try PrivilegePolicy.sudoersRule(username: "test_user")
        let script = PrivilegeManager.installScript(source: "/tmp/quoted app's $(untrusted)/helper", digest: String(repeating: "a", count: 64), rule: rule)
        let scriptURL = folder.appendingPathComponent("install.sh"), ruleURL = folder.appendingPathComponent("sudoers")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try rule.write(to: ruleURL, atomically: true, encoding: .utf8)
        for (executable, arguments) in [("/bin/sh", ["-n", scriptURL.path]), ("/usr/sbin/visudo", ["-cf", ruleURL.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }
}

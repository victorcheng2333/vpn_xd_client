import XCTest
import VPNCore
@testable import XDVPN

final class NetworkAndPrivilegeTests: XCTestCase {
    func testPhysicalNotificationSourcesShareComparisonAndSuppressRepeatedAnnouncements() {
        var values: [String: [String: Any]] = [
            "State:/Network/Interface/en0/Link": ["Active": true],
            "State:/Network/Interface/en0/IPv4": ["Addresses": ["192.168.1.8"], "Router": "192.168.1.1"]
        ]
        var observations: [PhysicalNetworkObservation] = []
        let monitor = PhysicalNetworkMonitor(initialSnapshot: values as NSDictionary) { observations.append($0) }
        for _ in 0..<20 {
            for source in [PhysicalNetworkObservation.Source.wifiLink, .wifiPower, .configuration] {
                monitor.observe(values as NSDictionary, source: source)
            }
        }
        XCTAssertTrue(observations.allSatisfy { !$0.shouldNotify && $0.online })
        values["State:/Network/Interface/en0/IPv4"]?["Router"] = "192.168.1.254"
        monitor.observe(values as NSDictionary, source: .wifiLink)
        monitor.observe(values as NSDictionary, source: .configuration)
        XCTAssertEqual(observations.filter(\.shouldNotify).count, 1)
        XCTAssertEqual(observations.first(where: \.shouldNotify)?.changedFields, ["en0/IPv4/Router"])
        values["State:/Network/Interface/en0/Link"] = ["Active": false]
        monitor.observe(values as NSDictionary, source: .wifiPower)
        XCTAssertEqual(observations.last?.online, false)
        XCTAssertEqual(observations.last?.shouldNotify, true)
        values["State:/Network/Interface/en0/Link"] = ["Active": true]
        monitor.observe(values as NSDictionary, source: .configuration)
        XCTAssertEqual(observations.last?.online, true)
        XCTAssertEqual(observations.last?.shouldNotify, true)
    }

    func testSSIDChangeWithIdenticalAddressesRemainsAnIndependentSignal() {
        let snapshot: NSDictionary = ["State:/Network/Interface/en0/Link": ["Active": true],
                                     "State:/Network/Interface/en0/IPv4": ["Addresses": ["192.168.1.8"]]]
        var observations: [PhysicalNetworkObservation] = []
        let monitor = PhysicalNetworkMonitor(initialSnapshot: snapshot) { observations.append($0) }
        monitor.observe(snapshot, source: .wifiSSID)
        monitor.observe(snapshot, source: .wifiLink)
        XCTAssertEqual(observations.map(\.shouldNotify), [true, false])
        XCTAssertTrue(observations[0].changedFields.isEmpty)
        XCTAssertFalse(observations[0].summary.contains("192.168.1.8"))
    }

    func testVPNOnlyFieldsCannotCreateAnEmptyPhysicalServiceChange() {
        let original: [String: [String: Any]] = ["State:/Network/Interface/en0/Link": ["Active": true]]
        var updated = original
        updated["State:/Network/Interface/en0/IPv4"] = ["AdditionalRoutes": [["DestinationAddress": "10.0.0.0"]]]
        XCTAssertEqual(PhysicalNetworkMonitor.physicalSnapshot(from: original), PhysicalNetworkMonitor.physicalSnapshot(from: updated))
    }

    func testAuthorizedOldHelperIsAnUpgradeRatherThanMissingAuthorization() {
        XCTAssertEqual(PrivilegeManager.status(exitCode: 0, version: "3\n"), .needsUpdate)
        XCTAssertEqual(PrivilegeManager.status(exitCode: 0, version: PrivilegePolicy.version + "\n"), .ready)
        XCTAssertEqual(PrivilegeManager.status(exitCode: 1, version: PrivilegePolicy.version), .needsRepair)
        XCTAssertEqual(PrivilegeManager.status(exitCode: 0, version: "invalid"), .needsRepair)
    }

    func testPhysicalReadinessIgnoresVPNAndGlobalReachability() {
        var values: [String: [String: Any]] = [
            "State:/Network/Interface/utun4/Link": ["Active": true],
            "State:/Network/Interface/utun4/IPv4": ["Addresses": ["10.0.0.8"]],
            "State:/Network/Global/IPv4": ["Router": "10.0.0.8"],
            "State:/Network/Interface/en0/Link": ["Active": false],
            "State:/Network/Interface/en0/IPv4": ["Addresses": ["192.168.1.8"]]
        ]
        XCTAssertFalse(PhysicalNetworkMonitor.hasUsablePhysicalNetwork(values as NSDictionary))
        values["State:/Network/Interface/en0/Link"] = ["Active": true]
        XCTAssertTrue(PhysicalNetworkMonitor.hasUsablePhysicalNetwork(values as NSDictionary))
        values["State:/Network/Global/IPv4"] = nil
        values["State:/Network/Global/DNS"] = ["ServerAddresses": ["10.0.0.1"]]
        XCTAssertTrue(PhysicalNetworkMonitor.hasUsablePhysicalNetwork(values as NSDictionary), "VPN route/DNS failure must not block physical readiness")
    }

    func testPhysicalReadinessWaitsForUsableAddressOnTheActiveInterface() {
        var values: [String: [String: Any]] = [
            "State:/Network/Interface/en0/Link": ["Active": true],
            "State:/Network/Interface/en8/Link": ["Active": false],
            "State:/Network/Interface/en8/IPv4": ["Addresses": ["192.168.1.8"]]
        ]
        for address in ["", "invalid", "0.0.0.0", "127.0.0.1", "169.254.1.2", "255.255.255.255", "::", "::1", "fe80::1234%en0", "ff02::1"] {
            values["State:/Network/Interface/en0/IPv4"] = ["Addresses": [address]]
            XCTAssertFalse(PhysicalNetworkMonitor.hasUsablePhysicalNetwork(values as NSDictionary), address)
        }
        for address in ["192.168.1.8", "10.0.1.2", "172.16.4.5", "2001:db8::2", "fd00::2"] {
            values["State:/Network/Interface/en0/IPv4"] = ["Addresses": [address]]
            XCTAssertTrue(PhysicalNetworkMonitor.hasUsablePhysicalNetwork(values as NSDictionary), address)
        }
        values["State:/Network/Interface/en0/IPv4"] = nil
        values["State:/Network/Interface/en0/IPv6"] = ["Addresses": ["2001:db8::2"]]
        XCTAssertTrue(PhysicalNetworkMonitor.hasUsablePhysicalNetwork(values as NSDictionary))
    }

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
        let script = PrivilegeManager.installScript(source: "/tmp/quoted app's $(untrusted)/helper", digest: String(repeating: "a", count: 64), rule: rule,
            runtimeSource: "/tmp/quoted app's $(untrusted)/OpenConnect", executableDigest: String(repeating: "b", count: 64), scriptDigest: String(repeating: "c", count: 64))
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

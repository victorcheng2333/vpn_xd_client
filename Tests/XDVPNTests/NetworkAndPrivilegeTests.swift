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

}

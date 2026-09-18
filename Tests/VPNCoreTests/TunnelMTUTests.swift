import XCTest
import Darwin
@testable import VPNCore

private final class MTUFixture {
    var values: [String: [String: Any]] = [:]
    var current = TunnelInterfaceState(index: 123, ipv4: ["10.8.0.2"], mtu: 1440)
    var reads = 0
    var writes: [(String, Int)] = []
    var failRead = false
    var failWrite = false
    var ignoreWrite = false
    var afterWrite: (() -> Void)?
    var offline = false
    var access: NetworkStateAccess {
        .init(read: { self.values[$0] }, write: { self.values[$0] = $1 },
              remove: { for key in $0 { self.values[key] = nil } }, interfaceExists: { _ in true },
              routes: offline ? .init(hostRoutes: { _ in [] }, physical: { throw RouteFailure.unavailable },
                                     update: { _, _ in XCTFail("Offline route must not change") }) : nil,
              interfaces: .init(read: { interface in
                  XCTAssertEqual(interface, "utun99999")
                  self.reads += 1
                  if self.failRead { throw RouteFailure.system("read fixture", EIO) }
                  return self.current
              }, setMTU: { interface, mtu in
                  self.writes.append((interface, mtu))
                  if self.failWrite { throw RouteFailure.system("write fixture", EPERM) }
                  if !self.ignoreWrite { self.current.mtu = mtu }
                  self.afterWrite?()
              }))
    }
}

final class TunnelMTUTests: XCTestCase {
    private let marker = "State:/Network/Service/utun99999/XDVPN"
    private let environment = ["VPNPID": "42424", "TUNDEV": "utun99999", "INTERNAL_IP4_ADDRESS": "10.8.0.2",
                               "VPNGATEWAY": "180.169.125.54", "INTERNAL_IP4_MTU": "1280"]

    private func session(_ fixture: MTUFixture) throws -> TunnelNetworkSession {
        let session = try TunnelNetworkSession.create(prefix: "/private/tmp/xdvpn-mtu-unit-", owner: geteuid(), state: fixture.access)
        try session.claim(environment: environment)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: session.directory) }
        return session
    }

    private func execute(_ reason: ManagedNetworkScript.Reason, session: TunnelNetworkSession,
                         environment: [String: String]? = nil) -> Int32 {
        ManagedNetworkScript.execute(reason: reason, session: session, environment: environment ?? self.environment,
            processID: 42424, parentExited: { false }, runScript: {
                XCTFail("MTU/reconnect must not launch a shell or reconfigure DNS")
                return 1
            }, diagnostic: { _ in })
    }

    func testNegotiatedMTUChangeHasDedicatedNativeHook() {
        XCTAssertNotNil(ManagedNetworkScript.Reason(rawValue: "mtu"), "Late DTLS MTU changes must reach the managed interface")
    }

    func testLateDTLSChangeUpdatesOnlyOwnedInterfaceAndReadsBackBeforeReturning() throws {
        let fixture = MTUFixture(), session = try session(fixture)
        fixture.values["State:/Network/Service/en0/DNS"] = ["ServerAddresses": ["192.168.1.1"]]
        let before = NSDictionary(dictionary: fixture.values)
        XCTAssertEqual(execute(.mtu, session: session), 0)
        XCTAssertEqual(fixture.writes.map(\.0), ["utun99999"])
        XCTAssertEqual(fixture.writes.map(\.1), [1280])
        XCTAssertEqual(fixture.current.mtu, 1280)
        XCTAssertEqual(fixture.reads, 2)
        XCTAssertEqual(NSDictionary(dictionary: fixture.values), before, "An MTU hook leaves dynamic-store services intact")
        XCTAssertEqual(execute(.mtu, session: session), 0)
        XCTAssertEqual(fixture.writes.count, 1, "Repeated notification must not mutate the interface")
        var raised = environment; raised["INTERNAL_IP4_MTU"] = "1400"
        XCTAssertEqual(execute(.mtu, session: session, environment: raised), 0)
        XCTAssertEqual(fixture.current.mtu, 1400)
    }

    func testReconnectCalibratesMTUBeforeOfflineRouteCanDefer() throws {
        let fixture = MTUFixture(); fixture.offline = true
        let session = try session(fixture)
        XCTAssertEqual(execute(.reconnect, session: session), 0)
        XCTAssertEqual(fixture.writes.map(\.1), [1280])
        fixture.current.mtu = 1440; fixture.failWrite = true
        XCTAssertNotEqual(execute(.reconnect, session: session), 0, "Offline route deferral cannot hide an MTU failure")
    }

    func testAttemptReconnectDoesNotApplyStalePreHandshakeMTU() throws {
        let fixture = MTUFixture(), session = try session(fixture)
        XCTAssertEqual(execute(.attemptReconnect, session: session), 0)
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testInvalidMTUAndHookIdentityFailBeforeTouchingTheInterface() throws {
        let fixture = MTUFixture(), session = try session(fixture)
        for value in ["", "0", "575", "9001", "-1", "1280\n", "+1280", " 1280", "1.28e3", "99999999999999999999999"] {
            var env = environment; env["INTERNAL_IP4_MTU"] = value
            XCTAssertNotEqual(execute(.mtu, session: session, environment: env), 0, value)
        }
        for (key, value) in [("INTERNAL_IP4_MTU", nil), ("VPNPID", "99"), ("TUNDEV", "en0"),
                             ("TUNDEV", "utun2"), ("INTERNAL_IP4_ADDRESS", "10.9.0.2")] as [(String, String?)] {
            var env = environment; env[key] = value
            XCTAssertNotEqual(execute(.mtu, session: session, environment: env), 0, key)
        }
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testForeignSessionAndReusedOrMissingInterfaceAreRejected() throws {
        for mutation in 0..<5 {
            let fixture = MTUFixture(), session = try session(fixture)
            switch mutation {
            case 0: fixture.values[marker] = ["SessionID": UUID().uuidString]
            case 1: fixture.values[marker] = nil
            case 2: fixture.current.ipv4 = ["10.99.0.2"]
            case 3: fixture.current.index = 0
            default: fixture.failRead = true
            }
            XCTAssertNotEqual(execute(.mtu, session: session), 0)
            XCTAssertTrue(fixture.writes.isEmpty)
        }
    }

    func testWriteFailureAndFalseSuccessAreNotAccepted() throws {
        for mutation in 0..<5 {
            let fixture = MTUFixture(), session = try session(fixture)
            switch mutation {
            case 0: fixture.failWrite = true
            case 1: fixture.ignoreWrite = true
            case 2: fixture.afterWrite = { fixture.current.index = 124 }
            case 3: fixture.afterWrite = { fixture.current.ipv4 = ["10.99.0.2"] }
            default: fixture.afterWrite = { fixture.values[self.marker] = ["SessionID": "foreign"] }
            }
            XCTAssertNotEqual(execute(.mtu, session: session), 0)
            XCTAssertEqual(fixture.writes.count, 1)
        }
    }

    func testNativeReaderUsesRealDarwinIOCTLWithoutChangingLoopback() throws {
        let state = try TunnelInterfaceAccess.live.read("lo0")
        XCTAssertEqual(state.index, if_nametoindex("lo0"))
        XCTAssertTrue(state.ipv4.contains("127.0.0.1"))
        XCTAssertGreaterThan(state.mtu, 0)
        XCTAssertThrowsError(try TunnelInterfaceAccess.live.read("missing-interface"))
    }
}

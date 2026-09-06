import XCTest
import Darwin
import SystemConfiguration
@testable import VPNCore

private final class RouteFixture {
    var values: [String: [String: Any]] = [:]
    var current: IPv4Route?
    var otherRoutes: [IPv4Route] = []
    var failInventory = false
    var physical: PhysicalRoute? = .init(interface: "en0", index: 14, address: "192.168.71.118", gateway: "192.168.71.1")
    var updates: [(TunnelRouteAccess.Action, IPv4Route)] = []
    var failMutation = false
    var ignoreMutation = false
    var routeAfterDelete: IPv4Route?
    var journalVisibleDuringMutation: (() -> Void)?
    var access: NetworkStateAccess {
        .init(read: { self.values[$0] }, write: { self.values[$0] = $1 }, remove: { for key in $0 { self.values[key] = nil } },
              interfaceExists: { _ in false }, routes: .init(hostRoutes: { destination in
                  if self.failInventory { throw RouteFailure.system("inventory", EIO) }
                  return ([self.current].compactMap { $0 } + self.otherRoutes).filter { $0.destination == destination && $0.isHost }
              }, physical: {
                  guard let physical = self.physical else { throw RouteFailure.unavailable }; return physical
              }, update: { action, route in
                  self.journalVisibleDuringMutation?()
                  self.updates.append((action, route))
                  if self.failMutation { throw RouteFailure.system("fixture", EADDRNOTAVAIL) }
                  if !self.ignoreMutation { self.current = action == .delete ? self.routeAfterDelete : route }
              }))
    }
}

final class TunnelRouteTests: XCTestCase {
    private let env = ["VPNPID": "42424", "TUNDEV": "utun99999", "INTERNAL_IP4_ADDRESS": "10.8.0.2", "INTERNAL_IP4_DNS": "172.24.4.79", "VPNGATEWAY": "180.169.125.54"]
    private func session(_ fixture: RouteFixture) throws -> TunnelNetworkSession {
        let session = try TunnelNetworkSession.create(prefix: "/private/tmp/xdvpn-route-unit-", owner: geteuid(), state: fixture.access)
        try session.claim(environment: env)
        return session
    }
    private func remove(_ session: TunnelNetworkSession) { try? FileManager.default.removeItem(atPath: session.directory) }

    func testSwitchReplacesOldGatewayAndSourceThenDisconnectRemovesHostRoute() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        var diagnostics: [String] = []
        try session.prepareServerRoute(environment: env, diagnostic: { diagnostics.append($0) })
        XCTAssertEqual(fixture.updates.map(\.0), [.add])
        fixture.physical = .init(interface: "en0", index: 14, address: "192.168.124.36", gateway: "192.168.124.1")
        try session.prepareServerRoute(environment: env, diagnostic: { diagnostics.append($0) })
        XCTAssertEqual(fixture.updates.map(\.0), [.add, .delete, .add])
        XCTAssertEqual(fixture.current?.source, "192.168.124.36")
        XCTAssertEqual(fixture.current?.gateway, "192.168.124.1")
        try session.prepareServerRoute(environment: env, diagnostic: { diagnostics.append($0) })
        XCTAssertEqual(fixture.updates.count, 3, "Repeated recovery must not mutate a correct route")
        fixture.physical = nil // Cleanup cannot depend on any physical/default route.
        try session.cleanup(processID: 42424)
        XCTAssertNil(fixture.current)
        XCTAssertEqual(fixture.updates.map(\.0), [.add, .delete, .add, .delete])
        XCTAssertTrue(diagnostics.contains { $0.contains("add verified") && $0.contains("192.168.124.36") })
        try session.finish()
    }

    func testSameInterfaceAndGatewayStillRefreshesChangedSourceAddress() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        fixture.physical?.address = "192.168.71.119"
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        XCTAssertEqual(fixture.updates.last?.0, .add)
        XCTAssertEqual(fixture.current?.source, "192.168.71.119")
    }

    func testScopedCacheAndOwnedStaticRouteCoexistAcrossConnectSwitchAndCleanup() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        var cache = fixture.physical!.host(env["VPNGATEWAY"]!)
        cache.flags = 1157759047 // Actual scoped clone flags from the incident.
        fixture.otherRoutes = [cache]
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        XCTAssertNotNil(fixture.current)
        XCTAssertEqual(fixture.current?.scope, 0)
        XCTAssertEqual(fixture.otherRoutes, [cache])
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        XCTAssertEqual(fixture.updates.map(\.0), [.add], "No second ADD over an existing owned route")
        fixture.physical = .init(interface: "en0", index: 14, address: "192.168.124.36", gateway: "192.168.124.1")
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        XCTAssertEqual(fixture.updates.map(\.0), [.add, .delete, .add])
        XCTAssertEqual(fixture.current?.source, "192.168.124.36")
        fixture.physical = nil
        try session.cleanup(processID: 42424)
        XCTAssertNil(fixture.current, "A preferred scoped cache must not hide an owned static route during cleanup")
        XCTAssertEqual(fixture.otherRoutes, [cache])
        try session.finish()
    }

    func testInventoryFailureKeepsPendingJournalUntilCleanupCanActuallyBeVerified() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        fixture.journalVisibleDuringMutation = { fixture.failInventory = true }
        XCTAssertThrowsError(try session.prepareServerRoute(environment: env, diagnostic: { _ in }))
        XCTAssertNotNil(fixture.current)
        XCTAssertThrowsError(try session.cleanup(processID: 42424))
        XCTAssertThrowsError(try session.finish())
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory + "/route.json"))
        fixture.journalVisibleDuringMutation = nil; fixture.failInventory = false
        try session.cleanup(processID: 42424)
        XCTAssertNil(fixture.current)
        try session.finish()
    }

    func testRouteTableDecodingRetainsAllScopesAndRejectsPartialSnapshots() throws {
        let host = try RouteSocket.message(type: RTM_GET, destination: "180.169.125.54", gateway: "192.168.71.1",
            source: "192.168.71.118", flags: RTF_UP | RTF_HOST | RTF_STATIC | RTF_GATEWAY, index: 14)
        let cache = try RouteSocket.message(type: RTM_GET, destination: "180.169.125.54", gateway: "192.168.71.1",
            source: "192.168.71.118", flags: 1157759047, index: 14)
        let parsed = try RouteSocket.decodeTable(cache + host)
        XCTAssertEqual(parsed.map(\.scope), [14, 0])
        XCTAssertEqual(parsed.map(\.source), ["192.168.71.118", "192.168.71.118"])
        XCTAssertThrowsError(try RouteSocket.decodeTable((cache + host).dropLast()))
        XCTAssertThrowsError(try RouteSocket.decodeTable(Data(repeating: 0, count: 100)))
    }

    func testLiveRouteInventoryIncludesSourceAddressWithoutChangingRoutes() throws {
        let routes = try RouteSocket.decodeTable(RouteSocket.table())
        let loopback = try XCTUnwrap(routes.first { $0.destination == "127.0.0.1" && $0.isHost && $0.scope == 0 })
        XCTAssertEqual(loopback.source, "127.0.0.1")
        XCTAssertEqual(loopback.interfaceIndex, if_nametoindex("lo0"))
        XCTAssertFalse(routes.isEmpty)
    }

    func testForeignRouteIsNotAdoptedChangedOrDeleted() throws {
        let fixture = RouteFixture()
        fixture.current = fixture.physical!.host(env["VPNGATEWAY"]!)
        let original = fixture.current, session = try session(fixture)
        defer { remove(session) }
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        fixture.physical?.address = "192.168.71.119"
        XCTAssertThrowsError(try session.prepareServerRoute(environment: env, diagnostic: { _ in }))
        try session.cleanup(processID: 42424)
        XCTAssertTrue(fixture.updates.isEmpty)
        XCTAssertEqual(fixture.current, original)
        try session.finish()
    }

    func testKernelCloneCanBeReplacedWithoutAdoptingExplicitStaticRoutes() throws {
        let fixture = RouteFixture()
        fixture.current = fixture.physical!.host(env["VPNGATEWAY"]!)
        fixture.current!.flags = RTF_UP | RTF_HOST | RTF_GATEWAY | RTF_WASCLONED
        let session = try session(fixture)
        defer { remove(session) }
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        XCTAssertEqual(fixture.updates.map(\.0), [.add])
        fixture.physical?.address = "192.168.71.119"
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        XCTAssertEqual(fixture.updates.last?.0, .add)
        try session.cleanup(processID: 42424)
        XCTAssertNil(fixture.current)
    }

    func testForeignReplacementOfOwnedRouteBlocksCleanupWithoutDeletion() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        fixture.current?.gateway = "192.168.71.254"
        XCTAssertThrowsError(try session.cleanup(processID: 42424))
        XCTAssertEqual(fixture.updates.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory + "/route.json"))
        XCTAssertTrue(session.cleanupFailureMessage().contains("180.169.125.54"))
    }

    func testLinkPruningAndRegeneratedKernelClonesDoNotBlockRecoveryOrCleanup() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        fixture.physical = .init(interface: "en0", index: 14, address: "192.168.124.36", gateway: "192.168.124.1")
        var clone = fixture.physical!.host(env["VPNGATEWAY"]!)
        clone.flags = RTF_UP | RTF_HOST | RTF_GATEWAY | RTF_WASCLONED
        fixture.current = clone // Kernel removed the old route with the old address.
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        XCTAssertEqual(fixture.updates.map(\.0), [.add, .add])
        XCTAssertEqual(fixture.current?.source, "192.168.124.36")
        fixture.routeAfterDelete = clone // Concurrent traffic repopulates a kernel cache.
        try session.cleanup(processID: 42424)
        XCTAssertEqual(fixture.current, clone)
        try session.finish()

        let next = try self.session(fixture)
        defer { remove(next) }
        try next.prepareServerRoute(environment: env, diagnostic: { _ in })
        fixture.current = clone // Already pruned before cleanup gets to read it.
        let count = fixture.updates.count
        try next.cleanup(processID: 42424)
        XCTAssertEqual(fixture.updates.count, count)
        try next.finish()
    }

    func testReadbackFailureIsNotSuccessAndRetryCanFinishCleanup() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        fixture.ignoreMutation = true
        XCTAssertThrowsError(try session.prepareServerRoute(environment: env, diagnostic: { _ in }))
        fixture.ignoreMutation = false
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        fixture.ignoreMutation = true
        XCTAssertThrowsError(try session.cleanup(processID: 42424))
        XCTAssertThrowsError(try session.finish())
        fixture.ignoreMutation = false
        try session.cleanup(processID: 42424)
        try session.finish()
    }

    func testOrphanRecoversRouteAfterCrashBetweenMutationAndVerification() throws {
        let fixture = RouteFixture()
        var session: TunnelNetworkSession? = try self.session(fixture)
        let path = session!.directory
        defer { try? FileManager.default.removeItem(atPath: path) }
        fixture.journalVisibleDuringMutation = {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/route.json"))
        }
        // Apply the mutation but fail the readback, leaving the saved intent.
        var access = fixture.access
        let realUpdate = access.routes!.update
        access.routes!.update = { action, route in
            try realUpdate(action, route)
            throw RouteFailure.system("simulated crash after write", EIO)
        }
        session = nil
        session = try TunnelNetworkSession(directory: path, token: String(path.split(separator: "-").suffix(5).joined(separator: "-")), owner: geteuid(), state: access)
        XCTAssertThrowsError(try session!.prepareServerRoute(environment: env, diagnostic: { _ in }))
        session = nil
        fixture.journalVisibleDuringMutation = nil
        try TunnelNetworkSession.recoverOrphans(prefix: "/private/tmp/xdvpn-route-unit-", owner: geteuid(), state: fixture.access, processAlive: { _ in false })
        XCTAssertNil(fixture.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAttemptReconnectRefreshesRouteWithoutLaunchingTheBlockedScript() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        for target in [PhysicalRoute(interface: "en0", index: 14, address: "192.168.124.37", gateway: "192.168.124.1"),
                       PhysicalRoute(interface: "en0", index: 14, address: "192.168.71.118", gateway: "192.168.71.1")] {
            fixture.physical = target
            var messages: [String] = []
            let result = ManagedNetworkScript.execute(reason: .attemptReconnect, session: session, environment: env, processID: 42424,
                parentExited: { false }, runScript: {
                    XCTFail("The route is already native; this shell blocked until the recovery deadline in the incident")
                    throw NetworkScriptRunner.Failure.timedOut
                }, diagnostic: { messages.append($0) })
            XCTAssertEqual(result, 0)
            XCTAssertEqual(fixture.current?.gateway, target.gateway)
            XCTAssertEqual(fixture.current?.source, target.address)
            XCTAssertTrue(messages.contains { $0.contains("route add verified") })
            XCTAssertEqual(messages.last, "XDVPN hook exited phase=attempt-reconnect status=0 native=true")
        }
        XCTAssertEqual(fixture.updates.map(\.0), [.add, .delete, .add, .delete, .add])
    }

    func testAttemptReconnectNeverReportsSuccessWhenNativeRouteUpdateFails() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        fixture.physical = .init(interface: "en0", index: 14, address: "192.168.124.37", gateway: "192.168.124.1")
        fixture.failMutation = true
        var messages: [String] = []
        let result = ManagedNetworkScript.execute(reason: .attemptReconnect, session: session, environment: env, processID: 42424,
            parentExited: { false }, runScript: { XCTFail("Do not fall back to the script after a native failure"); return 0 },
            diagnostic: { messages.append($0) })
        XCTAssertNotEqual(result, 0)
        XCTAssertEqual(fixture.current?.gateway, "192.168.71.1")
        XCTAssertTrue(messages.contains { $0.contains("route configuration failed") })
        XCTAssertFalse(messages.contains { $0.contains("native=true") })
    }

    func testOfflineRecoveryDefersWithoutDestroyingOrChangingTheRoute() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        try session.prepareServerRoute(environment: env, diagnostic: { _ in })
        fixture.physical = nil
        var messages: [String] = []
        let result = ManagedNetworkScript.execute(reason: .attemptReconnect, session: session, environment: env, processID: 42424,
            parentExited: { false }, runScript: { XCTFail("No legacy gateway guess while offline"); return 1 }, diagnostic: { messages.append($0) })
        XCTAssertEqual(result, 0)
        XCTAssertEqual(fixture.updates.count, 1)
        XCTAssertNotNil(fixture.current)
        XCTAssertTrue(messages.contains { $0.contains("route deferred") })
    }

    func testIPv4DefaultIsOwnedByConfigdEvenWithoutSuppliedDNS() throws {
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        var noDNS = env; noDNS["INTERNAL_IP4_DNS"] = nil
        try session.configureIPv4Service(environment: noDNS)
        let key = "State:/Network/Service/utun99999/IPv4"
        XCTAssertEqual(fixture.values[key]?["Router"] as? String, "10.8.0.2")
        XCTAssertEqual(fixture.values[key]?["OverridePrimary"] as? Int, 1)
        try session.cleanup(processID: 42424)
        XCTAssertNil(fixture.values[key])
    }

    func testSplitRoutesDoNotAddATunnelDefaultAndZeroPrefixDoes() throws {
        for defaultIncluded in [false, true] {
            let fixture = RouteFixture(), session = try session(fixture)
            defer { remove(session) }
            var split = env; split["CISCO_SPLIT_INC"] = "1"
            split["CISCO_SPLIT_INC_0_ADDR"] = defaultIncluded ? "0.0.0.0" : "10.20.0.0"
            split["CISCO_SPLIT_INC_0_MASKLEN"] = defaultIncluded ? "0" : "16"
            try session.configureIPv4Service(environment: split)
            XCTAssertEqual(fixture.values["State:/Network/Service/utun99999/IPv4"]?["Router"] as? String, defaultIncluded ? "10.8.0.2" : nil)
        }
    }

    func testKernelMessageContainsExplicitNewInterfaceAddress() throws {
        let packet = try RouteSocket.message(type: RTM_ADD, destination: "180.169.125.54", gateway: "192.168.124.1",
            source: "192.168.124.36", flags: RTF_UP | RTF_HOST | RTF_GATEWAY | RTF_STATIC, index: 14)
        let header = packet.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
        XCTAssertEqual(header.rtm_type, UInt8(RTM_ADD))
        XCTAssertNotEqual(header.rtm_addrs & RTA_IFA, 0, "Changing only the gateway can retain a stale source address")
        XCTAssertEqual(header.rtm_flags & RTF_IFSCOPE, 0, "The owned server route must also serve unscoped OpenConnect sockets")
        let parsed = try RouteSocket.decode(packet)
        XCTAssertEqual(parsed.source, "192.168.124.36")
        XCTAssertThrowsError(try RouteSocket.decode(packet.prefix(12)))
    }

    func testLiveRouteSocketReadOnlyRoundTrip() throws {
        let route = try XCTUnwrap(RouteSocket.lookup("127.0.0.1"))
        XCTAssertEqual(route.destination, "127.0.0.1")
        XCTAssertEqual(route.source, "127.0.0.1")
        XCTAssertEqual(route.interfaceIndex, if_nametoindex("lo0"))
    }

    func testRouteRepliesIgnoreConcurrentInterfaceNotificationsAndOtherRequests() throws {
        let packet = try RouteSocket.message(type: RTM_GET, destination: "127.0.0.1", flags: 0, index: 0)
        let request = packet.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
        let linkNotification = Data([8, 0, UInt8(RTM_VERSION), UInt8(RTM_IFINFO), 0, 0, 0, 0])
        XCTAssertNil(try RouteSocket.matchingReply(linkNotification, request: request))
        var otherRequest = request; otherRequest.rtm_seq = request.rtm_seq == 1 ? 2 : 1
        let other = withUnsafeBytes(of: &otherRequest) { Data($0) }
        XCTAssertNil(try RouteSocket.matchingReply(other, request: request))
        XCTAssertEqual(try RouteSocket.matchingReply(packet, request: request), packet)
        var rejected = request; rejected.rtm_errno = EADDRNOTAVAIL
        let errorReply = withUnsafeBytes(of: &rejected) { Data($0) }
        XCTAssertThrowsError(try RouteSocket.matchingReply(errorReply, request: request)) { error in
            guard case RouteFailure.system(_, EADDRNOTAVAIL) = error else { return XCTFail("Lost kernel errno: \(error)") }
        }
    }

    func testLivePhysicalRouteReadOnlyUsesCurrentInterfaceSource() throws {
        let access = try NetworkStateAccess.live()
        let physical: PhysicalRoute
        do { physical = try XCTUnwrap(access.routes).physical() }
        catch RouteFailure.unavailable { throw XCTSkip("No physical IPv4 network currently available") }
        XCTAssertTrue(physical.interface.hasPrefix("en"))
        XCTAssertEqual(physical.index, if_nametoindex(physical.interface))
        let scoped = try XCTUnwrap(RouteSocket.lookup("0.0.0.0", scope: physical.index))
        XCTAssertEqual(scoped.source, physical.address)
        XCTAssertEqual(scoped.gateway, physical.gateway)
    }

    func testBundledScriptCannotReintroduceWrongHostOrOldDefaultRoute() throws {
        let source = try XCTUnwrap(ProcessInfo.processInfo.environment["XDVPN_TEST_VPNC_SCRIPT"],
                                   "Run bash scripts/test.sh with the built runtime")
        let fixture = RouteFixture(), session = try session(fixture)
        defer { remove(session) }
        let generated = try session.managedScript(source: source)
        let folder = session.directory
        let body = try String(contentsOfFile: generated, encoding: .utf8)
            .replacingOccurrences(of: "/var/run/vpnc", with: folder + "/vpnc")
            .replacingOccurrences(of: "/etc/resolv.conf", with: folder + "/resolv.conf")
            .replacingOccurrences(of: "HOOKS_DIR=/etc/vpnc", with: "HOOKS_DIR=" + folder + "/hooks")
        let shim = """
        #!/bin/sh
        uname() { if [ "$1" = -s ]; then echo Darwin; else echo 26.0; fi; }
        ifconfig() { :; }
        networksetup() { :; }
        scutil() { cat >> \(folder)/scutil.txt; }
        netstat() { printf '%s\\n' 'default 10.8.0.2 UGScg utun99999' 'default 192.168.124.1 UGScIg en0'; }
        route() { printf '%s\\n' "$*" >> \(folder)/route.txt; return 1; }
        """
        let script = folder + "/replay-script"
        try (shim + "\n" + body).write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o700)
        try FileManager.default.createDirectory(atPath: folder + "/vpnc", withIntermediateDirectories: false)
        for phase in ["connect", "attempt-reconnect", "disconnect"] {
            try "192.168.71.1\n".write(toFile: folder + "/vpnc/defaultroute.42424", atomically: true, encoding: .utf8)
            try "nameserver 192.168.124.1\n".write(toFile: folder + "/vpnc/resolv.conf-backup.42424", atomically: true, encoding: .utf8)
            try "#@VPNC_GENERATED@\n".write(toFile: folder + "/resolv.conf", atomically: true, encoding: .utf8)
            var environment = env; environment["reason"] = phase; environment["PATH"] = "/usr/bin:/bin"
            let result = try NetworkScriptRunner.run(executable: script, environment: environment, timeout: 2)
            XCTAssertEqual(result, 0)
        }
        let commands = (try? String(contentsOfFile: folder + "/route.txt", encoding: .utf8)) ?? ""
        XCTAssertFalse(commands.contains("add -host"))
        XCTAssertFalse(commands.contains("delete -host"))
        XCTAssertFalse(commands.contains("add default"))
        XCTAssertFalse(commands.contains("delete default"))
        let original = try String(contentsOfFile: source, encoding: .utf8)
        XCTAssertFalse(original.contains("XD VPN owns"), "The installed Homebrew script must remain untouched")
    }
}

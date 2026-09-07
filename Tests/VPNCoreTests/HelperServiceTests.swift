import XCTest
@testable import VPNCore

private final class FakeTunnel: HelperTunnel {
    var starts = 0
    var reconnects = 0
    var stops = 0
    var completion: (() -> Void)?
    func start(profile: VPNProfile, password: String) { starts += 1 }
    func reconnect() { reconnects += 1 }
    func stop(completion: (() -> Void)?) { stops += 1; self.completion = completion }
}

final class HelperServiceTests: XCTestCase {
    private let identity = HelperIdentity(build: "test-build", bundlePath: "/Applications/XD VPN.app")
    private func make(engine: FakeTunnel, legacy: Bool = false, validate: @escaping () throws -> Void = {},
                      acquire: @escaping (uid_t) throws -> [AnyObject] = { _ in [] }) -> HelperSessionController {
        HelperSessionController(identity: identity, validate: validate, legacyPresent: { legacy }, retireLegacy: {},
                                acquire: acquire, makeEngine: { _, _ in engine })
    }
    private func open(_ controller: HelperSessionController, id: UUID, owner: uid_t = 501, identity: HelperIdentity? = nil) async -> String? {
        await withCheckedContinuation { continuation in
            controller.open(id: id, owner: owner, identity: identity ?? self.identity, event: { _ in }, reply: { continuation.resume(returning: $0) })
        }
    }
    private func send(_ controller: HelperSessionController, id: UUID, data: Data) async -> String? {
        await withCheckedContinuation { continuation in controller.send(id: id, data: data) { continuation.resume(returning: $0) } }
    }
    private func status(_ controller: HelperSessionController) async -> HelperServiceStatus {
        await withCheckedContinuation { continuation in controller.status { continuation.resume(returning: $0) } }
    }
    private func command(_ kind: HelperCommand.Kind) throws -> Data {
        try JSONEncoder().encode(kind == .connect ? HelperCommand(.connect, profile: .init(username: "alice"), password: "test") : HelperCommand(kind))
    }

    func testRejectsCommandsBeforeHandshakeAndFromAnotherConnection() async throws {
        let engine = FakeTunnel(), controller = make(engine: FakeTunnel()), id = UUID()
        let before = await send(controller, id: id, data: try command(.connect))
        XCTAssertNotNil(before)
        let own = make(engine: engine)
        let opened = await open(own, id: id); XCTAssertNil(opened)
        for kind in [HelperCommand.Kind.connect, .disconnect, .reconnect, .shutdown] {
            let error = await send(own, id: UUID(), data: try command(kind)); XCTAssertNotNil(error)
        }
        XCTAssertEqual(engine.starts + engine.reconnects + engine.stops, 0)
        let accepted = await send(own, id: id, data: try command(.connect)); XCTAssertNil(accepted)
        XCTAssertEqual(engine.starts, 1)
    }

    func testIdentityRootLegacyAndBundleValidationFailBeforeEngineCreation() async {
        let engine = FakeTunnel(), id = UUID()
        let controller = make(engine: engine)
        let root = await open(controller, id: id, owner: 0); XCTAssertNotNil(root)
        let mismatch = await open(controller, id: id, identity: .init(build: "other", bundlePath: identity.bundlePath)); XCTAssertNotNil(mismatch)
        let legacy = await open(make(engine: engine, legacy: true), id: id); XCTAssertNotNil(legacy)
        let invalid = await open(make(engine: engine, validate: { throw VPNError.system("changed") }), id: id); XCTAssertNotNil(invalid)
        let current = await status(controller); XCTAssertFalse(current.busy)
        XCTAssertEqual(engine.starts, 0)
    }

    func testDisconnectedOwnerRetainsLeaseAndRejectsNewOwnerUntilCleanupCompletes() async throws {
        final class Lease { let released: () -> Void; init(_ released: @escaping () -> Void) { self.released = released }; deinit { released() } }
        let released = expectation(description: "lease released after cleanup")
        let engine = FakeTunnel()
        var acquisitions = 0
        let controller = make(engine: engine, acquire: { _ in
            acquisitions += 1
            return acquisitions == 1 ? [Lease { released.fulfill() }] : []
        })
        let id = UUID()
        let opened = await open(controller, id: id); XCTAssertNil(opened)
        let closed = expectation(description: "closed")
        controller.close(id: id) { closed.fulfill() }
        let closing = await status(controller); XCTAssertTrue(closing.busy)
        let duplicate = await open(controller, id: UUID()); XCTAssertNotNil(duplicate)
        let late = await send(controller, id: id, data: try command(.connect)); XCTAssertNotNil(late)
        XCTAssertEqual(engine.stops, 1)
        // A second invalidation must not release or stop the engine twice.
        controller.close(id: id)
        _ = await status(controller)
        XCTAssertEqual(engine.stops, 1)
        let completion = engine.completion; engine.completion = nil; completion?()
        await fulfillment(of: [closed, released], timeout: 2)
        let reopened = await open(controller, id: UUID()); XCTAssertNil(reopened)
    }

    func testClosingAnotherConnectionCannotStopCurrentTunnel() async {
        let engine = FakeTunnel(), id = UUID()
        let owned = make(engine: engine)
        let opened = await open(owned, id: id); XCTAssertNil(opened)
        let closed = expectation(description: "non-owner closed")
        owned.close(id: UUID()) { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(engine.stops, 0)
        let current = await status(owned); XCTAssertTrue(current.busy)
    }

    func testShutdownWaitsForCleanupAndBlocksNewSessions() async {
        let engine = FakeTunnel()
        let owned = make(engine: engine)
        let opened = await open(owned, id: UUID()); XCTAssertNil(opened)
        let stopped = expectation(description: "daemon stopped")
        owned.shutdown { stopped.fulfill() }
        _ = await status(owned)
        let denied = await open(owned, id: UUID()); XCTAssertNotNil(denied)
        XCTAssertEqual(engine.stops, 1)
        engine.completion?(); engine.completion = nil
        await fulfillment(of: [stopped], timeout: 2)
        let after = await open(owned, id: UUID()); XCTAssertNotNil(after)
    }

    func testMalformedOversizedOrUnexpectedArgumentsNeverReachEngine() async throws {
        let engine = FakeTunnel(), id = UUID()
        let owned = make(engine: engine)
        let opened = await open(owned, id: id); XCTAssertNil(opened)
        for data in [Data(), Data(repeating: 65, count: HelperWire.maximumBytes + 1), Data("{invalid}".utf8),
                     Data(#"{"kind":"execute","path":"/bin/sh"}"#.utf8),
                     try JSONEncoder().encode(HelperCommand(.disconnect, password: "forbidden")),
                     try JSONEncoder().encode(HelperCommand(.connect, profile: .init(username: "alice"), password: "line\nbreak"))] {
            let error = await send(owned, id: id, data: data); XCTAssertNotNil(error)
        }
        XCTAssertEqual(engine.starts + engine.stops + engine.reconnects, 0)
    }

    func testChangingBundleAfterHandshakePreventsStartingEngine() async throws {
        let engine = FakeTunnel()
        var valid = true
        let id = UUID()
        let owned = make(engine: engine, validate: { if !valid { throw VPNError.system("bundle changed") } })
        let ownOpened = await open(owned, id: id); XCTAssertNil(ownOpened)
        valid = false
        let denied = await send(owned, id: id, data: try command(.connect)); XCTAssertNotNil(denied)
        XCTAssertEqual(engine.starts, 0)
    }

    func testRealXPCRejectsUnsignedCallerBeforeOpeningSession() async throws {
        let engine = FakeTunnel(), controller = make(engine: FakeTunnel())
        let delegate = HelperXPCListener(controller: controller)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate; listener.resume()
        let client = NSXPCConnection(listenerEndpoint: listener.endpoint)
        client.remoteObjectInterface = NSXPCInterface(with: HelperServiceProtocol.self)
        client.resume()
        defer { client.invalidate(); listener.invalidate(); withExtendedLifetime(delegate) {} }
        let denied = expectation(description: "kernel XPC peer requirement rejects test runner")
        let proxy = client.remoteObjectProxyWithErrorHandler { _ in denied.fulfill() } as! HelperServiceProtocol
        proxy.openSession(try JSONEncoder().encode(identity)) { _ in XCTFail("Unsigned caller reached exported service method") }
        await fulfillment(of: [denied], timeout: 5)
        let current = await status(controller); XCTAssertFalse(current.busy)
        XCTAssertEqual(engine.starts, 0)
    }
    func testConnectionLossStopsRealChildBeforeReleasingServiceSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("engine")
        try "#!/bin/sh\nread -r password\ntrap 'exit 0' INT TERM\necho 'Configured as 10.0.0.8'\nwhile :; do /bin/sleep 0.05; done\n".write(to: executable, atomically: true, encoding: .utf8)
        chmod(executable.path, 0o755)
        let connected = expectation(description: "real child connected")
        let stopped = expectation(description: "real child reaped")
        let controller = HelperSessionController(identity: identity, validate: {}, legacyPresent: { false }, retireLegacy: {}, acquire: { _ in [] },
            makeEngine: { _, emit in TunnelEngine(executable: executable.path, stopGrace: 0.2, killGrace: 1, emit: emit) })
        let id = UUID()
        let opened: String? = await withCheckedContinuation { continuation in
            controller.open(id: id, owner: getuid(), identity: identity, event: { event in
                if event.kind == .connected { connected.fulfill() }
                if event.kind == .stopped { stopped.fulfill() }
            }, reply: { continuation.resume(returning: $0) })
        }
        XCTAssertNil(opened)
        let sent = await send(controller, id: id, data: try command(.connect)); XCTAssertNil(sent)
        await fulfillment(of: [connected], timeout: 3)
        let closed = expectation(description: "control session released")
        controller.close(id: id) { closed.fulfill() }
        await fulfillment(of: [stopped, closed], timeout: 4, enforceOrder: true)
        let current = await status(controller); XCTAssertFalse(current.busy)
    }

    func testBundledHelperPathShellCharactersRemainOneExecutableArgument() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xpc-path-'$(exit 99)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("helper")
        try "#!/bin/sh\n[ \"$#\" = 1 ] && [ \"$1\" = --network-script ]\n".write(to: helper, atomically: true, encoding: .utf8)
        chmod(helper.path, 0o755)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", TunnelEngine.networkScriptCommand(helper.path)]
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }

}

import Foundation

public final class HelperXPCListener: NSObject, NSXPCListenerDelegate {
    private let controller: HelperSessionController
    public init(controller: HelperSessionController) { self.controller = controller }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let owner = connection.effectiveUserIdentifier
        guard owner > 0 else { return false }
        // This is checked by XPC against the live peer, avoiding PID reuse and
        // path lookup races. Enforce it BEFORE resume or accepting any message.
        connection.setCodeSigningRequirement(ServicePolicy.appRequirement)
        let endpoint = Endpoint(controller: controller, connection: connection, owner: owner)
        connection.exportedInterface = NSXPCInterface(with: HelperServiceProtocol.self)
        connection.exportedObject = endpoint
        connection.remoteObjectInterface = NSXPCInterface(with: HelperEventProtocol.self)
        connection.invalidationHandler = { endpoint.invalidated() }
        connection.interruptionHandler = { endpoint.invalidated(); connection.invalidate() }
        connection.resume()
        return true
    }

    private final class Endpoint: NSObject, HelperServiceProtocol {
        let id = UUID()
        let owner: uid_t
        let controller: HelperSessionController
        weak var connection: NSXPCConnection?
        private let lock = NSLock()
        private var closed = false
        init(controller: HelperSessionController, connection: NSXPCConnection, owner: uid_t) {
            self.controller = controller; self.connection = connection; self.owner = owner
        }
        func invalidated() {
            lock.lock(); closed = true; lock.unlock()
            controller.close(id: id)
        }
        func status(withReply reply: @escaping (Data?, String?) -> Void) {
            controller.status { status in reply(try? JSONEncoder().encode(status), nil) }
        }
        func openSession(_ identity: Data, withReply reply: @escaping (String?) -> Void) {
            // Invalidation and enqueueing open must be ordered, otherwise a
            // delayed open could allocate a tunnel lease for a dead peer.
            lock.lock(); defer { lock.unlock() }
            guard !closed else { reply("助手连接已关闭。"); return }
            do {
                let identity = try HelperWire.decode(HelperIdentity.self, from: identity)
                controller.open(id: id, owner: owner, identity: identity, event: { [weak self] event in
                    guard let self, let connection = self.connection,
                          let data = try? JSONEncoder().encode(event), data.count <= HelperWire.maximumBytes else { return }
                    let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.invalidated() } as? HelperEventProtocol
                    proxy?.receiveEvent(data)
                }, reply: reply)
            } catch { reply("助手握手参数无效。") }
        }
        func sendCommand(_ command: Data, withReply reply: @escaping (String?) -> Void) {
            controller.send(id: id, data: command, reply: reply)
        }
        func closeSession(withReply reply: @escaping (String?) -> Void) {
            controller.close(id: id) { reply(nil) }
        }
        func retireLegacyAuthorization(withReply reply: @escaping (String?) -> Void) { controller.migrate(reply: reply) }
    }
}

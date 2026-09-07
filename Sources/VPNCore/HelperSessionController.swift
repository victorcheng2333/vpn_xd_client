import Foundation

public protocol HelperTunnel: AnyObject {
    func start(profile: VPNProfile, password: String)
    func reconnect()
    func stop(completion: (() -> Void)?)
}
extension TunnelEngine: HelperTunnel {}

/// Serialize ownership separately from TunnelEngine's worker queue. A lost
/// connection cannot release the lease until the engine's stop callback fires.
public final class HelperSessionController {
    private final class Session {
        let id: UUID
        let engine: HelperTunnel
        var resources: [AnyObject]
        var closing = false
        var completions: [() -> Void] = []
        init(id: UUID, engine: HelperTunnel, resources: [AnyObject]) {
            self.id = id; self.engine = engine; self.resources = resources
        }
    }
    private let queue = DispatchQueue(label: "com.xd.vpn.xpc.sessions")
    private let identity: HelperIdentity
    private let validate: () throws -> Void
    private let legacyPresent: () -> Bool
    private let retireLegacy: () throws -> Void
    private let acquire: (uid_t) throws -> [AnyObject]
    private let makeEngine: (uid_t, @escaping (HelperEvent) -> Void) throws -> HelperTunnel
    private var session: Session?
    private var shuttingDown = false

    public init(identity: HelperIdentity, validate: @escaping () throws -> Void,
                legacyPresent: @escaping () -> Bool, retireLegacy: @escaping () throws -> Void,
                acquire: @escaping (uid_t) throws -> [AnyObject],
                makeEngine: @escaping (uid_t, @escaping (HelperEvent) -> Void) throws -> HelperTunnel) {
        self.identity = identity; self.validate = validate; self.legacyPresent = legacyPresent
        self.retireLegacy = retireLegacy; self.acquire = acquire; self.makeEngine = makeEngine
    }

    public func status(_ reply: @escaping (HelperServiceStatus) -> Void) {
        queue.async { reply(HelperServiceStatus(identity: self.identity, legacyAuthorization: self.legacyPresent(), busy: self.session != nil)) }
    }

    public func open(id: UUID, owner: uid_t, identity: HelperIdentity,
                     event: @escaping (HelperEvent) -> Void, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                guard owner > 0, identity == self.identity else { throw VPNError.unavailable("助手与 App 构建不匹配，请重新注册系统助手。") }
                guard !self.shuttingDown, self.session == nil else { throw VPNError.unavailable("已有 VPN 会话或清理正在进行，请稍后重试。") }
                try self.validate()
                guard !self.legacyPresent() else { throw VPNError.unavailable("请先在系统授权中迁移旧版授权，再使用新服务连接。") }
                let resources = try self.acquire(owner)
                let engine = try self.makeEngine(owner, event)
                self.session = Session(id: id, engine: engine, resources: resources)
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    public func send(id: UUID, data: Data, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let session = self.session, session.id == id, !session.closing, !self.shuttingDown else {
                reply("没有可用的助手会话。"); return
            }
            do {
                let command = try HelperWire.command(from: data)
                switch command.kind {
                case .connect:
                    try self.validate()
                    session.engine.start(profile: command.profile!, password: command.password!)
                case .disconnect: session.engine.stop(completion: nil)
                case .reconnect: session.engine.reconnect()
                case .shutdown: self.closeLocked(id: id) { reply(nil) }; return
                }
                reply(nil)
            } catch { reply("助手拒绝无效命令或已改变的应用组件。") }
        }
    }

    public func close(id: UUID, completion: @escaping () -> Void = {}) {
        queue.async { self.closeLocked(id: id, completion: completion) }
    }
    private func closeLocked(id: UUID, completion: @escaping () -> Void) {
        guard let session, session.id == id else { completion(); return }
        session.completions.append(completion)
        guard !session.closing else { return }
        session.closing = true
        session.engine.stop { [self] in
            queue.async {
                guard self.session === session else { return }
                self.session = nil
                // Release leases explicitly even if a stop completion remains
                // retained by a transport or engine implementation.
                session.resources.removeAll()
                session.completions.forEach { $0() }
                session.completions.removeAll()
            }
        }
    }

    public func migrate(reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                guard self.session == nil, !self.shuttingDown else { throw VPNError.unavailable("请先断开 VPN 并等待清理结束。") }
                try self.validate(); try self.retireLegacy(); reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    public func shutdown(completion: @escaping () -> Void) {
        queue.async {
            self.shuttingDown = true
            if let session = self.session { self.closeLocked(id: session.id, completion: completion) }
            else { completion() }
        }
    }
}

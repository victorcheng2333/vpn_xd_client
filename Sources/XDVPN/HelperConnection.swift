import Foundation
import VPNCore

private final class XPCReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}

@MainActor final class HelperConnection {
    private final class Events: NSObject, HelperEventProtocol {
        let receive: (Data) -> Void
        init(receive: @escaping (Data) -> Void) { self.receive = receive }
        func receiveEvent(_ event: Data) { receive(event) }
    }
    private let connection: NSXPCConnection
    var onEvent: ((HelperEvent) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init() {
        connection = NSXPCConnection(machServiceName: ServicePolicy.machService, options: .privileged)
        connection.setCodeSigningRequirement(ServicePolicy.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: HelperEventProtocol.self)
        connection.exportedObject = Events { [weak self] data in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                guard let event = try? HelperWire.decode(HelperEvent.self, from: data) else { self.fail(); return }
                self.onEvent?(event)
            }
        }
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.fail() } }
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.fail() } }
        connection.resume()
    }
    private func fail() {
        guard !closed else { return }
        close(); onClose?()
    }
    func close() {
        closed = true
        connection.invalidate()
    }
    deinit { connection.invalidate() }

    private func request<T: Sendable>(timeout: TimeInterval = 8,
                            _ invoke: (HelperServiceProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        guard !closed else { throw VPNError.unavailable("系统助手连接已关闭。") }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReply<T>(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                reply.finish(.failure(VPNError.unavailable("系统助手响应超时，请检查系统授权。")))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                reply.finish(.failure(VPNError.unavailable("无法连接可信系统助手，请检查系统授权或重新注册。")))
            }) as? HelperServiceProtocol else {
                reply.finish(.failure(VPNError.unavailable("系统助手接口不可用。"))); return
            }
            invoke(proxy) { reply.finish($0) }
        }
    }
    func status() async throws -> HelperServiceStatus {
        let data: Data = try await request { proxy, finish in
            proxy.status { data, error in
                if let data, error == nil { finish(.success(data)) }
                else { finish(.failure(VPNError.unavailable(error ?? "无法读取助手状态。"))) }
            }
        }
        return try HelperWire.decode(HelperServiceStatus.self, from: data)
    }
    func open(identity: HelperIdentity) async throws {
        let data = try JSONEncoder().encode(identity)
        let _: Bool = try await request { proxy, finish in
            proxy.openSession(data) { error in
                if let error { finish(.failure(VPNError.unavailable(error))) } else { finish(.success(true)) }
            }
        }
    }
    func migrate() async throws {
        let _: Bool = try await request(timeout: 30) { proxy, finish in
            proxy.retireLegacyAuthorization { error in
                if let error { finish(.failure(VPNError.unavailable(error))) } else { finish(.success(true)) }
            }
        }
    }
    func send(_ command: HelperCommand) throws {
        guard !closed else { throw VPNError.unavailable("系统助手连接已关闭。") }
        let data = try JSONEncoder().encode(command)
        _ = try HelperWire.command(from: data)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            Task { @MainActor in self?.fail() }
        }) as? HelperServiceProtocol else { throw VPNError.unavailable("系统助手接口不可用。") }
        proxy.sendCommand(data) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.onEvent?(.init(.failure, error)); self.fail()
            }
        }
    }
}

import Foundation
import VPNCore

@MainActor protocol HelperControlling: AnyObject {
    var onEvent: ((HelperEvent) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isReady: Bool { get }
    func prepare() async throws
    func send(_ command: HelperCommand) throws
    func shutdown()
}

@MainActor final class HelperBridge: HelperControlling {
    private var connection: HelperConnection?
    private var generation = UUID()
    private(set) var isReady = false
    var onEvent: ((HelperEvent) -> Void)?
    var onClose: (() -> Void)?

    func prepare() async throws {
        if isReady { return }
        guard await PrivilegeManager.status() == .ready else {
            throw VPNError.unavailable("请在连接页按提示启用并批准系统服务。")
        }
        try Task.checkCancellation()
        let identity = try HelperIdentity.read(bundle: Bundle.main.bundleURL)
        let current = UUID(); generation = current
        let connection = HelperConnection()
        self.connection = connection
        connection.onEvent = { [weak self] event in
            guard self?.generation == current else { return }
            self?.onEvent?(event)
        }
        connection.onClose = { [weak self] in
            guard let self, self.generation == current else { return }
            self.shutdown(); self.onClose?()
        }
        do {
            try await connection.open(identity: identity)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            isReady = true
        } catch {
            connection.close()
            if generation == current { shutdown() }
            throw error
        }
    }
    func send(_ command: HelperCommand) throws {
        guard isReady, let connection else { throw VPNError.unavailable("系统助手未连接。") }
        try connection.send(command)
    }
    func shutdown() {
        generation = UUID(); isReady = false
        // Invalidation is a cleanup request. The daemon retains ownership and
        // finishes TunnelEngine.stop independently of the UI's lifetime.
        connection?.close(); connection = nil
    }
}

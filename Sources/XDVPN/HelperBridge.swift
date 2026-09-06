import Foundation
import VPNCore
import Darwin

private final class ConnectionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    let continuation: CheckedContinuation<LocalSocket, Error>
    init(_ continuation: CheckedContinuation<LocalSocket, Error>) { self.continuation = continuation }
    func finish(_ result: Result<LocalSocket, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !resolved else { if case .success(let socket) = result { socket.close() }; return }
        resolved = true
        continuation.resume(with: result)
    }
}

@MainActor protocol HelperControlling: AnyObject {
    var onEvent: ((HelperEvent) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isReady: Bool { get }
    func prepare() async throws
    func send(_ command: HelperCommand) throws
    func shutdown()
}

@MainActor final class HelperBridge: HelperControlling {
    private var socket: LocalSocket?
    private var listener: LocalSocket?
    private var helperProcess: Process?
    private var directory: String?
    private var session = UUID()
    var onEvent: ((HelperEvent) -> Void)?
    var onClose: (() -> Void)?
    var isReady: Bool { socket != nil }

    func prepare() async throws {
        if isReady { return }
        let generation = UUID(); session = generation
        let privilege = await PrivilegeManager.status()
        if privilege == .needsUpdate {
            throw VPNError.unavailable("已有系统授权仍有效，请在「系统授权」升级系统助手，以安装本版内置连接引擎。")
        }
        guard privilege == .ready else {
            throw VPNError.unavailable("请先在「系统授权」中安装一次授权，之后打开应用和自动重连都不会再弹出管理员密码框。")
        }
        try Task.checkCancellation()
        guard session == generation else { throw CancellationError() }
        var template = Array("/private/tmp/xdvpn-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw VPNError.system("无法创建权限助手通信目录。") }
        let folder = String(cString: created)
        directory = folder
        let path = folder + "/control.sock"
        let listener = try LocalSocket.listener(path: path)
        self.listener = listener
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "--", PrivilegePolicy.helperPath, "--session", path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        helperProcess = process
        do {
            let connection: LocalSocket = try await withCheckedThrowingContinuation { continuation in
                let result = ConnectionResult(continuation)
                process.terminationHandler = { child in
                    guard child.terminationStatus != 0 else { return }
                    _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    result.finish(.failure(VPNError.system("无法启动权限助手，请在「系统授权」中重新检测或更新授权。")))
                    listener.close()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do { result.finish(.success(try listener.accept(expectedUID: 0, timeout: 8_000))) }
                    catch { result.finish(.failure(error)) }
                }
                do { try process.run() }
                catch { listener.close(); result.finish(.failure(error)) }
            }
            guard session == generation else { connection.close(); throw CancellationError() }
            socket = connection
            listener.close(); self.listener = nil
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    while let event = try connection.receive(HelperEvent.self) {
                        DispatchQueue.main.async { [weak self] in
                            guard self?.session == generation else { return }
                            self?.onEvent?(event)
                        }
                    }
                } catch { /* Treat malformed output as loss of the helper. */ }
                DispatchQueue.main.async { [weak self] in
                    guard self?.session == generation else { return }
                    self?.cleanup(); self?.onClose?()
                }
            }
        } catch {
            if session == generation { cleanup() }
            throw error
        }
    }

    func send(_ command: HelperCommand) throws {
        guard let socket else { throw VPNError.unavailable("权限助手未连接，请重新连接 VPN。") }
        try socket.send(command)
    }

    func shutdown() {
        try? socket?.send(HelperCommand(.shutdown))
        cleanup()
    }

    private func cleanup() {
        session = UUID()
        socket?.close(); socket = nil
        listener?.close(); listener = nil
        // EOF instructs the root helper to clean up its tunnel. Terminating sudo
        // here would also kill that helper before it can restore the routes.
        helperProcess = nil
        if let directory {
            try? FileManager.default.removeItem(atPath: directory + "/control.sock")
            try? FileManager.default.removeItem(atPath: directory)
        }
        directory = nil
    }

}

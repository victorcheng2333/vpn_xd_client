import Foundation
import Darwin

/// Owns exactly one foreground OpenConnect child and its network-state journal.
/// No global process searches, detached VPN processes or user-selected scripts.
public final class TunnelEngine {
    private let queue = DispatchQueue(label: "com.xd.vpn.engine")
    private let executable: String
    private let emit: (HelperEvent) -> Void
    private let networkSessionFactory: (() throws -> TunnelNetworkSession)?
    private var networkSession: TunnelNetworkSession?
    private var cleanupBlocked = false
    private var cleanupProcessID: Int32?
    private var stopSignalled = false
    private let stopGrace: TimeInterval
    private let killGrace: TimeInterval
    private var process: Process?
    private var requestedStop = false
    private var fatalFailure = false
    private var established = false
    private var transportFailure = false
    private var stopCallbacks: [() -> Void] = []

    public init(executable: String, networkSessionFactory: (() throws -> TunnelNetworkSession)? = nil,
                stopGrace: TimeInterval = 8, killGrace: TimeInterval = 40,
                emit: @escaping (HelperEvent) -> Void) {
        self.executable = executable; self.emit = emit
        self.networkSessionFactory = networkSessionFactory
        self.stopGrace = stopGrace; self.killGrace = killGrace
    }

    public func start(profile: VPNProfile, password: String) {
        queue.async { self.startLocked(profile: profile, password: password) }
    }

    private func startLocked(profile: VPNProfile, password: String) {
        guard process == nil else { return }
        if cleanupBlocked {
            guard let session = networkSession, let pid = cleanupProcessID else { return }
            do {
                try session.cleanup(processID: pid)
                try session.finish()
                networkSession = nil; cleanupProcessID = nil; cleanupBlocked = false
                emit(.init(.info, "上次网络清理已通过核对，继续连接。"))
            } catch {
                emit(.init(.failure, session.cleanupFailureMessage()))
                emit(.init(.stopped, "未启动新隧道：上次网络清理尚未通过核对。"))
                return
            }
        }
        do {
            try OpenConnect.validatePassword(password)
            var args = try OpenConnect.arguments(profile: profile)
            networkSession = try networkSessionFactory?()
            if networkSession != nil {
                // Fixed root-owned wrapper; never accept a script from the UI.
                args.insert("--script=\(PrivilegePolicy.helperPath) --network-script", at: 0)
            }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = args
            // A known environment also prevents inherited proxy/loader variables.
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": "C", "LC_ALL": "C", "HOME": "/var/root"]
            if let networkSession { child.environment?[TunnelNetworkSession.environmentKey] = networkSession.directory }
            child.currentDirectoryURL = URL(fileURLWithPath: "/")
            let input = Pipe(), output = Pipe()
            child.standardInput = input
            child.standardOutput = output
            child.standardError = output
            requestedStop = false; fatalFailure = false; established = false; transportFailure = false; stopSignalled = false
            try child.run()
            process = child
            emit(.init(.connecting, "正在验证身份并建立加密隧道。"))
            // Only stdin receives the password. It is never retained by the engine.
            do { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8)) }
            catch { /* The child's output and exit status explain early rejection. */ }
            try? input.fileHandleForWriting.close()

            DispatchQueue.global(qos: .utility).async {
                var pending = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let end = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending.prefix(upTo: end), as: UTF8.self)
                        pending.removeSubrange(...end)
                        self.queue.sync { if self.process === child { self.consume(line, child: child) } }
                    }
                    // Don't retain arbitrary, unbounded server responses.
                    if pending.count > 16_384 { pending.removeAll(keepingCapacity: true) }
                }
                if !pending.isEmpty {
                    let line = String(decoding: pending, as: UTF8.self)
                    self.queue.sync { if self.process === child { self.consume(line, child: child) } }
                }
                child.waitUntilExit()
                try? output.fileHandleForReading.close()
                self.queue.async { self.finished(child) }
            }
            queue.asyncAfter(deadline: .now() + 90) {
                guard self.process === child, !self.established, !self.requestedStop else { return }
                self.emit(.init(.info, "连接超时，请确认当前网络可以访问 VPN 服务器。"))
                self.signalStop(child)
            }
        } catch {
            try? networkSession?.finish(); networkSession = nil
            emit(.init(.failure, error.localizedDescription))
            emit(.init(.stopped, "连接未启动。"))
        }
    }

    private func consume(_ line: String, child: Process) {
        if EngineOutput.isTransportFailure(line) { transportFailure = true }
        // OpenConnect also prints this generic authentication epilogue after DNS
        // or TCP failure. Known transport errors remain retryable, while unknown
        // authentication failures conservatively stop to avoid account lockout.
        if line.lowercased().contains("failed to obtain webvpn cookie"), transportFailure, !fatalFailure {
            emit(.init(.info, "暂时无法访问 VPN 服务器。"))
            return
        }
        guard let event = EngineOutput.event(for: line, tunnelConfigured: established) else { return }
        if requestedStop && event.message == EngineOutput.networkConfigurationFailureMessage {
            // A failed route command during an explicit stop is not a failed
            // login. Native cleanup below decides whether stopping succeeded.
            emit(.init(.info, "断开脚本未完成，将由权限助手核对本次网络配置。"))
            return
        }
        if event.kind == .failure {
            guard !fatalFailure else { return }
            fatalFailure = true
            emit(event)
            signalStop(child)
        } else if !requestedStop && !stopSignalled && !fatalFailure {
            if event.kind == .connected { established = true; transportFailure = false }
            emit(event)
        }
    }

    private func finished(_ child: Process) {
        guard process === child else { return }
        let hadRecord = networkSession?.hasTunnelRecord == true
        if let networkSession {
            do {
                let removed = try networkSession.cleanup(processID: child.processIdentifier)
                try networkSession.finish()
                self.networkSession = nil; cleanupProcessID = nil
                if removed > 0 { emit(.init(.info, "权限助手已清除本次隧道残留的路由服务与 DNS 配置。")) }
            } catch {
                cleanupBlocked = true; fatalFailure = true
                cleanupProcessID = child.processIdentifier
                emit(.init(.failure, networkSession.cleanupFailureMessage()))
            }
        }
        process = nil
        let normal = requestedStop
        let message = cleanupBlocked ? "VPN 进程已退出，但网络清理核对失败。" :
            "VPN 进程已结束（\(child.terminationStatus)）。" + (hadRecord ? "本次隧道的 IPv4/DNS 状态已清理。" : "")
        emit(.init(.stopped, message, retryable: !normal && !fatalFailure))
        let callbacks = stopCallbacks; stopCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    private func signalStop(_ child: Process) {
        guard child.isRunning, !stopSignalled else { return }
        stopSignalled = true
        // Process.interrupt/terminate can signal the entire process group on
        // macOS. Send only to our OpenConnect PID, preserving its script tree.
        kill(child.processIdentifier, SIGINT)
        queue.asyncAfter(deadline: .now() + stopGrace) {
            if self.process === child && child.isRunning { kill(child.processIdentifier, SIGTERM) }
        }
        queue.asyncAfter(deadline: .now() + killGrace) {
            if self.process === child && child.isRunning {
                self.emit(.init(.info, "VPN 进程未响应停止，将结束该进程并核对本次网络配置。"))
                kill(child.processIdentifier, SIGKILL)
            }
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        queue.async {
            guard let child = self.process else { completion?(); return }
            if let completion { self.stopCallbacks.append(completion) }
            self.requestedStop = true
            self.signalStop(child)
        }
    }

    public func reconnect() {
        queue.async {
            guard let child = self.process, child.isRunning, self.established,
                  !self.requestedStop, !self.stopSignalled, !self.fatalFailure else { return }
            kill(child.processIdentifier, SIGUSR2)
            self.emit(.init(.reconnecting, "网络已变化，正在重新建立隧道。", retryable: true))
        }
    }
}

import Foundation
import Darwin

/// Owns exactly one foreground OpenConnect child. No PID files, global process
/// searches, shell commands, detached VPN processes or user-controlled scripts.
public final class TunnelEngine {
    private let queue = DispatchQueue(label: "com.xd.vpn.engine")
    private let executable: String
    private let emit: (HelperEvent) -> Void
    private var process: Process?
    private var requestedStop = false
    private var fatalFailure = false
    private var established = false
    private var transportFailure = false
    private var stopCallbacks: [() -> Void] = []

    public init(executable: String, emit: @escaping (HelperEvent) -> Void) {
        self.executable = executable; self.emit = emit
    }

    public func start(profile: VPNProfile, password: String) {
        queue.async { self.startLocked(profile: profile, password: password) }
    }

    private func startLocked(profile: VPNProfile, password: String) {
        guard process == nil else { return }
        do {
            try OpenConnect.validatePassword(password)
            let args = try OpenConnect.arguments(profile: profile)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = args
            // A known environment also prevents inherited proxy/loader variables.
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": "C", "LC_ALL": "C", "HOME": "/var/root"]
            child.currentDirectoryURL = URL(fileURLWithPath: "/")
            let input = Pipe(), output = Pipe()
            child.standardInput = input
            child.standardOutput = output
            child.standardError = output
            requestedStop = false; fatalFailure = false; established = false; transportFailure = false
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
                child.interrupt()
                self.escalateStop(child)
            }
        } catch {
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
        if event.kind == .failure {
            guard !fatalFailure else { return }
            fatalFailure = true
            emit(event)
            if child.isRunning { child.interrupt(); escalateStop(child) }
        } else if !requestedStop && !fatalFailure {
            if event.kind == .connected { established = true; transportFailure = false }
            emit(event)
        }
    }

    private func finished(_ child: Process) {
        guard process === child else { return }
        process = nil
        let normal = requestedStop
        emit(.init(.stopped, normal ? "已断开，系统网络配置已交还 OpenConnect 清理。" : "VPN 进程已结束（\(child.terminationStatus)）。", retryable: !normal && !fatalFailure))
        let callbacks = stopCallbacks; stopCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    private func escalateStop(_ child: Process) {
        queue.asyncAfter(deadline: .now() + 8) {
            if self.process === child && child.isRunning { child.terminate() }
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        queue.async {
            guard let child = self.process else { completion?(); return }
            if let completion { self.stopCallbacks.append(completion) }
            self.requestedStop = true
            if child.isRunning { child.interrupt(); self.escalateStop(child) }
        }
    }

    public func reconnect() {
        queue.async {
            guard let child = self.process, child.isRunning, self.established, !self.requestedStop else { return }
            kill(child.processIdentifier, SIGUSR2)
            self.emit(.init(.reconnecting, "网络已变化，正在重新建立隧道。", retryable: true))
        }
    }
}

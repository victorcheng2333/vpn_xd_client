import Foundation
import VPNCore
import Darwin
import OSLog

// This root-owned binary is the only executable named in the dedicated sudoers
// rule. It accepts no custom executable, script, PID, installer or shell command.
if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
    print(PrivilegePolicy.version)
    exit(0)
}
// This internal mode is not in the sudoers rule. Only an already privileged
// OpenConnect child can use it, with a root-owned private session directory.
if CommandLine.arguments == [CommandLine.arguments[0], "--network-script"] {
    exit(ManagedNetworkScript.run(environment: ProcessInfo.processInfo.environment))
}
guard let owner = try? PrivilegePolicy.sessionOwner(arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment, effectiveUID: geteuid()) else { exit(64) }
signal(SIGPIPE, SIG_IGN)
let path = CommandLine.arguments[2]
let directory = (path as NSString).deletingLastPathComponent
var info = stat()
guard directory.hasPrefix("/private/tmp/xdvpn-"),
      lstat(directory, &info) == 0, info.st_uid == owner,
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0,
      lstat(path, &info) == 0, info.st_uid == owner,
      info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else { exit(65) }

do {
    let socket = try LocalSocket.connect(path: path, expectedUID: owner)
    let diagnosticLog = HelperDiagnosticLog(userID: owner)
    let deliveryLock = NSLock()
    var logFailed = false
    var socketFailed = false
    func deliver(_ event: HelperEvent) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        do { try diagnosticLog.append(event); logFailed = false }
        catch {
            if !logFailed {
                logFailed = true
                let warning = "助手本地日志写入失败：\(diagnosticLog.directory)。连接日志仍由 App 保存。"
                Logger(subsystem: "com.xd.vpn.helper", category: "diagnostics").error("\(warning, privacy: .public)")
                try? socket.send(HelperEvent(.info, warning, diagnostic: .init(source: .helper, code: "log.writeFailed", phase: "helper", level: .error)))
            }
        }
        do { try socket.send(event) }
        catch {
            // The app may already be gone; cleanup still has a durable sink.
            if !socketFailed {
                socketFailed = true
                let closed = HelperEvent(.info, "App 接收通道已关闭，助手继续保存退出和清理日志。",
                    diagnostic: .init(source: .helper, code: "channel.deliveryFailed", phase: "shutdown"))
                do { try diagnosticLog.append(closed) }
                catch { Logger(subsystem: "com.xd.vpn.helper", category: "diagnostics").error("App 通道与助手文件日志均不可用。") }
            }
        }
    }
    let lease: SessionLease
    do { lease = try SessionLease(path: "/private/var/run/com.xd.vpn.\(owner).lock") }
    catch {
        deliver(HelperEvent(.failure, error.localizedDescription))
        deliver(HelperEvent(.stopped, "权限助手未启动连接。"))
        exit(75)
    }
    defer { withExtendedLifetime(lease) {} }
    guard let executable = OpenConnect.executable else {
        deliver(HelperEvent(.failure, "未找到 OpenConnect。请先运行 brew install openconnect。"))
        exit(69)
    }
    let engine = TunnelEngine(executable: executable, networkSessionFactory: { try TunnelNetworkSession.create() }) {
        event in deliver(event)
    }
    deliver(HelperEvent(.ready, "权限助手已就绪。"))
    deliver(HelperEvent(.info, "助手日志：\(diagnosticLog.directory)/helper.jsonl", diagnostic: .init(source: .helper, code: "log.started", phase: "helper")))
    do {
        commandLoop: while let command = try socket.receive(HelperCommand.self) {
            switch command.kind {
            case .connect:
                guard let profile = command.profile, let password = command.password else { break commandLoop }
                engine.start(profile: profile, password: password)
            case .disconnect: engine.stop()
            case .reconnect: engine.reconnect()
            case .shutdown: break commandLoop
            }
        }
    } catch {
        deliver(HelperEvent(.info, "助手命令读取失败：\(error.localizedDescription)", diagnostic: .init(source: .helper, code: "channel.readFailed", phase: "shutdown", level: .error)))
    }
    deliver(HelperEvent(.info, "助手命令循环已结束，将继续清理本次连接。", diagnostic: .init(source: .helper, code: "channel.closed", phase: "shutdown")))
    let stopped = DispatchSemaphore(value: 0)
    engine.stop { stopped.signal() }
    // Keep ownership until OpenConnect runs its disconnect script, including if
    // the UI crashes. Never kill an unrelated process or abandon a child.
    stopped.wait()
    socket.close()
} catch { exit(70) }

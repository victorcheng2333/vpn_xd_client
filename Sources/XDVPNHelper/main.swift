import Foundation
import VPNCore
import Darwin

// This root-owned binary is the only executable named in the dedicated sudoers
// rule. It accepts no custom executable, script, PID, installer or shell command.
if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
    print(PrivilegePolicy.version)
    exit(0)
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
    let lease: SessionLease
    do { lease = try SessionLease(path: "/private/var/run/com.xd.vpn.\(owner).lock") }
    catch {
        try? socket.send(HelperEvent(.failure, error.localizedDescription))
        try? socket.send(HelperEvent(.stopped, "权限助手未启动连接。"))
        exit(75)
    }
    defer { withExtendedLifetime(lease) {} }
    guard let executable = OpenConnect.executable else {
        try socket.send(HelperEvent(.failure, "未找到 OpenConnect。请先运行 brew install openconnect。"))
        exit(69)
    }
    let engine = TunnelEngine(executable: executable) { event in try? socket.send(event) }
    try socket.send(HelperEvent(.ready, "权限助手已就绪。"))
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
    } catch { /* Closing a malformed or broken channel also cleans up the tunnel. */ }
    let stopped = DispatchSemaphore(value: 0)
    engine.stop { stopped.signal() }
    // Keep ownership until OpenConnect runs its disconnect script, including if
    // the UI crashes. Never kill an unrelated process or abandon a child.
    stopped.wait()
    socket.close()
} catch { exit(70) }

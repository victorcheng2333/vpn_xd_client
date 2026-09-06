import Foundation
import Darwin

/// Bound the only script tree we create ourselves. Ordinary OpenConnect stop
/// signals never target this group. If this script hangs, end its whole tree,
/// then the helper's native dynamic-store cleanup runs independently of it.
enum NetworkScriptRunner {
    enum Failure: Error { case timedOut }
    static func run(executable: String, environment: [String: String], timeout: TimeInterval = 15) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw VPNError.system("无法创建网络脚本。") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw VPNError.system("无法创建网络脚本。") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Create a separate group atomically, BEFORE any script code executes.
        // Keep only standard IO; do not leak the helper's sockets/descriptors.
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, "/") == 0 else {
            throw VPNError.system("无法隔离网络脚本进程组。")
        }
        let arguments = [strdup(executable), nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { arguments.forEach { free($0) }; variables.forEach { free($0) } }
        var pid: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { argv in
            variables.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard result == 0 else { throw VPNError.system("网络脚本无法启动（\(result)）。") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
            if waited < 0 && errno != EINTR { throw VPNError.system("无法确认网络脚本退出。") }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                // We have not reaped this child, so this group ID cannot have
                // been reused. End all script writers before native cleanup.
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw Failure.timedOut
            }
            usleep(20_000)
        }
    }
}

public enum ManagedNetworkScript {
    enum Reason: String { case preInit = "pre-init", connect, attemptReconnect = "attempt-reconnect", reconnect, disconnect }

    public static func run(environment: [String: String]) -> Int32 {
        do {
            let session = try TunnelNetworkSession.openForScript(environment: environment)
            guard let reason = environment["reason"].flatMap(Reason.init(rawValue:)),
                  let pid = environment["VPNPID"].flatMap(Int32.init), pid > 1 else {
                throw VPNError.system("网络脚本参数无效。")
            }
            guard let script = ["/opt/homebrew/etc/vpnc/vpnc-script", "/usr/local/etc/vpnc/vpnc-script"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw VPNError.unavailable("未找到 vpnc-script。")
            }
            return execute(reason: reason, session: session, environment: environment, processID: pid,
                parentExited: { kill(pid, 0) != 0 && errno == ESRCH },
                runScript: { try NetworkScriptRunner.run(executable: session.managedScript(source: script), environment: environment) },
                diagnostic: { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) })
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("XDVPN network script failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // Keep phase handling injectable: tests exercise the wrapper itself, not
    // just the watchdog followed by an unrelated manual cleanup call.
    static func execute(reason: Reason, session: TunnelNetworkSession, environment: [String: String],
                        processID: Int32, parentExited: () -> Bool, runScript: () throws -> Int32,
                        diagnostic: (String) -> Void) -> Int32 {
        defer { withExtendedLifetime(session) {} } // Hold the script's journal lease through the watchdog and final verification.
        diagnostic("XDVPN hook begin phase=\(reason.rawValue) pid=\(processID)")
        if reason == .connect {
            do { try session.claim(environment: environment) }
            catch let conflict as TunnelNetworkSession.ClaimConflict {
                diagnostic("XDVPN claim conflict " + conflict.interface)
                return 1
            } catch {
                diagnostic("XDVPN tunnel identity rejected")
                return 1
            }
        }
        if reason == .connect || reason == .attemptReconnect || reason == .reconnect {
            do { try session.prepareServerRoute(environment: environment, diagnostic: diagnostic) }
            catch RouteFailure.unavailable where reason != .connect {
                diagnostic("XDVPN route deferred phase=\(reason.rawValue): physical route unavailable")
                return 0
            } catch {
                diagnostic("XDVPN route configuration failed phase=\(reason.rawValue): \(error.localizedDescription)")
                return 1
            }
        }
        if reason == .disconnect {
            // Release the dead resolver before route(8) can block on DNS.
            // Keep our ownership marker until all script writers have stopped.
            // A failed first pass must not prevent the normal script cleanup.
            do { try session.cleanup(processID: processID, afterExit: parentExited(), keepMarker: true, diagnostic: diagnostic) }
            catch { diagnostic("XDVPN preliminary cleanup failed: \(error.localizedDescription)") }
        }
        var code: Int32 = 1
        do {
            code = try runScript()
            diagnostic("XDVPN hook exited phase=\(reason.rawValue) status=\(code)")
        }
        catch NetworkScriptRunner.Failure.timedOut {
            diagnostic("XDVPN hook timeout phase=\(reason.rawValue) budget=15s")
            if reason == .attemptReconnect || reason == .reconnect {
                // OpenConnect can continue its own reconnect loop. Returning an
                // error here produces a generic fatal-looking "Script ... error".
                diagnostic("XDVPN hook deferred " + reason.rawValue)
                return 0
            }
        } catch { diagnostic("XDVPN hook launch failed phase=\(reason.rawValue): \(error.localizedDescription)") }
        if reason == .connect && code == 0 {
            do {
                try session.configureIPv4Service(environment: environment)
                diagnostic("XDVPN IPv4 service verified pid=\(processID)")
            } catch {
                diagnostic("XDVPN IPv4 service configuration failed: \(error.localizedDescription)")
                code = 1
            }
        }
        if reason == .disconnect || (reason == .connect && code != 0) {
            do { try session.cleanup(processID: processID, afterExit: parentExited(), diagnostic: diagnostic) }
            catch {
                diagnostic("XDVPN cleanup detail: \(error.localizedDescription)")
                diagnostic("XDVPN cleanup verification failed")
                return 1
            }
            if reason == .disconnect {
                diagnostic("XDVPN route and service cleanup verified pid=\(processID)")
                if code != 0 { diagnostic("XDVPN disconnect cleanup confirmed") }
                return 0
            }
        }
        return code
    }
}

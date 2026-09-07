import Foundation
import VPNCore
import Darwin
import OSLog

if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
    print("9")
    exit(0)
}
guard geteuid() == 0 else { exit(77) }
if CommandLine.arguments == [CommandLine.arguments[0], "--network-script"] {
    exit(ManagedNetworkScript.run(environment: ProcessInfo.processInfo.environment))
}
// launchd starts the daemon without user-supplied arguments. The old sudo
// --session entry point is deliberately absent.
guard CommandLine.arguments.count == 1 else { exit(64) }
signal(SIGPIPE, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

do {
    let bundle = try ServiceBundle.runningHelper()
    let runtime = try ServiceRuntime(source: bundle)
    let legacy = LegacyAuthorization()
    let controller = HelperSessionController(identity: bundle.identity, validate: { try bundle.revalidate() },
        legacyPresent: { legacy.isPresent }, retireLegacy: { try legacy.retire() },
        acquire: { owner in
            [try SessionLease(path: "/private/var/run/com.xd.vpn.service.lock", timeout: 0),
             try SessionLease(path: "/private/var/run/com.xd.vpn.\(owner).lock", timeout: 0)]
        }, makeEngine: { owner, event in
            let log = HelperDiagnosticLog(userID: owner)
            let logLock = NSLock()
            var logFailed = false
            return TunnelEngine(executable: runtime.bundle.engine, networkSessionFactory: { try TunnelNetworkSession.create() },
                networkScriptHelper: runtime.bundle.helper) { value in
                logLock.lock()
                var warn = false
                do { try log.append(value); logFailed = false }
                catch {
                    warn = !logFailed; logFailed = true
                    Logger(subsystem: "com.xd.vpn.helper", category: "diagnostics").error("Helper log write failed")
                }
                logLock.unlock()
                if warn {
                    event(.init(.info, "助手本地日志写入失败，App 仍保留连接日志。", diagnostic: .init(source: .helper, code: "log.writeFailed", phase: "helper", level: .error)))
                }
                event(value)
            }
        })
    let delegate = HelperXPCListener(controller: controller)
    let listener = NSXPCListener(machServiceName: ServicePolicy.machService)
    listener.delegate = delegate
    let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            listener.suspend()
            controller.shutdown { runtime.removeAfterShutdown(); exit(0) }
        }
        source.resume()
        return source
    }
    listener.resume()
    withExtendedLifetime((delegate, signals, runtime)) { dispatchMain() }
} catch {
    Logger(subsystem: "com.xd.vpn.helper", category: "startup").error("Service validation failed: \(error.localizedDescription, privacy: .public)")
    exit(78)
}

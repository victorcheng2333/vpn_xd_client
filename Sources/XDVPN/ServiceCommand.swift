import Foundation
import VPNCore

/// Explicit diagnostics bypass all UI/model initialization: these commands
/// never load VPN credentials, resume a saved connection or modify routes.
@MainActor enum ServiceCommand {
    static func run(_ action: String) async -> Int32 {
        do {
            switch action {
            case "register": try await PrivilegeManager.install()
            case "unregister": try await PrivilegeManager.uninstall()
            case "migrate": try await PrivilegeManager.migrate()
            case "status": break
            case "probe":
                let connection = HelperConnection(); defer { connection.close() }
                let remote = try await connection.status()
                guard remote.identity == (try HelperIdentity.read(bundle: Bundle.main.bundleURL)) else {
                    throw VPNError.unavailable("运行中的服务与当前应用不匹配。")
                }
                print("Trusted XPC service responded: matching build, busy=\(remote.busy), legacyAuthorization=\(remote.legacyAuthorization). No VPN connection started.")
            case "verify-bundle":
                let bundle = try ServiceBundle(url: Bundle.main.bundleURL)
                try ServiceRuntime.verifyCopy(source: bundle)
                print("Company signature, hardened runtime, bundled service and sealed runtime copy verified.")
            case "smoke": try await smoke()
            default: throw VPNError.invalidProfile("Unknown service command")
            }
            print("System service: \(await PrivilegeManager.status().title)")
            return 0
        } catch {
            fputs("System service: \(error.localizedDescription)\n", stderr)
            let detail = error as NSError
            fputs("Error domain: \(detail.domain), code: \(detail.code)\n", stderr)
            return 1
        }
    }
    private static func smoke() async throws {
        let identity = try HelperIdentity.read(bundle: Bundle.main.bundleURL)
        let owner = HelperConnection(), observer = HelperConnection()
        defer { owner.close(); observer.close() }
        let initial = try await observer.status()
        guard initial.identity == identity, !initial.busy else { throw VPNError.unavailable("服务版本不匹配或已有会话，未运行诊断。") }
        try await owner.open(identity: identity)
        var rejected = false
        do { try await observer.open(identity: identity) } catch { rejected = true }
        guard rejected else { throw VPNError.system("Duplicate session was accepted") }
        // Empty-session close exercises ownership cleanup without starting an engine.
        owner.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await observer.status().busy {
            guard ContinuousClock.now < deadline else { throw VPNError.system("Session cleanup timed out") }
            try await Task.sleep(for: .milliseconds(25))
        }
        let wrong = HelperIdentity(build: identity.build + "-mismatch", bundlePath: identity.bundlePath)
        rejected = false
        do { try await observer.open(identity: wrong) } catch { rejected = true }
        guard rejected else { throw VPNError.system("Mismatched build was accepted") }
        try await observer.open(identity: identity)
        observer.close()
        print("XPC verified: company peer, matching build, exclusive session, disconnect cleanup, stale-build rejection. No VPN connection started.")
    }
}

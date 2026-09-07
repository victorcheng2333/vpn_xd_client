import Foundation
import ServiceManagement
import VPNCore

enum PrivilegeStatus: Equatable {
    case checking, notInstalled, ready, needsUpdate, needsRepair, requiresApproval, needsMigration, invalidSignature, moveToApplications
    var title: String {
        switch self {
        case .checking: "正在检查系统服务"
        case .notInstalled: "尚未注册系统服务"
        case .ready: "系统服务已就绪"
        case .needsUpdate: "系统服务需要更新"
        case .needsRepair: "系统服务需要重新注册"
        case .requiresApproval: "等待 macOS 批准"
        case .needsMigration: "新服务已就绪，旧授权待迁移"
        case .invalidSignature: "需要公司签名的完整应用"
        case .moveToApplications: "请先将应用移入 Applications"
        }
    }
    var actionTitle: String {
        switch self {
        case .checking: "正在检测…"
        case .invalidSignature, .moveToApplications: "重新检测"
        case .requiresApproval: "打开系统设置"
        case .needsMigration: "迁移旧版授权"
        case .notInstalled: "启用系统服务"
        default: "重新注册服务"
        }
    }
    var canRequestService: Bool { [.notInstalled, .requiresApproval, .needsMigration, .needsUpdate, .needsRepair].contains(self) }
    var canRemoveService: Bool { [.ready, .needsUpdate, .needsMigration, .requiresApproval, .needsRepair].contains(self) }
    var instructions: String {
        switch self {
        case .requiresApproval: "请在系统设置的「登录项与扩展」中允许 XD VPN 后台服务。返回应用后会自动检测。"
        case .needsMigration: "新服务已就绪。请先断开并退出旧版 XD VPN，再点击「迁移旧版授权」。原有 VPN 配置和密码会保留。"
        case .needsUpdate: "请先断开 VPN，再重新注册系统服务，使其与当前应用版本一致。"
        case .needsRepair: "请先断开并退出其他版本的 XD VPN。重新注册会停止旧服务、等待清理完成，再启用当前版本；若仍失败，请检查系统设置中的后台服务。"
        case .invalidSignature: "请重新下载公司签名并完成 Apple 公证的完整安装包。"
        case .moveToApplications: "请将应用拖入 Applications 文件夹，从该位置重新打开。"
        default: "首次连接前需要启用 VPN 系统服务，并在 macOS 系统设置中批准。日常连接无需重复授权。"
        }
    }
}

@MainActor struct PrivilegeAccess {
    var status: () async -> PrivilegeStatus
    var install: () async throws -> Void
    var migrate: () async throws -> Void
    var uninstall: () async throws -> Void
    static let live = PrivilegeAccess(status: { await PrivilegeManager.status() }, install: { try await PrivilegeManager.install() },
                                      migrate: { try await PrivilegeManager.migrate() }, uninstall: { try await PrivilegeManager.uninstall() })
}

@MainActor enum PrivilegeManager {
    private static var service: SMAppService { .daemon(plistName: ServicePolicy.plistName) }

    static func status() async -> PrivilegeStatus {
        guard supportedLocation(Bundle.main.bundleURL) else { return .moveToApplications }
        let identity: HelperIdentity
        do { identity = try ServiceBundle(url: Bundle.main.bundleURL).identity }
        catch { return .invalidSignature }
        let registration = registrationStatus(service.status)
        guard registration == .ready else { return registration }
        let connection = HelperConnection(); defer { connection.close() }
        do { return status(local: identity, remote: try await connection.status()) }
        catch { return .needsRepair }
    }

    static func supportedLocation(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath()
        return path.deletingLastPathComponent().path == "/Applications" && path.pathExtension == "app"
    }
    static func registrationStatus(_ status: SMAppService.Status) -> PrivilegeStatus {
        switch status {
        case .enabled: .ready
        case .notRegistered: .notInstalled
        case .requiresApproval: .requiresApproval
        case .notFound: .needsRepair
        @unknown default: .needsRepair
        }
    }
    static func status(local: HelperIdentity, remote: HelperServiceStatus) -> PrivilegeStatus {
        guard local == remote.identity else { return .needsUpdate }
        return remote.legacyAuthorization ? .needsMigration : .ready
    }

    static func install() async throws {
        guard supportedLocation(Bundle.main.bundleURL) else { throw VPNError.unavailable("请先将应用拖入 Applications，再启用系统服务。") }
        _ = try ServiceBundle(url: Bundle.main.bundleURL)
        let service = self.service
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
        if service.status == .enabled {
            let connection = HelperConnection(); defer { connection.close() }
            try await ServiceRegistration.unregisterForReplacement(checkBusy: { try await connection.status().busy },
                                                                   unregister: { try await service.unregister() })
            try await ServiceRegistration.registerAfterUnregister(status: { service.status }, register: { try service.register() })
        } else {
            try service.register()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static func migrate() async throws {
        guard await status() == .needsMigration else { throw VPNError.unavailable("请先启用并批准新系统服务。") }
        let connection = HelperConnection(); defer { connection.close() }
        try await connection.migrate()
    }

    static func uninstall() async throws {
        if service.status == .notRegistered { return }
        if service.status == .enabled {
            let connection = HelperConnection(); defer { connection.close() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(50))
            while try await connection.status().busy {
                guard ContinuousClock.now < deadline else { throw VPNError.unavailable("VPN 清理尚未结束，请稍后移除系统服务。") }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        // Async completion waits for termination before any later registration.
        try await service.unregister()
    }
}

@MainActor enum ServiceRegistration {
    /// Explicit user-requested replacement only; never used by status polling
    /// or auto-connect. Replacing an App can invalidate a still-running old
    /// helper's dynamic signature, so an authenticated status reply is not
    /// always available. In that case, use SMAppService's managed termination
    /// and await exit; do not relax XPC authentication or kill a PID directly.
    /// The daemon handles SIGTERM by stopping its engine and cleanup children
    /// before exit. A known active session continues to block replacement.
    static func unregisterForReplacement(checkBusy: () async throws -> Bool,
                                         unregister: () async throws -> Void) async throws {
        let busy: Bool?
        do { busy = try await checkBusy() }
        catch is CancellationError { throw CancellationError() }
        catch { busy = nil }
        try Task.checkCancellation()
        guard busy != true else { throw VPNError.unavailable("请先断开所有 XD VPN 会话，等待网络清理结束。") }
        try await unregister()
    }

    /// The async unregister callback waits for process exit, but macOS can
    /// briefly retain the disabled BTM disposition. Retry only that EPERM
    /// transition, after a successful unregister; never retry approval/signature
    /// failures or use another registration mechanism.
    static func registerAfterUnregister(
        status: () -> SMAppService.Status,
        register: () throws -> Void,
        waitForSync: () async throws -> Void = { try await Task.sleep(for: .milliseconds(750)) }
    ) async throws {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            if status() == .requiresApproval { return }
            do { try register(); return }
            catch {
                let current = status()
                if current == .requiresApproval { return }
                let failure = error as NSError
                // The SDK exports the domain constant only from macOS 15;
                // its stable string also supports the macOS 14 deployment.
                guard attempt < 3, current == .notRegistered,
                      [NSPOSIXErrorDomain, "SMAppServiceErrorDomain"].contains(failure.domain),
                      failure.code == Int(EPERM) else { throw error }
                try await waitForSync()
            }
        }
    }
}

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
        case .requiresApproval: "打开系统设置"
        case .needsMigration: "迁移旧版授权"
        case .notInstalled: "启用系统服务"
        default: "重新注册服务"
        }
    }
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
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
        if service.status == .enabled {
            let connection = HelperConnection(); defer { connection.close() }
            let remote = try await connection.status()
            guard !remote.busy else { throw VPNError.unavailable("请先断开所有 XD VPN 会话，等待网络清理结束。") }
            try await service.unregister()
        }
        try service.register()
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

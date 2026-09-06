import ServiceManagement
import SwiftUI

@MainActor final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var issue: String?

    private let service = SMAppService.mainApp

    init() {
        status = SMAppService.mainApp.status
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    var detail: String {
        switch status {
        case .enabled: "已开启，登录 Mac 后启动；配合「自动连接」即可自动连接 VPN。"
        case .requiresApproval: "等待系统允许，请在登录项中开启 XD VPN"
        case .notRegistered: "登录 Mac 后启动客户端；配合「自动连接」即可自动连接 VPN。"
        case .notFound: "登录项不可用，请将完整应用移至「应用程序」后重新打开"
        @unknown default: "无法读取登录项状态，请检查系统设置"
        }
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        issue = nil
        refresh()
        do {
            if enabled {
                if !isRequested { try service.register() }
            } else if isRequested {
                try service.unregister()
            }
        } catch {
            issue = "\(enabled ? "开启" : "关闭")开机自动启动失败：\(error.localizedDescription)"
        }
        // System approval can still be pending after a successful registration.
        // Read the actual state instead of persisting a separate preference.
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

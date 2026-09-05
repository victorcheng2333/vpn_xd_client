import SwiftUI

/// Maps VPN status to the colors, symbols and copy used across the UI.
struct StatusPresentation {
    let tint: Color
    let symbol: String
    let menuBarSymbol: String
    let title: String
    let isAnimating: Bool

    init(status: VPNManager.Status) {
        switch status {
        case .setupRequired:
            tint = .secondary
            symbol = "shield"
            menuBarSymbol = "shield.slash"
            title = "需要设置"
            isAnimating = false
        case .disconnected:
            tint = Color(nsColor: .secondaryLabelColor)
            symbol = "shield.slash"
            menuBarSymbol = "shield.slash"
            title = "未连接"
            isAnimating = false
        case .connecting:
            tint = .orange
            symbol = "shield.lefthalf.filled"
            menuBarSymbol = "shield.lefthalf.filled"
            title = "正在连接"
            isAnimating = true
        case .connected:
            tint = .green
            symbol = "checkmark.shield.fill"
            menuBarSymbol = "checkmark.shield.fill"
            title = "已连接"
            isAnimating = false
        case .disconnecting:
            tint = .orange
            symbol = "shield.lefthalf.filled"
            menuBarSymbol = "shield.lefthalf.filled"
            title = "正在断开"
            isAnimating = true
        case .waitingToReconnect(let attempt):
            tint = .orange
            symbol = "arrow.triangle.2.circlepath"
            menuBarSymbol = "shield.lefthalf.filled"
            title = "等待重连（第 \(attempt) 次）"
            isAnimating = true
        case .failed:
            tint = .red
            symbol = "exclamationmark.shield.fill"
            menuBarSymbol = "exclamationmark.shield.fill"
            title = "连接失败"
            isAnimating = false
        }
    }
}

extension VPNManager.Failure {
    var message: String {
        switch self {
        case .authentication:
            return "认证失败，请检查用户名和密码。为避免账号被锁定，不会自动重试。"
        case .helperNotAuthorized:
            return "尚未完成系统授权，需要一次性安装授权助手才能启动 openconnect。"
        case .openconnectMissing:
            return "未找到 openconnect，请先执行 brew install openconnect。"
        case .certificate(let pin):
            return pin == nil
                ? "服务器证书校验失败。"
                : "服务器证书未被系统信任。如果确认这是公司 VPN，可以选择信任它。"
        case .unreachable:
            return "无法连接到 VPN 服务器，请检查网络。注意：在公司办公网络内无法连接 XD VPN。"
        case .timeout:
            return "连接超时。"
        case .dropped:
            return "连接已断开。"
        case .other(let text):
            return text
        }
    }
}

extension VPNManager.Status {
    var menuBarSymbol: String { StatusPresentation(status: self).menuBarSymbol }
}

enum DurationText {
    static func elapsed(since start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

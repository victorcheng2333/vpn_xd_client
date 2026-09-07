import SwiftUI

struct AuthorizationView: View {
    @EnvironmentObject var model: VPNModel
    @State private var confirmRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("由 macOS 管理 VPN 系统服务，日常连接无需输入 Mac 密码。").font(.system(size: 13)).foregroundStyle(Palette.muted)
            Card {
                VStack(alignment: .leading, spacing: 22) {
                    Label(model.privilegeStatus.title, systemImage: model.privilegeStatus == .ready ? "checkmark.shield.fill" : "lock.shield")
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(Palette.green)
                    Text(instructions)
                        .font(.system(size: 13)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    Text("VPN 密码仍保存在钥匙串；Mac 管理员密码不会被保存。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if let issue = model.privilegeIssue {
                        Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
                    }
                    HStack {
                        if [.ready, .needsUpdate, .needsMigration, .requiresApproval, .needsRepair].contains(model.privilegeStatus) {
                            Button("移除授权…") { confirmRemoval = true }.disabled(!model.canEdit || model.privilegeBusy)
                        }
                        Spacer()
                        Button("重新检测") { Task { await model.refreshPrivileges() } }.disabled(model.privilegeBusy)
                        if ![.ready, .invalidSignature, .moveToApplications, .checking].contains(model.privilegeStatus) {
                            Button { Task { await model.installPrivileges() } } label: {
                                Label(model.privilegeBusy ? "正在处理…" : model.privilegeStatus.actionTitle, systemImage: "lock.open")
                            }.buttonStyle(PrimaryButtonStyle()).frame(width: 170).disabled(model.privilegeBusy || !model.canEdit)
                        }
                    }
                }
            }
            HStack {
                Image(systemName: "network").foregroundStyle(Palette.green)
                Text(model.engineAvailable ? "已内置 OpenConnect，无需安装 Homebrew" : "内置连接引擎不完整，请重新下载应用").font(.system(size: 12))
                Spacer()
            }.padding(18).background(Palette.mint.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            if !model.canEdit { Text("请先断开 VPN，再更新或移除授权。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            Spacer()
        }.task { await model.refreshPrivileges() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refreshPrivileges() }
            }
            .alert("移除系统授权？", isPresented: $confirmRemoval) {
                Button("取消", role: .cancel) {}
                Button("移除授权", role: .destructive) { Task { await model.removePrivileges() } }
            } message: { Text("等待 VPN 清理后注销系统服务。之后连接前需要重新启用；VPN 配置和钥匙串密码会保留。") }
    }

    private var instructions: String {
        switch model.privilegeStatus {
        case .requiresApproval: "请在系统设置的「登录项与扩展」中允许 XD VPN 后台服务，然后返回应用重新检测。"
        case .needsMigration: "新服务已通过检查。请先断开并退出旧版 XD VPN，再迁移旧版授权。迁移会撤销旧免密规则并备份旧组件；VPN 配置和密码保留。"
        case .needsUpdate: "当前运行的系统服务来自另一份或旧版应用。请断开 VPN 后重新注册，使服务与此版本一致。"
        case .invalidSignature: "此构建不能启用特权服务。请安装公司 Developer ID 签名并完成 Apple 公证的完整安装包。"
        case .moveToApplications: "请将应用拖入 Applications 文件夹，从该位置打开后再启用系统服务。"
        default: "首次启用需在 macOS 系统设置中批准后台服务。助手和连接引擎随应用一起更新，日常连接和自动重连无需再次输入 Mac 密码。"
        }
    }
}

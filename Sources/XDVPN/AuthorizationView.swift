import SwiftUI

struct AuthorizationView: View {
    @EnvironmentObject var model: VPNModel
    @State private var confirmRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.privilegeStatus == .needsUpdate ? "已有授权仍有效，需要更新系统组件。" : "安装系统助手后，日常连接无需输入 Mac 密码。").font(.system(size: 13)).foregroundStyle(Palette.muted)
            Card {
                VStack(alignment: .leading, spacing: 22) {
                    Label(model.privilegeStatus.title, systemImage: model.privilegeStatus == .ready ? "checkmark.shield.fill" : "lock.shield")
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(Palette.green)
                    Text(model.privilegeStatus == .needsUpdate
                         ? "本版修复需要升级系统助手。已有授权和 VPN 配置会保留，权限范围不变。替换受保护的系统组件时，macOS 需要一次管理员确认。"
                         : "首次安装、升级或修复系统助手时，macOS 会请求管理员确认。日常打开应用、连接和自动重连无需输入 Mac 密码。")
                        .font(.system(size: 13)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    Text("VPN 密码仍保存在钥匙串；Mac 管理员密码不会被保存。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if let issue = model.privilegeIssue {
                        Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
                    }
                    HStack {
                        if model.privilegeStatus != .notInstalled && model.privilegeStatus != .checking {
                            Button("移除授权…") { confirmRemoval = true }.disabled(!model.canEdit || model.privilegeBusy)
                        }
                        Spacer()
                        Button("重新检测") { Task { await model.refreshPrivileges() } }.disabled(model.privilegeBusy)
                        if model.privilegeStatus != .ready {
                            Button { Task { await model.installPrivileges() } } label: {
                                Label(model.privilegeBusy ? "等待系统确认…" : model.privilegeStatus == .notInstalled ? "安装系统助手" : model.privilegeStatus == .needsUpdate ? "升级系统助手" : "修复系统助手", systemImage: "lock.open")
                            }.buttonStyle(PrimaryButtonStyle()).frame(width: 170).disabled(model.privilegeBusy || !model.canEdit)
                        }
                    }
                }
            }
            HStack {
                Image(systemName: "network").foregroundStyle(Palette.green)
                Text(model.engineAvailable ? "OpenConnect 已安装" : "请先安装 OpenConnect：brew install openconnect").font(.system(size: 12))
                Spacer()
            }.padding(18).background(Palette.mint.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            if !model.canEdit { Text("请先断开 VPN，再更新或移除授权。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            Spacer()
        }.task { await model.refreshPrivileges() }
            .alert("移除系统授权？", isPresented: $confirmRemoval) {
                Button("取消", role: .cancel) {}
                Button("移除授权", role: .destructive) { Task { await model.removePrivileges() } }
            } message: { Text("之后连接前需要重新安装授权。VPN 配置和钥匙串密码会保留。") }
    }
}

import SwiftUI

struct AuthorizationView: View {
    @EnvironmentObject var model: VPNModel
    @State private var confirmRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("授权一次，之后轻松连接。").font(.system(size: 13)).foregroundStyle(Palette.muted)
            Card {
                VStack(alignment: .leading, spacing: 22) {
                    Label(model.privilegeStatus.title, systemImage: model.privilegeStatus == .ready ? "checkmark.shield.fill" : "lock.shield")
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(Palette.green)
                    Text("安装专用授权助手时，macOS 会请求一次管理员确认。授权保存后，重新打开应用、连接和自动重连都无需再输入 Mac 密码。")
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
                                Label(model.privilegeBusy ? "等待系统确认…" : model.privilegeStatus == .notInstalled ? "安装授权" : "更新授权", systemImage: "lock.open")
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

import SwiftUI

/// A contextual notice on the connection page, hidden when the service is ready.
struct ServiceSetupView: View {
    @EnvironmentObject var model: VPNModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 19)).foregroundStyle(Palette.green)
            VStack(alignment: .leading, spacing: 7) {
                Text(model.privilegeStatus.title).font(.system(size: 14, weight: .semibold))
                Text(model.privilegeStatus.instructions).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if let issue = model.privilegeIssue {
                    Text(issue).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if !model.canEdit {
                    Text("请先断开 VPN，再处理系统服务。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.privilegeStatus.canRequestService {
                Button("重新检测") { Task { await model.refreshPrivileges() } }
                    .disabled(model.privilegeBusy).controlSize(.small)
            }
        }.padding(18).background(Palette.mint.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ServiceAdvancedView: View {
    @EnvironmentObject var model: VPNModel
    @State private var confirmRemoval = false
    var body: some View {
        Card(padding: 18) {
            DisclosureGroup("高级 · 系统服务") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.privilegeStatus.title).font(.system(size: 12, weight: .medium))
                    Text("移除服务前会等待 VPN 清理完成。VPN 配置和钥匙串密码会保留，下次连接前需要重新启用服务。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    if let issue = model.privilegeIssue {
                        Text(issue).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("查看连接准备") { model.page = .connection }
                        Spacer()
                        Button("移除系统服务…", role: .destructive) { confirmRemoval = true }
                            .disabled(!model.canEdit || model.privilegeBusy || !model.privilegeStatus.canRemoveService)
                    }
                    if !model.canEdit {
                        Text("请先断开 VPN，再移除系统服务。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.padding(.top, 14)
            }.font(.system(size: 12, weight: .medium))
        }
        .alert("移除系统服务？", isPresented: $confirmRemoval) {
            Button("取消", role: .cancel) {}
            Button("移除服务", role: .destructive) { Task { await model.removePrivileges() } }
        } message: { Text("之后连接前需要重新启用服务；VPN 配置和钥匙串密码会保留。") }
    }
}

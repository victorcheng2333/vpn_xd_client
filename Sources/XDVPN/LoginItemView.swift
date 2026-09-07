import SwiftUI

struct LoginItemView: View {
    @EnvironmentObject private var loginItem: LoginItemManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 15) {
                Image(systemName: "power.circle").font(.system(size: 20)).foregroundStyle(Palette.green)
                    .frame(width: 43, height: 43).background(.white, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text("开机自动启动").font(.system(size: 13, weight: .semibold))
                    Text(loginItem.detail).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 5)
                Toggle("开机自动启动", isOn: Binding(get: { loginItem.isRequested }, set: { loginItem.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(Palette.green).controlSize(.regular)
                    .help("登录 Mac 后启动 XD VPN；是否连接 VPN 由「自动连接」设置决定。")
            }
            if let issue = loginItem.issue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loginItem.requiresApproval || loginItem.issue != nil {
                Button("前往系统设置") { loginItem.openSystemSettings() }
                    .font(.system(size: 11))
            }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

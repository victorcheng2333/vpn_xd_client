import SwiftUI

/// The everyday controls live here; configuration and logs remain in the window.
struct MenuPanelView: View {
    @EnvironmentObject var model: VPNModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundStyle(Palette.green)
                Text("XD VPN").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").font(.system(size: 9)).foregroundStyle(Palette.muted)
                Spacer()
                Button { show(.profile) } label: { Image(systemName: "gearshape").font(.system(size: 17)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("VPN 配置")
            }
            VStack(spacing: 7) {
                OrbitView(connected: model.state == .connected, busy: model.state.isBusy).frame(height: 128)
                Text(model.state.title).font(.system(size: 22, weight: .semibold))
                Text(model.profile?.displayServer ?? "你的工作网络，随时就绪")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            if let issue = model.issue {
                Text(issue).font(.system(size: 11)).foregroundStyle(Color(hex: 0x946B37)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: model.state.isActive ? "power" : model.privilegeStatus == .ready ? "power" : "lock.open")
            }.buttonStyle(PrimaryButtonStyle(destructive: model.state.isActive)).disabled(model.state == .disconnecting)

            if let profile = model.profile {
                VStack(spacing: 10) {
                    row("账号", profile.username)
                    row("VPN 地址", model.address ?? "—")
                    HStack {
                        Text("连接时长").foregroundStyle(Palette.muted)
                        Spacer()
                        if let date = model.connectedAt {
                            Text(date, style: .timer).monospacedDigit()
                        } else { Text("—") }
                    }.font(.system(size: 11))
                }.padding(15).background(.white, in: RoundedRectangle(cornerRadius: 13))
            }
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Palette.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("自动连接").font(.system(size: 12, weight: .semibold))
                    Text("启动时连接，手动断开后保持断开").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("自动连接", isOn: Binding(get: { model.autoConnect }, set: { model.setAutoConnect($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(Palette.green).controlSize(.small)
                    .help("仅修改自动连接配置。手动断开后，需再次点击连接或重启应用才会连接。")
            }.padding(15).background(Palette.mint.opacity(0.35), in: RoundedRectangle(cornerRadius: 13))
            HStack {
                Button { show(.authorization) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(model.privilegeStatus == .ready ? Palette.green : .orange).frame(width: 5, height: 5)
                        Text(model.privilegeStatus.title).font(.system(size: 10))
                    }
                }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                Spacer()
                Button("日志") { show(.activity) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.muted)
                Button("退出并断开") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.ink)
            }
        }.padding(22).frame(width: 350).background(Palette.canvas).foregroundStyle(Palette.ink)
            .preferredColorScheme(.light).task { await model.refreshPrivileges() }
    }

    private var primaryTitle: String {
        if model.state == .disconnecting { return "正在断开…" }
        if model.state == .connected { return "断开连接" }
        if model.state.isActive { return "取消连接" }
        if !model.readyToConnect { return "配置 VPN" }
        return model.privilegeStatus == .ready ? "连接 VPN" : "安装系统授权"
    }
    private func primaryAction() {
        if model.state.isActive { model.disconnect() }
        else if !model.readyToConnect { show(.profile) }
        else if model.privilegeStatus != .ready { show(.authorization) }
        else { model.connect() }
    }
    private func show(_ page: Page) {
        model.page = page; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(Palette.muted); Spacer(); Text(value).lineLimit(1) }.font(.system(size: 11))
    }
}

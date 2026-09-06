import SwiftUI

/// The everyday controls live here; configuration and logs remain in the window.
struct MenuPanelView: View {
    @EnvironmentObject var model: VPNModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: model.state.menuBarSymbol).foregroundStyle(model.state.statusColor)
                Text("XD VPN").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").font(.system(size: 9)).foregroundStyle(Palette.muted)
                Spacer()
                Button { show(.profile) } label: { Image(systemName: "gearshape").font(.system(size: 17)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("VPN 配置")
            }
            VStack(spacing: 7) {
                OrbitView(state: model.state).frame(height: 128)
                Text(model.state.displayTitle).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(model.state.statusColor)
                Text(connectionHint).font(.system(size: 11)).foregroundStyle(model.state.statusColor)
                    .multilineTextAlignment(.center)
                Text(model.profile?.displayServer ?? "你的工作网络，随时就绪")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }.frame(maxWidth: .infinity).padding(.top, 2).padding(.bottom, 18)
                .background(model.state.statusSurface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.state.statusColor.opacity(0.12)))
            if let issue = model.issue {
                Text(issue).font(.system(size: 11)).foregroundStyle(Color(hex: 0x946B37)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: model.state.isActive ? (model.state == .connected ? "power" : "xmark") : model.privilegeStatus == .ready ? "power" : "lock.open")
            }.buttonStyle(PrimaryButtonStyle(secondary: model.state.isActive)).disabled(model.state == .disconnecting)

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

    private var connectionHint: String {
        switch model.state {
        case .idle: "尚未接入工作网络"
        case .connected: "VPN 通道已建立，可以访问工作网络"
        case .authorizing, .connecting: "正在建立 VPN 通道，请稍候"
        case .reconnecting: "连接暂时中断，正在恢复"
        case .waiting: model.networkAvailable ? "尚未连接，稍后自动重试" : "网络不可用，恢复后自动重连"
        case .disconnecting: "正在结束 VPN 会话，请稍候"
        case .failed: "未能接入工作网络，请检查错误提示"
        }
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

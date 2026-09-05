import AppKit
import SwiftUI

/// The connection page. Used both inside the menu bar popover and in the
/// main window (`layout` only changes sizes and chrome).
struct StatusPanelView: View {
    enum Layout { case popover, window }
    let layout: Layout

    @Environment(VPNManager.self) private var vpn
    @Environment(\.openSettings) private var openSettings

    private var presentation: StatusPresentation { StatusPresentation(status: vpn.status) }
    private var tint: Color { presentation.tint }
    private var isWindow: Bool { layout == .window }
    private var width: CGFloat { isWindow ? 380 : 320 }

    var body: some View {
        @Bindable var vpn = vpn
        VStack(spacing: 0) {
            header
                .padding(.top, isWindow ? 30 : 16)
                .padding(.horizontal, 18)

            if isWindow { Spacer(minLength: 4) }

            hero
                .padding(.top, isWindow ? 4 : 6)

            VStack(spacing: 12) {
                primaryAction
                statusCards
                optionsCard(vpn: $vpn)
            }
            .padding(.horizontal, 18)
            .padding(.top, isWindow ? 26 : 20)

            if isWindow { Spacer(minLength: 12) }

            footer
                .padding(.horizontal, 18)
                .padding(.top, isWindow ? 6 : 14)
                .padding(.bottom, isWindow ? 16 : 14)
        }
        .frame(width: width)
        .frame(minHeight: isWindow ? 570 : nil)
        .background(background)
        .animation(.easeInOut(duration: 0.3), value: vpn.status)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text("XD VPN")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.3)
                .frame(maxWidth: isWindow ? .infinity : nil, alignment: isWindow ? .center : .leading)
            if !isWindow {
                Spacer()
                Button { MainWindowController.shared.show() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(IconButtonStyle())
                .help("打开主窗口")
                Button(action: showSettings) {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(IconButtonStyle())
                .help("设置")
            }
        }
        .overlay(alignment: .trailing) {
            if isWindow {
                Button(action: showSettings) {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(IconButtonStyle())
                .help("设置")
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ConnectionOrb(status: vpn.status, tint: tint, size: isWindow ? 144 : 112)
            VStack(spacing: 8) {
                Text(presentation.title)
                    .font(Theme.display(isWindow ? 23 : 20))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                StatusChip(tint: tint, text: subtitle)
            }
        }
    }

    private var subtitle: Text {
        switch vpn.status {
        case .setupRequired:
            return Text("填写账户后一键连接")
        case .disconnected, .connecting, .failed:
            return Text(vpn.profile.host)
        case .connected:
            return Text("\(vpn.profile.host)")
        case .recovering:
            return Text("网络变化，正在恢复隧道")
        case .disconnecting:
            return Text("正在关闭隧道")
        case .waitingToReconnect:
            return Text("稍后自动重试")
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch vpn.status {
        case .setupRequired:
            Button(action: showSettings) { Text("开始设置") }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.accent))
        case .disconnected, .failed:
            Button { vpn.connect() } label: { Text("连接") }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.accent))
                .keyboardShortcut(.defaultAction)
        case .connecting, .waitingToReconnect:
            Button { vpn.disconnect() } label: { Text("取消") }
                .buttonStyle(SecondaryButtonStyle())
        case .connected, .recovering:
            Button { vpn.disconnect() } label: { Text("断开连接") }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
        case .disconnecting:
            Button {} label: { Text("正在断开…") }
                .buttonStyle(SecondaryButtonStyle(tint: .secondary))
                .disabled(true)
        }
    }

    @ViewBuilder
    private var statusCards: some View {
        if vpn.status.hasTunnel {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    StatCell(label: "VPN IP", value: vpn.assignedIP ?? "—")
                    divider
                    StatCell(label: "在线时长") { elapsed }
                    divider
                    StatCell(label: "账户", value: vpn.profile.username)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if vpn.status == .recovering || vpn.isExternalSession {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack {
                        Text(vpn.status == .recovering ? "保持原会话与 IP，最多等 90 秒" : "接管的外部 openconnect 进程")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if vpn.status == .recovering {
                            Button("直接重新登录") { vpn.restartSession() }
                                .buttonStyle(.plain)
                                .font(Theme.captionMedium)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
            .themedCard()
        }

        if case .waitingToReconnect(let attempt) = vpn.status {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.transitional)
                Text("第 \(attempt) 次重连")
                    .font(Theme.bodyMedium)
                Spacer()
                if let next = vpn.nextRetryDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                        Text("\(remaining) 秒后")
                            .font(Theme.value)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .themedCard()
        }

        if case .failed(let failure) = vpn.status {
            failureCard(failure)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 28).padding(.horizontal, 10)
    }

    @ViewBuilder
    private var elapsed: some View {
        if let since = vpn.connectedSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(DurationText.elapsed(since: since, to: context.date))
            }
        } else {
            Text("—")
        }
    }

    private func failureCard(_ failure: VPNManager.Failure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.top, 1)
                Text(failure.message)
                    .font(Theme.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                switch failure {
                case .certificate(let pin?):
                    linkButton("信任并重试") { vpn.trustServerCertificate(pin: pin) }
                case .helperNotAuthorized:
                    linkButton("去授权", action: showSettings)
                case .authentication:
                    linkButton("检查账户", action: showSettings)
                default:
                    EmptyView()
                }
                Spacer()
                linkButton("查看日志", muted: true, action: showSettings)
            }
        }
        .padding(14)
        .themedCard()
    }

    private func linkButton(_ title: String, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.captionMedium)
            .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
    }

    private func optionsCard(vpn: Bindable<VPNManager>) -> some View {
        VStack(spacing: 0) {
            OptionRow(
                icon: "arrow.triangle.2.circlepath",
                iconTint: Theme.accent,
                title: "自动连接",
                subtitle: autoConnectSubtitle,
                isOn: vpn.autoConnect
            )
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 49)
            OptionRow(
                icon: "power",
                iconTint: Color(nsColor: .systemGray),
                title: "开机启动",
                subtitle: "登录后静默待在菜单栏",
                isOn: vpn.launchAtLogin
            )
        }
        .themedCard()
    }

    private var autoConnectSubtitle: String {
        if vpn.autoConnect && vpn.autoConnectPaused { return "已暂停，点「连接」后恢复" }
        return vpn.autoConnect ? "保持在线，掉线自动重连" : "启动时连接并保持在线"
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(vpn.helperStatus.isUsable ? Theme.connected : Theme.transitional)
                    .frame(width: 5, height: 5)
                Text(vpn.helperStatus.isUsable ? "系统授权正常" : vpn.helperStatus.title)
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(Theme.captionMedium)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .help(vpn.hasActiveSession ? "退出并断开 VPN" : "退出")
        }
    }

    /// The popover keeps the system material; the window gets its own
    /// visual-effect backdrop. Both get a faint status-colored wash up top.
    private var background: some View {
        ZStack {
            if isWindow { VisualEffectBackground(material: .popover) }
            RadialGradient(
                colors: [tint.opacity(0.14), .clear],
                center: UnitPoint(x: 0.5, y: isWindow ? 0.26 : 0.28),
                startRadius: 0, endRadius: isWindow ? 280 : 220
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Actions

    private func showSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
    }
}

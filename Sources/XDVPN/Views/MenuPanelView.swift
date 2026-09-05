import AppKit
import SwiftUI

/// Content of the menu bar popover: status, primary action, options.
struct MenuPanelView: View {
    @Environment(VPNManager.self) private var vpn
    @Environment(\.openSettings) private var openSettings

    private var presentation: StatusPresentation { StatusPresentation(status: vpn.status) }

    var body: some View {
        @Bindable var vpn = vpn
        VStack(spacing: 14) {
            header
            hero
            primaryAction
            statusCards
            optionsCard(vpn: $vpn)
            footer
        }
        .padding(16)
        .frame(width: 300)
        .background(backgroundTint)
        .animation(.easeInOut(duration: 0.3), value: vpn.status)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(presentation.tint)
            Text("XD VPN").font(.headline)
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            StatusHeroView(status: vpn.status, presentation: presentation)
                .padding(.top, 4)
            VStack(spacing: 3) {
                Text(presentation.title)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.numericText())
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch vpn.status {
        case .setupRequired:
            Text("填写 VPN 账户后即可一键连接")
        case .disconnected:
            Text(vpn.profile.host)
        case .connecting:
            Text(vpn.profile.host)
        case .connected:
            if let since = vpn.connectedSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("\(vpn.profile.host) · \(DurationText.elapsed(since: since, to: context.date))")
                        .monospacedDigit()
                }
            } else {
                Text(vpn.profile.host)
            }
        case .disconnecting:
            Text("正在关闭隧道")
        case .waitingToReconnect:
            if let next = vpn.nextRetryDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                    Text("\(remaining) 秒后重试")
                        .monospacedDigit()
                }
            } else {
                Text("稍后重试")
            }
        case .failed:
            Text(vpn.profile.host)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch vpn.status {
        case .setupRequired:
            Button("开始设置", action: showSettings)
                .buttonStyle(PillButtonStyle(tint: .accentColor))
        case .disconnected, .failed:
            Button("连接") { vpn.connect() }
                .buttonStyle(PillButtonStyle(tint: .accentColor))
                .keyboardShortcut(.defaultAction)
        case .connecting, .waitingToReconnect:
            Button("取消") { vpn.disconnect() }
                .buttonStyle(PillButtonStyle(tint: .orange))
        case .connected:
            Button("断开连接") { vpn.disconnect() }
                .buttonStyle(PillButtonStyle(tint: .red))
        case .disconnecting:
            Button("正在断开…") {}
                .buttonStyle(PillButtonStyle(tint: .orange))
                .disabled(true)
        }
    }

    @ViewBuilder
    private var statusCards: some View {
        if vpn.status == .connected {
            VStack(spacing: 6) {
                DetailRow(label: "服务器", value: vpn.profile.server, monospaced: true)
                DetailRow(label: "账户", value: vpn.profile.username)
                if let ip = vpn.assignedIP {
                    DetailRow(label: "VPN IP", value: ip, monospaced: true)
                }
                if vpn.isExternalSession {
                    DetailRow(label: "会话", value: "接管的外部 openconnect 进程")
                }
            }
            .padding(12)
            .card()
        }

        if case .failed(let failure) = vpn.status {
            failureCard(failure)
        }
    }

    private func failureCard(_ failure: VPNManager.Failure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 13))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                switch failure {
                case .certificate(let pin?):
                    Button("信任并重试") { vpn.trustServerCertificate(pin: pin) }
                case .helperNotAuthorized:
                    Button("去授权", action: showSettings)
                case .authentication:
                    Button("检查账户", action: showSettings)
                default:
                    EmptyView()
                }
                Spacer()
                Button("查看日志", action: showSettings)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(12)
        .card()
    }

    private func optionsCard(vpn: Bindable<VPNManager>) -> some View {
        VStack(spacing: 0) {
            ToggleRow(
                icon: "arrow.triangle.2.circlepath",
                title: "自动连接",
                subtitle: autoConnectSubtitle,
                isOn: vpn.autoConnect
            )
            Divider().padding(.leading, 44)
            ToggleRow(
                icon: "power",
                title: "开机启动",
                subtitle: "登录后在菜单栏静默运行",
                isOn: vpn.launchAtLogin
            )
        }
        .card()
    }

    private var autoConnectSubtitle: String {
        if vpn.autoConnect && vpn.autoConnectPaused { return "已暂停，点击「连接」后恢复保持在线" }
        return vpn.autoConnect ? "保持在线，掉线后自动重连" : "启动时连接并保持在线"
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(vpn.helperStatus.isUsable ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(vpn.helperStatus.isUsable ? "系统授权正常" : vpn.helperStatus.title)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .help(vpn.hasActiveSession ? "退出并断开 VPN" : "退出")
        }
        .padding(.top, 2)
    }

    private var backgroundTint: some View {
        RadialGradient(
            colors: [presentation.tint.opacity(0.18), .clear],
            center: .top,
            startRadius: 0,
            endRadius: 260
        )
        .ignoresSafeArea()
    }

    // MARK: Actions

    private func showSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
    }
}

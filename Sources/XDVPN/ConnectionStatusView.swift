import SwiftUI

extension ConnectionState {
    var statusColor: Color {
        switch self {
        case .idle, .waiting, .disconnecting: Color(hex: 0x626D7A)
        case .authorizing, .connecting, .reconnecting: Color(hex: 0x326CB0)
        case .connected: Palette.green
        case .failed: Color(hex: 0xB44538)
        }
    }

    var statusSurface: Color {
        switch self {
        case .idle, .waiting, .disconnecting: Color(hex: 0xF5F6F8)
        case .authorizing, .connecting, .reconnecting: Color(hex: 0xF1F6FC)
        case .connected: Color(hex: 0xF0F8F3)
        case .failed: Color(hex: 0xFFF5F3)
        }
    }

    var statusSymbol: String {
        switch self {
        case .idle, .disconnecting: "power"
        case .connected: "checkmark.shield.fill"
        case .waiting: "pause.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }

    var statusLabel: String {
        switch self {
        case .idle: "未连接"
        case .connected: "已连接"
        case .authorizing: "准备中"
        case .connecting: "连接中"
        case .reconnecting: "恢复中"
        case .waiting: "等待重连"
        case .disconnecting: "断开中"
        case .failed: "连接失败"
        }
    }

    var displayTitle: String {
        switch self {
        case .idle: "VPN 未连接"
        case .connected: "工作网络已连接"
        case .failed: "VPN 连接失败"
        default: title
        }
    }
}

struct ConnectionStatusBadge: View {
    let state: ConnectionState

    var body: some View {
        Label(state.statusLabel, systemImage: state == .connected ? "checkmark.circle.fill" : state.statusSymbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(state == .connected ? .white : state.statusColor)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(state == .connected ? state.statusColor : state.statusColor.opacity(0.09), in: Capsule())
            .accessibilityLabel("VPN 状态：\(state.statusLabel)")
    }
}

struct OrbitView: View {
    let state: ConnectionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsProgress: Bool { state.isBusy && state != .waiting }
    private var animates: Bool { showsProgress && !reduceMotion }

    var body: some View {
        // Only in-progress states animate. Idle and waiting remain visibly at rest.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            GeometryReader { geometry in
                let size = min(geometry.size.height, 210.0)
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                ZStack {
                    if state == .connected {
                        Circle().fill(RadialGradient(colors: [Palette.mint, .clear], center: .center, startRadius: size * 0.2, endRadius: size * 0.5))
                            .frame(width: size, height: size)
                        ForEach(0..<2) { index in
                            Circle().stroke(Palette.green.opacity(index == 0 ? 0.14 : 0.07), lineWidth: 1)
                                .frame(width: size * (0.72 + Double(index) * 0.19), height: size * (0.72 + Double(index) * 0.19))
                        }
                    } else if showsProgress {
                        Circle().stroke(state.statusColor.opacity(0.12), lineWidth: 2.5)
                            .frame(width: size * 0.78, height: size * 0.78)
                    } else {
                        Circle().stroke(state.statusColor.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                            .frame(width: size * 0.78, height: size * 0.78)
                    }
                    if showsProgress {
                        Circle().trim(from: 0, to: 0.23)
                            .stroke(state.statusColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: size * 0.78, height: size * 0.78)
                            .rotationEffect(.degrees(animates ? phase * 360 : -90))
                    }
                    Circle().fill(state == .connected ? Palette.green : state.statusColor.opacity(0.08))
                        .frame(width: size * 0.57, height: size * 0.57)
                        .overlay(Circle().stroke(state.statusColor.opacity(0.1), lineWidth: 1)
                            .frame(width: size * 0.57, height: size * 0.57))
                    Image(systemName: state.statusSymbol)
                        .font(.system(size: size * 0.24, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(state == .connected ? .white : state.statusColor)
                        .contentTransition(.symbolEffect(.replace))
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }.accessibilityHidden(true)
    }
}

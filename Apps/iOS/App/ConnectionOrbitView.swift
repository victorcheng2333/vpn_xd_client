import SwiftUI

enum ConnectionAppearance {
    case idle, connecting, connected, disconnecting

    // Match Sources/XDVPN/ConnectionStatusView.swift and Theme.swift.
    var color: Color {
        switch self {
        case .connecting: Color(hex: 0x326CB0)
        case .connected: Color(hex: 0x227858)
        case .idle, .disconnecting: Color(hex: 0x626D7A)
        }
    }
    var showsProgress: Bool { self == .connecting || self == .disconnecting }
    var symbol: String {
        switch self {
        case .idle, .disconnecting: "power"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.shield.fill"
        }
    }
}

struct ConnectionOrbitView: View {
    let appearance: ConnectionAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var animates: Bool { appearance.showsProgress && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
            ZStack {
                if appearance == .connected {
                    Circle().fill(RadialGradient(colors: [Color(hex: 0xDAEFE3), .clear], center: .center, startRadius: 32, endRadius: 80))
                    ForEach(0..<2) { index in
                        Circle().stroke(appearance.color.opacity(index == 0 ? 0.14 : 0.07), lineWidth: 1)
                            .frame(width: 115 + CGFloat(index) * 30, height: 115 + CGFloat(index) * 30)
                    }
                } else if appearance.showsProgress {
                    Circle().stroke(appearance.color.opacity(0.12), lineWidth: 2.5).frame(width: 125, height: 125)
                } else {
                    Circle().stroke(appearance.color.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                        .frame(width: 125, height: 125)
                }
                if appearance.showsProgress {
                    Circle().trim(from: 0, to: 0.23)
                        .stroke(appearance.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 125, height: 125)
                        .rotationEffect(.degrees(animates ? phase * 360 : -90))
                }
                Circle().fill(appearance == .connected ? appearance.color : appearance.color.opacity(0.08))
                    .frame(width: 91, height: 91)
                    .overlay(Circle().stroke(appearance.color.opacity(0.1), lineWidth: 1))
                Image(systemName: appearance.symbol)
                    .font(.system(size: 38, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(appearance == .connected ? .white : appearance.color)
                    .contentTransition(.symbolEffect(.replace))
            }.frame(width: 160, height: 160)
        }.accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

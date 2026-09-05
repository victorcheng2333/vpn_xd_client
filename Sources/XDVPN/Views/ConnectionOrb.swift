import SwiftUI

/// The hero: a tactile disc with a status ring, glow, pulse and the brand shield.
struct ConnectionOrb: View {
    let status: VPNManager.Status
    let tint: Color
    var size: CGFloat = 116

    @State private var spinning = false
    @State private var pulsing = false

    private var isBusy: Bool { status.isBusy }
    private var isConnected: Bool { status == .connected }

    var body: some View {
        ZStack {
            // Ambient glow
            Circle()
                .fill(RadialGradient(
                    colors: [tint.opacity(isConnected ? 0.30 : (isBusy ? 0.18 : 0.0)), .clear],
                    center: .center, startRadius: size * 0.3, endRadius: size * 0.85
                ))
                .frame(width: size * 1.7, height: size * 1.7)

            // Pulse rings while connected
            if isConnected {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .stroke(tint.opacity(0.5), lineWidth: 1)
                        .frame(width: size, height: size)
                        .scaleEffect(pulsing ? 1.45 : 1.0)
                        .opacity(pulsing ? 0 : 0.7)
                        .animation(
                            .easeOut(duration: 2.6).repeatForever(autoreverses: false).delay(Double(index) * 1.3),
                            value: pulsing
                        )
                }
                .onAppear { pulsing = true }
                .onDisappear { pulsing = false }
            }

            // Disc: soft vertical gradient, rim highlight, layered shadows.
            Circle()
                .fill(LinearGradient(colors: [Theme.discTop, Theme.discBottom], startPoint: .top, endPoint: .bottom))
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.9), .black.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.10), radius: 14, y: 8)
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)

            // Status ring just inside the rim
            Circle()
                .strokeBorder(tint.opacity(isConnected ? 1 : (isBusy ? 0.35 : 0.18)), lineWidth: 3.5)
                .frame(width: size - 10, height: size - 10)
                .shadow(color: tint.opacity(isConnected ? 0.45 : 0), radius: 8)

            // Activity arc
            if isBusy {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0), tint], center: .center),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .frame(width: size - 13.5, height: size - 13.5)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear {
                        spinning = false
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spinning = true }
                    }
                    .onDisappear { spinning = false }
            }

            ShieldGlyph(status: status, tint: tint)
                .frame(width: size * 0.34, height: size * 0.40)
        }
        .frame(width: size * 1.3, height: size * 1.2)
        .animation(.easeInOut(duration: 0.35), value: status)
    }
}

/// Brand shield rendered for a status.
struct ShieldGlyph: View {
    let status: VPNManager.Status
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let stroke = max(2, geo.size.width * 0.065)
            ZStack {
                switch status {
                case .connected:
                    ShieldShape()
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .overlay(ShieldShape().stroke(.white.opacity(0.35), lineWidth: 1).padding(0.5))
                        .shadow(color: tint.opacity(0.35), radius: 6, y: 3)
                    CheckShape()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                        .padding(rect.width * 0.08)
                case .failed:
                    ShieldShape()
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: tint.opacity(0.3), radius: 6, y: 3)
                    VStack(spacing: rect.height * 0.07) {
                        Capsule().fill(Color.white).frame(width: stroke, height: rect.height * 0.30)
                        Circle().fill(Color.white).frame(width: stroke * 1.1, height: stroke * 1.1)
                    }
                    .offset(y: -rect.height * 0.06)
                default:
                    ShieldShape()
                        .stroke(status.isBusy ? tint : Theme.idle, style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
                        .padding(stroke / 2)
                    if status.isBusy {
                        Circle().fill(tint)
                            .frame(width: stroke * 1.4, height: stroke * 1.4)
                            .offset(y: -rect.height * 0.05)
                    }
                }
            }
        }
    }
}

import SwiftUI

/// The big status ring in the middle of the menu panel.
struct StatusHeroView: View {
    let status: VPNManager.Status
    let presentation: StatusPresentation
    @State private var spinning = false

    private let size: CGFloat = 104

    var body: some View {
        ZStack {
            Circle()
                .fill(presentation.tint.opacity(status == .connected ? 0.16 : 0.10))
                .frame(width: size, height: size)

            Circle()
                .strokeBorder(presentation.tint.opacity(0.28), lineWidth: 5)
                .frame(width: size, height: size)

            if presentation.isAnimating {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(presentation.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: size - 5, height: size - 5)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear {
                        spinning = false
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                            spinning = true
                        }
                    }
                    .onDisappear { spinning = false }
            } else if status == .connected {
                Circle()
                    .strokeBorder(presentation.tint, lineWidth: 5)
                    .frame(width: size, height: size)
            }

            Image(systemName: presentation.symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(presentation.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .shadow(color: status == .connected ? presentation.tint.opacity(0.45) : .clear, radius: 22)
        .animation(.easeInOut(duration: 0.35), value: status)
    }
}

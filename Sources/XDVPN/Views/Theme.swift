import AppKit
import SwiftUI

/// Design tokens. Follows the macOS HIG: system materials, semantic colors,
/// SF fonts, native controls. Light appearance is the primary target; every
/// color is semantic so dark mode works without special casing.
enum Theme {
    // Status colors (system palette so they match the user's Mac).
    static let accent = Color.accentColor
    static let connected = Color(nsColor: .systemGreen)
    static let transitional = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let idle = Color(nsColor: .tertiaryLabelColor)

    // Surfaces
    static let hairline = Color.primary.opacity(0.08)
    static let hairlineStrong = Color.primary.opacity(0.12)
    static let subtleFill = Color.primary.opacity(0.045)
    static let discTop = Color(nsColor: .controlBackgroundColor)
    static let discBottom = Color(nsColor: .controlBackgroundColor).opacity(0.85)

    // Typography
    static func display(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .semibold) }
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let value = Font.system(size: 14, weight: .semibold).monospacedDigit()
}

// MARK: - Shapes

/// The brand shield. Same geometry as the app icon and the menu bar glyph.
struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let top = rect.minY, bottom = rect.maxY, left = rect.minX, right = rect.maxX
        let midX = rect.midX
        let r = w * 0.16
        p.move(to: CGPoint(x: left + r, y: top))
        p.addLine(to: CGPoint(x: right - r, y: top))
        p.addQuadCurve(to: CGPoint(x: right, y: top + r), control: CGPoint(x: right, y: top))
        p.addLine(to: CGPoint(x: right, y: top + h * 0.50))
        p.addCurve(
            to: CGPoint(x: midX, y: bottom),
            control1: CGPoint(x: right, y: top + h * 0.80),
            control2: CGPoint(x: midX + w * 0.24, y: bottom - h * 0.05)
        )
        p.addCurve(
            to: CGPoint(x: left, y: top + h * 0.50),
            control1: CGPoint(x: midX - w * 0.24, y: bottom - h * 0.05),
            control2: CGPoint(x: left, y: top + h * 0.80)
        )
        p.addLine(to: CGPoint(x: left, y: top + r))
        p.addQuadCurve(to: CGPoint(x: left + r, y: top), control: CGPoint(x: left, y: top))
        p.closeSubpath()
        return p
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.52))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.69))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.34))
        return p
    }
}

// MARK: - Controls

/// Filled, softly glossy action button (the classic macOS prominent look).
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.86)], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .top, endPoint: .center))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .shadow(color: tint.opacity(0.28), radius: 6, y: 2)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Neutral action button on a material surface (used for disconnect / cancel).
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small round icon button used in headers.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Circle())
    }
}

/// Control-Center-style module: material fill, hairline, soft shadow.
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
    }
}

extension View {
    func themedCard() -> some View { modifier(CardStyle()) }
}

/// Status pill: colored dot + text.
struct StatusChip: View {
    let tint: Color
    let text: Text

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            text.font(Theme.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.subtleFill))
    }
}

/// One line inside the options card: System-Settings-style icon tile, title, subtitle, switch.
struct OptionRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [iconTint, iconTint.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            .shadow(color: iconTint.opacity(0.25), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.bodyMedium).foregroundStyle(.primary)
                Text(subtitle).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// Label/value cell for the stats strip.
struct StatCell<Value: View>: View {
    let label: String
    @ViewBuilder let value: () -> Value

    init(label: String, value: String) where Value == Text {
        self.label = label
        self.value = { Text(value) }
    }

    init(label: String, @ViewBuilder value: @escaping () -> Value) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.captionMedium).foregroundStyle(.secondary)
            value()
                .font(Theme.value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// NSVisualEffectView bridge for the main window background.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

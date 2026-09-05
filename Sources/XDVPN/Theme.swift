import SwiftUI

enum Palette {
    static let canvas = Color(hex: 0xF6F7F3)
    static let ink = Color(hex: 0x1B302A)
    static let muted = Color(hex: 0x7D8983)
    static let green = Color(hex: 0x227858)
    static let mint = Color(hex: 0xDAEFE3)
    static let line = Color(hex: 0xE6EAE3)
    static let sidebar = Color(hex: 0x192D27)
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
struct Card<Content: View>: View {
    var padding: CGFloat = 24
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).background(.white, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line, lineWidth: 1))
    }
}
struct PrimaryButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .frame(height: 46).frame(maxWidth: .infinity)
            .background(destructive ? Palette.ink : Palette.green, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
struct SmallLabel: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.7).foregroundStyle(Palette.muted) }
}
struct FieldShell<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.system(size: 12, weight: .medium)); if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Palette.muted) } }
            content.textFieldStyle(.plain).font(.system(size: 14)).padding(.horizontal, 14).frame(height: 42)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
        }
    }
}

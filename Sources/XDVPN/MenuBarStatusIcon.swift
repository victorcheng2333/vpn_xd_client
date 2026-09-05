import AppKit
import SwiftUI

extension ConnectionState {
    var menuBarSymbol: String {
        switch self {
        case .idle: "xmark.shield"
        case .connected: "checkmark.shield.fill"
        case .authorizing, .connecting, .reconnecting, .waiting, .disconnecting:
            "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.shield"
        }
    }
}

struct MenuBarStatusIcon: View {
    let state: ConnectionState

    private var symbolImage: NSImage {
        let image = NSImage(systemSymbolName: state.menuBarSymbol, accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return image?.withSymbolConfiguration(configuration) ?? image ?? NSImage()
    }

    var body: some View {
        // Distinguish states by shape even in a monochrome macOS menu bar.
        Image(nsImage: symbolImage)
            .renderingMode(.template)
            .symbolRenderingMode(.monochrome)
            .accessibilityLabel("XD VPN：\(state.title)")
            .help("XD VPN · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · \(state.title)")
    }
}

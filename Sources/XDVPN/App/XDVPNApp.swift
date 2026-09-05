import AppKit
import SwiftUI

@main
struct XDVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let vpn = VPNManager.shared

    init() {
        ScriptDump.runIfRequested()
        Snapshot.runIfRequested()
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environment(vpn)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(vpn)
        }
    }
}

/// Separate view so the menu bar icon re-renders when the status changes.
private struct MenuBarLabel: View {
    private let vpn = VPNManager.shared

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: vpn.status))
            .accessibilityLabel("XD VPN: \(StatusPresentation(status: vpn.status).title)")
    }
}

/// Menu bar glyphs: the status SF Symbol rendered larger than the default
/// label size (18×20pt instead of 14×15pt), as a template image.
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for status: VPNManager.Status) -> NSImage {
        let name = status.menuBarSymbol
        if let cached = cache[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

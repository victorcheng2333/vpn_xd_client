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
        Image(systemName: vpn.status.menuBarSymbol)
            .accessibilityLabel("XD VPN: \(StatusPresentation(status: vpn.status).title)")
    }
}

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
            StatusPanelView(layout: .popover)
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


import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        VPNManager.shared.start()
        // Pop the panel when the user opens the app; stay quiet at login.
        if !Self.launchedAsLoginItem {
            MenuBarPanel.openAfterLaunch()
        }
        ensureEditMenu()
    }

    /// Tear the tunnel down before quitting so no root openconnect is left behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let vpn = VPNManager.shared
        guard vpn.hasActiveSession else { return .terminateNow }
        Task { @MainActor in
            await vpn.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Menu bar-only apps have no visible menu, but ⌘C/⌘V/⌘A in the settings
    /// window still route through the main menu. Make sure an Edit menu exists.
    private func ensureEditMenu() {
        let app = NSApplication.shared
        let hasPaste = app.mainMenu?.items.contains { item in
            item.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } ?? false
        } ?? false
        guard !hasPaste else { return }

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let menu = app.mainMenu ?? NSMenu()
        menu.addItem(item)
        app.mainMenu = menu
    }
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication,
              let prop = event.paramDescriptor(forKeyword: keyAEPropData)
        else { return false }
        return prop.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

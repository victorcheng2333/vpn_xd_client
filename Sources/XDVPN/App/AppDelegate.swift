import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        VPNManager.shared.start()
        ensureEditMenu()
        // Show the connection window when the user opens the app themselves;
        // stay quiet in the menu bar when macOS launched us at login.
        if !Self.launchedAsLoginItem {
            MainWindowController.shared.show()
        }
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

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication,
              let prop = event.paramDescriptor(forKeyword: keyAEPropData)
        else { return false }
        return prop.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// LSUIElement apps get no main menu, which silently kills ⌘C/⌘V/⌘A in
    /// text fields. Build a minimal Edit menu so the shortcuts route properly.
    private func ensureEditMenu() {
        let app = NSApplication.shared
        let mainMenu = app.mainMenu ?? NSMenu()
        if mainMenu.items.contains(where: { $0.submenu?.title == "Edit" }) { return }
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
        mainMenu.addItem(item)
        app.mainMenu = mainMenu
    }
}

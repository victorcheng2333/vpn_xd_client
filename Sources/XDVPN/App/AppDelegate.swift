import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        VPNManager.shared.start()
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
}

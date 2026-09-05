import AppKit
import SwiftUI

/// The standalone connection window shown at launch (unless launched as a
/// login item) and from the popover's expand button. Closing it just hides
/// it; the app keeps living in the menu bar.
@MainActor
final class MainWindowController: NSWindowController {
    static let shared = MainWindowController()

    private init() {
        let root = StatusPanelView(layout: .window).environment(VPNManager.shared)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = "XD VPN"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

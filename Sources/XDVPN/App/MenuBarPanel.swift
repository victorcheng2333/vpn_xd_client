import AppKit

/// Opens the MenuBarExtra panel programmatically by clicking its status bar
/// button. SwiftUI offers no API for this, so we look the button up once the
/// scene has been built (retrying briefly, since it appears asynchronously).
@MainActor
enum MenuBarPanel {
    static func openAfterLaunch(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.5 : 0.4)) {
            MainActor.assumeIsolated {
                if let button = statusBarButton() {
                    button.performClick(nil)
                    VPNManager.shared.note("启动时已自动打开面板")
                } else if attempt < 10 {
                    openAfterLaunch(attempt: attempt + 1)
                } else {
                    VPNManager.shared.note("启动时未找到菜单栏按钮，未自动打开面板")
                }
            }
        }
    }

    private static func statusBarButton() -> NSStatusBarButton? {
        for window in NSApplication.shared.windows where window.className.contains("StatusBarWindow") {
            if let button = findButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}

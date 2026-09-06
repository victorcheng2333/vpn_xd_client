import SwiftUI
import AppKit

@main struct XDVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: VPNModel

    init() {
        let primary = AppInstanceCoordinator.shared.isPrimary
        _model = StateObject(wrappedValue: VPNModel(startMonitoring: primary, resumeAutomatically: primary,
                                                   activityLog: primary ? RollingActivityLog() : nil))
    }
    var body: some Scene {
        Window("XD VPN", id: "main") {
            ContentView().environmentObject(model)
                .onAppear { delegate.model = model; NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("VPN 配置…") { model.page = .profile; delegate.showWindow() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出并断开 XD VPN") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
        }
        MenuBarExtra(isInserted: Binding(get: { !model.isQuitting && AppInstanceCoordinator.shared.isPrimary }, set: { _ in })) {
            MenuPanelView().environmentObject(model)
        } label: {
            MenuBarStatusIcon(state: model.state)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: VPNModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppInstanceCoordinator.shared.isPrimary else {
            AppInstanceCoordinator.shared.activateExisting()
            NSApp.terminate(nil)
            return
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.quit { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(); return true
    }
    func showWindow() {
        NSApp.windows.first { $0.title == "XD VPN" }?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

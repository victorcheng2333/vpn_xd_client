import AppKit
import SwiftUI

/// Developer aid: `XDVPN --snapshot <dir>` renders the menu panel in every
/// status (plus the settings tabs) to PNG files and exits. Used to eyeball
/// the UI without clicking through the menu bar.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 else { return }
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        NSApplication.shared.setActivationPolicy(.prohibited)
        let vpn = VPNManager.shared
        vpn.previewApply(profile: VPNProfile(server: "vpn.xindong.com:8443", username: "chengfei"), hasPassword: true)

        let statuses: [(String, VPNManager.Status, String?, Bool)] = [
            ("01-setup", .setupRequired, nil, false),
            ("02-disconnected", .disconnected, nil, false),
            ("03-connecting", .connecting, nil, false),
            ("04-connected", .connected, "10.8.0.23", true),
            ("05-reconnecting", .waitingToReconnect(attempt: 2), nil, true),
            ("06-failed-auth", .failed(.authentication), nil, false),
            ("07-failed-cert", .failed(.certificate(pin: "pin-sha256:AbCdEf0123456789+/=")), nil, false),
            ("08-failed-helper", .failed(.helperNotAuthorized), nil, false),
            ("09-paused", .disconnected, nil, true),
        ]
        for (name, status, ip, auto) in statuses {
            vpn.previewApply(status: status, ip: ip, autoConnect: auto, paused: name.contains("paused"))
            let view = MenuPanelView().environment(vpn)
            write(render(view, width: 300), to: dir.appendingPathComponent("\(name).png"))
        }
        write(render(SettingsView().environment(vpn), width: 480), to: dir.appendingPathComponent("10-settings.png"))
        vpn.previewApply(status: .disconnected, ip: nil, autoConnect: true, paused: false)
        exit(0)
    }

    private static func render<V: View>(_ view: V, width: CGFloat) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.backgroundColor = .windowBackgroundColor
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle one run-loop turn before caching the display.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep?, to url: URL) {
        guard let rep, let data = rep.representation(using: .png, properties: [:]) else {
            print("snapshot: failed \(url.lastPathComponent)")
            return
        }
        try? data.write(to: url)
        print("snapshot: wrote \(url.lastPathComponent) \(Int(rep.size.width))x\(Int(rep.size.height))")
    }
}

extension VPNManager {
    /// Preview-only mutators used by `Snapshot`.
    func previewApply(profile: VPNProfile, hasPassword: Bool) {
        self.profile = profile
        previewSetHasStoredPassword(hasPassword)
    }

    func previewApply(status: Status, ip: String?, autoConnect: Bool, paused: Bool) {
        previewSet(status: status, ip: ip, paused: paused)
        self.autoConnect = autoConnect
    }
}

/// `XDVPN --print-helper` / `--print-install-script`: dump the embedded
/// scripts so they can be linted with `bash -n` outside the app.
enum ScriptDump {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--print-helper") {
            print(PrivilegedHelper.scriptSource)
            exit(0)
        }
        if args.contains("--print-install-script") {
            print(PrivilegedHelper.installScriptForLinting())
            exit(0)
        }
    }
}

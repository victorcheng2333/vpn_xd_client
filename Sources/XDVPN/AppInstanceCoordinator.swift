import AppKit
import Darwin

/// Older builds do not own our lock, so also check the bundle ID before allowing
/// a new version to auto-connect. Never terminate a different VPN application.
@MainActor final class AppInstanceCoordinator {
    static let shared = AppInstanceCoordinator()
    let isPrimary: Bool
    private let descriptor: Int32
    private let existing: NSRunningApplication?

    private init() {
        existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.xd.vpn")
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("XD VPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        isPrimary = existing == nil && descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    func activateExisting() { existing?.activate(options: [.activateAllWindows]) }
    deinit { if descriptor >= 0 { close(descriptor) } }
}

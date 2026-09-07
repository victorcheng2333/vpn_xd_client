import Foundation
import Darwin

/// Retire only this app's legacy destinations. No shell, arbitrary paths or
/// recursive deletion. Successful migration preserves a private rollback copy.
public struct LegacyAuthorization {
    private let root: URL
    private let owner: uid_t
    private let beforeMove: (String) throws -> Void
    private let processIsActive: () -> Bool
    public init() { self.init(root: URL(fileURLWithPath: "/"), owner: 0, processIsActive: Self.hasRunningLegacyProcess) }
    init(root: URL, owner: uid_t, beforeMove: @escaping (String) throws -> Void = { _ in }, processIsActive: @escaping () -> Bool = { false }) {
        self.root = root; self.owner = owner; self.beforeMove = beforeMove; self.processIsActive = processIsActive
    }
    private let paths = ["private/etc/sudoers.d/xd-vpn-astra", "Library/PrivilegedHelperTools/com.xd.vpn.helper",
                         "Library/PrivilegedHelperTools/com.xd.vpn.openconnect"]
    public var isPresent: Bool {
        paths.contains { var value = stat(); return lstat(root.appendingPathComponent($0).path, &value) == 0 }
    }

    public func retire() throws {
        guard geteuid() == owner else { throw VPNError.unavailable("旧版授权迁移需要系统服务执行。") }
        let fm = FileManager.default
        let present = paths.filter { var s = stat(); return lstat(root.appendingPathComponent($0).path, &s) == 0 }
        guard !present.isEmpty else { return }
        guard !processIsActive() else { throw VPNError.unavailable("旧版助手或引擎仍在运行，请先断开并退出旧版。") }
        for path in present { try validateTree(root.appendingPathComponent(path)) }
        let rule = root.appendingPathComponent(paths[0])
        if present.contains(paths[0]) {
            let contents = try String(contentsOf: rule, encoding: .utf8)
            let lines = contents.split(separator: "\n")
            guard lines.count == 2, let username = lines.last?.split(separator: " ").first,
                  contents == (try PrivilegePolicy.sudoersRule(username: String(username))) else {
                throw VPNError.unavailable("旧 sudoers 内容与本客户端规则不一致，已保留原文件。")
            }
        }
        // Hold every legacy per-user lease while withdrawing the shared rule.
        // A live old helper keeps its lease through all network cleanup.
        let run = root.appendingPathComponent("private/var/run")
        try validateParents(run)
        func leaseNames() throws -> [String] { try fm.contentsOfDirectory(atPath: run.path).filter {
            $0.range(of: "\\Acom\\.xd\\.vpn\\.[0-9]+\\.lock\\z", options: .regularExpression) != nil
        } }
        let names = try leaseNames()
        var leases = try names.map { try SessionLease(path: run.appendingPathComponent($0).path, owner: owner, timeout: 0) }
        defer { withExtendedLifetime(leases) {} }
        let base = root.appendingPathComponent("Library/PrivilegedHelperTools/.xdvpn-legacy-backups")
        try validateParents(base.deletingLastPathComponent())
        if mkdir(base.path, 0o700) != 0 && errno != EEXIST { throw VPNError.system("无法创建旧授权备份目录。") }
        try validateTree(base)
        var permissions = stat()
        guard lstat(base.path, &permissions) == 0, permissions.st_mode & 0o077 == 0 else {
            throw VPNError.unavailable("旧授权备份目录必须仅 root 可访问。")
        }
        let backup = base.appendingPathComponent(UUID().uuidString)
        guard mkdir(backup.path, 0o700) == 0 else { throw VPNError.system("无法创建旧授权备份。") }
        var moved: [(URL, URL)] = []
        do {
            // Rule goes first: no new old-style sessions can start afterward.
            for path in present {
                try beforeMove(path)
                let source = root.appendingPathComponent(path)
                let destination = backup.appendingPathComponent(source.lastPathComponent)
                try fm.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
            // Recheck after withdrawing the rule and executable, including
            // legacy sessions that raced with the initial inventory.
            leases += try leaseNames().filter { !names.contains($0) }.map {
                try SessionLease(path: run.appendingPathComponent($0).path, owner: owner, timeout: 0)
            }
            guard !processIsActive() else { throw VPNError.unavailable("旧助手在迁移期间启动。") }
        } catch {
            var restored = true
            for (source, destination) in moved.reversed() {
                do { try fm.moveItem(at: destination, to: source) } catch { restored = false }
            }
            if !restored { throw VPNError.system("旧授权迁移未完成，备份保留在 \(backup.path)，需要管理员恢复。") }
            throw VPNError.system("旧授权迁移未完成，已恢复原文件。")
        }
    }

    private static func hasRunningLegacyProcess() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard actual > 0, actual < pids.count else { return true }
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let value = String(cString: path)
                if value == PrivilegePolicy.helperPath || value.hasPrefix(OpenConnect.installedDirectory + "/") ||
                    value.hasPrefix("/Library/PrivilegedHelperTools/.xdvpn-legacy-backups/") { return true }
            }
        }
        return false
    }

    private func validateParents(_ url: URL) throws {
        var path = url
        while path.path != root.path && path.path != "/" {
            try validateEntry(path, directory: true)
            path.deleteLastPathComponent()
        }
    }
    private func validateTree(_ url: URL) throws {
        try validateParents(url.deletingLastPathComponent())
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw VPNError.system("无法读取旧授权文件。") }
        let directory = value.st_mode & S_IFMT == S_IFDIR
        try validateEntry(url, directory: directory)
        if directory {
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                try validateTree(url.appendingPathComponent(name))
            }
        }
    }
    private func validateEntry(_ url: URL, directory: Bool) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_uid == owner,
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              value.st_mode & 0o022 == 0, directory || value.st_nlink == 1 else {
            throw VPNError.unavailable("旧授权路径或权限异常，未修改任何受保护文件。")
        }
    }
}

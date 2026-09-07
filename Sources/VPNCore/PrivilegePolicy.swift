import Foundation
import Darwin

public enum PrivilegePolicy {
    public static let version = "9"
    public static let helperPath = "/Library/PrivilegedHelperTools/com.xd.vpn.helper"
    public static let rulePath = "/private/etc/sudoers.d/xd-vpn-astra"

    public static func trustedInstalledHelper(at path: String = helperPath) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
              FileManager.default.isExecutableFile(atPath: path) else { return false }
        var parent = (path as NSString).deletingLastPathComponent
        while parent != "/" {
            guard lstat(parent, &info) == 0, info.st_uid == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else { return false }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return true
    }

    public static func sudoersRule(username: String) throws -> String {
        guard username != "ALL", username.range(of: "^[a-zA-Z_][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil else {
            throw VPNError.system("当前 macOS 用户名不适用于自动配置授权。")
        }
        // The helper accepts only --version and --session <private socket>.
        // It validates SUDO_UID, socket ownership and peer UID independently.
        return "# XD VPN: only the dedicated VPN helper is allowed.\n\(username) ALL=(root) NOPASSWD: \(helperPath) --version, \(helperPath) --session *\n"
    }
}

import Foundation
import CryptoKit
import VPNCore

enum PrivilegeStatus: Equatable {
    case checking, notInstalled, ready, needsRepair
    var title: String {
        switch self {
        case .checking: "正在检查系统授权"
        case .notInstalled: "尚未安装授权"
        case .ready: "系统授权正常"
        case .needsRepair: "系统授权需要更新"
        }
    }
}

/// Install one bounded root-owned helper. No administrator password is stored.
/// Normal launches only use sudo -n, so they cannot display a password prompt.
enum PrivilegeManager {
    static func status() async -> PrivilegeStatus {
        guard FileManager.default.fileExists(atPath: PrivilegePolicy.helperPath) else { return .notInstalled }
        guard PrivilegePolicy.trustedInstalledHelper() else { return .needsRepair }
        do {
            let result = try await run("/usr/bin/sudo", ["-n", "--", PrivilegePolicy.helperPath, "--version"])
            return result.code == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == PrivilegePolicy.version ? .ready : .needsRepair
        } catch { return .needsRepair }
    }

    static func install() async throws {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/XDVPNHelper").path
        guard FileManager.default.isExecutableFile(atPath: source) else { throw VPNError.system("应用中的授权助手不完整，请重新下载应用。") }
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: source))).map { String(format: "%02x", $0) }.joined()
        let rule = try PrivilegePolicy.sudoersRule(username: NSUserName())
        try await authorize(installScript(source: source, digest: digest, rule: rule))
        guard await status() == .ready else { throw VPNError.system("系统授权未生效，请点击重新检测；也可以重新安装授权。") }
    }

    static func uninstall() async throws {
        try await authorize("""
        set -eu
        /bin/rm -f '\(PrivilegePolicy.rulePath)' '\(PrivilegePolicy.helperPath)'
        """)
    }

    static func installScript(source: String, digest: String, rule: String) -> String {
        """
        set -eu
        umask 077
        TARGET=\(shellQuote(PrivilegePolicy.helperPath))
        RULE=\(shellQuote(PrivilegePolicy.rulePath))
        for DIRECTORY in /Library /Library/PrivilegedHelperTools /private/etc /private/etc/sudoers.d; do
            if [ ! -e "$DIRECTORY" ]; then /bin/mkdir "$DIRECTORY"; /bin/chmod 755 "$DIRECTORY"; fi
            [ ! -L "$DIRECTORY" ] && [ -d "$DIRECTORY" ] || exit 71
            [ "$(/usr/bin/stat -f %u "$DIRECTORY")" = 0 ] || exit 71
            if /usr/bin/find "$DIRECTORY" -prune \\( -perm -0020 -o -perm -0002 \\) -print | /usr/bin/grep -q .; then exit 71; fi
        done
        # Never enable unrelated sudoers snippets or rewrite the global policy.
        /usr/bin/grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+(/private)?/etc/sudoers.d/?[[:space:]]*$' /private/etc/sudoers || exit 72
        WORK=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.xdvpn-install.XXXXXXXX)
        trap '/bin/rm -rf "$WORK"' EXIT
        /usr/bin/install -o root -g wheel -m 755 \(shellQuote(source)) "$WORK/helper"
        [ "$(/usr/bin/shasum -a 256 "$WORK/helper" | /usr/bin/awk '{print $1}')" = \(shellQuote(digest)) ] || exit 73
        /usr/bin/codesign --verify --strict "$WORK/helper"
        /usr/bin/printf '%s' \(shellQuote(rule)) > "$WORK/rule"
        /usr/sbin/chown root:wheel "$WORK/rule"
        /bin/chmod 440 "$WORK/rule"
        /usr/sbin/visudo -cf "$WORK/rule" >/dev/null
        /bin/mv -f "$WORK/helper" "$TARGET"
        /bin/mv -f "$WORK/rule" "$RULE"
        """
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func authorize(_ script: String) async throws {
        let literal = "\"" + script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
        let result = try await run("/usr/bin/osascript", ["-e", "do shell script \(literal) with administrator privileges"], timeout: 180)
        guard result.code == 0 else {
            if result.output.contains("-128") { throw VPNError.system("已取消系统授权。") }
            throw VPNError.system("安装或移除授权未完成。请确认有管理员权限，且系统允许使用 sudoers.d。")
        }
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) async throws -> (code: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe; process.standardError = pipe
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, output))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

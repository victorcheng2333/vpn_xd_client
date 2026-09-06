import Foundation
import CryptoKit
import VPNCore

enum PrivilegeStatus: Equatable {
    case checking, notInstalled, ready, needsUpdate, needsRepair
    var title: String {
        switch self {
        case .checking: "正在检查系统授权"
        case .notInstalled: "尚未安装授权"
        case .ready: "系统授权正常"
        case .needsUpdate: "系统助手需要升级"
        case .needsRepair: "系统助手需要修复"
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
            let status = status(exitCode: result.code, version: result.output)
            guard status == .ready else { return status }
            guard OpenConnect.installedRuntimeIsTrusted else { return .needsRepair }
            return runtimeStatus(bundle: Bundle.main.bundleURL,
                                 installedDirectory: URL(fileURLWithPath: OpenConnect.installedDirectory))
        } catch { return .needsRepair }
    }

    // Content freshness is independent of the helper protocol version. Ownership
    // is validated before this comparison; a matching digest does not grant trust.
    static func runtimeStatus(bundle: URL, installedDirectory: URL) -> PrivilegeStatus {
        guard let executable = OpenConnect.bundledExecutable(in: bundle) else { return .needsRepair }
        let bundledDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent()
        do {
            let matches = try ["openconnect", "vpnc-script"].map { name in
                let bundled = try Data(contentsOf: bundledDirectory.appendingPathComponent(name))
                let installed = try Data(contentsOf: installedDirectory.appendingPathComponent(name))
                return SHA256.hash(data: bundled) == SHA256.hash(data: installed)
            }
            return matches.allSatisfy { $0 } ? .ready : .needsUpdate
        } catch { return .needsRepair }
    }

    static func status(exitCode: Int32, version: String) -> PrivilegeStatus {
        guard exitCode == 0, Int(version.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return .needsRepair }
        return version.trimmingCharacters(in: .whitespacesAndNewlines) == PrivilegePolicy.version ? .ready : .needsUpdate
    }

    static func install() async throws {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/XDVPNHelper").path
        guard FileManager.default.isExecutableFile(atPath: source) else { throw VPNError.system("应用中的授权助手不完整，请重新下载应用。") }
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: source))).map { String(format: "%02x", $0) }.joined()
        guard let executable = OpenConnect.executable else { throw VPNError.system("应用中的内置连接引擎不完整，请重新下载应用。") }
        let runtimeSource = (executable as NSString).deletingLastPathComponent
        let executableDigest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable))).map { String(format: "%02x", $0) }.joined()
        let scriptDigest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: runtimeSource + "/vpnc-script"))).map { String(format: "%02x", $0) }.joined()
        let rule = try PrivilegePolicy.sudoersRule(username: NSUserName())
        try await authorize(installScript(source: source, digest: digest, rule: rule,
            runtimeSource: runtimeSource, executableDigest: executableDigest, scriptDigest: scriptDigest))
        guard await status() == .ready else { throw VPNError.system("系统授权未生效，请点击重新检测；也可以重新安装授权。") }
    }

    static func uninstall() async throws {
        try await authorize("""
        set -eu
        /bin/rm -f '\(PrivilegePolicy.rulePath)' '\(PrivilegePolicy.helperPath)'
        /bin/rm -rf '\(OpenConnect.installedDirectory)'
        """)
    }

    static func installScript(source: String, digest: String, rule: String,
                              runtimeSource: String, executableDigest: String, scriptDigest: String) -> String {
        """
        set -eu
        umask 077
        TARGET=\(shellQuote(PrivilegePolicy.helperPath))
        RULE=\(shellQuote(PrivilegePolicy.rulePath))
        RUNTIME=\(shellQuote(OpenConnect.installedDirectory))
        for DIRECTORY in /Library /Library/PrivilegedHelperTools /private/etc /private/etc/sudoers.d; do
            if [ ! -e "$DIRECTORY" ]; then /bin/mkdir "$DIRECTORY"; /bin/chmod 755 "$DIRECTORY"; fi
            [ ! -L "$DIRECTORY" ] && [ -d "$DIRECTORY" ] || exit 71
            [ "$(/usr/bin/stat -f %u "$DIRECTORY")" = 0 ] || exit 71
            if /usr/bin/find "$DIRECTORY" -prune \\( -perm -0020 -o -perm -0002 \\) -print | /usr/bin/grep -q .; then exit 71; fi
        done
        # Never enable unrelated sudoers snippets or rewrite the global policy.
        /usr/bin/grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+(/private)?/etc/sudoers.d/?[[:space:]]*$' /private/etc/sudoers || exit 72
        WORK=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.xdvpn-install.XXXXXXXX)
        MUTATING=0
        COMMITTED=0
        cleanup() {
            RESULT=$?
            trap - EXIT
            if [ "$MUTATING" = 1 ] && [ "$COMMITTED" = 0 ]; then
                /bin/rm -f "$TARGET" "$RULE"
                /bin/rm -rf "$RUNTIME"
                if [ -f "$WORK/previous-helper" ]; then /bin/mv "$WORK/previous-helper" "$TARGET"; fi
                if [ -f "$WORK/previous-rule" ]; then /bin/mv "$WORK/previous-rule" "$RULE"; fi
                if [ -d "$WORK/previous-runtime" ]; then /bin/mv "$WORK/previous-runtime" "$RUNTIME"; fi
            fi
            /bin/rm -rf "$WORK"
            exit "$RESULT"
        }
        trap cleanup EXIT
        /usr/bin/install -o root -g wheel -m 755 \(shellQuote(source)) "$WORK/helper"
        [ "$(/usr/bin/shasum -a 256 "$WORK/helper" | /usr/bin/awk '{print $1}')" = \(shellQuote(digest)) ] || exit 73
        /usr/bin/codesign --verify --strict "$WORK/helper"
        /bin/mkdir "$WORK/runtime"
        /bin/chmod 755 "$WORK/runtime"
        /usr/bin/install -o root -g wheel -m 755 \(shellQuote(runtimeSource + "/openconnect")) "$WORK/runtime/openconnect"
        /usr/bin/install -o root -g wheel -m 755 \(shellQuote(runtimeSource + "/vpnc-script")) "$WORK/runtime/vpnc-script"
        [ "$(/usr/bin/shasum -a 256 "$WORK/runtime/openconnect" | /usr/bin/awk '{print $1}')" = \(shellQuote(executableDigest)) ] || exit 73
        [ "$(/usr/bin/shasum -a 256 "$WORK/runtime/vpnc-script" | /usr/bin/awk '{print $1}')" = \(shellQuote(scriptDigest)) ] || exit 73
        /usr/bin/codesign --verify --strict "$WORK/runtime/openconnect"
        /bin/sh -n "$WORK/runtime/vpnc-script"
        /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root LANG=C "$WORK/runtime/openconnect" --version >/dev/null
        /usr/bin/printf '%s' \(shellQuote(rule)) > "$WORK/rule"
        /usr/sbin/chown root:wheel "$WORK/rule"
        /bin/chmod 440 "$WORK/rule"
        /usr/sbin/visudo -cf "$WORK/rule" >/dev/null
        # Snapshot only our fixed destinations, then publish after every check.
        [ ! -L "$TARGET" ] && [ ! -L "$RULE" ] && [ ! -L "$RUNTIME" ] || exit 71
        if [ -e "$TARGET" ]; then [ -f "$TARGET" ] || exit 71; /bin/cp -p "$TARGET" "$WORK/previous-helper"; fi
        if [ -e "$RULE" ]; then [ -f "$RULE" ] || exit 71; /bin/cp -p "$RULE" "$WORK/previous-rule"; fi
        if [ -e "$RUNTIME" ]; then [ -d "$RUNTIME" ] || exit 71; /bin/cp -pR "$RUNTIME" "$WORK/previous-runtime"; fi
        MUTATING=1
        /bin/rm -rf "$RUNTIME"
        /bin/mv "$WORK/runtime" "$RUNTIME"
        /bin/mv -f "$WORK/helper" "$TARGET"
        /bin/mv -f "$WORK/rule" "$RULE"
        COMMITTED=1
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

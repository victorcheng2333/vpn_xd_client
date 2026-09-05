import Foundation

enum HelperStatus: Equatable {
    case unknown
    case notInstalled
    /// Installed but `sudo -n` still asks for a password (sudoers rule missing/broken).
    case notAuthorized
    /// Installed and authorized, but the on-disk script differs from the bundled one.
    case outdated
    case ready

    /// Whether connecting can be attempted at all.
    var isUsable: Bool { self == .ready || self == .outdated }

    var title: String {
        switch self {
        case .unknown: return "检查中…"
        case .notInstalled: return "未授权"
        case .notAuthorized: return "授权无效"
        case .outdated: return "已授权（助手需更新）"
        case .ready: return "已授权"
        }
    }
}

/// Manages the tiny root helper that starts/stops openconnect.
///
/// Privilege model: a one-time admin prompt installs
///   * `/usr/local/libexec/xd-vpn-helper` (root:wheel, 0755) – the only thing
///     that ever runs as root, and it accepts a fixed set of commands;
///   * `/etc/sudoers.d/xd-vpn` – lets the current user run *that file only*
///     via `sudo -n`, without a password.
/// After that, connecting and reconnecting never prompt again.
enum PrivilegedHelper {
    static let installPath = "/usr/local/libexec/xd-vpn-helper"
    static let sudoersPath = "/etc/sudoers.d/xd-vpn"
    static let pidFilePath = "/var/run/xd-vpn-openconnect.pid"
    static let version = 2

    // MARK: Helper script (installed verbatim)

    static let scriptSource = #"""
    #!/bin/bash
    # xd-vpn-helper — privileged helper for the XD VPN app.
    #
    # Installed to /usr/local/libexec/xd-vpn-helper (root:wheel 0755) and
    # whitelisted in /etc/sudoers.d/xd-vpn so the app can start/stop
    # openconnect without a password prompt. Only the commands below exist.
    XD_VPN_HELPER_VERSION=2
    PIDFILE=/var/run/xd-vpn-openconnect.pid

    find_openconnect() {
        local p
        for p in /opt/homebrew/bin/openconnect /usr/local/bin/openconnect /usr/bin/openconnect; do
            if [ -x "$p" ]; then echo "$p"; return 0; fi
        done
        return 1
    }

    running_pid() {
        local pid
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
                *openconnect*) echo "$pid"; return 0 ;;
            esac
        fi
        return 1
    }

    case "$1" in
        version)
            echo "$XD_VPN_HELPER_VERSION"
            ;;
        connect)
            server="$2"; user="$3"; servercert="$4"
            if ! [[ "$server" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
                echo "helper: invalid server '$server'" >&2; exit 64
            fi
            if ! [[ "$user" =~ ^[A-Za-z0-9._@+-]+$ ]]; then
                echo "helper: invalid user '$user'" >&2; exit 64
            fi
            if ! oc=$(find_openconnect); then
                echo "helper: openconnect not found (brew install openconnect)" >&2; exit 69
            fi
            if pid=$(running_pid); then
                echo "helper: openconnect already running (pid $pid)" >&2; exit 75
            fi
            extra=()
            if [ -n "$servercert" ]; then
                if ! [[ "$servercert" =~ ^(pin-sha256:[A-Za-z0-9+/=]+|[0-9a-fA-F]{40})$ ]]; then
                    echo "helper: invalid servercert" >&2; exit 64
                fi
                extra=(--servercert "$servercert")
            fi
            if ! echo $$ > "$PIDFILE"; then
                echo "helper: cannot write $PIDFILE" >&2; exit 73
            fi
            # exec keeps our pid, so the pid file now points at openconnect.
            # --reconnect-timeout: how long openconnect keeps retrying with the
            # session cookie after a drop before giving up (then the app logs in again).
            exec "$oc" "$server" --protocol=anyconnect --passwd-on-stdin \
                --user="$user" --non-inter --reconnect-timeout 60 ${extra[@]+"${extra[@]}"}
            ;;
        reconnect)
            # SIGUSR2 makes openconnect drop and immediately re-establish the
            # tunnel with its existing session (same IP, no re-login). Used
            # after Wi-Fi switches / wake from sleep.
            if pid=$(running_pid); then
                kill -USR2 "$pid"
            else
                pkill -USR2 -x openconnect 2>/dev/null
            fi
            ;;
        disconnect)
            sig=INT
            [ "$2" = "force" ] && sig=KILL
            if pid=$(running_pid); then
                kill -"$sig" "$pid"
            else
                pkill -"$sig" -x openconnect 2>/dev/null
            fi
            rm -f "$PIDFILE"
            ;;
        *)
            echo "usage: xd-vpn-helper version | connect <server> <user> [servercert] | reconnect | disconnect [force]" >&2
            exit 64
            ;;
    esac
    """#

    /// Test hook: when set, the helper at this path is executed directly
    /// (without sudo). Used by `--selftest` with a fake helper.
    static var overridePath: String? { ProcessInfo.processInfo.environment["XDVPN_HELPER_OVERRIDE"] }

    /// Executable and arguments for invoking the helper with `arguments`.
    static func command(_ arguments: [String]) -> (executable: String, arguments: [String]) {
        if let overridePath { return (overridePath, arguments) }
        return ("/usr/bin/sudo", ["-n", installPath] + arguments)
    }

    // MARK: Status

    static func checkStatus() async -> HelperStatus {
        let path = overridePath ?? installPath
        guard FileManager.default.fileExists(atPath: path) else { return .notInstalled }
        let cmd = command(["version"])
        let result = await Shell.run(cmd.executable, cmd.arguments, timeout: 10)
        guard result.succeeded else { return .notAuthorized }
        let installed = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return normalized(installed) == normalized(scriptSource) ? .ready : .outdated
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Install / uninstall (one admin prompt each)

    struct AdminError: LocalizedError {
        let message: String
        let cancelled: Bool
        var errorDescription: String? { message }
    }

    static func install() async throws {
        try await runAsAdmin(script: try installScript(for: NSUserName()))
    }

    static func installScriptForLinting() -> String {
        (try? installScript(for: "example")) ?? ""
    }

    private static func installScript(for user: String) throws -> String {
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw AdminError(message: "无法识别当前用户名: \(user)", cancelled: false)
        }
        return """
        #!/bin/bash
        set -e
        HELPER='\(installPath)'
        SUDOERS='\(sudoersPath)'
        USER_NAME='\(user)'
        /usr/bin/install -d -o root -g wheel -m 755 "$(dirname "$HELPER")"
        /bin/cat > "$HELPER.tmp" <<'XD_VPN_HELPER_EOF'
        \(scriptSource)
        XD_VPN_HELPER_EOF
        /usr/sbin/chown root:wheel "$HELPER.tmp"
        /bin/chmod 755 "$HELPER.tmp"
        /bin/mv -f "$HELPER.tmp" "$HELPER"
        /usr/bin/printf '%s\\n' "# Installed by XD VPN.app: lets $USER_NAME run the VPN helper without a password." "$USER_NAME ALL=(root) NOPASSWD: $HELPER" > "$SUDOERS.tmp"
        /usr/sbin/chown root:wheel "$SUDOERS.tmp"
        /bin/chmod 440 "$SUDOERS.tmp"
        /usr/sbin/visudo -cf "$SUDOERS.tmp" >/dev/null
        /bin/mv -f "$SUDOERS.tmp" "$SUDOERS"
        if ! /usr/bin/grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers; then
            /usr/bin/printf '\\n#includedir /etc/sudoers.d\\n' >> /etc/sudoers
        fi
        /usr/sbin/visudo -c >/dev/null
        """
    }

    static func uninstall() async throws {
        let script = """
        #!/bin/bash
        /bin/rm -f '\(sudoersPath)' '\(installPath)' '\(pidFilePath)'
        """
        try await runAsAdmin(script: script)
    }

    private static func runAsAdmin(script: String) async throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("xd-vpn-admin-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let appleScript = "do shell script \"/bin/bash \" & quoted form of \"\(url.path)\" with administrator privileges"
        let result = await Shell.run("/usr/bin/osascript", ["-e", appleScript], timeout: 300)
        guard result.succeeded else {
            let text = result.combinedOutput
            let cancelled = text.contains("-128") || text.contains("User canceled")
            throw AdminError(
                message: cancelled ? "已取消授权" : "授权安装失败：\(text)",
                cancelled: cancelled
            )
        }
    }

    // MARK: Runtime commands

    /// Ask the running openconnect to re-establish the tunnel with its session cookie.
    @discardableResult
    static func reconnect() async -> ShellResult {
        let cmd = command(["reconnect"])
        return await Shell.run(cmd.executable, cmd.arguments, timeout: 10)
    }

    @discardableResult
    static func disconnect(force: Bool = false) async -> ShellResult {
        let cmd = command(force ? ["disconnect", "force"] : ["disconnect"])
        return await Shell.run(cmd.executable, cmd.arguments, timeout: 10)
    }

    /// Whether a Homebrew/system openconnect binary is present (for hints in the UI).
    static var openconnectPath: String? {
        ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect", "/usr/bin/openconnect"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

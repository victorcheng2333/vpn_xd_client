import AppKit
import Foundation
import Network
import Observation
import ServiceManagement

/// Owns the VPN state machine: connect/disconnect, auto-reconnect ("keep
/// online"), fast recovery after network changes, log collection, helper
/// status and login-item registration.
@MainActor
@Observable
final class VPNManager {
    static let shared = VPNManager()

    // MARK: - Types

    enum Status: Equatable {
        case setupRequired
        case disconnected
        case connecting
        case connected
        /// openconnect is alive but re-establishing the tunnel (network change,
        /// dead peer). Same session and IP once it comes back.
        case recovering
        case disconnecting
        case waitingToReconnect(attempt: Int)
        case failed(Failure)

        var isBusy: Bool {
            switch self {
            case .connecting, .disconnecting, .waitingToReconnect, .recovering: return true
            default: return false
            }
        }

        /// Tunnel is up or being restored by a live openconnect process.
        var hasTunnel: Bool { self == .connected || self == .recovering }
    }

    enum Failure: Equatable {
        case authentication
        case helperNotAuthorized
        case openconnectMissing
        case certificate(pin: String?)
        case unreachable
        case timeout
        case dropped
        case other(String)

        /// Failures that are worth retrying automatically. Anything that could be
        /// a wrong password is deliberately excluded to avoid locking the account.
        var isRetryable: Bool {
            switch self {
            case .unreachable, .timeout, .dropped: return true
            default: return false
            }
        }
    }

    struct LogEntry: Identifiable, Equatable {
        enum Kind { case app, output, error }
        let id = UUID()
        let time: Date
        let kind: Kind
        let text: String
    }

    enum Trigger { case user, automatic }

    private enum Phase { case idle, starting, authenticating, tunnel }

    private enum Keys {
        static let autoConnect = "autoConnect"
    }

    // MARK: - Persisted settings

    @ObservationIgnored private let defaults = UserDefaults.standard

    var profile: VPNProfile {
        didSet { profile.save(to: defaults) }
    }

    /// "Keep online": reconnect whenever the tunnel drops and connect at launch.
    var autoConnect: Bool {
        didSet {
            guard autoConnect != oldValue else { return }
            defaults.set(autoConnect, forKey: Keys.autoConnect)
            autoConnectDidChange()
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !isSyncingLaunchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }

    // MARK: - Runtime state

    private(set) var status: Status = .disconnected
    private(set) var connectedSince: Date?
    private(set) var assignedIP: String?
    /// True when we attached to an openconnect process we did not start ourselves.
    private(set) var isExternalSession = false
    /// Set when the user disconnects manually while auto-connect is on.
    private(set) var autoConnectPaused = false
    private(set) var helperStatus: HelperStatus = .unknown
    private(set) var hasStoredPassword = false
    private(set) var nextRetryDate: Date?
    private(set) var log: [LogEntry] = []

    var isConfigured: Bool { profile.isComplete && hasStoredPassword }
    var hasActiveSession: Bool { session != nil || externalPID != nil }
    var hasLegacyScriptPassword: Bool {
        !profile.username.isEmpty
            && Keychain.exists(service: Keychain.legacyScriptService, account: profile.username)
    }

    private var wantsToStayOnline: Bool {
        autoConnect && !autoConnectPaused && isConfigured
    }

    // MARK: - Private state

    @ObservationIgnored private var session: OpenConnectSession?
    @ObservationIgnored private var externalPID: pid_t?
    @ObservationIgnored private var externalMonitor: Timer?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var connectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var userRequestedDisconnect = false
    @ObservationIgnored private var restartAfterExit = false
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var detectedFailure: Failure?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkWatcher: NetworkWatcher?
    @ObservationIgnored private var networkWasReachable = true
    @ObservationIgnored private var lastKick: Date = .distantPast
    @ObservationIgnored private var isSyncingLaunchAtLogin = false
    @ObservationIgnored private var started = false
    /// Test hook: bypasses the keychain (used by `--selftest`).
    @ObservationIgnored var testPasswordOverride: String?

    private static let maxLogEntries = 600
    private static let connectTimeout: TimeInterval = 90
    /// If a cookie-based recovery has not produced a tunnel within this time,
    /// give up on it and log in from scratch.
    private static let recoveryTimeout: TimeInterval = 90
    private static let kickCooldown: TimeInterval = 3

    // MARK: - Init / lifecycle

    private init() {
        profile = VPNProfile.load(from: defaults)
        autoConnect = defaults.bool(forKey: Keys.autoConnect)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Called once from the app delegate after launch.
    func start() {
        guard !started else { return }
        started = true
        appendLog(.app, "XD VPN 已启动")
        hasStoredPassword = testPasswordOverride != nil || Keychain.exists()
        status = isConfigured ? .disconnected : .setupRequired
        startNetworkMonitors()
        observeSystemEvents()

        Task {
            await refreshHelperStatus()
            await adoptExternalSessionIfAny()
            if status == .disconnected, wantsToStayOnline {
                appendLog(.app, "自动连接已开启，正在连接")
                connect(trigger: .automatic)
            }
        }
    }

    /// Gracefully stops a session we started. Used when the app quits.
    func shutdown() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        autoConnectPaused = true
        guard session != nil else { return }
        userRequestedDisconnect = true
        appendLog(.app, "退出应用，断开 VPN")
        await PrivilegedHelper.disconnect()
        for _ in 0..<40 {
            if session == nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await PrivilegedHelper.disconnect(force: true)
    }

    // MARK: - Public actions

    func connect(trigger: Trigger = .user) {
        reconnectTask?.cancel()
        reconnectTask = nil
        nextRetryDate = nil
        if trigger == .user {
            autoConnectPaused = false
            reconnectAttempt = 0
        }

        guard !hasActiveSession else { return }
        switch status {
        case .connecting, .connected, .recovering, .disconnecting: return
        default: break
        }

        guard profile.isComplete else {
            status = .setupRequired
            return
        }
        guard let password = testPasswordOverride ?? Keychain.read(), !password.isEmpty else {
            hasStoredPassword = false
            status = .setupRequired
            appendLog(.error, "钥匙串中没有 VPN 密码，请在设置中填写")
            return
        }
        guard helperStatus.isUsable else {
            status = .failed(.helperNotAuthorized)
            Task { await refreshHelperStatus() }
            return
        }

        userRequestedDisconnect = false
        restartAfterExit = false
        detectedFailure = nil
        phase = .starting
        assignedIP = nil
        status = .connecting
        appendLog(.app, trigger == .user ? "正在连接 \(profile.server)" : "自动连接 \(profile.server)")

        let newSession = OpenConnectSession()
        newSession.onLine = { [weak self] line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleOutput(line) }
            }
        }
        newSession.onExit = { [weak self] code in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleSessionEnded(exitCode: code) }
            }
        }
        do {
            try newSession.start(
                server: profile.server.trimmingCharacters(in: .whitespaces),
                user: profile.username.trimmingCharacters(in: .whitespaces),
                password: password,
                serverCertPin: profile.serverCertPin
            )
            session = newSession
        } catch {
            phase = .idle
            status = .failed(.other(error.localizedDescription))
            appendLog(.error, "无法启动 openconnect: \(error.localizedDescription)")
            return
        }

        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectTimeout))
            guard !Task.isCancelled, let self, self.status == .connecting else { return }
            self.appendLog(.error, "连接超时，正在终止")
            self.detectedFailure = .timeout
            await PrivilegedHelper.disconnect()
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        nextRetryDate = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = nil
        restartAfterExit = false
        if autoConnect { autoConnectPaused = true }

        guard hasActiveSession else {
            status = isConfigured ? .disconnected : .setupRequired
            return
        }
        userRequestedDisconnect = true
        status = .disconnecting
        appendLog(.app, "正在断开")

        Task { await PrivilegedHelper.disconnect() }
        disconnectTimeoutTask?.cancel()
        disconnectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.hasActiveSession else { return }
            self.appendLog(.error, "openconnect 未退出，强制结束")
            await PrivilegedHelper.disconnect(force: true)
        }
    }

    func toggleConnection() {
        if hasActiveSession || status.isBusy { disconnect() } else { connect() }
    }

    /// Ask the live openconnect to drop and immediately re-establish the tunnel
    /// with its session cookie (same IP, no re-login). Used after Wi‑Fi
    /// switches, wake from sleep, or when the network comes back.
    func kickTunnel(reason: String) {
        guard phase == .tunnel, hasActiveSession else { return }
        guard Date().timeIntervalSince(lastKick) > Self.kickCooldown else { return }
        lastKick = Date()

        guard helperStatus == .ready else {
            // Old helper without the `reconnect` command: fall back to a full restart.
            appendLog(.app, "\(reason)，授权助手版本较旧，改为重新登录")
            restartSession()
            return
        }
        appendLog(.app, "\(reason)，立即恢复隧道")
        enterRecovering()
        Task { await PrivilegedHelper.reconnect() }
    }

    /// Tear the current session down and log in again (new IP).
    func restartSession() {
        guard hasActiveSession else { return }
        appendLog(.app, "重新登录 VPN")
        restartAfterExit = true
        userRequestedDisconnect = false
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = nil
        status = .disconnecting
        Task { await PrivilegedHelper.disconnect() }
        disconnectTimeoutTask?.cancel()
        disconnectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.hasActiveSession else { return }
            await PrivilegedHelper.disconnect(force: true)
        }
    }

    /// Accept the certificate pin openconnect suggested and try again.
    func trustServerCertificate(pin: String) {
        profile.serverCertPin = pin
        appendLog(.app, "已信任服务器证书 \(pin)")
        connect(trigger: .user)
    }

    func saveProfile(server: String, username: String, password: String, serverCertPin: String) throws {
        profile = VPNProfile(
            server: server.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            serverCertPin: serverCertPin.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !password.isEmpty {
            try Keychain.write(password)
            hasStoredPassword = true
        }
        appendLog(.app, "已保存配置 \(profile.username)@\(profile.server)")
        refreshIdleStatus()
    }

    /// Copies the password the original `xd-vpn` script stored in the keychain.
    func importLegacyScriptPassword() throws -> Bool {
        guard let password = Keychain.read(service: Keychain.legacyScriptService, account: profile.username),
              !password.isEmpty
        else { return false }
        try Keychain.write(password)
        hasStoredPassword = true
        appendLog(.app, "已从 xd-vpn 脚本导入密码")
        refreshIdleStatus()
        return true
    }

    func clearPassword() {
        Keychain.delete()
        hasStoredPassword = false
        appendLog(.app, "已清除保存的密码")
        refreshIdleStatus()
    }

    func clearLog() { log.removeAll() }

    /// Record an app-level event in the log.
    func note(_ text: String) { appendLog(.app, text) }

    // MARK: - Helper

    func refreshHelperStatus() async {
        helperStatus = await PrivilegedHelper.checkStatus()
        if helperStatus.isUsable, case .failed(.helperNotAuthorized) = status {
            status = .disconnected
        }
    }

    func installHelper() async throws {
        try await PrivilegedHelper.install()
        appendLog(.app, "已安装系统授权助手")
        await refreshHelperStatus()
        if helperStatus == .ready, status == .disconnected, wantsToStayOnline {
            connect(trigger: .automatic)
        }
    }

    func uninstallHelper() async throws {
        if hasActiveSession { disconnect() }
        try await PrivilegedHelper.uninstall()
        appendLog(.app, "已移除系统授权助手")
        await refreshHelperStatus()
    }

    // MARK: - Output parsing

    private func handleOutput(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        let lower = line.lowercased()
        let looksLikeError = line.hasPrefix("sudo:") || line.hasPrefix("helper:")
            || lower.contains("fail") || lower.contains("error") || lower.contains("rejected")
            || lower.contains("dead peer")
        appendLog(looksLikeError ? .error : .output, line)

        if line.hasPrefix("sudo:") {
            detectedFailure = .helperNotAuthorized
            return
        }
        if line.contains("helper: openconnect not found") {
            detectedFailure = .openconnectMissing
            return
        }
        if line.contains("helper: openconnect already running") {
            detectedFailure = .other("已有一个 openconnect 进程在运行")
            return
        }

        // Certificate problems (highest priority: they also trigger an auth failure line).
        if let range = line.range(of: "--servercert ") {
            let pin = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            detectedFailure = .certificate(pin: pin.isEmpty ? nil : pin)
        } else if line.contains("failed verification") {
            detectedFailure = .certificate(pin: nil)
        }

        if detectedFailure == nil {
            if line.contains("Login failed") || line.contains("Authentication failed")
                || line.contains("Failed to complete authentication")
                || line.contains("Failed to obtain WebVPN cookie")
            {
                detectedFailure = .authentication
            } else if line.contains("Failed to open HTTPS connection")
                || line.contains("getaddrinfo failed")
                || line.hasPrefix("Failed to connect to")
                || line.contains("SSL connection failure")
                || line.contains("Failed to reconnect")
            {
                detectedFailure = .unreachable
            }
        }

        // Phase tracking.
        if phase == .starting,
           line.contains("Please enter your username and password")
            || line.hasPrefix("Password:") || line.contains("XML POST enabled")
        {
            phase = .authenticating
        }

        // Tunnel lost while the process stays alive → openconnect is recovering it.
        if phase == .tunnel, status == .connected,
           lower.contains("dead peer") || line.contains("Got pause command")
            || line.contains("Caller paused the connection")
            || line.contains("Failed to reconnect")
            || line.contains("Rehandshake failed")
        {
            appendLog(.app, "隧道中断，openconnect 正在恢复")
            enterRecovering()
        }

        if line.contains("Got CONNECT response") || line.contains("CSTP connected") {
            // First connect: wait for "Connected/Configured as <ip>" to report the IP.
            // Recovery: the session already has its IP, so this alone means we're back.
            if status == .recovering { markConnected(ip: assignedIP) } else { phase = .tunnel }
        }
        if let ip = Self.firstMatch(#"(?:Connected|Configured) as ([0-9A-Fa-f.:]+)"#, in: line) {
            markConnected(ip: ip)
        }
        if line.contains("Established DTLS connection"), status == .recovering {
            markConnected(ip: assignedIP)
        }
    }

    private func markConnected(ip: String?) {
        phase = .tunnel
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = nil
        if let ip { assignedIP = ip }
        switch status {
        case .connected:
            break
        case .recovering:
            status = .connected
            appendLog(.app, "隧道已恢复")
        default:
            connectedSince = Date()
            status = .connected
            reconnectAttempt = 0
            nextRetryDate = nil
            appendLog(.app, "已连接，分配 IP \(ip ?? "未知")")
        }
    }

    private func enterRecovering() {
        guard status != .recovering else { return }
        status = .recovering
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.recoveryTimeout))
            guard !Task.isCancelled, let self, self.status == .recovering else { return }
            self.appendLog(.error, "隧道恢复超时，重新登录")
            self.restartSession()
        }
    }

    // MARK: - Session end & auto-reconnect

    private func handleSessionEnded(exitCode: Int32?) {
        session = nil
        stopExternalMonitor()
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        disconnectTimeoutTask?.cancel()
        disconnectTimeoutTask = nil
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = nil

        let endedPhase = phase
        let wasConnected = endedPhase == .tunnel
        let wasExternal = isExternalSession
        let failure = detectedFailure
        let restart = restartAfterExit
        phase = .idle
        detectedFailure = nil
        restartAfterExit = false
        isExternalSession = false
        connectedSince = nil
        assignedIP = nil

        if let exitCode { appendLog(.app, "openconnect 已退出 (code \(exitCode))") }

        if userRequestedDisconnect {
            userRequestedDisconnect = false
            status = .disconnected
            appendLog(.app, "已断开")
            return
        }

        if restart {
            status = .disconnected
            connect(trigger: .automatic)
            return
        }

        let resolved: Failure
        if let failure {
            resolved = failure
        } else if wasConnected || wasExternal {
            resolved = .dropped
        } else if endedPhase == .authenticating {
            resolved = .authentication
        } else if let exitCode, exitCode != 0 {
            resolved = .other("openconnect 异常退出 (code \(exitCode))")
        } else {
            resolved = .dropped
        }

        if resolved.isRetryable, wantsToStayOnline {
            appendLog(.app, wasConnected ? "连接已断开，准备自动重连" : "连接失败，稍后自动重试")
            scheduleReconnect()
        } else {
            status = .failed(resolved)
            if resolved == .helperNotAuthorized { Task { await refreshHelperStatus() } }
        }
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(3 * pow(2, Double(reconnectAttempt - 1)), 60)
        nextRetryDate = Date().addingTimeInterval(delay)
        status = .waitingToReconnect(attempt: reconnectAttempt)
        appendLog(.app, "第 \(reconnectAttempt) 次重连将在 \(Int(delay)) 秒后开始")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connect(trigger: .automatic)
        }
    }

    /// Fire a pending reconnect immediately (network came back, machine woke up).
    private func reconnectNowIfWaiting(reason: String) {
        switch status {
        case .waitingToReconnect:
            appendLog(.app, "\(reason)，立即重连")
            connect(trigger: .automatic)
        case .failed(let failure) where failure.isRetryable && wantsToStayOnline:
            appendLog(.app, "\(reason)，重新连接")
            connect(trigger: .automatic)
        default:
            break
        }
    }

    /// Network became usable again / changed: recover the tunnel or retry right away.
    private func networkBecameUsable(reason: String) {
        reconnectAttempt = 0
        if phase == .tunnel {
            kickTunnel(reason: reason)
        } else {
            reconnectNowIfWaiting(reason: reason)
        }
    }

    private func autoConnectDidChange() {
        if autoConnect {
            autoConnectPaused = false
            appendLog(.app, "自动连接已开启")
            switch status {
            case .disconnected: connect(trigger: .automatic)
            case .failed(let failure) where failure.isRetryable: connect(trigger: .automatic)
            default: break
            }
        } else {
            appendLog(.app, "自动连接已关闭")
            reconnectTask?.cancel()
            reconnectTask = nil
            nextRetryDate = nil
            if case .waitingToReconnect = status { status = .disconnected }
        }
    }

    private func refreshIdleStatus() {
        switch status {
        case .setupRequired, .disconnected, .failed:
            status = isConfigured ? .disconnected : .setupRequired
            if status == .disconnected, wantsToStayOnline, helperStatus.isUsable {
                connect(trigger: .automatic)
            }
        default:
            break
        }
    }

    // MARK: - External (orphaned) openconnect processes

    private func adoptExternalSessionIfAny() async {
        guard session == nil, externalPID == nil else { return }
        // Never adopt real processes while running against a fake helper (--selftest).
        guard PrivilegedHelper.overridePath == nil else { return }
        guard let pid = await Self.findRunningOpenConnect() else { return }
        externalPID = pid
        isExternalSession = true
        phase = .tunnel
        connectedSince = await Self.processStartDate(pid) ?? Date()
        status = .connected
        appendLog(.app, "发现正在运行的 openconnect (pid \(pid))，已接管")
        startExternalMonitor()
    }

    private func startExternalMonitor() {
        stopExternalMonitor()
        externalMonitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let pid = self.externalPID else { return }
                    if !Self.processExists(pid) {
                        self.externalPID = nil
                        self.handleSessionEnded(exitCode: nil)
                    }
                }
            }
        }
    }

    private func stopExternalMonitor() {
        externalMonitor?.invalidate()
        externalMonitor = nil
        externalPID = nil
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func findRunningOpenConnect() async -> pid_t? {
        if let text = try? String(contentsOfFile: PrivilegedHelper.pidFilePath, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           processExists(pid)
        {
            let comm = await Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
            if comm.stdout.contains("openconnect") { return pid }
        }
        let result = await Shell.run("/usr/bin/pgrep", ["-x", "openconnect"])
        return result.stdout
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .first
    }

    private static func processStartDate(_ pid: pid_t) async -> Date? {
        let result = await Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "lstart="])
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text.replacingOccurrences(of: "  ", with: " "))
    }

    // MARK: - System events

    private func startNetworkMonitors() {
        // Coarse reachability (any usable path at all).
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.networkChanged(reachable: reachable) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "xdvpn.network"))
        pathMonitor = monitor

        // Fine-grained: which physical network we are on (Wi‑Fi switch etc.).
        let watcher = NetworkWatcher()
        watcher.onChange = { [weak self] reason in
            self?.networkBecameUsable(reason: reason)
        }
        watcher.start()
        networkWatcher = watcher
    }

    private func networkChanged(reachable: Bool) {
        let cameBack = reachable && !networkWasReachable
        networkWasReachable = reachable
        if cameBack {
            networkBecameUsable(reason: "网络已恢复")
        } else if !reachable, phase == .tunnel, status == .connected {
            appendLog(.app, "网络不可用，等待恢复")
        }
    }

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.systemDidWake() }
            }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.appendLog(.app, "系统进入睡眠") }
            }
        }
    }

    private func systemDidWake() {
        appendLog(.app, "系统已唤醒")
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            // Give the Wi‑Fi a moment to re-associate. If the path monitor
            // reports the network coming back first, that already triggers recovery.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if self.networkWasReachable {
                self.networkBecameUsable(reason: "系统已唤醒")
            }
        }
    }

    // MARK: - Login item

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                appendLog(.app, "已加入登录项")
            } else {
                try SMAppService.mainApp.unregister()
                appendLog(.app, "已移出登录项")
            }
        } catch {
            appendLog(.error, "设置开机启动失败: \(error.localizedDescription)")
            isSyncingLaunchAtLogin = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isSyncingLaunchAtLogin = false
        }
    }

    // MARK: - Preview support

    func previewSet(status: Status, ip: String?, paused: Bool) {
        self.status = status
        assignedIP = ip
        connectedSince = status.hasTunnel ? Date().addingTimeInterval(-754) : nil
        nextRetryDate = {
            if case .waitingToReconnect = status { return Date().addingTimeInterval(6) }
            return nil
        }()
        autoConnectPaused = paused
        helperStatus = status == .failed(.helperNotAuthorized) ? .notInstalled : .ready
    }

    func previewSetHasStoredPassword(_ value: Bool) {
        hasStoredPassword = value
    }

    // MARK: - Log

    private func appendLog(_ kind: LogEntry.Kind, _ text: String) {
        log.append(LogEntry(time: Date(), kind: kind, text: text))
        if log.count > Self.maxLogEntries {
            log.removeFirst(log.count - Self.maxLogEntries)
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

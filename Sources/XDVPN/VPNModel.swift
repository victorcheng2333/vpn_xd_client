import SwiftUI
import Network
import VPNCore

enum Page: String, CaseIterable { case connection = "连接", profile = "VPN 配置", authorization = "系统授权", activity = "连接日志"
    var icon: String { switch self { case .connection: "square.grid.2x2"; case .profile: "slider.horizontal.3"; case .authorization: "checkmark.shield"; case .activity: "text.alignleft" } }
}
enum ConnectionState: Equatable {
    case idle, authorizing, connecting, connected, reconnecting, waiting, disconnecting, failed
    var title: String {
        switch self {
        case .idle: "尚未连接"; case .authorizing: "正在准备连接"; case .connecting: "正在连接"; case .connected: "已安全连接"
        case .reconnecting: "正在恢复连接"; case .waiting: "等待重新连接"; case .disconnecting: "正在断开"; case .failed: "连接需要检查"
        }
    }
    var isBusy: Bool { [.authorizing, .connecting, .reconnecting, .waiting, .disconnecting].contains(self) }
    var isActive: Bool { ![.idle, .failed].contains(self) }
}
struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let isError: Bool
}

@MainActor final class VPNModel: ObservableObject {
    @Published var page: Page = .connection
    @Published private(set) var profile: VPNProfile?
    @Published private(set) var hasPassword = false
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var autoConnect: Bool
    @Published private(set) var issue: String?
    @Published private(set) var address: String?
    @Published private(set) var connectedAt: Date?
    @Published private(set) var retryAt: Date?
    @Published private(set) var entries: [ActivityEntry] = []
    @Published private(set) var engineAvailable: Bool
    @Published private(set) var networkAvailable = true
    @Published var toast: String?
    @Published private(set) var privilegeStatus: PrivilegeStatus = .checking
    @Published private(set) var privilegeBusy = false
    @Published private(set) var privilegeIssue: String?
    @Published private(set) var isQuitting = false
    private let defaults: UserDefaults
    private let bridge: any HelperControlling
    private let credentials: CredentialAccess
    private let engineLocator: () -> String?
    private let monitor = NWPathMonitor()
    private var retry = RetryPolicy()
    private var retryTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var generation = UUID()
    private var desiredConnection = false
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var physicalMonitor: PhysicalNetworkMonitor?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryDeadline: Task<Void, Never>?
    private var lastRecoveryKick: ContinuousClock.Instant?
    private var pendingRecovery = false
    private var tunnelEstablished = false
    private var restartAfterStop = false
    private let recoveryDelay: Duration
    private let recoveryTimeout: Duration
    private let recoveryCooldown: Duration

    var readyToConnect: Bool { profile != nil && hasPassword }
    var canEdit: Bool { !state.isActive }

    init(defaults: UserDefaults = .standard, bridge: (any HelperControlling)? = nil,
         credentials: CredentialAccess = .live, startMonitoring: Bool = true, resumeAutomatically: Bool = true,
         recoveryDelay: Duration = .seconds(1), recoveryTimeout: Duration = .seconds(10),
         recoveryCooldown: Duration = .seconds(3),
         engineLocator: @escaping () -> String? = { OpenConnect.executable }) {
        self.defaults = defaults
        self.recoveryDelay = recoveryDelay; self.recoveryTimeout = recoveryTimeout
        self.recoveryCooldown = recoveryCooldown
        self.bridge = bridge ?? HelperBridge()
        self.credentials = credentials
        self.engineLocator = engineLocator
        engineAvailable = engineLocator() != nil
        profile = defaults.data(forKey: "profile").flatMap { try? JSONDecoder().decode(VPNProfile.self, from: $0) }
        autoConnect = defaults.bool(forKey: "autoConnect")
        if let profile { hasPassword = credentials.contains(profile.credentialAccount) }
        self.bridge.onEvent = { [weak self] in self?.receive($0) }
        self.bridge.onClose = { [weak self] in self?.helperClosed() }
        if startMonitoring {
        Task { [weak self] in await self?.refreshPrivileges() }
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkChanged(path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.xd.vpn.network"))
        let physical = PhysicalNetworkMonitor { [weak self] in
            Task { @MainActor in self?.physicalNetworkChanged() }
        }
        physicalMonitor = physical
        if !physical.start() { log("部分网络事件监听不可用，将继续使用网络状态与 DPD 恢复。") }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        })
        }
        log("XD VPN 已就绪。")
        if autoConnect && resumeAutomatically {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.readyToConnect { self.connect() }
                else { self.setAutoConnect(false) }
            }
        }
    }

    func save(_ draft: VPNProfile, password: String) throws {
        guard canEdit else { throw VPNError.invalidProfile("请先断开连接，再修改 VPN 配置。") }
        let validated = try draft.validated()
        let old = profile
        if !password.isEmpty { try credentials.save(password, validated.credentialAccount) }
        else if !credentials.contains(validated.credentialAccount) {
            throw VPNError.invalidProfile("请填写密码。更换服务器、用户名或认证组时，需要重新填写密码。")
        }
        let data = try JSONEncoder().encode(validated)
        defaults.set(data, forKey: "profile")
        profile = validated; hasPassword = true
        if let old, old.credentialAccount != validated.credentialAccount {
            do { try credentials.delete(old.credentialAccount) }
            catch { log("新配置已保存；旧密码未能从钥匙串删除。", error: true) }
        }
        issue = nil; state = .idle
        log("VPN 配置已保存，密码已存入本机钥匙串。")
        toast = "配置已保存"
        page = .connection
    }

    func forgetPassword() throws {
        guard canEdit, let profile else { return }
        try credentials.delete(profile.credentialAccount)
        hasPassword = false; setAutoConnect(false)
        toast = "已删除保存的密码"
        log("已从钥匙串删除 VPN 密码。")
    }

    func refreshEngine() { engineAvailable = engineLocator() != nil }

    func setAutoConnect(_ enabled: Bool) {
        if enabled && !readyToConnect { page = .profile; toast = "先保存 VPN 配置，即可开启自动连接"; return }
        autoConnect = enabled
        defaults.set(enabled, forKey: "autoConnect")
        if enabled {
            log("Auto Connect 已开启。应用运行时将自动保持连接。")
            connect()
            if state == .reconnecting { enterRecovering() }
        }
        else {
            retryTask?.cancel(); cancelRecoveryDeadline(); retryAt = nil
            if state == .waiting { state = .idle; desiredConnection = false }
        }
    }

    func connect() {
        guard !isQuitting else { return }
        guard ![.connected, .connecting, .authorizing, .reconnecting, .disconnecting].contains(state) else { return }
        guard readyToConnect, let profile else { page = .profile; return }
        refreshEngine()
        guard engineAvailable else { fail("未安装 OpenConnect。请在终端运行 brew install openconnect，再点击重新检测。") ; return }
        desiredConnection = true
        issue = nil
        pendingRecovery = false; recoveryTask?.cancel()
        retryTask?.cancel(); retryAt = nil
        guard networkAvailable && !sleeping else { state = .waiting; return }
        generation = UUID(); let attempt = generation
        state = bridge.isReady ? .connecting : .authorizing
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bridge.prepare()
                guard self.desiredConnection, self.generation == attempt, !Task.isCancelled else { return }
                let password = try self.credentials.read(profile.credentialAccount)
                try self.bridge.send(.init(.connect, profile: profile, password: password))
                self.state = .connecting
            } catch {
                guard self.generation == attempt else { return }
                self.fail(error.localizedDescription)
                if self.privilegeStatus == .notInstalled || self.privilegeStatus == .needsRepair { self.page = .authorization }
            }
        }
    }

    func disconnect() {
        let wasAuthorizing = state == .authorizing
        desiredConnection = false; generation = UUID()
        connectTask?.cancel(); retryTask?.cancel(); retryAt = nil
        cancelRecovery()
        // An explicit disconnect also turns off Auto Connect, so it stays off.
        autoConnect = false; defaults.set(false, forKey: "autoConnect")
        if wasAuthorizing { bridge.shutdown(); resetConnection(); return }
        if bridge.isReady && [.connected, .connecting, .reconnecting].contains(state) {
            state = .disconnecting
            do { try bridge.send(.init(.disconnect)) }
            catch { bridge.shutdown(); resetConnection() }
        } else { resetConnection() }
    }

    private func receive(_ event: HelperEvent) {
        guard !isQuitting else { return }
        log(event.message, error: event.kind == .failure)
        switch event.kind {
        case .ready, .info: break
        case .connecting: if desiredConnection && state != .disconnecting { state = .connecting }
        case .connected:
            guard desiredConnection else { try? bridge.send(.init(.disconnect)); return }
            guard state != .disconnecting else { return }
            tunnelEstablished = true; cancelRecoveryDeadline()
            state = .connected; issue = nil; retry.reset(); retryAt = nil
            if connectedAt == nil { connectedAt = Date() }
            if let ip = event.address { address = ip }
            if pendingRecovery { scheduleNetworkRecovery() }
        case .reconnecting:
            enterRecovering()
        case .failure:
            issue = event.message
            desiredConnection = false
            cancelRecovery()
            autoConnect = false; defaults.set(false, forKey: "autoConnect")
            retryTask?.cancel(); retryAt = nil
            // Keep controls locked until OpenConnect has actually exited.
            state = .disconnecting
        case .stopped:
            connectedAt = nil; address = nil; tunnelEstablished = false
            cancelRecoveryDeadline(); lastRecoveryKick = nil
            if restartAfterStop && desiredConnection {
                restartAfterStop = false; state = .waiting
                if pendingRecovery { scheduleNetworkRecovery() }
                else { connect() }
            }
            else if desiredConnection && autoConnect && event.retryable { scheduleRetry() }
            else if issue != nil { state = .failed }
            else if desiredConnection && event.retryable {
                fail("VPN 连接已结束。请检查网络和服务器地址后重试；公司 VPN 可能无法在办公网内连接。")
            }
            else { state = .idle; desiredConnection = false }
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        state = .waiting
        guard networkAvailable && !sleeping else { retryAt = nil; return }
        let delay = retry.nextDelay()
        retryAt = Date().addingTimeInterval(delay)
        log("将在 \(Int(delay)) 秒后自动重连。")
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.autoConnect, self.desiredConnection else { return }
            self.connect()
        }
    }

    func networkChanged(_ online: Bool) {
        guard !isQuitting else { return }
        let wasOnline = networkAvailable
        networkAvailable = online
        if !online {
            recoveryTask?.cancel(); cancelRecoveryDeadline()
            retryTask?.cancel(); retryAt = nil
            if desiredConnection { pendingRecovery = true }
            if state == .connected { state = .reconnecting; log("网络暂时不可用，等待网络恢复。") }
        } else if !wasOnline && desiredConnection {
            retry.reset()
            pendingRecovery = true
            scheduleNetworkRecovery()
        }
    }

    func physicalNetworkChanged() {
        guard desiredConnection, !isQuitting else { return }
        retry.reset()
        pendingRecovery = true
        scheduleNetworkRecovery()
    }

    private func scheduleNetworkRecovery() {
        recoveryTask?.cancel()
        retryTask?.cancel(); retryAt = nil
        guard desiredConnection, networkAvailable, !sleeping, !isQuitting else { return }
        let now = ContinuousClock.now
        let earliestKick = lastRecoveryKick?.advanced(by: recoveryCooldown) ?? now
        // Keep the latest network event during cooldown instead of dropping it.
        let deadline = max(now.advanced(by: recoveryDelay), earliestKick)
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled, let self, self.desiredConnection, self.networkAvailable, !self.sleeping, !self.isQuitting else { return }
            self.recoveryTask = nil
            self.recoverOnReadyNetwork()
        }
    }

    private func recoverOnReadyNetwork() {
        pendingRecovery = false
        switch state {
        case .connected,
             .reconnecting where tunnelEstablished:
            enterRecovering()
            log("检测到唤醒或网络切换，立即恢复现有 VPN 会话。")
            do { try bridge.send(.init(.reconnect)) }
            catch { helperClosed(); return }
            lastRecoveryKick = ContinuousClock.now
        case .connecting, .reconnecting:
            // An initial login has no reusable session yet. Finish its cleanup
            // before sending another login, never overlap two VPN processes.
            restartTunnelAfterCleanup()
        case .authorizing:
            generation = UUID(); connectTask?.cancel(); bridge.shutdown()
            state = .waiting; connect()
        case .waiting:
            connect()
        case .disconnecting:
            pendingRecovery = restartAfterStop
        case .idle, .failed:
            break
        }
    }

    /// Every established-tunnel recovery uses the same bounded episode, whether
    /// triggered by a network notification or by OpenConnect's own DPD output.
    private func enterRecovering() {
        guard desiredConnection, !isQuitting,
              [.connected, .connecting, .reconnecting].contains(state) else { return }
        state = .reconnecting
        guard tunnelEstablished, autoConnect, networkAvailable, !sleeping,
              recoveryDeadline == nil else { return }
        recoveryDeadline = Task { [weak self, recoveryTimeout] in
            do { try await Task.sleep(for: recoveryTimeout) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.recoveryDeadline = nil
            guard self.autoConnect, self.desiredConnection, self.state == .reconnecting,
                  self.networkAvailable, !self.sleeping, !self.isQuitting else { return }
            self.log("原会话未能及时恢复，清理旧隧道后重新登录。")
            self.restartTunnelAfterCleanup()
        }
    }

    private func cancelRecoveryDeadline() {
        recoveryDeadline?.cancel(); recoveryDeadline = nil
    }

    private func restartTunnelAfterCleanup() {
        recoveryTask?.cancel(); recoveryTask = nil
        cancelRecoveryDeadline()
        restartAfterStop = true; state = .disconnecting
        do { try bridge.send(.init(.disconnect)) }
        catch { restartAfterStop = false; helperClosed() }
    }

    private func cancelRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil
        cancelRecoveryDeadline(); lastRecoveryKick = nil
        pendingRecovery = false; restartAfterStop = false
    }

    func systemWillSleep() {
        sleeping = true; retryTask?.cancel(); retryAt = nil
        recoveryTask?.cancel(); cancelRecoveryDeadline()
        if desiredConnection { pendingRecovery = true }
        if state == .connected { state = .reconnecting }
    }

    func systemDidWake() {
        sleeping = false
        guard desiredConnection, !isQuitting else { return }
        retry.reset()
        pendingRecovery = true
        scheduleNetworkRecovery()
    }

    private func helperClosed() {
        guard !isQuitting else { return }
        if state.isActive {
            fail("权限助手已退出。请重新连接；若持续失败，请在「系统授权」中重新检测。")
        }
    }
    private func fail(_ message: String) {
        issue = message; state = .failed; desiredConnection = false
        cancelRecovery(); tunnelEstablished = false
        autoConnect = false; defaults.set(false, forKey: "autoConnect")
        retryTask?.cancel(); retryAt = nil; connectedAt = nil; address = nil
        log(message, error: true)
    }
    private func resetConnection() { tunnelEstablished = false; state = issue == nil ? .idle : .failed; connectedAt = nil; address = nil }
    func log(_ message: String, error: Bool = false) {
        entries.append(.init(message: message, isError: error))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }
    func clearLog() { entries.removeAll() }
    func copyLog() {
        let formatter = ISO8601DateFormatter()
        let text = entries.map { "\(formatter.string(from: $0.date)) \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        toast = "日志已复制"
    }
    func quit(completion: @escaping () -> Void) {
        guard !isQuitting else { completion(); return }
        // Remove the menu item immediately. The root helper owns cleanup after
        // receiving shutdown/EOF, so a lost stopped event cannot hang the app.
        isQuitting = true; desiredConnection = false; generation = UUID()
        retryTask?.cancel(); connectTask?.cancel(); retryAt = nil
        cancelRecovery()
        monitor.cancel(); physicalMonitor?.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        bridge.shutdown()
        completion()
    }

    func refreshPrivileges() async {
        privilegeStatus = await PrivilegeManager.status()
    }

    func installPrivileges() async {
        guard canEdit, !privilegeBusy, !isQuitting else { return }
        privilegeBusy = true; privilegeIssue = nil
        defer { privilegeBusy = false }
        do {
            try await PrivilegeManager.install()
            await refreshPrivileges()
            issue = nil; state = .idle
            toast = "授权已保存，之后连接无需再次授权"
            log("系统授权已安装。之后通过专用助手免密连接。")
        } catch { privilegeIssue = error.localizedDescription }
    }

    func removePrivileges() async {
        guard canEdit, !privilegeBusy, !isQuitting else { return }
        privilegeBusy = true; privilegeIssue = nil
        defer { privilegeBusy = false }
        do {
            bridge.shutdown()
            try await PrivilegeManager.uninstall()
            setAutoConnect(false)
            await refreshPrivileges()
            toast = "已移除系统授权"
            log("已移除本客户端的系统授权。")
        } catch { privilegeIssue = error.localizedDescription }
    }
}

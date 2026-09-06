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
    @Published private(set) var logFileIssue: String?
    let activityLog: RollingActivityLog?
    private let defaults: UserDefaults
    private let bridge: any HelperControlling
    private let credentials: CredentialAccess
    private let engineLocator: () -> String?
    // Fallback only. The regular monitor below uses physical link/IP state,
    // independent of the default route and resolver installed by the VPN.
    private let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
    private var retry = RetryPolicy()
    private var retryTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var generation = UUID()
    // Current-session intent is independent of the saved Auto Connect preference.
    // Manual cancellation and terminal errors suspend it until another connect
    // action or the next application launch.
    private var desiredConnection = false
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var physicalMonitor: PhysicalNetworkMonitor?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryDeadline: Task<Void, Never>?
    private var lastRecoveryKick: ContinuousClock.Instant?
    private var pendingRecovery = false
    private var recoveryReasons = Set<String>()
    private var tunnelEstablished = false
    private var restartAfterStop = false
    private let recoveryDelay: Duration
    private let recoveryTimeout: Duration
    private let recoveryCooldown: Duration

    var readyToConnect: Bool { profile != nil && hasPassword }
    var canEdit: Bool { !state.isActive }

    init(defaults: UserDefaults = .standard, bridge: (any HelperControlling)? = nil,
         credentials: CredentialAccess = .live, startMonitoring: Bool = true, resumeAutomatically: Bool = true,
         recoveryDelay: Duration = .seconds(1), recoveryTimeout: Duration = .seconds(3),
         recoveryCooldown: Duration = .seconds(3),
         activityLog: RollingActivityLog? = nil,
         engineLocator: @escaping () -> String? = { OpenConnect.executable }) {
        self.defaults = defaults
        self.activityLog = activityLog
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
        activityLog?.onStatus = { [weak self] available in
            Task { @MainActor in
                guard let self else { return }
                self.logFileIssue = available ? nil : "文件日志暂不可用，连接不受影响；仍可查看本次会话日志。"
            }
        }
        if startMonitoring {
        Task { [weak self] in await self?.refreshPrivileges() }
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.fallbackNetworkChanged(path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.xd.vpn.network"))
        let physical = PhysicalNetworkMonitor { [weak self] observation in
            Task { @MainActor in self?.physicalNetworkObserved(observation) }
        }
        physicalMonitor = physical
        if !physical.start() { log("部分网络事件监听不可用，将继续使用可用的物理网络监听与 DPD 恢复。") }
        if let online = physical.isAvailable { networkChanged(online) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        })
        }
        log("XD VPN 已就绪。", source: .lifecycle, event: "app.started")
        if autoConnect && resumeAutomatically {
            let startupGeneration = generation
            Task { @MainActor [weak self] in
                guard let self, self.autoConnect, self.generation == startupGeneration else { return }
                self.connect()
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
        hasPassword = false
        toast = "已删除保存的密码"
        log("已从钥匙串删除 VPN 密码。")
    }

    func refreshEngine() { engineAvailable = engineLocator() != nil }

    func setAutoConnect(_ enabled: Bool) {
        guard autoConnect != enabled else { return }
        autoConnect = enabled
        defaults.set(enabled, forKey: "autoConnect")
        if enabled {
            log("Auto Connect 已开启。下次启动时自动连接，连接中掉线后自动重试；手动断开后保持断开。")
            if state == .reconnecting { enterRecovering() }
        }
        else {
            retryTask?.cancel(); retryAt = nil
            if state == .waiting { state = .idle; desiredConnection = false }
            if restartAfterStop { desiredConnection = false; cancelRecovery() }
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
        log("开始新连接尝试。", source: .recovery, event: "connect.begin")
        // Until the command is sent there is no child to stop or acknowledge
        // cleanup. Offline cancellation must invalidate this pending task.
        state = .authorizing
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bridge.prepare()
                guard self.desiredConnection, self.generation == attempt, !Task.isCancelled else { return }
                let password = try self.credentials.read(profile.credentialAccount)
                try self.bridge.send(.init(.connect, profile: profile, password: password))
                self.log("已向助手发送新连接请求。", source: .recovery, event: "connect.requested")
                self.state = .connecting
            } catch {
                guard self.generation == attempt else { return }
                self.fail(error.localizedDescription)
                await self.refreshPrivileges()
                guard self.generation == attempt else { return }
                if [.notInstalled, .needsUpdate, .needsRepair].contains(self.privilegeStatus) { self.page = .authorization }
            }
        }
    }

    func disconnect() {
        guard !isQuitting else { return }
        log("用户请求断开或取消连接。", event: "disconnect.requested")
        let wasAuthorizing = state == .authorizing
        desiredConnection = false; generation = UUID()
        connectTask?.cancel(); retryTask?.cancel(); retryAt = nil
        cancelRecovery()
        if wasAuthorizing { bridge.shutdown(); resetConnection(); return }
        if state == .disconnecting { return } // Cleanup is already in progress.
        if bridge.isReady && [.connected, .connecting, .reconnecting].contains(state) {
            state = .disconnecting
            do { try bridge.send(.init(.disconnect)) }
            catch { bridge.shutdown(); resetConnection() }
        } else { resetConnection() }
    }

    private func receive(_ event: HelperEvent) {
        guard !isQuitting else { return }
        log(event.message, error: event.kind == .failure, source: .helper, event: event.kind.rawValue)
        switch event.kind {
        case .ready, .info: break
        case .connecting: if desiredConnection && state != .disconnecting { state = .connecting }
        case .connected:
            guard state != .disconnecting else { return }
            guard desiredConnection else { try? bridge.send(.init(.disconnect)); return }
            tunnelEstablished = true; cancelRecoveryDeadline()
            state = networkAvailable && !sleeping ? .connected : .reconnecting
            issue = nil; retry.reset(); retryAt = nil
            if connectedAt == nil { connectedAt = Date() }
            if let ip = event.address { address = ip }
            if pendingRecovery { scheduleNetworkRecovery() }
            else { recoveryReasons.removeAll() }
        case .reconnecting:
            enterRecovering()
        case .failure:
            if desiredConnection, autoConnect, tunnelEstablished,
               state == .reconnecting || restartAfterStop,
               event.message == EngineOutput.networkConfigurationFailureMessage {
                // A previously working tunnel can lose its interface/routes on
                // Wi-Fi change. Version 2 helpers stop it as a fatal error, but
                // a fresh login can rebuild the configuration. Wait for their
                // stopped event even when it carries retryable: false.
                issue = nil
                retryTask?.cancel(); retryAt = nil
                recoveryTask?.cancel(); recoveryTask = nil
                cancelRecoveryDeadline()
                restartAfterStop = true; state = .disconnecting
                log("恢复现有会话时网络配置失败，等待旧进程清理后立即重新登录。")
                break
            }
            issue = event.message
            desiredConnection = false
            cancelRecovery()
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
        if wasOnline != online && desiredConnection {
            recoveryReasons.insert(online ? "物理网络重新就绪" : "物理网络断开")
        }
        networkAvailable = online
        if !online {
            recoveryTask?.cancel(); cancelRecoveryDeadline()
            retryTask?.cancel(); retryAt = nil
            if desiredConnection { pendingRecovery = true }
            guard desiredConnection else { return }
            switch state {
            case .connected, .connecting, .reconnecting:
                if tunnelEstablished {
                    if state == .connected { log("物理网络已断开，暂停主动恢复，等待网络重新就绪。") }
                    state = .reconnecting
                } else {
                    // An unfinished login has no established session to preserve.
                    // The version 3 helper owns and verifies any partial cleanup.
                    stopTunnelForRecovery(restart: true)
                }
            case .authorizing:
                generation = UUID(); connectTask?.cancel(); bridge.shutdown()
                state = .waiting
            case .waiting, .disconnecting, .idle, .failed:
                break
            }
        } else if !wasOnline && desiredConnection {
            retry.reset()
            pendingRecovery = true
            scheduleNetworkRecovery()
        }
    }

    private func fallbackNetworkChanged(_ online: Bool) {
        guard physicalMonitor?.isAvailable == nil else { return }
        if networkAvailable != online {
            log("回退网络监听报告物理网络\(online ? "就绪" : "未就绪")。", source: .physical, event: "fallback.changed")
        }
        networkChanged(online)
    }

    func physicalNetworkObserved(_ observation: PhysicalNetworkObservation) {
        guard !isQuitting else { return }
        guard observation.shouldNotify else {
            // Keep recurring AP announcements out of the UI and recovery
            // timers, but retain evidence of why they were ignored on disk.
            persist(observation.summary, date: Date(), source: .physical, event: "notification.ignored")
            return
        }
        log(observation.summary, source: .physical, event: "configuration.changed")
        physicalNetworkChanged(online: observation.online, reason: observation.source.rawValue + ":" +
            (observation.changedFields.isEmpty ? "SSID 变化通知" : observation.changedFields.joined(separator: ",")))
    }

    // Callers promise a real change, not merely another "still online" signal.
    func physicalNetworkChanged(online: Bool? = nil, reason: String = "物理配置变化") {
        if desiredConnection { recoveryReasons.insert(reason) }
        if let online {
            let wasOnline = networkAvailable
            networkChanged(online)
            // A readiness transition already schedules recovery or cleanup.
            guard online && wasOnline else { return }
        }
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
        let reason = recoveryReasons.isEmpty ? "物理网络变化" : recoveryReasons.sorted().joined(separator: "；")
        recoveryReasons.removeAll()
        switch state {
        case .connected,
             .reconnecting where tunnelEstablished:
            enterRecovering()
            do {
                try bridge.send(.init(.reconnect))
                log("已向助手请求恢复现有 VPN 会话；原因：\(reason)。", source: .recovery, event: "reconnect.requested")
            }
            catch { helperClosed(); return }
            lastRecoveryKick = ContinuousClock.now
        case .connecting, .reconnecting:
            // An initial login has no reusable session yet. Finish its cleanup
            // before sending another login, never overlap two VPN processes.
            log("网络变化发生在首次登录期间，清理后重试；原因：\(reason)。", source: .recovery, event: "login.restart")
            restartTunnelAfterCleanup()
        case .authorizing:
            generation = UUID(); connectTask?.cancel(); bridge.shutdown()
            state = .waiting; connect()
        case .waiting:
            log("网络就绪，继续待执行的连接；原因：\(reason)。", source: .recovery, event: "connection.resumed")
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
        guard tunnelEstablished, networkAvailable, !sleeping,
              recoveryDeadline == nil else { return }
        recoveryDeadline = Task { [weak self, recoveryTimeout] in
            do { try await Task.sleep(for: recoveryTimeout) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.recoveryDeadline = nil
            guard self.desiredConnection, self.state == .reconnecting,
                  self.networkAvailable, !self.sleeping, !self.isQuitting else { return }
            self.log(self.autoConnect ? "原会话未能及时恢复，清理旧隧道后重新登录。" : "原会话未能及时恢复，清理旧隧道并恢复系统网络。", source: .recovery, event: "recovery.deadline")
            self.stopTunnelForRecovery(restart: self.autoConnect)
        }
    }

    private func cancelRecoveryDeadline() {
        recoveryDeadline?.cancel(); recoveryDeadline = nil
    }

    private func restartTunnelAfterCleanup() {
        stopTunnelForRecovery(restart: true)
    }

    private func stopTunnelForRecovery(restart: Bool) {
        recoveryTask?.cancel(); recoveryTask = nil
        cancelRecoveryDeadline()
        restartAfterStop = restart
        if !restart { desiredConnection = false; pendingRecovery = false }
        state = .disconnecting
        do { try bridge.send(.init(.disconnect)) }
        catch { restartAfterStop = false; helperClosed() }
    }

    private func cancelRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil
        cancelRecoveryDeadline(); lastRecoveryKick = nil
        pendingRecovery = false; restartAfterStop = false
        recoveryReasons.removeAll()
    }

    func systemWillSleep() {
        log("系统即将睡眠，暂停主动恢复。", source: .lifecycle, event: "system.sleep")
        sleeping = true; retryTask?.cancel(); retryAt = nil
        recoveryTask?.cancel(); cancelRecoveryDeadline()
        if desiredConnection { pendingRecovery = true }
        if state == .connected { state = .reconnecting }
    }

    func systemDidWake() {
        sleeping = false
        log("系统已唤醒。", source: .lifecycle, event: "system.wake")
        guard desiredConnection, !isQuitting else { return }
        recoveryReasons.insert("系统唤醒")
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
        retryTask?.cancel(); retryAt = nil; connectedAt = nil; address = nil
        log(message, error: true)
    }
    private func resetConnection() { tunnelEstablished = false; state = issue == nil ? .idle : .failed; connectedAt = nil; address = nil }
    func log(_ message: String, error: Bool = false, source: RollingActivityLog.Source = .app, event: String = "status") {
        let entry = ActivityEntry(message: message, isError: error)
        entries.append(entry)
        persist(message, date: entry.date, source: source, event: event, error: error)
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }
    private func persist(_ message: String, date: Date, source: RollingActivityLog.Source, event: String, error: Bool = false) {
        activityLog?.append(message, date: date, source: source, event: event, state: state.title,
                            connection: generation.uuidString, autoConnect: autoConnect, isError: error)
    }
    func showLogFolder() {
        guard let activityLog, NSWorkspace.shared.open(activityLog.directory) else {
            toast = "日志目录暂不可用，请查看本次会话日志。"
            return
        }
    }
    func clearLog() { entries.removeAll() }
    func copyLog() {
        let formatter = ISO8601DateFormatter()
        let text = entries.map { "\(formatter.string(from: $0.date)) \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        toast = "日志已复制"
    }
    func quit(completion: @escaping () -> Void) {
        guard !isQuitting else {
            if let activityLog { activityLog.flush(completion: completion) }
            else { completion() }
            return
        }
        log("退出应用，已请求助手独立完成断开清理。", source: .lifecycle, event: "app.quitting")
        // Remove the menu item immediately. The root helper owns cleanup after
        // receiving shutdown/EOF, so a lost stopped event cannot hang the app.
        isQuitting = true; desiredConnection = false; generation = UUID()
        retryTask?.cancel(); connectTask?.cancel(); retryAt = nil
        cancelRecovery()
        monitor.cancel(); physicalMonitor?.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        bridge.shutdown()
        if let activityLog { activityLog.flush(completion: completion) }
        else { completion() }
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
            toast = "系统助手已就绪，连接无需输入 Mac 密码"
            log("系统助手已安装或升级，专用免密授权已通过检测。")
            page = .connection
        } catch { privilegeIssue = error.localizedDescription }
    }

    func removePrivileges() async {
        guard canEdit, !privilegeBusy, !isQuitting else { return }
        privilegeBusy = true; privilegeIssue = nil
        defer { privilegeBusy = false }
        do {
            bridge.shutdown()
            try await PrivilegeManager.uninstall()
            await refreshPrivileges()
            toast = "已移除系统授权"
            log("已移除本客户端的系统授权。")
        } catch { privilegeIssue = error.localizedDescription }
    }
}

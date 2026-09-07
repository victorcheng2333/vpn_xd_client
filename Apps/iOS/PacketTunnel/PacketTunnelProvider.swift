import Foundation
import Network
import NetworkExtension

/// Waits only on the C worker. The provider queue and NE completion handlers never block.
private final class SettingsReply {
    private let condition = NSCondition()
    private var value: Bool?
    var pending: Bool { condition.lock(); defer { condition.unlock() }; return value == nil }
    @discardableResult func finish(_ result: Bool) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard value == nil else { return false }
        value = result; condition.broadcast(); return true
    }
    func wait() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(20)
        while value == nil { if !condition.wait(until: deadline) { value = false } }
        return value!
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "XDVPN.iOS.tunnel")
    private let worker = DispatchQueue(label: "XDVPN.iOS.openconnect", qos: .utility)
    private var engine: OCEngine?
    private var pump: PacketPump?
    private var monitor: NWPathMonitor?
    private var pathUpdate: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var generation = 0
    private var sessionSerial = 0
    private var stopping = false
    private var available = true
    private var pathSignature: String?
    private var startReply: ((Error?) -> Void)?
    private var stopReplies: [() -> Void] = []
    private var settingsReply: SettingsReply?
    private var profile: VPNProfile?
    private var passwordReference: Data?
    private var snapshot = DiagnosticSnapshot()
    private var timer: DispatchSourceTimer?
    private let store = SharedStore()
    private var lastSettingsError: Error?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            guard self.engine == nil, self.startReply == nil, self.monitor == nil else {
                completionHandler(ConfigurationError.invalid("已有连接正在运行。")); return
            }
            self.stopping = false
            self.sessionSerial += 1
            let session = self.sessionSerial
            self.pathSignature = nil
            self.lastSettingsError = nil
            self.startReply = completionHandler
            do {
                guard let proto = self.protocolConfiguration as? NETunnelProviderProtocol, let reference = proto.passwordReference else {
                    throw ConfigurationError.invalid("缺少 VPN 配置或密码，请在 App 中保存。")
                }
                self.profile = try VPNProfile.decode(proto.providerConfiguration)
                self.passwordReference = reference
                self.snapshot = DiagnosticSnapshot()
                self.record("正在准备连接")
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
                self.monitor = monitor; monitor.start(queue: self.queue)
                self.startAttempt()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 5, repeating: 5)
                timer.setEventHandler { [weak self] in self?.saveSnapshot() }
                self.timer = timer; timer.resume()
                self.queue.asyncAfter(deadline: .now() + 90) { [weak self] in
                    guard let self, self.sessionSerial == session, self.startReply != nil else { return }
                    self.finish(ConfigurationError.invalid("首次连接超时，请检查网络、网关和认证方式。"))
                }
            } catch { self.finish(error) }
        }
    }
    private func startAttempt() {
        guard !stopping, engine == nil, let profile, let passwordReference else { return }
        retry = nil
        do {
            var policy = try store.read(RecoveryPolicy.self, name: "recovery", fallback: RecoveryPolicy())
            do { try policy.begin(now: Date()) }
            catch { try store.write(policy, name: "recovery"); throw error }
            try store.write(policy, name: "recovery")
            let password = try KeychainStore.read(passwordReference)
            let engine = OCEngine(server: profile.server, username: profile.username, password: password, group: profile.group, useDTLS: profile.useDTLS)
            self.engine = engine
            generation += 1
            let token = generation
            engine.updateNetworkAvailable(available, reconnect: false)
            worker.async { [weak self] in
                guard let self else { return }
                let result = engine.run(settingsHandler: { [weak self] dictionary, fd in
                    guard let self else { return false }
                    let reply = SettingsReply()
                    self.queue.async { self.apply(dictionary, fd: fd, token: token, reply: reply) }
                    return reply.wait()
                }, eventHandler: { [weak self] event in
                    self?.queue.async { [weak self] in self?.event(event, token: token) }
                })
                self.queue.async { self.attemptFinished(engine: engine, result: result, token: token) }
            }
        } catch { blockAutomatic(error.localizedDescription); finish(error) }
    }
    private func apply(_ dictionary: [String: Any], fd: Int32, token: Int, reply: SettingsReply) {
        guard token == generation, !stopping, reply.pending else { reply.finish(false); return }
        do {
            let plan = try NetworkPlan(dictionary)
            guard plan.requiresFullTunnel == (profile?.fullTunnel == true) else {
                throw ConfigurationError.invalid(plan.requiresFullTunnel
                    ? "网关要求全隧道，当前保存的路由配置不兼容。"
                    : "网关下发分流策略，当前保存的路由配置不兼容。")
            }
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: plan.gateway)
            if let address = plan.ipv4 {
                let v4 = NEIPv4Settings(addresses: [address.address], subnetMasks: [address.ipv4Mask])
                v4.includedRoutes = plan.includes.filter { $0.family == AF_INET }.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.ipv4Mask) }
                v4.excludedRoutes = plan.excludes.filter { $0.family == AF_INET }.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.ipv4Mask) }
                settings.ipv4Settings = v4
            }
            if let address = plan.ipv6 {
                let v6 = NEIPv6Settings(addresses: [address.address], networkPrefixLengths: [NSNumber(value: address.prefix)])
                v6.includedRoutes = plan.includes.filter { $0.family == AF_INET6 }.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) }
                v6.excludedRoutes = plan.excludes.filter { $0.family == AF_INET6 }.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) }
                settings.ipv6Settings = v6
            }
            if plan.blocksIPv6 {
                // includeAllNetworks enforces capture; a local-only IPv6 address
                // lets the pump explicitly discard IPv6 instead of forwarding it
                // to an IPv4-only gateway. This is not a server-assigned address.
                let v6 = NEIPv6Settings(addresses: ["fd6d:7864:7670::1"], networkPrefixLengths: [128])
                v6.includedRoutes = [NEIPv6Route.default()]
                settings.ipv6Settings = v6
            }
            let dns = NEDNSSettings(servers: plan.dns)
            dns.matchDomains = plan.domains
            dns.matchDomainsNoSearch = true
            dns.searchDomains = plan.searchDomains
            settings.dnsSettings = dns
            settings.mtu = NSNumber(value: plan.mtu)
            settingsReply = reply
            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else { reply.finish(false); return }
                self.queue.async {
                    guard token == self.generation, !self.stopping, reply.pending else { reply.finish(false); return }
                    self.settingsReply = nil
                    if let error { self.lastSettingsError = error; reply.finish(false); return }
                    self.snapshot.address = [plan.ipv4?.address, plan.ipv6?.address].compactMap { $0 }.joined(separator: " / ")
                    if let pump = self.pump { pump.mtu = plan.mtu; pump.blocksIPv6 = plan.blocksIPv6 }
                    else {
                        let pump = PacketPump(flow: self.packetFlow, fd: fd, mtu: plan.mtu, queue: self.queue)
                        pump.blocksIPv6 = plan.blocksIPv6
                        self.pump = pump; pump.start()
                    }
                    if plan.blocksIPv6 { self.record("IPv4 全隧道，IPv6 已阻断", updatePhase: false) }
                    reply.finish(true)
                }
            }
        } catch { lastSettingsError = error; reply.finish(false) }
    }
    private func event(_ event: String, token: Int) {
        guard token == generation, !stopping else { return }
        switch event {
        case "authenticating": record("正在认证")
        case "establishing": record("正在建立隧道")
        case "recovering": snapshot.transport = "恢复中"; reasserting = startReply == nil; record(available ? "正在恢复连接" : "等待网络")
        case "tls": snapshot.transport = "TLS"; saveSnapshot()
        case "dtls": snapshot.transport = "DTLS"; saveSnapshot()
        case "connected":
            reasserting = false
            if snapshot.transport != "DTLS" { snapshot.transport = "TLS" }
            record("已连接")
            let completion = startReply; startReply = nil; completion?(nil)
        case "certificateRejected": record("服务器证书校验失败")
        default: break
        }
    }
    private func attemptFinished(engine: OCEngine, result: Int, token: Int) {
        guard token == generation else { return }
        pump?.stop(); saveSnapshot(); pump = nil; self.engine = nil
        settingsReply?.finish(false); settingsReply = nil
        if stopping { completeStop(); return }
        let error: Error
        if engine.certificateFailed { error = ConfigurationError.invalid(engine.certificateFailureDetail) }
        else if engine.authenticationFailed || result == -Int(EPERM) { error = ConfigurationError.invalid("认证被拒绝或会话已过期。请检查密码；验证版暂不支持 MFA/SSO。") }
        else if engine.settingsFailed { error = lastSettingsError ?? ConfigurationError.invalid("隧道网络配置失败或超时。") }
        else {
            reasserting = startReply == nil
            record("连接中断（\(result)），等待恢复")
            let job = DispatchWorkItem { [weak self] in
                guard let self, !self.stopping else { return }
                if self.available { self.startAttempt() } else { self.retry = nil }
            }
            retry = job; queue.asyncAfter(deadline: .now() + 3 + Double.random(in: 0...1), execute: job)
            return
        }
        blockAutomatic(error.localizedDescription); finish(error)
    }
    private func pathChanged(_ path: Network.NWPath) {
        guard !stopping else { return }
        let names = path.availableInterfaces.filter { $0.type != .other && $0.type != .loopback }.map { $0.name }.sorted().joined(separator: ",")
        let signature = "\(path.status)|\(names)|\(path.supportsIPv4)|\(path.supportsIPv6)"
        guard signature != pathSignature else { return }
        let hadPath = pathSignature != nil
        pathSignature = signature
        available = path.status != .unsatisfied
        pathUpdate?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping else { return }
            self.record(self.available ? "网络路径可用" : "等待网络", updatePhase: !self.available)
            self.engine?.updateNetworkAvailable(self.available, reconnect: hadPath)
            if self.available && self.engine == nil && self.retry == nil { self.startAttempt() }
        }
        pathUpdate = job
        queue.asyncAfter(deadline: .now() + 0.75, execute: job)
    }
    override func sleep(completionHandler: @escaping () -> Void) {
        queue.async { self.record("系统进入睡眠", updatePhase: false); completionHandler() }
    }
    override func wake() {
        queue.async {
            guard !self.stopping else { return }
            self.record("系统唤醒", updatePhase: false)
            self.engine?.updateNetworkAvailable(self.available, reconnect: true)
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.record("系统停止隧道（\(reason.rawValue)）")
            self.stopReplies.append(completionHandler)
            self.stopping = true; self.cancelWork()
            let start = self.startReply; self.startReply = nil
            start?(ConfigurationError.invalid("连接已取消。"))
            self.engine?.cancel()
            if self.engine == nil { self.completeStop() }
        }
    }
    private func finish(_ error: Error) {
        guard !stopping else { return }
        stopping = true; record(error.localizedDescription); cancelWork(); engine?.cancel()
        let completion = startReply; startReply = nil
        if let completion { completion(error) }
        else { cancelTunnelWithError(error) }
        if engine == nil { completeStop() }
    }
    private func cancelWork() {
        retry?.cancel(); retry = nil; pathUpdate?.cancel(); pathUpdate = nil
        monitor?.cancel(); monitor = nil; timer?.cancel(); timer = nil
        settingsReply?.finish(false); settingsReply = nil
        pump?.stop(); reasserting = false
    }
    private func completeStop() {
        pump?.stop(); saveSnapshot(); pump = nil
        let completions = stopReplies; stopReplies = []
        completions.forEach { $0() }
    }
    private func blockAutomatic(_ reason: String) {
        do {
            var policy = try store.read(RecoveryPolicy.self, name: "recovery", fallback: RecoveryPolicy())
            policy.blockedReason = reason; try store.write(policy, name: "recovery")
        } catch { record("无法保存恢复限制，连接已停止") }
        // Best effort: even if preferences cannot be changed here, the durable gate prevents further password submissions.
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            for manager in managers ?? [] {
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                      proto.providerBundleIdentifier == Bundle.main.bundleIdentifier else { continue }
                manager.isOnDemandEnabled = false
                manager.saveToPreferences { _ in }
            }
        }
    }
    private func record(_ event: String, updatePhase: Bool = true) {
        if updatePhase { snapshot.phase = event }
        let stamp = ISO8601DateFormatter().string(from: Date())
        if snapshot.events.last?.hasSuffix(event) != true { snapshot.events.append("\(stamp)  \(event)") }
        snapshot.events = Array(snapshot.events.suffix(64)); saveSnapshot()
    }
    private func saveSnapshot() {
        snapshot.updatedAt = Date()
        if let pump {
            snapshot.packetsToTunnel = pump.sent; snapshot.packetsFromTunnel = pump.received; snapshot.droppedPackets = pump.dropped
        }
        try? store.write(snapshot, name: "diagnostics")
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async {
            guard messageData == Data("status".utf8) else { completionHandler?(nil); return }
            self.saveSnapshot(); completionHandler?(try? JSONEncoder().encode(self.snapshot))
        }
    }
}

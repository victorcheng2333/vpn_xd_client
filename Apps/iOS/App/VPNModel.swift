import Foundation
import NetworkExtension
import Combine

@MainActor
final class VPNModel: ObservableObject {
    @Published var profile = VPNProfile()
    @Published var password = ""
    @Published private(set) var hasPassword = false
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var busy = false
    @Published private(set) var onDemandActive = false
    @Published var message: String?
    @Published private(set) var snapshot = DiagnosticSnapshot()
    @Published private(set) var probeResult = "尚未验证"
    @Published private(set) var probing = false
    private var didLoadProfile = false
    private var manager: NETunnelProviderManager?
    private var observer: AnyCancellable?
    private let store = SharedStore()

    var active: Bool { [.connecting, .connected, .reasserting, .disconnecting].contains(status) }
    var title: String {
        switch status {
        case .connected: return "已连接"
        case .connecting: return "正在连接"
        case .reasserting: return "正在恢复"
        case .disconnecting: return "正在断开"
        default: return "尚未连接"
        }
    }
    init() {
        observer = NotificationCenter.default.publisher(for: .NEVPNStatusDidChange).receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor in await self?.load() }
        }
    }
    func load() async {
        #if targetEnvironment(simulator)
        message = "当前模拟器用于界面检查，真实 VPN 请在 iPhone 上验证。"
        return
        #else
        guard !busy else { return }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == RuntimeConfiguration.providerID }
            if let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol {
                if !didLoadProfile { profile = try VPNProfile.decode(proto.providerConfiguration); didLoadProfile = true }
                hasPassword = proto.passwordReference != nil
            }
            refreshStatus()
            await refreshDiagnostics()
        } catch { message = error.localizedDescription }
        #endif
    }
    private func refreshStatus() {
        status = manager?.connection.status ?? .invalid
        onDemandActive = manager?.isOnDemandEnabled ?? false
    }
    func save() async { await perform { try await self.saveConfiguration() } }
    func connect() async {
        await perform {
            try await self.saveConfiguration()
            guard let manager = self.manager else { throw ConfigurationError.invalid("VPN 配置尚未保存。") }
            try self.store.write(RecoveryPolicy(), name: "recovery")
            manager.isOnDemandEnabled = self.profile.onDemand
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            if manager.connection.status == .disconnected || manager.connection.status == .invalid {
                do { try manager.connection.startVPNTunnel() }
                catch {
                    manager.isOnDemandEnabled = false
                    try? await manager.saveToPreferences()
                    throw error
                }
            }
            self.message = nil
        }
    }
    func disconnect() async {
        await perform {
            guard let manager = self.manager else { return }
            // Persist pause first. If saving fails, do not pretend the automatic restart has been disabled.
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            guard !manager.isOnDemandEnabled else { throw ConfigurationError.invalid("按需恢复未能暂停，请在系统 VPN 设置中关闭。") }
            manager.connection.stopVPNTunnel()
            self.message = "已暂停按需恢复；再次点击连接后才会重新启用。"
        }
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; refreshStatus() }
        do { try await operation() }
        catch { message = error.localizedDescription }
    }
    private func saveConfiguration() async throws {
        guard !active, !onDemandActive else { throw ConfigurationError.invalid("请先断开并暂停按需恢复，再修改或保存配置。") }
        let validated = try profile.validated()
        let manager = self.manager ?? NETunnelProviderManager()
        let old = manager.protocolConfiguration as? NETunnelProviderProtocol
        let oldReference = old?.passwordReference
        let oldProfile = try? VPNProfile.decode(old?.providerConfiguration)
        var newReference: Data?
        if !password.isEmpty { newReference = try KeychainStore.save(password) }
        else if oldProfile?.username != validated.username || oldProfile?.server != validated.server || oldReference == nil {
            throw ConfigurationError.invalid("首次配置或修改服务器/用户名后，请重新填写密码。")
        }
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = RuntimeConfiguration.providerID
        proto.serverAddress = validated.server
        proto.username = validated.username
        proto.passwordReference = newReference ?? oldReference
        proto.providerConfiguration = try validated.configuration
        proto.disconnectOnSleep = false
        let evaluate = NEOnDemandRuleEvaluateConnection()
        let rule = NEEvaluateConnectionRule(matchDomains: validated.domainList, andAction: .connectIfNeeded)
        if !validated.probeURL.isEmpty { rule.probeURL = URL(string: validated.probeURL) }
        evaluate.connectionRules = [rule]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "XD VPN 验证版"
        manager.isEnabled = true
        manager.onDemandRules = validated.onDemand ? [evaluate] : []
        manager.isOnDemandEnabled = false
        do { try await manager.saveToPreferences() }
        catch {
            if let newReference { KeychainStore.delete(newReference) }
            try? await manager.loadFromPreferences()
            throw error
        }
        // Preferences now reference the new item, even if the subsequent reload fails.
        if newReference != nil, let oldReference { KeychainStore.delete(oldReference) }
        self.manager = manager; profile = validated; password = ""; hasPassword = true
        try await manager.loadFromPreferences()
        message = "配置已保存，点击连接开始验证。"
    }
    func refreshDiagnostics() async {
        if let saved = try? store.read(DiagnosticSnapshot.self, name: "diagnostics", fallback: DiagnosticSnapshot()) { snapshot = saved }
        if let policy = try? store.read(RecoveryPolicy.self, name: "recovery", fallback: RecoveryPolicy()), let reason = policy.blockedReason {
            message = "自动恢复已暂停：" + reason
        }
        guard let session = manager?.connection as? NETunnelProviderSession, [.connected, .reasserting].contains(session.status) else { return }
        do {
            try session.sendProviderMessage(Data("status".utf8)) { [weak self] data in
                guard let data, let snapshot = try? JSONDecoder().decode(DiagnosticSnapshot.self, from: data) else { return }
                Task { @MainActor in self?.snapshot = snapshot }
            }
        } catch { /* Persisted diagnostics remain available if IPC is interrupted. */ }
    }
    func probe() async {
        guard !probing else { return }
        probing = true; defer { probing = false }
        do {
            let validated = try profile.validated()
            guard let url = URL(string: validated.probeURL), !validated.probeURL.isEmpty else {
                throw ConfigurationError.invalid("请先填写 HTTPS 内网验证地址。")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 15
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: ProbeRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let started = Date()
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ConfigurationError.invalid("未收到 HTTP 响应。") }
            probeResult = "HTTP \(response.statusCode) · \(Int(Date().timeIntervalSince(started) * 1000)) ms · \(Date().formatted(date: .omitted, time: .standard))"
        } catch { probeResult = "验证失败：" + error.localizedDescription }
    }
    var report: String {
        "XD VPN iOS 0.1 验证报告\n系统状态：\(title)\n事件时间：\(snapshot.updatedAt)\n传输：\(snapshot.transport)\n上行包：\(snapshot.packetsToTunnel) 下行包：\(snapshot.packetsFromTunnel) 丢弃包：\(snapshot.droppedPackets)\n" + snapshot.events.joined(separator: "\n")
    }
}

/// A redirect still proves an HTTP response from the requested endpoint; do not follow it to a public login page.
private final class ProbeRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

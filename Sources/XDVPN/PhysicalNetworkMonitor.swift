import Foundation
import SystemConfiguration
import CoreWLAN
import Darwin

struct PhysicalNetworkObservation {
    enum Source: String { case configuration = "configd", wifiLink = "wifi-link", wifiPower = "wifi-power", wifiSSID = "wifi-ssid" }
    let source: Source
    let online: Bool
    let changedFields: [String]
    var shouldNotify: Bool { !changedFields.isEmpty || source == .wifiSSID }
    var summary: String {
        "来源=\(source.rawValue)，物理网络=\(online ? "就绪" : "未就绪")，配置变化=\(changedFields.isEmpty ? "无" : changedFields.joined(separator: ","))，\(shouldNotify ? "处理变化" : "忽略重复通知")。"
    }
}

/// Observe the underlying link, not global routes/DNS changed by vpnc-script.
/// SSID events are consumed without reading or storing the Wi-Fi network name.
final class PhysicalNetworkMonitor: NSObject, CWEventDelegate {
    private var store: SCDynamicStore?
    private let wifi = CWWiFiClient()
    private var snapshot: NSDictionary
    private let onObservation: (PhysicalNetworkObservation) -> Void
    private(set) var isAvailable: Bool?
    private let patterns = ["State:/Network/Interface/en[0-9]+/(IPv4|IPv6|Link)"]

    init(initialSnapshot: NSDictionary = [:], onObservation: @escaping (PhysicalNetworkObservation) -> Void) {
        self.snapshot = initialSnapshot
        self.onObservation = onObservation
        super.init()
    }

    func start() -> Bool {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "XD VPN Physical Network" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<PhysicalNetworkMonitor>.fromOpaque(info).takeUnretainedValue().configurationChanged()
        }, &context)
        var configured = false
        if let store {
            snapshot = currentSnapshot(store)
            configured = SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)
                && SCDynamicStoreSetDispatchQueue(store, .main)
            if configured { isAvailable = Self.hasUsablePhysicalNetwork(snapshot) }
            else {
                SCDynamicStoreSetDispatchQueue(store, nil)
                self.store = nil // Keep the fallback active if DHCP events cannot be observed.
            }
        }
        wifi.delegate = self
        var wifiConfigured = true
        for event: CWEventType in [.ssidDidChange, .linkDidChange, .powerDidChange] {
            do { try wifi.startMonitoringEvent(with: event) }
            catch { wifiConfigured = false }
        }
        return configured && wifiConfigured
    }

    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        isAvailable = nil
        try? wifi.stopMonitoringAllEvents()
        wifi.delegate = nil
    }

    static func isPhysicalConfigurationKey(_ key: String) -> Bool {
        key.range(of: "^State:/Network/Interface/en[0-9]+/(IPv4|IPv6|Link)$", options: .regularExpression) != nil
    }

    private func currentSnapshot(_ store: SCDynamicStore) -> NSDictionary {
        let values = SCDynamicStoreCopyMultiple(store, nil, patterns as CFArray) as? [String: [String: Any]] ?? [:]
        return Self.physicalSnapshot(from: values)
    }

    static func physicalSnapshot(from values: [String: [String: Any]]) -> NSDictionary {
        var result: [String: [String: Any]] = [:]
        for (key, value) in values where Self.isPhysicalConfigurationKey(key) {
            // AdditionalRoutes can be written on en0 by the VPN itself. They
            // must not trigger a reconnect which changes the routes again.
            let fields = value.filter { ["Addresses", "Router", "SubnetMasks", "PrefixLength", "Active"].contains($0.key) }
            if !fields.isEmpty { result[key] = fields }
        }
        return result as NSDictionary
    }

    /// A VPN can keep the global path satisfied (or break it) independently of
    /// Wi-Fi. Read link and assigned addresses on the same physical interface.
    /// Link-local/self-assigned addresses alone cannot reach a VPN server.
    static func hasUsablePhysicalNetwork(_ snapshot: NSDictionary) -> Bool {
        let values = snapshot as? [String: [String: Any]] ?? [:]
        return values.contains { key, value in
            guard isPhysicalConfigurationKey(key), key.hasSuffix("/Link"),
                  value["Active"] as? Bool == true else { return false }
            let prefix = String(key.dropLast("Link".count))
            let addresses = (values[prefix + "IPv4"]?["Addresses"] as? [String] ?? [])
                + (values[prefix + "IPv6"]?["Addresses"] as? [String] ?? [])
            return addresses.contains(where: isRoutableAddress)
        }
    }

    private static func isRoutableAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let first = value >> 24
            return first != 0 && first != 127 && first < 224 && value >> 16 != 0xa9fe
        }
        var ipv6 = in6_addr()
        guard let rawHost = address.split(separator: "%", maxSplits: 1).first else { return false }
        let host = String(rawHost)
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { bytes in
            // Accept global unicast and unique local IPv6 addresses.
            bytes[0] & 0xe0 == 0x20 || bytes[0] & 0xfe == 0xfc
        }
    }

    private func configurationChanged() {
        guard let store else { return }
        observe(currentSnapshot(store), source: .configuration)
    }

    // Both notification paths use this gate. Equal Link/Power announcements
    // are observations, not evidence that the transport needs rebuilding.
    func observe(_ updated: NSDictionary, source: PhysicalNetworkObservation.Source) {
        let old = snapshot as? [String: [String: Any]] ?? [:]
        let new = updated as? [String: [String: Any]] ?? [:]
        var changed: [String] = []
        for key in Set(old.keys).union(new.keys).sorted() where Self.isPhysicalConfigurationKey(key) {
            for field in ["Active", "Addresses", "Router", "SubnetMasks", "PrefixLength"] {
                let before = old[key]?[field] as? NSObject, after = new[key]?[field] as? NSObject
                if before == nil && after == nil { continue }
                if let before, let after, before.isEqual(after) { continue }
                // Only field names enter diagnostics; never log network IDs or addresses.
                changed.append(key.replacingOccurrences(of: "State:/Network/Interface/", with: "") + "/" + field)
            }
        }
        snapshot = updated
        isAvailable = Self.hasUsablePhysicalNetwork(updated)
        onObservation(.init(source: source, online: isAvailable == true, changedFields: changed))
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { notify(.wifiSSID) }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { notify(.wifiLink) }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { notify(.wifiPower) }

    private func notify(_ source: PhysicalNetworkObservation.Source) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = self.store else { return }
            // CoreWLAN notifications can precede the dynamic-store callback.
            // Use the same comparison even when CoreWLAN arrives first. A real
            // SSID-change event remains independent of address changes.
            self.observe(self.currentSnapshot(store), source: source)
        }
    }
}

import Foundation
import SystemConfiguration
import CoreWLAN

/// Observe the underlying link, not global routes/DNS changed by vpnc-script.
/// SSID events are consumed without reading or storing the Wi-Fi network name.
final class PhysicalNetworkMonitor: NSObject, CWEventDelegate {
    private var store: SCDynamicStore?
    private let wifi = CWWiFiClient()
    private var snapshot: NSDictionary = [:]
    private let onChange: () -> Void
    private let patterns = ["State:/Network/Interface/en[0-9]+/(IPv4|IPv6|Link)"]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
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
            result[key] = value.filter { ["Addresses", "Router", "SubnetMasks", "PrefixLength", "Active"].contains($0.key) }
        }
        return result as NSDictionary
    }

    private func configurationChanged() {
        guard let store else { return }
        let updated = currentSnapshot(store)
        guard !snapshot.isEqual(updated) else { return }
        snapshot = updated
        onChange()
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { notify() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { notify() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { notify() }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.store != nil else { return }
            self.onChange()
        }
    }
}

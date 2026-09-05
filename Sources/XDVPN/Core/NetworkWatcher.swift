import Foundation
import SystemConfiguration

/// Watches the *underlying* physical network through SCDynamicStore: IPv4
/// addresses and routers of non-tunnel interfaces plus link state. Fires when
/// the network the Mac is sitting on changes (Wi‑Fi switch, cable plugged,
/// wake from sleep), so the tunnel can be kicked immediately instead of
/// waiting for openconnect's dead-peer timers.
@MainActor
final class NetworkWatcher {
    /// Called (debounced) with a short human-readable reason.
    var onChange: ((String) -> Void)?

    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var debounce: Task<Void, Never>?
    private var stableFingerprint = ""
    private var linkStates: [String: Bool] = [:]
    private var linkCameUp = false

    private static let patterns = [
        "State:/Network/Interface/[^/]+/IPv4",
        "State:/Network/Service/[^/]+/IPv4",
        "State:/Network/Interface/[^/]+/Link",
    ]
    /// Virtual / internal interfaces that must not count as "the network".
    private static let ignoredPrefixes = [
        "utun", "ipsec", "ppp", "lo", "gif", "stf", "awdl", "llw", "bridge", "vmenet", "anpi", "ap",
    ]
    private static let settleDelay: TimeInterval = 1.5

    func start() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let watcher = Unmanaged<NetworkWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.storeChanged() }
        }
        guard let store = SCDynamicStoreCreate(nil, "XDVPN" as CFString, callback, &context),
              SCDynamicStoreSetNotificationKeys(store, nil, Self.patterns as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        runLoopSource = source

        let snapshot = takeSnapshot()
        stableFingerprint = snapshot.fingerprint
        linkStates = snapshot.links
    }

    /// Current fingerprint, for logging.
    var description: String { takeSnapshot().fingerprint }

    private func storeChanged() {
        let snapshot = takeSnapshot()
        for (name, active) in snapshot.links where active && linkStates[name] == false {
            linkCameUp = true
        }
        linkStates = snapshot.links

        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            guard !Task.isCancelled, let self else { return }
            self.settle()
        }
    }

    private func settle() {
        let snapshot = takeSnapshot()
        let changed = snapshot.fingerprint != stableFingerprint
        let cameUp = linkCameUp
        linkCameUp = false
        stableFingerprint = snapshot.fingerprint
        guard snapshot.hasAddress, changed || cameUp else { return }
        onChange?(changed ? "底层网络变化 (\(snapshot.summary))" : "链路恢复")
    }

    private struct SnapshotResult {
        var fingerprint: String
        var summary: String
        var hasAddress: Bool
        var links: [String: Bool]
    }

    private func takeSnapshot() -> SnapshotResult {
        guard let store,
              let values = SCDynamicStoreCopyMultiple(store, nil, Self.patterns as CFArray) as? [String: Any]
        else { return SnapshotResult(fingerprint: "", summary: "", hasAddress: false, links: [:]) }

        var parts: [String] = []
        var summary: [String] = []
        var links: [String: Bool] = [:]
        var hasAddress = false

        for (key, raw) in values {
            guard let dict = raw as? [String: Any] else { continue }
            let components = key.split(separator: "/").map(String.init)
            // State:/Network/Interface/<if>/IPv4 → ["State:", "Network", "Interface", "<if>", "IPv4"]
            guard components.count == 5 else { continue }
            let kind = components[2], leaf = components[4]

            if kind == "Interface", leaf == "Link" {
                let name = components[3]
                guard !Self.isIgnored(name) else { continue }
                links[name] = (dict["Active"] as? Bool) ?? false
            } else if kind == "Interface", leaf == "IPv4" {
                let name = components[3]
                guard !Self.isIgnored(name) else { continue }
                let addresses = (dict["Addresses"] as? [String] ?? []).sorted()
                if !addresses.isEmpty { hasAddress = true }
                parts.append("\(name)=\(addresses.joined(separator: ","))")
                summary.append("\(name) \(addresses.joined(separator: ","))")
            } else if kind == "Service", leaf == "IPv4" {
                let name = (dict["InterfaceName"] as? String) ?? components[3]
                guard !Self.isIgnored(name) else { continue }
                let router = (dict["Router"] as? String) ?? "-"
                parts.append("\(name)->\(router)")
            }
        }
        return SnapshotResult(
            fingerprint: parts.sorted().joined(separator: "|"),
            summary: summary.sorted().joined(separator: "; "),
            hasAddress: hasAddress,
            links: links
        )
    }

    private static func isIgnored(_ name: String) -> Bool {
        ignoredPrefixes.contains { name.hasPrefix($0) }
    }
}

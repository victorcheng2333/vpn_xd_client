import Foundation
import SystemConfiguration
import Darwin

/// The helper uses the dynamic store directly: cleanup must never need DNS,
/// a default gateway, a shell, or a functioning tunnel.
struct NetworkStateAccess {
    var read: (String) throws -> [String: Any]?
    var write: (String, [String: Any]) throws -> Void
    var remove: ([String]) throws -> Void
    var interfaceExists: (String) -> Bool
    var routes: TunnelRouteAccess? = nil

    static func live() throws -> Self {
        guard let store = SCDynamicStoreCreate(nil, "XD VPN Network Cleanup" as CFString, nil, nil) else {
            throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
        }
        return Self(read: { key in
            if let value = SCDynamicStoreCopyValue(store, key as CFString) {
                guard let dictionary = value as? [String: Any] else {
                    throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
                }
                return dictionary
            }
            guard SCError() == kSCStatusNoKey else { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
            return nil
        }, write: { key, value in
            guard SCDynamicStoreSetValue(store, key as CFString, value as CFDictionary) else {
                throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
            }
        }, remove: { keys in
            guard SCDynamicStoreSetMultiple(store, nil, keys as CFArray, nil) else {
                throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
            }
        }, interfaceExists: { if_nametoindex($0) != 0 }, routes: .live(store: store))
    }
}

struct TunnelNetworkRecord: Codable, Equatable {
    let processID: Int32
    let interface: String
    let ipv4: String
    let dns: [String]
}

/// A private journal is written BEFORE vpnc-script can modify the network.
/// Only the root-owned helper's fixed script entry point can claim a session;
/// server output is never treated as evidence of interface ownership.
public final class TunnelNetworkSession {
    struct ClaimConflict: Error { let interface: String }
    public static let environmentKey = "XDVPN_NETWORK_SESSION"
    private static let directoryPrefix = "/private/var/run/xdvpn-network-"
    public let directory: String
    private let token: String
    private let state: NetworkStateAccess
    private let owner: uid_t
    private let lease: Int32
    private var recordPath: String { directory + "/tunnel.json" }
    private var routePath: String { directory + "/route.json" }

    private struct RouteRecord: Codable {
        var processID: Int32
        var server: String
        var external: Bool
        var owned: IPv4Route?
        // Persist intent BEFORE the kernel mutation, so a crash can be recovered.
        var pending: IPv4Route?
    }

    private func readRouteRecord() throws -> RouteRecord? {
        try validateDirectory()
        var info = stat()
        guard lstat(routePath, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw RouteFailure.invalid
        }
        guard info.st_uid == owner, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size < 8192, info.st_mode & 0o077 == 0 else { throw RouteFailure.invalid }
        let record = try JSONDecoder().decode(RouteRecord.self, from: Data(contentsOf: URL(fileURLWithPath: routePath)))
        guard record.processID > 1, RouteSocket.usableIPv4(record.server) else { throw RouteFailure.invalid }
        for route in [record.owned, record.pending].compactMap({ $0 }) {
            guard route.destination == record.server, route.isHost, route.scope == 0,
                  route.gateway.map(RouteSocket.usableIPv4) == true, route.source.map(RouteSocket.usableIPv4) == true,
                  route.interfaceIndex > 0 else { throw RouteFailure.invalid }
        }
        return record
    }

    private func saveRouteRecord(_ record: RouteRecord) throws {
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: routePath), options: .atomic)
        guard chmod(routePath, 0o600) == 0 else { throw RouteFailure.invalid }
    }

    private func serverRoute(_ server: String, routes: TunnelRouteAccess, diagnostic: (String) -> Void) throws -> IPv4Route? {
        let all = try routes.hostRoutes(server)
        diagnostic("XDVPN route inventory server=\(server): \(all.map(\.description).joined(separator: "; "))")
        let exact = all.filter { $0.destination == server && $0.isHost && $0.scope == 0 }
        guard exact.count <= 1 else { throw RouteFailure.conflict("multiple unscoped host entries for \(server)") }
        return exact.first
    }

    func prepareServerRoute(environment: [String: String], diagnostic: (String) -> Void) throws {
        guard let routes = state.routes else { return } // Injected non-network tests.
        guard let tunnel = try readRecord(), let rawPID = environment["VPNPID"], Int32(rawPID) == tunnel.processID,
              let server = environment["VPNGATEWAY"], RouteSocket.usableIPv4(server) else { throw RouteFailure.invalid }
        let physical = try routes.physical()
        let target = physical.host(server)
        let selected = try serverRoute(server, routes: routes, diagnostic: diagnostic)
        var current = selected
        diagnostic("XDVPN route before \(selected?.description ?? "none"); desired \(target.description)")
        var record: RouteRecord
        if let previous = try readRouteRecord() {
            guard previous.processID == tunnel.processID, previous.server == server else { throw RouteFailure.invalid }
            record = previous
        } else {
            // A kernel-generated clone of the physical default is a cache,
            // not an independently installed host route. RTM_ADD replaces it.
            if let route = current, route.isKernelClone,
               route.gateway == physical.gateway, route.source == physical.address, route.interfaceIndex == physical.index {
                current = nil
            }
            record = RouteRecord(processID: tunnel.processID, server: server, external: current != nil, owned: nil, pending: nil)
            try saveRouteRecord(record)
        }
        if record.external {
            // An existing, independently configured route is never adopted or removed.
            guard let current, current.interfaceIndex == physical.index, current.source == physical.address,
                  current.gateway == physical.gateway else { throw RouteFailure.conflict(selected?.description ?? "none") }
            diagnostic("XDVPN route preserve external \(current.description)")
            return
        }
        // A link transition may prune our static route, after which traffic
        // creates a fresh physical-default clone. Replace only a verified
        // current physical clone; do not mistake it for a foreign static route.
        if let route = current, route.isKernelClone,
           route.gateway == physical.gateway, route.source == physical.address, route.interfaceIndex == physical.index {
            current = nil
        }
        if let current {
            guard [record.owned, record.pending].compactMap({ $0 }).contains(where: current.matches) else {
                throw RouteFailure.conflict(current.description)
            }
            if current.matches(target) {
                record.owned = current; record.pending = nil; try saveRouteRecord(record)
                diagnostic("XDVPN route verified unchanged \(current.description)")
                return
            }
        }
        if let current { record.owned = current }
        record.pending = target; try saveRouteRecord(record)
        if let current {
            diagnostic("XDVPN route replace: delete requested \(current.description)")
            try routes.update(.delete, current)
            if let remaining = try serverRoute(server, routes: routes, diagnostic: diagnostic), !remaining.isKernelClone {
                throw RouteFailure.system("verify replacement delete", EIO)
            }
        }
        diagnostic("XDVPN route add requested \(target.description)")
        try routes.update(.add, target)
        guard let installed = try serverRoute(server, routes: routes, diagnostic: diagnostic), installed.matches(target) else {
            throw RouteFailure.system("verify add", EIO)
        }
        record.owned = installed; record.pending = nil; try saveRouteRecord(record)
        diagnostic("XDVPN route add verified \(installed.description)")
    }

    private func cleanupServerRoute(processID: Int32, diagnostic: (String) -> Void) throws {
        guard let record = try readRouteRecord() else { return }
        guard record.processID == processID, let routes = state.routes else { throw RouteFailure.invalid }
        if !record.external, let selected = try serverRoute(record.server, routes: routes, diagnostic: diagnostic), !selected.isKernelClone {
            guard [record.owned, record.pending].compactMap({ $0 }).contains(where: selected.matches) else {
                throw RouteFailure.conflict(selected.description)
            }
            diagnostic("XDVPN route delete requested \(selected.description)")
            try routes.update(.delete, selected)
            if let remaining = try serverRoute(record.server, routes: routes, diagnostic: diagnostic), !remaining.isKernelClone {
                throw RouteFailure.system("verify delete \(remaining.description)", EIO)
            }
        }
        diagnostic("XDVPN route cleanup verified server=\(record.server) external=\(record.external)")
        guard unlink(routePath) == 0 else { throw RouteFailure.invalid }
    }

    func configureIPv4Service(environment: [String: String]) throws {
        guard state.routes != nil else { return }
        guard let record = try readRecord() else { throw RouteFailure.invalid }
        let prefix = "State:/Network/Service/\(record.interface)/"
        guard try state.read(prefix + "XDVPN")?["SessionID"] as? String == token else { throw RouteFailure.invalid }
        let count: Int
        if let raw = environment["CISCO_SPLIT_INC"], !raw.isEmpty {
            guard let value = Int(raw), (0...4096).contains(value) else { throw RouteFailure.invalid }
            count = value
        } else { count = 0 }
        let fullTunnel = count == 0 || (0..<count).contains {
            environment["CISCO_SPLIT_INC_\($0)_ADDR"] == "0.0.0.0" && environment["CISCO_SPLIT_INC_\($0)_MASKLEN"] == "0"
        }
        var ipv4 = try state.read(prefix + "IPv4") ?? ["InterfaceName": record.interface, "Addresses": [record.ipv4], "SubnetMasks": ["255.255.255.255"]]
        guard ipv4["InterfaceName"] as? String == record.interface, ipv4["Addresses"] as? [String] == [record.ipv4] else { throw RouteFailure.invalid }
        if fullTunnel { ipv4["Router"] = record.ipv4; ipv4["OverridePrimary"] = 1 }
        try state.write(prefix + "IPv4", ipv4)
        guard let verified = try state.read(prefix + "IPv4"), NSDictionary(dictionary: verified).isEqual(to: ipv4) else {
            throw RouteFailure.system("verify IPv4 service", EIO)
        }
    }

    // A server's "Configured as" line precedes script execution. Confirm the
    // private ownership record and actual network state before publishing it.
    func verifyConfiguration(processID: Int32) throws {
        guard let record = try readRecord(), record.processID == processID else { throw RouteFailure.invalid }
        let prefix = "State:/Network/Service/\(record.interface)/"
        guard try state.read(prefix + "XDVPN")?["SessionID"] as? String == token,
              let ipv4 = try state.read(prefix + "IPv4"), ipv4["InterfaceName"] as? String == record.interface,
              ipv4["Addresses"] as? [String] == [record.ipv4] else { throw RouteFailure.invalid }
        if !record.dns.isEmpty {
            guard try state.read(prefix + "DNS")?["ServerAddresses"] as? [String] == record.dns else {
                throw RouteFailure.system("verify tunnel DNS", EIO)
            }
        }
        if let routes = state.routes {
            guard let route = try readRouteRecord(), route.processID == processID, route.pending == nil,
                  let current = try serverRoute(route.server, routes: routes, diagnostic: { _ in }) else { throw RouteFailure.invalid }
            if !route.external {
                guard let owned = route.owned, current.matches(owned) else { throw RouteFailure.invalid }
            }
        }
    }

    /// Keep the packaged vpnc implementation for tunnel/DNS/split routes, but
    /// take its IPv4 server host route and stale default restoration out of play.
    func managedScript(source: String) throws -> String {
        guard state.routes != nil else { return source }
        let text = try String(contentsOfFile: source, encoding: .utf8)
        guard text.components(separatedBy: "#### Main").count == 2 else { throw RouteFailure.invalid }
        let overrides = """
        # XD VPN owns and verifies the IPv4 VPN server route through PF_ROUTE.
        set_vpngateway_route() { :; }
        del_vpngateway_route() { :; }
        set_ipv4_default_route() { :; }
        # configd restores the current physical default when our service is removed.
        # Never restore the gateway saved on a previous Wi-Fi network.
        reset_ipv4_default_route() { rm -f -- "$DEFAULT_ROUTE_FILE"; }
        # The tunnel's dynamic-store DNS must not become persistent Wi-Fi DNS
        # while configd asynchronously changes the primary interface.
        networksetup() { :; }
        """
        let path = directory + "/vpnc-managed-script"
        try text.replacingOccurrences(of: "#### Main", with: overrides + "\n#### Main")
            .write(toFile: path, atomically: true, encoding: .utf8)
        guard chmod(path, 0o700) == 0 else { throw RouteFailure.invalid }
        return path
    }

    public static func create() throws -> TunnelNetworkSession {
        let state = try NetworkStateAccess.live()
        try recoverOrphans(prefix: directoryPrefix, owner: 0, state: state)
        return try create(prefix: directoryPrefix, owner: 0, state: state)
    }

    static func create(prefix: String, owner: uid_t, state: NetworkStateAccess) throws -> TunnelNetworkSession {
        let token = UUID().uuidString
        let directory = prefix + token
        guard geteuid() == owner, mkdir(directory, 0o700) == 0 else {
            throw VPNError.system("无法创建专用网络清理记录。")
        }
        do { return try Self(directory: directory, token: token, owner: owner, state: state) }
        catch { rmdir(directory); throw error }
    }

    init(directory: String, token: String, owner: uid_t, state: NetworkStateAccess, exclusive: Bool = false) throws {
        self.directory = directory; self.token = token; self.owner = owner; self.state = state
        try Self.validateDirectory(directory, owner: owner)
        let fd = open(directory + "/lease", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VPNError.system("无法打开网络清理记录锁。") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
            close(fd); throw VPNError.system("网络清理记录锁权限不正确。")
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(fd)
            if busy { throw JournalBusy() }
            throw VPNError.system("无法锁定网络清理记录。")
        }
        lease = fd
    }

    private struct JournalBusy: Error {}
    deinit { close(lease) }

    public static func openForScript(environment: [String: String]) throws -> TunnelNetworkSession {
        guard geteuid() == 0, let directory = environment[environmentKey],
              directory.hasPrefix(directoryPrefix),
              let token = UUID(uuidString: String(directory.dropFirst(directoryPrefix.count))),
              directory == directoryPrefix + token.uuidString else {
            throw VPNError.system("网络脚本只能在权限助手创建的会话内运行。")
        }
        return try Self(directory: directory, token: token.uuidString, owner: 0, state: .live())
    }

    private func validateDirectory() throws {
        try Self.validateDirectory(directory, owner: owner)
    }

    private static func validateDirectory(_ directory: String, owner: uid_t) throws {
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == owner,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw VPNError.system("网络清理记录的权限不正确。")
        }
    }

    /// Recover only journals whose helper AND script wrappers have released
    /// their shared leases and whose recorded OpenConnect PID is no longer live.
    /// Legacy v3 journals lack a lease: allow their 15s wrappers ample time to exit.
    static func recoverOrphans(prefix: String, owner: uid_t, state: NetworkStateAccess,
                               processAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno != ESRCH },
                               legacyGrace: TimeInterval = 60) throws {
        let parent = (prefix as NSString).deletingLastPathComponent
        let stem = (prefix as NSString).lastPathComponent
        for name in try FileManager.default.contentsOfDirectory(atPath: parent).sorted() {
            guard name.hasPrefix(stem), let token = UUID(uuidString: String(name.dropFirst(stem.count))),
                  name == stem + token.uuidString else { continue }
            let directory = parent + "/" + name
            do {
                try validateDirectory(directory, owner: owner)
                var info = stat()
                if lstat(directory + "/lease", &info) != 0 {
                    guard errno == ENOENT, lstat(directory, &info) == 0 else {
                        throw VPNError.system("无法核对遗留清理记录。")
                    }
                    // Do not create a lease for a fresh legacy journal: that
                    // would incorrectly label it as safe on the next scan.
                    if Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) < legacyGrace {
                        throw VPNError.system("旧版清理记录仍在等待脚本退出，请一分钟后重试。")
                    }
                }
                let session: TunnelNetworkSession
                do { session = try Self(directory: directory, token: token.uuidString, owner: owner, state: state, exclusive: true) }
                catch is JournalBusy { continue }
                do {
                    if let record = try session.readRecord() {
                        guard !processAlive(record.processID) else {
                            throw VPNError.system("遗留记录中的 VPN 进程仍存在，暂不清理。")
                        }
                        try session.cleanup(processID: record.processID)
                    }
                    try session.finish()
                } catch { throw VPNError.system(session.cleanupFailureMessage()) }
            } catch {
                throw VPNError.system("\(error.localizedDescription) 清理记录：\(directory)。再次连接会重新检查。")
            }
        }
    }

    public func cleanupFailureMessage() -> String {
        let detail: String
        if let record = try? readRecord() {
            let prefix = "State:/Network/Service/\(record.interface)/"
            detail = "记录进程：\(record.processID)；接口：\(record.interface)；检查键：\(prefix)IPv4、\(prefix)DNS、\(prefix)XDVPN。"
        } else { detail = "无法读取有效的隧道身份记录。" }
        let route = (try? readRouteRecord()).map { "服务器路由：\($0.server)；归属：\($0.external ? "外部配置" : "本连接")；记录：\(routePath)。" } ?? ""
        return "\(EngineOutput.networkCleanupFailureMessage) \(detail)\(route)记录：\(directory)。再次连接会先重试清理；归属不匹配时不会删除。"
    }

    var hasTunnelRecord: Bool { (try? readRecord()) != nil }

    private func readRecord() throws -> TunnelNetworkRecord? {
        try validateDirectory()
        var info = stat()
        guard lstat(recordPath, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
        }
        guard info.st_uid == owner, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size <= 8192 else {
            throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
        }
        let record = try JSONDecoder().decode(TunnelNetworkRecord.self, from: Data(contentsOf: URL(fileURLWithPath: recordPath)))
        guard Self.valid(record) else { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
        return record
    }

    private static func valid(_ record: TunnelNetworkRecord) -> Bool {
        guard record.processID > 1, record.interface.range(of: "\\Autun[0-9]{1,5}\\z", options: .regularExpression) != nil,
              validIPv4(record.ipv4), record.dns.count <= 16, record.dns.allSatisfy(validIPv4) else { return false }
        return true
    }

    private static func validIPv4(_ address: String) -> Bool {
        var value = in_addr()
        return inet_pton(AF_INET, address, &value) == 1
    }

    public func claim(environment: [String: String]) throws {
        guard let processID = environment["VPNPID"].flatMap(Int32.init),
              let interface = environment["TUNDEV"], let ipv4 = environment["INTERNAL_IP4_ADDRESS"] else {
            throw VPNError.system("网络脚本缺少本次隧道的身份信息。")
        }
        let record = TunnelNetworkRecord(processID: processID, interface: interface, ipv4: ipv4,
            dns: (environment["INTERNAL_IP4_DNS"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
        guard Self.valid(record) else { throw VPNError.system("网络脚本的隧道身份无效。") }
        let prefix = "State:/Network/Service/\(interface)/"
        if let previous = try readRecord() {
            guard previous == record, try state.read(prefix + "XDVPN")?["SessionID"] as? String == token else {
                throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
            }
            return
        }
        // A reused utun number can still have another client's stale state.
        // Refuse to overwrite it; ownership cannot be inferred from the name.
        for suffix in ["IPv4", "DNS", "XDVPN"] {
            guard try state.read(prefix + suffix) == nil else {
                throw ClaimConflict(interface: interface)
            }
        }
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: recordPath), options: .atomic)
        guard chmod(recordPath, 0o600) == 0 else { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
        try state.write(prefix + "XDVPN", ["SessionID": token])
    }

    /// Returns the number of residual service keys removed. A mismatched owner,
    /// changed configuration, or reused live interface is never deleted.
    @discardableResult public func cleanup(processID: Int32, afterExit: Bool = true,
                                          keepMarker: Bool = false, interfaceWait: TimeInterval = 2,
                                          diagnostic: (String) -> Void = { _ in }) throws -> Int {
        let deadline = ProcessInfo.processInfo.systemUptime + interfaceWait
        while true {
            if let removed = try cleanupPass(processID: processID, afterExit: afterExit, keepMarker: keepMarker) {
                if !keepMarker { try cleanupServerRoute(processID: processID, diagnostic: diagnostic) }
                return removed
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
            }
            usleep(50_000)
            // Re-read identity, ownership and addresses on every pass. Do not
            // delete using a snapshot taken before the asynchronous utun detach.
        }
    }

    private func cleanupPass(processID: Int32, afterExit: Bool, keepMarker: Bool) throws -> Int? {
        guard let record = try readRecord() else { return 0 }
        guard record.processID == processID else { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
        let prefix = "State:/Network/Service/\(record.interface)/"
        let ipv4 = try state.read(prefix + "IPv4")
        let dns = try state.read(prefix + "DNS")
        let marker = try state.read(prefix + "XDVPN")
        if ipv4 == nil && dns == nil && marker == nil { return 0 }
        guard marker?["SessionID"] as? String == token else {
            throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
        }
        if let ipv4 {
            guard ipv4["InterfaceName"] as? String == record.interface,
                  ipv4["Addresses"] as? [String] == [record.ipv4] else {
                throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
            }
        }
        if let dns {
            guard dns["ServerAddresses"] as? [String] == record.dns else {
                throw VPNError.system(EngineOutput.networkCleanupFailureMessage)
            }
        }
        if afterExit && (ipv4 != nil || dns != nil) && state.interfaceExists(record.interface) { return nil }
        var existing = keepMarker ? [] : [prefix + "XDVPN"]
        if ipv4 != nil { existing.append(prefix + "IPv4") }
        if dns != nil { existing.append(prefix + "DNS") }
        if !existing.isEmpty { try state.remove(existing) }
        for key in (keepMarker ? ["IPv4", "DNS"] : ["IPv4", "DNS", "XDVPN"]).map({ prefix + $0 }) {
            guard try state.read(key) == nil else { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
        }
        return (ipv4 == nil ? 0 : 1) + (dns == nil ? 0 : 1)
    }

    public func finish() throws {
        try validateDirectory()
        guard try readRouteRecord() == nil else { throw RouteFailure.system("server route cleanup incomplete", EBUSY) }
        if unlink(directory + "/vpnc-managed-script") != 0 && errno != ENOENT { throw RouteFailure.invalid }
        if unlink(recordPath) != 0 && errno != ENOENT { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
        if unlink(directory + "/lease") != 0 && errno != ENOENT { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
        guard rmdir(directory) == 0 else { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
    }
}

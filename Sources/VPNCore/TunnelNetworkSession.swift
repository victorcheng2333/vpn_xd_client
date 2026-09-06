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
        }, interfaceExists: { if_nametoindex($0) != 0 })
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
        return "\(EngineOutput.networkCleanupFailureMessage) \(detail)记录：\(directory)。再次连接会先重试清理；归属不匹配时不会删除。"
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
                                          keepMarker: Bool = false, interfaceWait: TimeInterval = 2) throws -> Int {
        let deadline = ProcessInfo.processInfo.systemUptime + interfaceWait
        while true {
            if let removed = try cleanupPass(processID: processID, afterExit: afterExit, keepMarker: keepMarker) { return removed }
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
        if unlink(recordPath) != 0 && errno != ENOENT { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
        if unlink(directory + "/lease") != 0 && errno != ENOENT { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
        guard rmdir(directory) == 0 else { throw VPNError.system(EngineOutput.networkCleanupFailureMessage) }
    }
}

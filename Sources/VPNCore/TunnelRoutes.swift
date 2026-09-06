import Foundation
import Darwin
import SystemConfiguration

struct IPv4Route: Codable, Equatable {
    var destination: String
    var gateway: String?
    var source: String?
    var interfaceIndex: UInt32
    var flags: Int32
    var isHost: Bool { flags & RTF_HOST != 0 }
    var isKernelClone: Bool { flags & RTF_WASCLONED != 0 && flags & RTF_STATIC == 0 }
    var scope: UInt32 { flags & RTF_IFSCOPE != 0 ? interfaceIndex : 0 }
    func matches(_ other: Self) -> Bool {
        destination == other.destination && gateway == other.gateway && source == other.source &&
        interfaceIndex == other.interfaceIndex && scope == other.scope &&
        flags & (RTF_HOST | RTF_GATEWAY | RTF_STATIC) == other.flags & (RTF_HOST | RTF_GATEWAY | RTF_STATIC)
    }
    var description: String {
        "destination=\(destination) gateway=\(gateway ?? "none") source=\(source ?? "none") interface=\(interfaceIndex) scope=\(scope) flags=\(flags)"
    }
}

struct PhysicalRoute: Equatable {
    var interface: String
    var index: UInt32
    var address: String
    var gateway: String
    func host(_ destination: String) -> IPv4Route {
        .init(destination: destination, gateway: gateway, source: address, interfaceIndex: index,
              flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC)
    }
}

enum RouteFailure: LocalizedError {
    case unavailable, conflict(String), system(String, Int32), invalid
    var errorDescription: String? {
        switch self {
        case .unavailable: return "物理出口路由尚未就绪，等待网络恢复。"
        case .conflict(let detail): return "服务器路由归属或出口不匹配，未覆盖已有配置：\(detail)"
        case .system(let action, let code): return "路由操作 \(action) 失败：errno=\(code) \(String(cString: strerror(code)))"
        case .invalid: return "服务器路由记录或内核响应无效。"
        }
    }
}

struct TunnelRouteAccess {
    enum Action: String { case add, delete }
    // Complete host-route inventory, not a best-route lookup. Scoped caches
    // and an unscoped static route can coexist for the same destination.
    var hostRoutes: (String) throws -> [IPv4Route]
    var physical: () throws -> PhysicalRoute
    var update: (Action, IPv4Route) throws -> Void

    static func live(store: SCDynamicStore) -> Self {
        .init(hostRoutes: { try RouteSocket.hostRoutes($0) }, physical: {
            guard let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else {
                throw RouteFailure.unavailable
            }
            let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any]
            let order = setup?["ServiceOrder"] as? [String] ?? []
            let ranked = keys.sorted {
                func rank(_ key: String) -> Int { order.firstIndex(of: key.components(separatedBy: "/")[3]) ?? Int.max }
                return rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1)
            }
            for key in ranked {
                guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let name = value["InterfaceName"] as? String, name.range(of: #"\Aen[0-9]+\z"#, options: .regularExpression) != nil,
                      let addresses = value["Addresses"] as? [String], let gateway = value["Router"] as? String,
                      RouteSocket.usableIPv4(gateway),
                      let link = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any],
                      (link["Active"] as? NSNumber)?.boolValue == true else { continue }
                let index = if_nametoindex(name)
                guard index > 0, let route = try RouteSocket.lookup("0.0.0.0", scope: index),
                      route.destination == "0.0.0.0", route.interfaceIndex == index,
                      route.gateway == gateway, let address = route.source,
                      addresses.contains(address), RouteSocket.usableIPv4(address) else { continue }
                return PhysicalRoute(interface: name, index: index, address: address, gateway: gateway)
            }
            throw RouteFailure.unavailable
        }, update: { action, route in try RouteSocket.update(action, route: route) })
    }
}

/// Numeric PF_ROUTE operations only: no shell, DNS, default-route deletion or flush.
/// Read back every mutation at the journal layer before claiming success.
enum RouteSocket {
    static func hostRoutes(_ destination: String) throws -> [IPv4Route] {
        try decodeTable(table()).filter { $0.isHost && $0.destination == destination }
    }

    // NET_RT_DUMP includes every scope and each route's RTA_IFA. RTM_GET
    // chooses a usable route and cannot prove that our exact entry is absent.
    static func table() throws -> Data {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { throw RouteFailure.system("route table size", errno) }
            guard size <= 16 * 1024 * 1024 else { throw RouteFailure.invalid }
            var data = Data(count: max(size, 4096))
            var used = data.count
            let result = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &used, nil, 0) }
            if result != 0 {
                let code = errno
                if code == ENOMEM { continue } // Table grew between the two reads.
                throw RouteFailure.system("route table read", code)
            }
            guard used <= data.count else { throw RouteFailure.invalid }
            return Data(data.prefix(used))
        }
        throw RouteFailure.system("route table changed repeatedly", ENOMEM)
    }

    static func decodeTable(_ data: Data) throws -> [IPv4Route] {
        var offset = 0, routes: [IPv4Route] = []
        while offset < data.count {
            guard data.count - offset >= MemoryLayout<rt_msghdr>.size else { throw RouteFailure.invalid }
            let header = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            let size = Int(header.rtm_msglen)
            guard header.rtm_type == RTM_GET, size >= MemoryLayout<rt_msghdr>.size,
                  size <= data.count - offset else { throw RouteFailure.invalid }
            routes.append(try decode(Data(data[offset..<(offset + size)])))
            offset += size
        }
        return routes
    }
    static func usableIPv4(_ string: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        return value >> 24 != 0 && value >> 24 != 127 && value >> 24 < 224 && value >> 16 != 0xa9fe
    }
    static func lookup(_ destination: String, scope: UInt32 = 0) throws -> IPv4Route? {
        do {
            let packet = try message(type: RTM_GET, destination: destination, flags: scope == 0 ? 0 : RTF_IFSCOPE, index: scope)
            return try decode(exchange(packet))
        } catch RouteFailure.system(_, let error) where error == ESRCH { return nil }
    }
    static func update(_ action: TunnelRouteAccess.Action, route: IPv4Route) throws {
        guard route.isHost, route.scope == 0, usableIPv4(route.destination),
              let gateway = route.gateway, usableIPv4(gateway),
              let source = route.source, usableIPv4(source), route.interfaceIndex > 0 else { throw RouteFailure.invalid }
        // RTM_CHANGE also uses best-match lookup and can change a scoped cache
        // instead of our static entry. Replace owned routes with DELETE + ADD.
        let type = action == .add ? RTM_ADD : RTM_DELETE
        _ = try exchange(message(type: type, destination: route.destination, gateway: gateway,
                                 source: source, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC, index: route.interfaceIndex))
    }
    static func message(type: Int32, destination: String, gateway: String? = nil,
                        source: String? = nil, flags: Int32, index: UInt32) throws -> Data {
        guard index <= UInt16.max else { throw RouteFailure.invalid }
        var header = rt_msghdr()
        header.rtm_version = UInt8(RTM_VERSION); header.rtm_type = UInt8(type)
        header.rtm_flags = flags; header.rtm_index = UInt16(index)
        header.rtm_pid = getpid(); header.rtm_seq = Int32.random(in: 1...Int32.max)
        var payload = Data()
        func append<T>(_ value: T, flag: Int32) {
            var value = value
            payload.append(withUnsafeBytes(of: &value) { Data($0) })
            // Darwin routing sockaddrs use 32-bit alignment, including on arm64.
            while payload.count % 4 != 0 { payload.append(0) }
            header.rtm_addrs |= flag
        }
        func address(_ value: String) throws -> sockaddr_in {
            var result = sockaddr_in()
            result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); result.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, value, &result.sin_addr) == 1 else { throw RouteFailure.invalid }
            return result
        }
        append(try address(destination), flag: RTA_DST)
        if let gateway { append(try address(gateway), flag: RTA_GATEWAY) }
        var link = sockaddr_dl()
        link.sdl_len = UInt8(MemoryLayout<sockaddr_dl>.size); link.sdl_family = sa_family_t(AF_LINK)
        link.sdl_index = UInt16(index)
        append(link, flag: RTA_IFP)
        if let source { append(try address(source), flag: RTA_IFA) }
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + payload.count)
        var result = withUnsafeBytes(of: &header) { Data($0) }; result.append(payload)
        return result
    }
    static func decode(_ data: Data) throws -> IPv4Route {
        guard data.count >= MemoryLayout<rt_msghdr>.size else { throw RouteFailure.invalid }
        let header = data.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
        guard header.rtm_version == RTM_VERSION, Int(header.rtm_msglen) <= data.count else { throw RouteFailure.invalid }
        var offset = MemoryLayout<rt_msghdr>.size
        var values: [Int32: String] = [:]
        for bit in 0..<RTAX_MAX where header.rtm_addrs & (1 << bit) != 0 {
            guard offset + 2 <= Int(header.rtm_msglen) else { throw RouteFailure.invalid }
            let length = Int(data[offset]), family = Int32(data[offset + 1])
            let padded = length == 0 ? 4 : (length + 3) & ~3
            guard offset + padded <= Int(header.rtm_msglen) else { throw RouteFailure.invalid }
            if family == AF_INET && length >= 8 {
                values[1 << bit] = data[(offset + 4)..<(offset + 8)].map(String.init).joined(separator: ".")
            }
            offset += padded
        }
        guard let destination = values[RTA_DST] else { throw RouteFailure.invalid }
        return .init(destination: destination, gateway: values[RTA_GATEWAY], source: values[RTA_IFA],
                     interfaceIndex: UInt32(header.rtm_index), flags: header.rtm_flags)
    }
    static func matchingReply(_ data: Data, request: rt_msghdr) throws -> Data? {
        // PF_ROUTE also broadcasts interface/address notifications, including
        // shorter headers, precisely while Wi-Fi is changing. They are not
        // failed replies to this operation.
        guard data.count >= 4, data[2] == RTM_VERSION, data[3] == request.rtm_type else { return nil }
        guard data.count >= MemoryLayout<rt_msghdr>.size else { throw RouteFailure.invalid }
        let response = data.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
        guard response.rtm_pid == request.rtm_pid && response.rtm_seq == request.rtm_seq else { return nil }
        guard response.rtm_errno == 0 else { throw RouteFailure.system("RTM_\(request.rtm_type)", response.rtm_errno) }
        return data
    }
    private static func exchange(_ packet: Data) throws -> Data {
        let request = packet.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { throw RouteFailure.system("socket", errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let sent = packet.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == packet.count else { throw RouteFailure.system("write", errno) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var buffer = [UInt8](repeating: 0, count: 8192)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 50)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw RouteFailure.system("poll", errno) }
            if result == 0 { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw RouteFailure.system("read", count < 0 ? errno : EIO) }
            let data = Data(buffer.prefix(count))
            if let reply = try matchingReply(data, request: request) { return reply }
        }
        throw RouteFailure.system("reply timeout", ETIMEDOUT)
    }
}

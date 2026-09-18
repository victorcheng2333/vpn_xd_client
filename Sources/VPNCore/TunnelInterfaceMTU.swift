import Foundation
import Darwin

enum TunnelMTUFailure: LocalizedError {
    case invalid, identity, system(String, Int32)
    var errorDescription: String? {
        switch self {
        case .invalid: return "网关 MTU 无效或超出支持范围。"
        case .identity: return "无法确认 MTU 更新属于本次隧道，未修改其他接口。"
        case .system(let action, let code): return "隧道 MTU 操作 \(action) 失败：errno=\(code) \(String(cString: strerror(code)))"
        }
    }
}

struct TunnelInterfaceState: Equatable {
    var index: UInt32
    var ipv4: [String]
    var mtu: Int
}

/// Direct ioctls avoid blocking OpenConnect on a shell while its data loop is
/// paused. Keep access injectable so ownership and failed readback are tested
/// without creating or changing a real network interface.
struct TunnelInterfaceAccess {
    var read: (String) throws -> TunnelInterfaceState
    var setMTU: (String, Int) throws -> Void

    static let live = Self(read: { interface in
        let index = if_nametoindex(interface)
        guard index != 0 else { throw TunnelMTUFailure.system("find interface", ENXIO) }
        let request = try request(interface: interface, mtu: nil)
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { throw TunnelMTUFailure.system("read interface addresses", errno) }
        defer { freeifaddrs(addresses) }
        var ipv4: [String] = [], cursor = addresses
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interface,
                  let address = current.pointee.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else {
                throw TunnelMTUFailure.system("read interface IPv4", errno)
            }
            ipv4.append(String(cString: buffer))
        }
        guard if_nametoindex(interface) == index else { throw TunnelMTUFailure.identity }
        return TunnelInterfaceState(index: index, ipv4: ipv4, mtu: Int(request.ifr_ifru.ifru_mtu))
    }, setMTU: { interface, mtu in
        _ = try request(interface: interface, mtu: mtu)
    })

    private static func request(interface: String, mtu: Int?) throws -> ifreq {
        let bytes = Array(interface.utf8)
        guard !bytes.isEmpty, bytes.count < Int(IFNAMSIZ), !bytes.contains(0),
              mtu.map({ (576...9000).contains($0) }) ?? true else { throw TunnelMTUFailure.invalid }
        var request = ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { $0.copyBytes(from: bytes) }
        if let mtu { request.ifr_ifru.ifru_mtu = Int32(mtu) }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TunnelMTUFailure.system("open socket", errno) }
        defer { close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw TunnelMTUFailure.system("isolate socket", errno) }
        // Darwin's struct-bearing _IOW/_IOWR macros are not imported into
        // Swift. These are SIOCSIFMTU ('i',52) and SIOCGIFMTU ('i',51), with
        // the SDK's native ifreq size rather than a hard-coded ABI size.
        let direction = mtu == nil ? UInt(IOC_INOUT) : UInt(IOC_IN)
        let operation = direction | (UInt(MemoryLayout<ifreq>.size) << 16) | (UInt(105) << 8) | (mtu == nil ? 51 : 52)
        guard ioctl(fd, operation, &request) == 0 else {
            throw TunnelMTUFailure.system(mtu == nil ? "read interface" : "set interface", errno)
        }
        return request
    }
}

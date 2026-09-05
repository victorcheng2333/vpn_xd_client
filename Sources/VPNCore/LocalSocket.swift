import Foundation
import Darwin

/// Private AF_UNIX transport: filesystem permissions plus kernel peer-UID checks.
/// One bounded JSON message per line; no secrets in files or process arguments.
public final class LocalSocket: @unchecked Sendable {
    public let descriptor: Int32
    private let writeLock = NSLock()
    private let readLock = NSLock()
    private var buffer = Data()
    private var closed = false
    public static let maxFrame = 32_768

    public init(descriptor: Int32) {
        self.descriptor = descriptor
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    // Keep the descriptor allocated until in-flight readers release this object;
    // this prevents a concurrent close/read from reaching a reused descriptor.
    deinit { close(); Darwin.close(descriptor) }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw VPNError.system("本地通信路径过长。") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { dest in dest.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    public static func listener(path: String) throws -> LocalSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPNError.system("无法创建本地通信。") }
        let channel = LocalSocket(descriptor: fd)
        let bound = try withAddress(path) { Darwin.bind(fd, $0, $1) }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 1) == 0 else { throw VPNError.system("无法启动本地权限助手通信。") }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return channel
    }

    public static func connect(path: String, expectedUID: uid_t) throws -> LocalSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPNError.system("无法创建通信。") }
        let channel = LocalSocket(descriptor: fd)
        let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard result == 0, channel.peerUID == expectedUID else { throw VPNError.system("本地通信身份验证失败。") }
        return channel
    }

    public func accept(expectedUID: uid_t, timeout: Int32 = 120_000) throws -> LocalSocket {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
        var ready = false
        while Date() < deadline && !isClosed {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, min(timeout, 250)) > 0 && event.revents & Int16(POLLIN) != 0 { ready = true; break }
        }
        guard ready && !isClosed else { throw VPNError.system("等待管理员授权超时或已取消，请重新连接。") }
        let fd = Darwin.accept(descriptor, nil, nil)
        guard fd >= 0 else { throw VPNError.system("权限助手连接失败。") }
        // macOS inherits O_NONBLOCK from the listener; the framed reader below
        // deliberately blocks on its dedicated worker instead of treating EAGAIN as EOF.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let peer = LocalSocket(descriptor: fd)
        guard peer.peerUID == expectedUID else { throw VPNError.system("权限助手身份不匹配。") }
        return peer
    }

    public var peerUID: uid_t? {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
    }

    public func send<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count < Self.maxFrame else { throw VPNError.system("通信内容过长。") }
        data.append(10)
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { throw VPNError.system("权限助手已退出。") }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let size = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw VPNError.system("无法向权限助手发送请求。") }
                offset += size
            }
        }
    }

    public func receive<T: Decodable>(_ type: T.Type) throws -> T? {
        readLock.lock(); defer { readLock.unlock() }
        while true {
            if isClosed { return nil }
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                guard line.count < Self.maxFrame else { throw VPNError.system("通信内容超出限制。") }
                let value = try JSONDecoder().decode(type, from: line)
                buffer.removeSubrange(...end)
                return value
            }
            guard buffer.count < Self.maxFrame else { throw VPNError.system("通信内容超出限制。") }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }

    public func close() {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(descriptor, SHUT_RDWR)
    }
    private var isClosed: Bool { writeLock.lock(); defer { writeLock.unlock() }; return closed }
}

import Foundation
import Darwin

/// A new UI may start before the previous helper has finished route cleanup.
/// Hold this lease until its child exits, so two sessions cannot overlap.
public final class SessionLease {
    private let descriptor: Int32

    public init(path: String, owner: uid_t = 0, timeout: TimeInterval = 12) throws {
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VPNError.system("无法获取 VPN 会话锁。") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
            close(fd); throw VPNError.system("VPN 会话锁权限不正确。")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                close(fd); throw VPNError.unavailable("上一次 VPN 正在清理网络，请稍后重新连接。")
            }
            usleep(50_000)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

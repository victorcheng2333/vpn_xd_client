import Foundation
import Darwin

/// Keep running tunnels independent of replacements of the user-installed App.
/// Nothing is executed until the copy in the private directory is verified.
public final class ServiceRuntime {
    public let bundle: ServiceBundle
    private let copy: PrivateRuntimeCopy

    public init(source: ServiceBundle) throws {
        guard geteuid() == 0 else { throw VPNError.unavailable("运行副本只能由系统服务创建。") }
        let copy = try PrivateRuntimeCopy(source: source.url, parent: RuntimeStorage.prepare(), owner: 0)
        let bundle = try ServiceBundle(url: copy.app)
        guard source.hasSamePayload(as: bundle) else { throw VPNError.unavailable("复制期间应用已改变，请重新注册系统服务。") }
        self.copy = copy
        self.bundle = bundle
    }

    /// Call only after every engine and network-cleanup child has stopped.
    public func removeAfterShutdown() { copy.remove() }

    /// Exercise the same copy/seal/signature pipeline without registering or
    /// starting a privileged service. The temporary copy is removed on return.
    public static func verifyCopy(source: ServiceBundle) throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let copy = try PrivateRuntimeCopy(source: source.url, parent: parent, owner: geteuid())
        try withExtendedLifetime(copy) {
            guard source.hasSamePayload(as: try ServiceBundle(url: copy.app)) else {
                throw VPNError.unavailable("复制期间应用已改变。")
            }
        }
    }
}

/// /private/var/run can legitimately be root:daemon 0775 on macOS. Keep
/// executable copies under an independently protected root-owned hierarchy.
enum RuntimeStorage {
    static let systemRoot = URL(fileURLWithPath: "/Library")

    static func prepare(root: URL = systemRoot, owner: uid_t = 0) throws -> URL {
        guard geteuid() == owner else { throw VPNError.unavailable("运行目录必须由系统服务创建。") }
        func validate(_ directory: URL, privateAccess: Bool = false) throws {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == owner,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & (privateAccess ? 0o077 : 0o022) == 0 else {
                throw VPNError.unavailable("运行目录的路径或权限异常：\(directory.path)")
            }
        }
        try validate(root)
        let shared = root.appendingPathComponent("PrivilegedHelperTools", isDirectory: true)
        let storage = shared.appendingPathComponent("com.xd.vpn.runtime", isDirectory: true)
        for (directory, mode) in [(shared, mode_t(0o755)), (storage, mode_t(0o700))] {
            if mkdir(directory.path, mode) != 0 && errno != EEXIST {
                throw VPNError.system("无法创建运行目录：\(directory.path)")
            }
            try validate(directory, privateAccess: directory == storage)
        }
        return storage
    }
}

/// Tests use an isolated directory owned by the test user. Production always
/// uses protected RuntimeStorage with owner 0, never a location supplied over XPC.
final class PrivateRuntimeCopy {
    let directory: URL
    let app: URL

    init(source: URL, parent: URL, owner: uid_t) throws {
        var info = stat()
        guard geteuid() == owner, lstat(parent.path, &info) == 0,
              info.st_uid == owner, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o022 == 0 else { throw VPNError.unavailable("运行副本目录权限异常。") }
        var template = Array(parent.appendingPathComponent("com.xd.vpn.runtime.XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw VPNError.system("无法创建私有运行目录。") }
        directory = URL(fileURLWithPath: String(cString: template))
        app = directory.appendingPathComponent("XD VPN.app")
        do {
            try FileManager.default.copyItem(at: source, to: app)
            try Self.seal(app, owner: owner)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func seal(_ url: URL, owner: uid_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw VPNError.system("无法读取运行副本。") }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        guard isDirectory || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else {
            throw VPNError.unavailable("运行副本中不允许链接或特殊文件。")
        }
        // The enclosing mkdtemp directory already excludes every other user.
        // Drop inherited ownership, write permissions and set-id bits as well.
        guard chown(url.path, owner, getegid()) == 0,
              chmod(url.path, isDirectory || info.st_mode & 0o111 != 0 ? 0o700 : 0o600) == 0 else {
            throw VPNError.system("无法保护运行副本。")
        }
        if isDirectory {
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                try seal(url.appendingPathComponent(name), owner: owner)
            }
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { remove() }
}

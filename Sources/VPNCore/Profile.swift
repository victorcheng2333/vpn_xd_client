import Foundation
import Darwin

public struct VPNProfile: Codable, Equatable {
    public var name: String
    public var server: String
    public var username: String
    public var authGroup: String

    public init(name: String = "工作网络", server: String = "vpn.xindong.com:8443", username: String = "", authGroup: String = "") {
        self.name = name; self.server = server; self.username = username; self.authGroup = authGroup
    }

    public func validated() throws -> VPNProfile {
        var profile = self
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.authGroup = authGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.name.isEmpty { profile.name = "工作网络" }
        let urlString = profile.server.contains("://") ? profile.server : "https://" + profile.server
        guard !profile.server.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URLComponents(string: urlString), url.scheme == "https",
              let host = url.host, !host.isEmpty, !host.hasPrefix("-"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw VPNError.invalidProfile("请输入有效的 VPN 地址，例如 vpn.xindong.com:8443。仅支持 HTTPS。")
        }
        guard !profile.username.isEmpty else { throw VPNError.invalidProfile("请填写 VPN 用户名。") }
        for value in [profile.name, profile.server, profile.username, profile.authGroup] {
            guard value.utf8.count <= 1024, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw VPNError.invalidProfile("配置中包含无效字符，或内容过长。")
            }
        }
        profile.server = urlString
        return profile
    }

    public var displayServer: String { server.replacingOccurrences(of: "https://", with: "") }
    public var credentialAccount: String { "\(server)|\(username)|\(authGroup)" }
}

public enum VPNError: LocalizedError {
    case invalidProfile(String), unavailable(String), system(String)
    public var errorDescription: String? {
        switch self { case .invalidProfile(let text), .unavailable(let text), .system(let text): return text }
    }
}

public enum OpenConnect {
    public static let bundledDirectory = "Contents/Resources/OpenConnect"
    public static let installedDirectory = "/Library/PrivilegedHelperTools/com.xd.vpn.openconnect"

    public static var executable: String? {
        bundledExecutable(in: Bundle.main.bundleURL)
    }

    public static func bundledExecutable(in bundle: URL) -> String? {
        let directory = bundle.appendingPathComponent(bundledDirectory)
        guard ["openconnect", "vpnc-script"].allSatisfy({
            let path = directory.appendingPathComponent($0).path
            var info = stat()
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && FileManager.default.isExecutableFile(atPath: path)
        }) else { return nil }
        return directory.appendingPathComponent("openconnect").path
    }

    public static func arguments(profile: VPNProfile) throws -> [String] {
        let p = try profile.validated()
        var args = ["--protocol=anyconnect", "--passwd-on-stdin", "--non-inter", "--no-external-auth",
                    // Use the macOS CA bundle, never a build-machine OpenSSL store.
                    "--cafile=/etc/ssl/cert.pem", "--no-system-trust",
                    "--reconnect-timeout=300", "--force-dpd=20", "--user=\(p.username)",
                    // Never run a server-supplied CSD/host-check executable as root.
                    "--csd-wrapper=/usr/bin/false"]
        if !p.authGroup.isEmpty { args.append("--authgroup=\(p.authGroup)") }
        args.append("--server=\(p.server)")
        return args
    }

    public static func validatePassword(_ password: String) throws {
        guard !password.isEmpty, password.utf8.count < 4096,
              !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
            throw VPNError.invalidProfile("密码不能为空、超过 4095 字节或包含换行。")
        }
    }
}

public struct RetryPolicy {
    public private(set) var attempts = 0
    public init() {}
    public mutating func nextDelay() -> TimeInterval {
        let delay = min(60.0, 3.0 * pow(2, Double(min(attempts, 5))))
        attempts += 1
        return delay
    }
    public mutating func reset() { attempts = 0 }
}

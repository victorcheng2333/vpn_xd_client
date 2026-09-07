import Foundation
import Security
import CryptoKit
import Darwin

/// Gatekeeper protects registered app bundles. We additionally validate all
/// signed resources and reject runtime entitlements that weaken peer identity.
public struct ServiceBundle {
    public let url: URL
    public let identity: HelperIdentity
    public let helper: String
    public let engine: String
    public let script: String
    private let digest: String

    public init(url: URL) throws {
        let url = url.resolvingSymlinksInPath()
        guard url.pathExtension == "app" else { throw VPNError.unavailable("系统助手必须位于完整 App 内。") }
        self.url = url
        helper = url.appendingPathComponent(ServicePolicy.helperRelativePath).path
        engine = url.appendingPathComponent(OpenConnect.bundledDirectory + "/openconnect").path
        script = url.appendingPathComponent(OpenConnect.bundledDirectory + "/vpnc-script").path
        try Self.verify(url, requirement: ServicePolicy.appRequirement)
        for (path, identifier) in [(helper, ServicePolicy.helperIdentifier), (engine, "com.xd.vpn.openconnect")] {
            try Self.requireRegularExecutable(path)
            try Self.verify(URL(fileURLWithPath: path), requirement: ServicePolicy.requirement(identifier: identifier))
        }
        try Self.requireRegularExecutable(script)
        identity = try HelperIdentity.read(bundle: url)
        digest = try Self.fingerprint([helper, engine, script])
    }

    public func revalidate() throws {
        let current = try ServiceBundle(url: url)
        guard current.identity == identity, current.digest == digest else {
            throw VPNError.unavailable("应用已更新，请重新注册系统助手后连接。")
        }
    }

    public static func runningHelper() throws -> ServiceBundle {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else {
            throw VPNError.system("无法确认助手可执行文件位置。")
        }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard executable.path == bundle.appendingPathComponent(ServicePolicy.helperRelativePath).path else {
            throw VPNError.unavailable("系统助手不在受支持的 App 包位置。")
        }
        return try ServiceBundle(url: bundle)
    }

    public static func verify(_ url: URL, requirement text: String) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw VPNError.unavailable("公司签名或应用完整性校验失败，请安装正式签名的完整应用。")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { throw VPNError.unavailable("无法读取代码签名。") }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for key in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables"] {
            if entitlements[key] as? Bool == true { throw VPNError.unavailable("特权服务不接受调试或可注入的应用。") }
        }
        let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard flags & 0x10000 != 0 else { throw VPNError.unavailable("系统助手要求启用 Hardened Runtime。") }
    }

    private static func requireRegularExecutable(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, FileManager.default.isExecutableFile(atPath: path) else {
            throw VPNError.unavailable("应用中的系统组件缺失或类型无效。")
        }
    }
    private static func fingerprint(_ paths: [String]) throws -> String {
        var hash = SHA256()
        for path in paths { hash.update(data: try Data(contentsOf: URL(fileURLWithPath: path))) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

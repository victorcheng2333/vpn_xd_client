import Foundation

/// Only Foundation value types cross XPC. No caller-selected paths or UIDs.
@objc public protocol HelperServiceProtocol {
    func status(withReply reply: @escaping (Data?, String?) -> Void)
    func openSession(_ identity: Data, withReply reply: @escaping (String?) -> Void)
    func sendCommand(_ command: Data, withReply reply: @escaping (String?) -> Void)
    func closeSession(withReply reply: @escaping (String?) -> Void)
    func retireLegacyAuthorization(withReply reply: @escaping (String?) -> Void)
}

@objc public protocol HelperEventProtocol {
    func receiveEvent(_ event: Data)
}

public struct HelperIdentity: Codable, Equatable {
    public let protocolVersion: Int
    public let build: String
    public let bundlePath: String

    public init(protocolVersion: Int = 9, build: String, bundlePath: String) {
        self.protocolVersion = protocolVersion; self.build = build; self.bundlePath = bundlePath
    }

    public static func read(bundle: URL) throws -> HelperIdentity {
        let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == ServicePolicy.appIdentifier,
              let build = plist["XDVPNBuildIdentifier"] as? String, !build.isEmpty else {
            throw VPNError.unavailable("应用缺少有效构建标识，请重新安装完整应用。")
        }
        return HelperIdentity(build: build, bundlePath: bundle.resolvingSymlinksInPath().path)
    }
}

public struct HelperServiceStatus: Codable {
    public let identity: HelperIdentity
    public let legacyAuthorization: Bool
    public let busy: Bool
    public init(identity: HelperIdentity, legacyAuthorization: Bool, busy: Bool) {
        self.identity = identity; self.legacyAuthorization = legacyAuthorization; self.busy = busy
    }
}

public enum HelperWire {
    public static let maximumBytes = 64 * 1024
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumBytes else { throw VPNError.invalidProfile("助手消息大小无效。") }
        return try JSONDecoder().decode(type, from: data)
    }
    public static func command(from data: Data) throws -> HelperCommand {
        let command = try decode(HelperCommand.self, from: data)
        if command.kind == .connect {
            guard let profile = command.profile, let password = command.password else {
                throw VPNError.invalidProfile("连接参数不完整。")
            }
            _ = try profile.validated(); try OpenConnect.validatePassword(password)
        } else if command.profile != nil || command.password != nil {
            throw VPNError.invalidProfile("此助手命令不接受连接参数。")
        }
        return command
    }
}

public enum ServicePolicy {
    public static let teamIdentifier = "KQY8A3BNVG"
    public static let appIdentifier = "com.xd.vpn"
    public static let helperIdentifier = "com.xd.vpn.helper"
    public static let machService = "KQY8A3BNVG.com.xd.vpn.helper"
    public static let plistName = "com.xd.vpn.helper.plist"
    public static let helperRelativePath = "Contents/Library/LaunchServices/com.xd.vpn.helper"
    public static let appRequirement = requirement(identifier: appIdentifier)
    public static let helperRequirement = requirement(identifier: helperIdentifier)

    public static func requirement(identifier: String) -> String {
        precondition([appIdentifier, helperIdentifier, "com.xd.vpn.openconnect"].contains(identifier))
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and ! entitlement[\"com.apple.security.get-task-allow\"] exists and ! entitlement[\"com.apple.security.cs.disable-library-validation\"] exists and ! entitlement[\"com.apple.security.cs.allow-dyld-environment-variables\"] exists"
    }
}

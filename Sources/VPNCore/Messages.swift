import Foundation

public struct HelperCommand: Codable {
    public enum Kind: String, Codable { case connect, disconnect, reconnect, shutdown }
    public var kind: Kind
    public var profile: VPNProfile?
    public var password: String?
    public init(_ kind: Kind, profile: VPNProfile? = nil, password: String? = nil) {
        self.kind = kind; self.profile = profile; self.password = password
    }
}

public struct HelperEvent: Codable, Equatable {
    public enum Kind: String, Codable { case ready, connecting, connected, reconnecting, stopped, failure, info }
    public var kind: Kind
    public var message: String
    public var address: String?
    public var retryable: Bool
    public init(_ kind: Kind, _ message: String, address: String? = nil, retryable: Bool = false) {
        self.kind = kind; self.message = message; self.address = address; self.retryable = retryable
    }
}

/// Translate a small allowlist of engine messages. Raw server responses, cookies,
/// passwords and authentication form contents are never forwarded or persisted.
public enum EngineOutput {
    public static func isTransportFailure(_ line: String) -> Bool {
        let text = line.lowercased()
        return ["failed to connect to host", "failed to connect to proxy", "getaddrinfo failed", "name or service not known", "nodename nor servname provided", "connection timed out", "network is unreachable", "no route to host", "connection refused", "temporary failure in name resolution"]
            .contains { text.contains($0) }
    }
    public static func event(for line: String, tunnelConfigured: Bool = false) -> HelperEvent? {
        let text = line.lowercased()
        if text.contains("server certificate verify failed") || text.contains("certificate verification failed") || text.contains("certificate does not match") || text.contains("certificate has expired") {
            return .init(.failure, "服务器证书验证失败。请联系 IT 检查证书或企业根证书。")
        }
        if text.contains("login failed") || text.contains("authentication failed") || text.contains("authentication failure") || text.contains("failed to obtain webvpn cookie") || text.contains("failed to authenticate") || text.contains("no password provided") || text.contains("non-interactive mode") {
            return .init(.failure, "登录未完成。请检查账号、密码和认证组；如需验证码或 SSO，请使用公司客户端。")
        }
        if (text.contains("script") && (text.contains("failed") || text.contains("error"))) || text.contains("failed to open tun") || text.contains("failed to configure tun") {
            return .init(.failure, "网络接口或路由配置失败，请检查 OpenConnect 与 vpnc-script 安装。")
        }
        if text.contains("configured as "), !text.contains("ssl disconnected") {
            let tail = line.components(separatedBy: "Configured as ").last ?? ""
            let ip = String(tail.prefix { $0 != "," && !$0.isWhitespace })
            let safeIP = !ip.isEmpty && ip.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" } ? ip : nil
            return .init(.connected, "VPN 隧道已建立。", address: safeIP)
        }
        if text.contains("cstp reconnected") || (tunnelConfigured && text.contains("cstp connected.")) {
            return .init(.connected, "VPN 连接已恢复。")
        }
        if text.contains("reconnecting") || text.contains("reconnect failed") || text.contains("dead peer detected") || text.contains("detected dead peer") || text.contains("ssl connection failure") {
            return .init(.reconnecting, "网络连接中断，正在恢复隧道。", retryable: true)
        }
        if text.contains("established dtls connection") {
            return .init(.info, "DTLS 加密通道已就绪。")
        }
        return nil
    }
}

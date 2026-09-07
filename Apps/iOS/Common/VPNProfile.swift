import Foundation

enum ConfigurationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct VPNProfile: Codable, Equatable {
    var server = "https://vpn.xindong.com:8443"
    var username = ""
    var group = ""
    var useDTLS = true
    // Optional for compatibility with profiles saved before this setting existed.
    var fullTunnel: Bool? = nil
    var onDemand = false
    var domains = ""
    var probeURL = ""

    func validated() throws -> VPNProfile {
        var result = self
        result.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.server.contains("://") { result.server = "https://" + result.server }
        guard let url = URLComponents(string: result.server), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, (url.port == nil || (1...65535).contains(url.port!)) else {
            throw ConfigurationError.invalid("请输入有效的 HTTPS VPN 地址，不能包含密码、查询参数或片段。")
        }
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.username.isEmpty, result.username.utf8.count <= 256,
              result.group.utf8.count <= 256, result.server.utf8.count <= 2048,
              ![result.username, result.group, result.server].contains(where: { $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw ConfigurationError.invalid("请填写用户名，并检查字段长度和换行符。")
        }
        if onDemand && domainList.isEmpty { throw ConfigurationError.invalid("按需连接需要至少一个内网域名，例如 intranet.example.com。") }
        for domain in domainList {
            guard domain.utf8.count <= 253, domain.contains("."),
                  domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                      !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") &&
                      $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                  }), domain.rangeOfCharacter(from: .letters) != nil else {
                throw ConfigurationError.invalid("按需域名只接受完整域名，不接受 URL、通配符或 IP。")
            }
        }
        guard domainList.count <= 32 else { throw ConfigurationError.invalid("最多配置 32 个按需域名。") }
        if !probeURL.isEmpty {
            guard let probe = URLComponents(string: probeURL), probe.scheme == "https", probe.host != nil,
                  probe.user == nil, probe.password == nil, probe.query == nil, probe.fragment == nil else {
                throw ConfigurationError.invalid("验证地址须为不含凭据和查询参数的 HTTPS 内网页面。")
            }
        }
        return result
    }
    var domainList: [String] {
        Array(Set(domains.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).map { $0.lowercased() })).sorted()
    }
    var configuration: [String: Any] { get throws { ["version": 1, "profile": try JSONEncoder().encode(self)] } }
    static func decode(_ dictionary: [String: Any]?) throws -> VPNProfile {
        guard let dictionary, dictionary["version"] as? Int == 1, let data = dictionary["profile"] as? Data else {
            throw ConfigurationError.invalid("VPN 配置版本无效，请重新保存配置。")
        }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

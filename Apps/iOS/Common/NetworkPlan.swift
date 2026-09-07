import Foundation
import Darwin

struct IPRoute: Equatable {
    let address: String
    let prefix: Int
    let family: Int32
    var ipv4Mask: String {
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return [24, 16, 8, 0].map { String((mask >> $0) & 255) }.joined(separator: ".")
    }
    static func family(of address: String) -> Int32? {
        var bytes = [UInt8](repeating: 0, count: 16)
        if inet_pton(AF_INET, address, &bytes) == 1 { return AF_INET }
        if inet_pton(AF_INET6, address, &bytes) == 1 { return AF_INET6 }
        return nil
    }
    static func maskPrefix(_ mask: String) throws -> Int {
        guard family(of: mask) == AF_INET else { throw ConfigurationError.invalid("IPv4 掩码无效。") }
        let value = mask.split(separator: ".").reduce(UInt32(0)) { ($0 << 8) | UInt32($1)! }
        let inverse = ~value
        guard inverse & (inverse &+ 1) == 0 else { throw ConfigurationError.invalid("IPv4 掩码必须连续。") }
        return value.nonzeroBitCount
    }
    init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let family = Self.family(of: parts[0]) else {
            throw ConfigurationError.invalid("网关下发了无效的 IP 路由。")
        }
        let maxPrefix = family == AF_INET ? 32 : 128
        let prefix: Int
        if parts.count == 1 { prefix = maxPrefix }
        else if parts[1].contains(".") && family == AF_INET { prefix = try Self.maskPrefix(parts[1]) }
        else if let number = Int(parts[1]), (0...maxPrefix).contains(number) { prefix = number }
        else { throw ConfigurationError.invalid("网关下发了无效的路由前缀。") }
        self.address = parts[0]; self.prefix = prefix; self.family = family
    }
}

struct NetworkPlan {
    let gateway: String
    let ipv4: IPRoute?
    let ipv6: IPRoute?
    let includes: [IPRoute]
    let excludes: [IPRoute]
    let dns: [String]
    let domains: [String]
    let searchDomains: [String]
    let mtu: Int
    let requiresFullTunnel: Bool
    let blocksIPv6: Bool

    init(_ input: [String: Any]) throws {
        func text(_ name: String) -> String { input[name] as? String ?? "" }
        guard IPRoute.family(of: text("gateway")) != nil else { throw ConfigurationError.invalid("网关地址无效。") }
        gateway = text("gateway")
        ipv4 = text("address").isEmpty ? nil : try IPRoute(text("address") + "/" + text("netmask"))
        if !text("netmask6").isEmpty { ipv6 = try IPRoute(text("netmask6")) }
        else { ipv6 = text("address6").isEmpty ? nil : try IPRoute(text("address6")) }
        guard ipv4 != nil || ipv6 != nil, ipv4?.family != AF_INET6, ipv6?.family != AF_INET else {
            throw ConfigurationError.invalid("网关没有分配有效的隧道地址。")
        }
        var routes = try (input["includes"] as? [String] ?? []).map(IPRoute.init)
        if routes.isEmpty {
            if ipv4 != nil { routes.append(try IPRoute("0.0.0.0/0")) }
            if ipv6 != nil { routes.append(try IPRoute("::/0")) }
        }
        excludes = try (input["excludes"] as? [String] ?? []).map(IPRoute.init)
        guard routes.count <= 256, excludes.count <= 256 else { throw ConfigurationError.invalid("路由数量超过验证版上限。") }
        for route in routes {
            guard route.family == AF_INET ? ipv4 != nil : ipv6 != nil else {
                throw ConfigurationError.invalid("网关路由与分配的地址族不匹配。")
            }
        }
        let full4 = routes.contains { $0.family == AF_INET && $0.prefix == 0 }
        let full6 = routes.contains { $0.family == AF_INET6 && $0.prefix == 0 }
        requiresFullTunnel = full4 || full6
        blocksIPv6 = full4 && ipv6 == nil
        if full4 != full6 && !blocksIPv6 {
            throw ConfigurationError.invalid("暂不支持 IPv6 单栈全隧道或混合全隧道/分流策略。")
        }
        // includeAllNetworks cannot honor explicit route exclusions. Never
        // silently replace a server exclusion policy with a different one.
        if requiresFullTunnel && !excludes.isEmpty {
            throw ConfigurationError.invalid("全隧道包含排除路由，当前版本无法完整应用该策略。")
        }
        if blocksIPv6 && (input["dns"] as? [String] ?? []).contains(where: { IPRoute.family(of: $0) == AF_INET6 }) {
            throw ConfigurationError.invalid("IPv4 全隧道不能使用网关未支持的 IPv6 DNS。")
        }
        includes = routes
        dns = input["dns"] as? [String] ?? []
        guard !dns.isEmpty, dns.count <= 3, dns.allSatisfy({ IPRoute.family(of: $0) != nil }) else {
            throw ConfigurationError.invalid("网关 DNS 配置无效或为空。")
        }
        let split = input["splitDNS"] as? [String] ?? []
        guard split.count <= 256, split.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 253 && !$0.contains(where: { $0.isWhitespace || $0 == "/" }) }) else {
            throw ConfigurationError.invalid("网关分流 DNS 域名无效。")
        }
        domains = split.isEmpty ? [""] : split
        searchDomains = text("domain").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard searchDomains.count <= 32, searchDomains.allSatisfy({ $0.utf8.count <= 253 && !$0.contains("/") }) else {
            throw ConfigurationError.invalid("网关 DNS 搜索域无效。")
        }
        mtu = input["mtu"] as? Int ?? 0
        guard (ipv6 == nil ? 576 : 1280)...9000 ~= mtu else { throw ConfigurationError.invalid("网关 MTU 超出支持范围。") }
        guard text("pac").isEmpty else { throw ConfigurationError.invalid("网关要求 PAC 代理，验证版尚未支持。") }
    }
}

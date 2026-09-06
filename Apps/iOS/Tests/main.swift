import Foundation
import Darwin

var checks = 0
func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { fputs("FAIL: \(name)\n", stderr); exit(1) }
}
func rejects(_ name: String, _ work: () throws -> Void) {
    checks += 1
    do { try work(); fputs("FAIL: \(name) did not reject\n", stderr); exit(1) } catch {}
}
var profile = VPNProfile()
profile.username = "tester"
expect(try profile.validated().server == "https://vpn.xindong.com:8443", "default HTTPS URL")
profile.server = "vpn.example.com:8443/group"
expect(try profile.validated().server == "https://vpn.example.com:8443/group", "normalize URL")
for invalid in ["http://vpn.example.com", "https://user:secret@vpn.example.com", "https://vpn.example.com?token=secret", "https://vpn.example.com/#fragment", "https://vpn.example.com:0"] {
    profile.server = invalid
    rejects("invalid URL") { _ = try profile.validated() }
}
profile.server = "https://vpn.example.com"
profile.onDemand = true
rejects("missing On Demand domains") { _ = try profile.validated() }
profile.domains = "intranet.example.com, docs.example.com, intranet.example.com"
expect(try profile.validated().domainList.count == 2, "normalize domains")
profile.domains = "https://intranet.example.com"
rejects("URL is not domain") { _ = try profile.validated() }
profile.domains = "10.0.0.1"
rejects("IP is not demand domain") { _ = try profile.validated() }
profile.onDemand = false; profile.domains = ""
expect(try VPNProfile.decode(profile.configuration) == profile, "profile round trip")
rejects("unknown config version") { _ = try VPNProfile.decode(["version": 2, "profile": Data()]) }

expect(try IPRoute("10.0.0.0/255.255.0.0").prefix == 16, "dotted mask")
expect(try IPRoute("10.0.0.0/0").ipv4Mask == "0.0.0.0", "zero prefix")
expect(try IPRoute("2001:db8::/64").family == AF_INET6, "IPv6 route")
for route in ["10.0.0.0/33", "10.0.0.0/255.0.255.0", "2001:db8::/129", "10.0.0.999/24"] {
    rejects("bad route") { _ = try IPRoute(route) }
}
var input: [String: Any] = ["gateway":"203.0.113.1", "address":"10.8.0.2", "netmask":"255.255.255.0", "dns":["10.8.0.1"], "mtu":1400, "includes":["10.0.0.0/8"], "excludes":[], "splitDNS":["example.internal"], "pac":""]
expect(try NetworkPlan(input).domains == ["example.internal"], "split DNS")
input["includes"] = []
rejects("IPv4-only full tunnel rejected") { _ = try NetworkPlan(input) }
input["netmask6"] = "fd00::2/64"; input["dns"] = ["fd00::1"]
expect(try NetworkPlan(input).includes.count == 2, "dual stack full tunnel")
var v6Only = input
v6Only["address"] = ""; v6Only["netmask"] = ""
rejects("IPv6-only full tunnel rejected") { _ = try NetworkPlan(v6Only) }
input["domain"] = "example.internal corp.internal"
expect(try NetworkPlan(input).searchDomains.count == 2, "DNS search domains preserved")
input["mtu"] = 1200
rejects("IPv6 minimum MTU") { _ = try NetworkPlan(input) }
input["mtu"] = 1400; input["pac"] = "https://example.com/proxy.pac"
rejects("mandatory PAC not silently dropped") { _ = try NetworkPlan(input) }

var ipv4 = Data(repeating: 0, count: 20); ipv4[0] = 0x45; ipv4[3] = 20
let framed = PacketCodec.encode(ipv4, family: AF_INET, mtu: 1400)!
expect(Array(framed.prefix(4)) == [0,0,0,2], "Darwin family prefix is network endian")
expect(PacketCodec.decode(framed, mtu: 1400)?.0 == ipv4, "IPv4 packet round trip")
expect(PacketCodec.encode(ipv4, family: AF_INET6, mtu: 1400) == nil, "family mismatch")
expect(PacketCodec.decode(Data([0,0,0,99]) + ipv4, mtu: 1400) == nil, "unknown family")
expect(PacketCodec.encode(ipv4, family: AF_INET, mtu: 19) == nil, "MTU bound")
ipv4[3] = 21
expect(PacketCodec.encode(ipv4, family: AF_INET, mtu: 1400) == nil, "IPv4 truncated payload")
var ipv6 = Data(repeating: 0, count: 40); ipv6[0] = 0x60
expect(PacketCodec.decode(PacketCodec.encode(ipv6, family: AF_INET6, mtu: 1400)!, mtu: 1400)?.1 == AF_INET6, "IPv6 packet round trip")
ipv6[5] = 1
expect(PacketCodec.encode(ipv6, family: AF_INET6, mtu: 1400) == nil, "IPv6 truncated payload")

let now = Date(timeIntervalSince1970: 10000)
var policy = RecoveryPolicy()
for offset in [0, 10, 20] { try policy.begin(now: now.addingTimeInterval(Double(offset))) }
policy.connected(now: now.addingTimeInterval(21))
let persisted = try JSONEncoder().encode(policy)
var restored = try JSONDecoder().decode(RecoveryPolicy.self, from: persisted)
rejects("rapid cold restart budget survives successful connect and process restart") { try restored.begin(now: now.addingTimeInterval(30)) }
expect(restored.blockedReason != nil, "persist permanent pause")
rejects("pause survives timeout window") { try restored.begin(now: now.addingTimeInterval(600)) }
var expired = policy
try expired.begin(now: now.addingTimeInterval(600))
expect(expired.attempts.count == 1, "old transient attempts expire")
print("Passed \(checks) iOS configuration, routing, packet and recovery checks.")

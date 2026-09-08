import Foundation
import Darwin
import NetworkExtension

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
var oldProfile = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
oldProfile.removeValue(forKey: "fullTunnel")
let legacyProfile = try JSONDecoder().decode(VPNProfile.self, from: JSONSerialization.data(withJSONObject: oldProfile))
expect(legacyProfile.fullTunnel == nil, "legacy saved profile remains readable")
expect(try legacyProfile.validated().fullTunnel == true, "missing route policy uses company full-tunnel default")
expect(VPNProfile().fullTunnel == true && VPNProfile().useDTLS, "new company profile defaults to full tunnel and DTLS preference")
profile.fullTunnel = true
expect(try VPNProfile.decode(profile.configuration).fullTunnel == true, "full tunnel selection persists")
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
let ipv4Full = try NetworkPlan(input)
expect(ipv4Full.requiresFullTunnel && ipv4Full.blocksIPv6, "IPv4 full tunnel requires enforced routing and IPv6 blocking")
expect(ipv4Full.ipv6 == nil, "never present blocking address as server-assigned IPv6")
var excludedFull = input
excludedFull["excludes"] = ["192.168.0.0/16"]
rejects("full tunnel must not silently ignore excluded routes") { _ = try NetworkPlan(excludedFull) }
var badDNS = input
badDNS["dns"] = ["2001:db8::53"]
rejects("IPv4-only tunnel cannot reach IPv6 DNS") { _ = try NetworkPlan(badDNS) }
input["netmask6"] = "fd00::2/64"; input["dns"] = ["fd00::1"]
expect(try NetworkPlan(input).includes.count == 2, "dual stack full tunnel")
expect(try !NetworkPlan(input).blocksIPv6, "dual stack preserves IPv6 forwarding")
var mixed = input
mixed["includes"] = ["0.0.0.0/0", "fd00::/64"]
rejects("mixed family full/split policy is not overridden") { _ = try NetworkPlan(mixed) }
expect(PacketCodec.canForward(family: AF_INET, blocksIPv6: true), "IPv4 allowed with IPv6 blocked")
expect(!PacketCodec.canForward(family: AF_INET6, blocksIPv6: true), "IPv6 is dropped with IPv4-only gateway")
expect(PacketCodec.canForward(family: AF_INET6, blocksIPv6: false), "IPv6 preserved with dual stack gateway")
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

expect(RecoveryPolicy.requiresCredentialCheck(result: -Int(EPERM), authenticationFailed: false, authenticationCompleted: false), "authorization failure before login requires credential check")
expect(RecoveryPolicy.requiresCredentialCheck(result: -Int(EINTR), authenticationFailed: true, authenticationCompleted: false), "rejected password form never retries")
expect(!RecoveryPolicy.requiresCredentialCheck(result: -Int(EPERM), authenticationFailed: false, authenticationCompleted: true), "CONNECT 401 after login renews expired session")
expect(RecoveryPolicy.requiresCredentialCheck(result: -Int(EPERM), authenticationFailed: true, authenticationCompleted: true), "explicit credential rejection still blocks recovery")
expect(!RecoveryPolicy.requiresCredentialCheck(result: -Int(ENETDOWN), authenticationFailed: false, authenticationCompleted: false), "network loss before login remains retryable")
expect(!RecoveryPolicy.requiresCredentialCheck(result: -Int(EPIPE), authenticationFailed: false, authenticationCompleted: true), "disconnected session remains retryable")

let now = Date(timeIntervalSince1970: 10000)
var policy = RecoveryPolicy()
for offset in [0, 10, 20] { try policy.begin(now: now.addingTimeInterval(Double(offset))) }
policy.connected(now: now.addingTimeInterval(21))
let persisted = try JSONEncoder().encode(policy)
var restored = try JSONDecoder().decode(RecoveryPolicy.self, from: persisted)
rejects("rapid cold restart budget survives successful connect and process restart") { try restored.begin(now: now.addingTimeInterval(30)) }
expect(restored.blockedReason == nil, "rate limit never permanently blocks automatic recovery")
do {
    try restored.begin(now: now.addingTimeInterval(30))
    expect(false, "rate limit must wait")
} catch let cooldown as RecoveryPolicy.Cooldown {
    expect(cooldown.retryAt == now.addingTimeInterval(300), "retry scheduled when oldest attempt expires")
}
try restored.begin(now: now.addingTimeInterval(300))
expect(restored.attempts.count == 3, "cooldown expires automatically without resetting the remaining budget")
rejects("cooldown does not allow a burst after expiry") { try restored.begin(now: now.addingTimeInterval(301)) }
var credentialBlock = RecoveryPolicy(blockedReason: "认证被拒绝")
rejects("actual credential blocks stay permanent") { try credentialBlock.begin(now: now.addingTimeInterval(600)) }
var expired = policy
try expired.begin(now: now.addingTimeInterval(600))
expect(expired.attempts.count == 1, "old transient attempts expire")

// Automatic-connection migration and system rules.
var automatic = VPNProfile()
automatic.username = "tester"
expect(!automatic.automaticConnectionEnabled && automatic.makeOnDemandRules().isEmpty, "automatic connection defaults off")
automatic.onDemand = true
automatic.domains = "intranet.example.com"
automatic.probeURL = "https://intranet.example.com/health"
let legacyRules = automatic.makeOnDemandRules()
expect(automatic.automaticConnectionEnabled, "legacy preference remains enabled")
expect(legacyRules.first is NEOnDemandRuleEvaluateConnection, "legacy domain trigger is not broadened")
let legacyRule = (legacyRules.first as? NEOnDemandRuleEvaluateConnection)?.connectionRules?.first
expect(legacyRule?.matchDomains == ["intranet.example.com"], "legacy domain scope preserved")
expect(legacyRule?.probeURL?.absoluteString == automatic.probeURL, "legacy probe preserved")
automatic.autoConnect = false
expect(!automatic.automaticConnectionEnabled && automatic.makeOnDemandRules().isEmpty, "explicit off overrides legacy on")
automatic.autoConnect = true
automatic.domains = ""
expect(try automatic.validated().automaticConnectionEnabled, "new auto-connect needs no internal domain")
expect(automatic.makeOnDemandRules().count == 1, "one system connection rule")
let automaticRule = automatic.makeOnDemandRules().first
expect(automaticRule is NEOnDemandRuleConnect && automaticRule?.interfaceTypeMatch == .any, "auto-connect covers Wi-Fi and cellular")
expect(automaticRule?.probeURL == nil && automaticRule?.dnsSearchDomainMatch == nil, "manual probe does not gate automatic connection")
let roundTrip = try VPNProfile.decode(automatic.configuration)
expect(roundTrip.autoConnect == true, "automatic connection persists")
var oldAutomatic = try JSONSerialization.jsonObject(with: JSONEncoder().encode(automatic)) as! [String: Any]
oldAutomatic.removeValue(forKey: "autoConnect")
oldAutomatic["domains"] = "intranet.example.com"
let restoredAutomatic = try VPNProfile.decode(["version": 1, "profile": JSONSerialization.data(withJSONObject: oldAutomatic)])
expect(restoredAutomatic.autoConnect == nil && restoredAutomatic.makeOnDemandRules().first is NEOnDemandRuleEvaluateConnection, "old saved profiles retain domain rules after decode")


func qualityTime(_ seconds: Double, wall: Double? = nil, boot: Int64 = 1) -> QualityInstant {
    QualityInstant(date: Date(timeIntervalSince1970: wall ?? (200000 + seconds)), continuous: seconds, boot: boot)
}
let qualityIntent = QualityIntent()
var quality = ConnectionQuality()
quality.providerStarted(intent: qualityIntent, at: qualityTime(0))
quality.connected(at: qualityTime(2))
quality.connected(at: qualityTime(3))
expect(quality.count(.connectionSucceeded, at: qualityTime(3).date) == 1, "duplicate connected notification counted once")
expect(quality.events.last?.duration == 2, "first connection uses monotonic duration")
quality.networkAvailable(false, at: qualityTime(5))
quality.recover(reason: .transport, at: qualityTime(6))
quality.networkAvailable(true, at: qualityTime(8))
quality.connected(at: qualityTime(10))
expect(quality.count(.recoveryStarted, at: qualityTime(10).date) == 1, "duplicate path and engine recovery notifications coalesce")
expect(quality.lastRecovery(at: qualityTime(10).date)?.duration == 5, "recovery duration includes known offline wait")
expect(quality.issue == nil, "successful recovery clears transient issue")
quality.recover(reason: .network, at: qualityTime(15))
quality.stop(reason: .user, at: qualityTime(16))
quality.stop(reason: .user, at: qualityTime(17))
expect(quality.count(.recoveryCancelled, at: qualityTime(17).date) == 1, "manual disconnect cancels recovery once")
expect(quality.count(.recoveryFailed, at: qualityTime(17).date) == 0, "manual disconnect is not recovery failure")
expect(quality.session == nil, "manual disconnect ends duration accounting")
quality.providerStarted(intent: QualityIntent(), at: qualityTime(20))
quality.stop(reason: .user, at: qualityTime(21))
expect(quality.count(.connectionCancelled, at: qualityTime(21).date) == 1, "cancel first connection without failure")

var restarted = ConnectionQuality()
restarted.providerStarted(intent: qualityIntent, at: qualityTime(0))
restarted.connected(at: qualityTime(1))
restarted.recover(reason: .network, at: qualityTime(2))
restarted = try JSONDecoder().decode(ConnectionQuality.self, from: JSONEncoder().encode(restarted))
restarted.providerStarted(intent: qualityIntent, at: qualityTime(4))
restarted.providerStarted(intent: qualityIntent, at: qualityTime(5))
restarted.connected(at: qualityTime(7, wall: 190000))
expect(restarted.events.last?.duration == 5, "persisted recovery duration survives restart and wall-clock correction")
expect(restarted.events.filter { $0.kind == .recoveryStarted }.count == 1, "repeated extension restarts preserve one pending recovery")
expect(restarted.events.filter { $0.kind == .connectionSucceeded }.count == 1, "automatic restart does not become manual connection attempt")
restarted.providerStarted(intent: qualityIntent, at: qualityTime(10))
restarted.connected(at: qualityTime(11))
expect(restarted.events.last?.kind == .recoverySucceeded && restarted.events.last?.duration == nil, "missing hard-termination boundary never invents recovery duration")
expect(restarted.events.filter { $0.kind == .recoveryStarted }.count == 2, "hard restart records one additional recovery")
restarted.recover(reason: .network, at: qualityTime(12))
restarted = try JSONDecoder().decode(ConnectionQuality.self, from: JSONEncoder().encode(restarted))
restarted.providerStarted(intent: qualityIntent, at: qualityTime(2, wall: 200015, boot: 2))
restarted.connected(at: qualityTime(3, wall: 200016, boot: 2))
expect(restarted.events.last?.duration == nil, "device reboot cannot reuse old monotonic clock")

var initialOffline = ConnectionQuality()
initialOffline.providerStarted(intent: qualityIntent, at: qualityTime(0))
initialOffline.networkAvailable(false, at: qualityTime(1))
initialOffline.connected(at: qualityTime(5))
expect(initialOffline.events.filter { $0.kind == .recoveryStarted }.isEmpty, "first connection offline wait is not a reconnection")
expect(initialOffline.events.last?.duration == 5, "initial connection retains offline wait")

var failedQuality = ConnectionQuality()
failedQuality.providerStarted(intent: qualityIntent, at: qualityTime(0))
failedQuality.fail(reason: .authentication, at: qualityTime(1))
failedQuality.fail(reason: .authentication, at: qualityTime(2))
expect(failedQuality.count(.connectionFailed, at: qualityTime(2).date) == 1, "terminal authentication failure counts once")
expect(failedQuality.issue?.reason == .authentication, "authentication action is retained for UI")
failedQuality.providerStarted(intent: QualityIntent(), at: qualityTime(3))
failedQuality.connected(at: qualityTime(4))
failedQuality.recover(reason: .sessionExpired, at: qualityTime(5))
failedQuality.fail(reason: .retryLimit, at: qualityTime(6))
expect(failedQuality.count(.recoveryFailed, at: qualityTime(6).date) == 1, "exhausted recovery is separate from initial connection failure")
expect(failedQuality.count(.connectionFailed, at: qualityTime(6).date) == 1, "failed recovery does not inflate login failure count")

var pending = ConnectionQuality()
pending.providerStarted(intent: qualityIntent, at: qualityTime(0))
pending.connected(at: qualityTime(1))
pending.recover(reason: .network, at: qualityTime(2))
var pausedIntent = qualityIntent
pausedIntent.enabled = false
pausedIntent.changedAt = qualityTime(3)
let pausedDisplay = pending.display(intent: pausedIntent, at: qualityTime(3))
expect(pausedDisplay.session == nil && pausedDisplay.count(.recoveryCancelled, at: qualityTime(3).date) == 1, "manual pause reflected even if provider misses stop callback")
expect(pending.session != nil, "main app does not mutate extension-owned history")

let nextDayDisplay = pending.display(intent: pausedIntent, at: qualityTime(86404))
expect(nextDayDisplay.count(.recoveryCancelled, at: qualityTime(86404).date) == 0, "missed stop callback must not create a fresh cancellation every day")
var newAfterPause = QualityIntent()
newAfterPause.previousStop = QualityIntent.Stop(id: qualityIntent.id, at: qualityTime(3))
var pendingAcrossDays = pending
pendingAcrossDays.providerStarted(intent: newAfterPause, at: qualityTime(86404))
expect(pendingAcrossDays.count(.recoveryCancelled, at: qualityTime(86404).date) == 0, "next manual connection preserves the actual old stop time")
pending.providerStarted(intent: QualityIntent(), at: qualityTime(4))
expect(pending.count(.recoveryCancelled, at: qualityTime(4).date) == 1, "new manual session closes prior pending recovery without false failure")
expect(pending.count(.recoveryFailed, at: qualityTime(4).date) == 0, "replaced connection is never an automatic recovery failure")
let stoppedID = pending.session?.id
pending.providerStarted(intent: pausedIntent, at: qualityTime(5))
expect(pending.session?.id != stoppedID && pending.session?.id != pausedIntent.id, "system-settings start after app pause is a distinct session")

var midnight = ConnectionQuality()
midnight.providerStarted(intent: qualityIntent, at: qualityTime(0))
midnight.connected(at: qualityTime(1))
midnight.recover(reason: .network, at: qualityTime(2))
midnight.connected(at: qualityTime(86410))
expect(midnight.count(.recoverySucceeded, at: qualityTime(86411).date) == 1, "recovery completed inside window is retained when start expired")
expect(midnight.count(.recoveryStarted, at: qualityTime(86411).date) == 0, "totals use completions rather than mismatched start-window denominator")
midnight.prune(at: qualityTime(172820).date)
expect(midnight.events.isEmpty, "history expires after 24 hours")
var bounded = ConnectionQuality()
for index in 0..<1100 {
    bounded.providerStarted(intent: QualityIntent(), at: qualityTime(Double(index * 2)))
    bounded.connected(at: qualityTime(Double(index * 2 + 1)))
}
expect(bounded.events.count <= 2048 && bounded.incomplete, "persisted history has a bounded size and discloses truncation")
expect(ConnectionQuality().events.isEmpty && ConnectionQuality().lastRecovery(at: Date()) == nil, "empty install has no fabricated quality samples")

print("Passed \(checks) iOS configuration, routing, packet and recovery checks.")

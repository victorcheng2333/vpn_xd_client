package com.xd.vpn.android

import com.xd.vpn.android.core.*
import org.junit.Assert.*
import org.junit.Test

class PolicyTest {
    private fun rejects(block: () -> Unit) { try { block(); fail("Expected validation rejection") } catch (_: IllegalArgumentException) {} }
    @Test fun profileNormalizesOnlyPermittedInputs() {
        val p = Profile(" vpn.example.com:8443/group ", " person ").validated()
        assertEquals("https://vpn.example.com:8443/group", p.server); assertEquals("person", p.username)
        assertFalse(p.autoConnect)
    }
    @Test fun profileRejectsCredentialUrlsCleartextAndAmbiguousComponents() {
        listOf("http://vpn.example.com", "https://u:p@vpn.example.com", "https://vpn.example.com?q=1", "https://vpn.example.com#x", "https://vpn.example.com:0", "https://vpn.example.com:65536", "https:///path", "https://vpn.example.com/a\nb").forEach {
            rejects { Profile(it, "person").validated() }
        }
        rejects { Profile(username = "").validated() }; rejects { Profile(username = "a\nb").validated() }
        rejects { Profile(username = "中".repeat(100)).validated() }
    }
    @Test fun enablingPreferenceNeverArmsRecovery() {
        val gate = RecoveryPolicy()
        assertFalse(gate.canResume(autoConnect = true))
        val armed = gate.manualStart(); assertFalse(armed.canResume(false)); assertTrue(armed.canResume(true))
        assertFalse(armed.stop().canResume(true))
    }
    @Test fun recoveryBudgetSurvivesFastSuccessfulConnectionsAndClockRollback() {
        var gate = RecoveryPolicy().manualStart()
        repeat(3) { gate = gate.begin(10_000L + it) }
        assertEquals(3, gate.attempts.size)
        assertEquals(Failure.BUDGET, gate.begin(10_100).blocked)
        assertEquals(Failure.BUDGET, gate.begin(1).blocked)
        assertEquals(1, gate.begin(310_003).attempts.size)
        assertTrue(gate.begin(10_100).manualStart().canResume(true))
    }
    @Test fun expiredCookieIsDistinctFromPasswordRejection() {
        assertEquals(Failure.SESSION, RecoveryPolicy.classify(-1, true, false, false, false))
        assertEquals(Failure.AUTH, RecoveryPolicy.classify(-1, false, false, false, false))
        assertEquals(Failure.AUTH, RecoveryPolicy.classify(-4, true, true, false, false))
        assertEquals(Failure.CERTIFICATE, RecoveryPolicy.classify(-22, false, false, true, false))
        assertEquals(Failure.SETTINGS, RecoveryPolicy.classify(-22, true, false, false, true))
    }
    private fun plan(address6: String = "", mask6: String = "", dns: List<String> = listOf("10.0.0.53"), excludes: List<String> = emptyList(), pac: String = "", mtu: Int = 1400) =
        NetworkPlan.create(listOf("10.20.0.8", "255.255.255.255", address6, mask6, "corp.example.com", pac), dns, listOf("10.0.0.0/8"), excludes, emptyList(), mtu)
    @Test fun ipv4FullTunnelDoesNotAccidentallyAllowIpv6DnsBypass() {
        val plan = plan(dns = listOf("10.0.0.53", "2001:db8::53"))
        assertEquals(listOf(IpPrefix("0.0.0.0", 0)), plan.routes)
        assertEquals(listOf("10.0.0.53"), plan.dns)
        assertEquals(1, plan.addresses.size)
        rejects { plan(dns = listOf("2001:db8::53")) }
    }
    @Test fun dualStackUsesServerAddressAndPrefix() {
        val plan = plan("2001:db8::8", "2001:db8::/64")
        assertEquals(IpPrefix("2001:db8::8", 64), plan.addresses[1])
        assertEquals(IpPrefix("::", 0), plan.routes[1])
        rejects { plan("2001:db8::8/64", mtu = 1200) }
    }
    @Test fun networkRejectsPacExcludesHostnamesAndBadMasks() {
        rejects { plan(pac = "https://pac.example.com/a") }; rejects { plan(excludes = listOf("10.0.0.0/8")) }
        rejects { plan(dns = listOf("dns.example.com")) }; rejects { plan(mtu = 9001) }
        rejects { NetworkPlan.mask("255.0.255.0") }; assertEquals(24, NetworkPlan.mask("255.255.255.0"))
        rejects { plan("localhost/64") }; rejects { plan("2001:db8::1%wlan0/64") }
    }
    @Test fun numericAddressParserRejectsAbbreviationsAndOctal() {
        listOf("127.1", "010.0.0.1", "256.0.0.1", "0x7f.0.0.1", "1.2.3.-1", "1.2.3.4.example.com").forEach { assertFalse(NetworkPlan.ipv4(it)) }
        assertTrue(NetworkPlan.ipv6("2001:db8::1")); assertFalse(NetworkPlan.ipv6("example.com"))
    }
    private fun event(kind: EventKind, time: Long, elapsed: Long, boot: Int = 1, id: String = "r") = QualityEvent(kind, time, elapsed, boot, id)
    @Test fun qualityDeduplicatesCompletionAndIgnoresCancelledRecovery() {
        val events = listOf(event(EventKind.RECOVERY_START, 100, 10), event(EventKind.RECOVERY_OK, 300, 210), event(EventKind.RECOVERY_OK, 300, 210),
            event(EventKind.RECOVERY_START, 400, 310, id = "r2"), event(EventKind.CANCEL, 500, 410, id = "r2"))
        assertEquals(QualitySummary(1, 0, 200, false), Quality.summarize(events, 600, false))
    }
    @Test fun qualityDoesNotInventDurationAcrossBootOrUnknownStart() {
        assertNull(Quality.summarize(listOf(event(EventKind.RECOVERY_START, 100, 10), event(EventKind.RECOVERY_OK, 200, 110, boot = 2)), 300, false).lastDurationMs)
        assertNull(Quality.summarize(listOf(event(EventKind.RECOVERY_START, 100, -1), event(EventKind.RECOVERY_OK, 200, 110)), 300, false).lastDurationMs)
        val missing = Quality.summarize(listOf(event(EventKind.RECOVERY_FAILED, 200, 110)), 300, false)
        assertTrue(missing.incomplete); assertNull(missing.lastDurationMs)
    }
    @Test fun qualityUses24HourWindowAndRejectsFutureCompletions() {
        val events = listOf(event(EventKind.RECOVERY_START, 1, 1), event(EventKind.RECOVERY_OK, 100, 100), event(EventKind.RECOVERY_FAILED, 200_000_000, 200, id = "f"))
        assertEquals(0, Quality.summarize(events, 86_400_101, false).successes)
        assertEquals(0, Quality.summarize(events, 86_400_101, false).failures)
    }
}

package com.xd.vpn.android

import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import androidx.test.platform.app.InstrumentationRegistry
import com.xd.vpn.android.core.*
import com.xd.vpn.android.data.SecureStore
import com.xd.vpn.android.service.XDVpnService
import org.junit.Assert.*
import org.junit.Test

/** Runs only on a disposable emulator; uses synthetic credentials and an untrusted loopback gateway. */
class ServiceLifecycleTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val repo get() = (context.applicationContext as VPNApplication).repository
    private fun shell(command: String) { instrumentation.uiAutomation.executeShellCommand(command).use { descriptor -> java.io.FileInputStream(descriptor.fileDescriptor).use { it.readBytes() } } }
    private fun waitFor(predicate: () -> Boolean) {
        val until = System.nanoTime() + 10_000_000_000L
        while (!predicate() && System.nanoTime() < until) Thread.sleep(50)
        assertTrue("Timed out waiting for VPN service state", predicate())
    }
    @Test fun foregroundServiceRejectsUntrustedGatewayAndPersistsPause() {
        NativeEngineTest().Gateway().use { gateway ->
            repo.save(Profile("https://127.0.0.1:${gateway.port}", "synthetic-test-only", true), "not-a-real-account".toByteArray())
            assertFalse(repo.mayResume()) // preference alone is not authorization
            shell("appops set ${context.packageName} ACTIVATE_VPN allow")
            try {
                assertNull(VpnService.prepare(context))
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                instrumentation.waitForIdleSync()
                ContextCompat.startForegroundService(context, Intent(context, XDVpnService::class.java).setAction(XDVpnService.CONNECT))
                waitFor { repo.state.value.snapshot.phase == Phase.FAILED }
                assertEquals(Failure.CERTIFICATE.message, repo.state.value.snapshot.message)
                val gate = SecureStore(context).loadGate()
                assertEquals(Failure.CERTIFICATE, gate.blocked); assertFalse(gate.armed); assertEquals(1, gate.attempts.size)
                assertEquals(0, gateway.requests.get())
                // Simulate a sticky/system start. A persisted failure must not submit again.
                context.startService(Intent(context, XDVpnService::class.java))
                Thread.sleep(300)
                assertEquals(1, SecureStore(context).loadGate().attempts.size)
                assertEquals(0, gateway.requests.get())
            } finally {
                context.startService(Intent(context, XDVpnService::class.java).setAction(XDVpnService.STOP))
                waitFor { repo.state.value.snapshot.phase == Phase.IDLE }
                shell("appops set ${context.packageName} ACTIVATE_VPN default")
            }
        }
    }
    @Test fun manualDisconnectCancelsHandshakeAndNeverRearmsOnSystemStart() {
        NativeEngineTest().Gateway(stall = true).use { gateway ->
            repo.save(Profile("https://127.0.0.1:${gateway.port}", "synthetic-test-only", true), "not-a-real-account".toByteArray())
            shell("appops set ${context.packageName} ACTIVATE_VPN allow")
            try {
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                instrumentation.waitForIdleSync()
                ContextCompat.startForegroundService(context, Intent(context, XDVpnService::class.java).setAction(XDVpnService.CONNECT))
                waitFor { gateway.connections.get() == 1 }
                context.startService(Intent(context, XDVpnService::class.java).setAction(XDVpnService.STOP))
                waitFor { repo.state.value.snapshot.phase == Phase.IDLE }
                val gate = SecureStore(context).loadGate()
                assertFalse(gate.armed); assertNull(gate.blocked); assertTrue(repo.state.value.profile.autoConnect)
                val count = gateway.connections.get()
                context.startService(Intent(context, XDVpnService::class.java))
                Thread.sleep(300)
                assertEquals(count, gateway.connections.get()); assertFalse(repo.mayResume())
            } finally {
                context.startService(Intent(context, XDVpnService::class.java).setAction(XDVpnService.STOP))
                waitFor { repo.state.value.snapshot.phase == Phase.IDLE }
                shell("appops set ${context.packageName} ACTIVATE_VPN default")
            }
        }
    }

}

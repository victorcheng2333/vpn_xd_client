package com.xd.vpn.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.xd.vpn.android.core.*
import com.xd.vpn.android.data.*
import com.xd.vpn.android.ui.VPNApp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class StorageAndUiTest {
    @get:Rule val compose = createComposeRule()
    @Test fun threeTabsExposeParityControls() {
        val state = ViewState(Profile(username = "test-only"), false)
        compose.setContent { VPNApp(state, false, {}, {}, { _, _ -> }, {}, {}) }
        compose.onNodeWithText("连接 VPN").assertIsDisplayed()
        compose.onNodeWithContentDescription("自动连接").assertIsNotEnabled()
        compose.onNodeWithText("设置").performClick()
        compose.onNodeWithText("HTTPS 服务器地址").assertIsDisplayed()
        compose.onNodeWithText("保存配置").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("连接质量").performClick()
        compose.onNodeWithText("最近 24 小时", substring = true).assertExists()
        compose.onNodeWithText("暂无连接记录").assertExists()
        compose.onNodeWithText("分享诊断报告").performScrollTo().assertIsDisplayed()
    }
    @Test fun connectingWithoutSavedConfigurationOffersSettingsInsteadOfStarting() {
        var connects = 0
        compose.setContent { VPNApp(ViewState(Profile(username = "test-only"), false), false, { connects++ }, {}, { _, _ -> }, {}, {}) }
        compose.onNodeWithText("连接 VPN").performClick()
        compose.onNodeWithText("尚未配置 VPN").assertIsDisplayed()
        compose.onNodeWithText("去设置").performClick()
        compose.onNodeWithText("HTTPS 服务器地址").assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, connects) }
    }
    @Test fun connectedSettingsCannotEditCredentials() {
        compose.setContent { VPNApp(ViewState(Profile(username = "test-only"), true, Snapshot(phase = Phase.CONNECTED)), false, {}, {}, { _, _ -> }, {}, {}) }
        compose.onNodeWithText("断开").assertIsDisplayed()
        compose.onNodeWithText("设置").performClick()
        compose.onNodeWithText("用户名").assertIsNotEnabled()
        compose.onNodeWithText("保存配置").performScrollTo().assertIsNotEnabled()
    }
    @Test fun qualityObservationTracksPageLifecycleAndCompositionWithoutStartingVpn() {
        val demand = StatsDemand()
        val visible = mutableStateOf(true)
        var connects = 0
        lateinit var owner: LifecycleOwner
        lateinit var registry: LifecycleRegistry
        compose.runOnIdle {
            owner = object : LifecycleOwner { override val lifecycle get() = registry }
            registry = LifecycleRegistry(owner)
            registry.currentState = Lifecycle.State.STARTED
        }
        compose.setContent {
            CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                if (visible.value) VPNApp(ViewState(Profile(username = "test-only"), false), false,
                    { connects++ }, {}, { _, _ -> }, {}, {}, observeStats = demand::acquire)
            }
        }
        compose.runOnIdle { assertFalse(demand.active.value) }
        compose.onNodeWithText("连接质量").performClick()
        compose.waitUntil { demand.active.value }
        compose.runOnIdle { registry.currentState = Lifecycle.State.CREATED }
        compose.waitUntil { !demand.active.value }
        compose.runOnIdle { registry.currentState = Lifecycle.State.STARTED }
        compose.waitUntil { demand.active.value }
        compose.onNodeWithText("连接").performClick()
        compose.waitUntil { !demand.active.value }
        compose.onNodeWithText("连接质量").performClick()
        compose.waitUntil { demand.active.value }
        compose.runOnIdle { visible.value = false }
        compose.waitUntil { !demand.active.value }
        compose.runOnIdle { assertEquals(0, connects) }
    }
    @Test fun diagnosticsDistinguishUnsampledCountersAndObservationLeavesSessionUntouched() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val context = object : android.content.ContextWrapper(base) {
            override fun getNoBackupFilesDir() = java.io.File(base.cacheDir, "stats-report-test").apply { mkdirs() }
        }
        try {
            val repo = VPNRepository(context)
            assertTrue(repo.report().contains("包计数尚未采样"))
            repo.update { it.copy(phase = Phase.FAILED, txPackets = 12, rxPackets = 34, statsAt = 1_700_000_000_000) }
            val before = repo.state.value
            val subscription = repo.statsDemand.acquire()
            subscription.close()
            assertEquals(before, repo.state.value)
            assertFalse(repo.mayResume())
            assertTrue(repo.report().contains("上行包 12 / 下行包 34"))
            assertTrue(repo.report().contains("最近采样："))
            assertTrue(repo.report().contains("缓存样本不代表最终流量"))
        } finally { context.noBackupFilesDir.deleteRecursively() }
    }
    @Test fun encryptedPasswordRoundTripsWithoutPlaintextAndSurvivesStoreReload() {
        // Isolated context directory, never modifies a user's profile.
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val context = object : android.content.ContextWrapper(base) {
            override fun getNoBackupFilesDir() = java.io.File(base.cacheDir, "storage-test").apply { mkdirs() }
        }
        val secret = "synthetic-password-test-only".toByteArray()
        try {
            val store = SecureStore(context)
            store.save(Profile(username = "synthetic"), secret)
            assertArrayEquals(secret, SecureStore(context).password())
            assertFalse(java.io.File(context.noBackupFilesDir, "vpn/profile.json").readText().contains(String(secret)))
            store.save(Profile(username = "synthetic", autoConnect = true), null)
            assertArrayEquals(secret, store.password())
            assertTrue(store.loadProfile().autoConnect)
            val gate = RecoveryPolicy().manualStart().begin(100).begin(101)
            store.saveGate(gate); assertEquals(gate, SecureStore(context).loadGate())
            store.saveGate(gate.stop()); assertFalse(SecureStore(context).loadGate().canResume(true))
        } finally { secret.fill(0); context.noBackupFilesDir.deleteRecursively() }
    }
    @Test fun disablingPreferenceBeforeNextColdAttemptPreventsCredentialSubmission() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val context = object : android.content.ContextWrapper(base) {
            override fun getNoBackupFilesDir() = java.io.File(base.cacheDir, "retry-preference-test").apply { mkdirs() }
        }
        try {
            val repo = VPNRepository(context)
            repo.save(Profile(username = "synthetic", autoConnect = true), "synthetic-only".toByteArray())
            repo.manualStart(); assertNull(repo.beginAttempt())
            repo.setAutoConnect(false)
            assertEquals(Failure.NETWORK, repo.beginAttempt(requireAutomatic = true))
            assertEquals(1, SecureStore(context).loadGate().attempts.size)
            repo.stopIntent()
            assertFalse(VPNRepository(context).mayResume())
            java.io.File(context.noBackupFilesDir, "vpn/recovery.json").writeText("corrupt")
            assertFalse(SecureStore(context).loadGate().canResume(true))
            // A damaged gate is read as disarmed and surfaces only as an incomplete-history hint, never as a resumable state.
            assertTrue(VPNRepository(context).state.value.incomplete)
        } finally { context.noBackupFilesDir.deleteRecursively() }
    }
    @Test fun historyIsPersistedOffTheCallingThreadInOrder() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val context = object : android.content.ContextWrapper(base) {
            override fun getNoBackupFilesDir() = java.io.File(base.cacheDir, "history-test").apply { mkdirs() }
        }
        try {
            val repo = VPNRepository(context)
            repo.record(EventKind.START); repo.record(EventKind.AUTHENTICATING); repo.record(EventKind.CONNECTED)
            val until = System.nanoTime() + 5_000_000_000L
            while (System.nanoTime() < until && VPNRepository(context).state.value.events.size < 3) Thread.sleep(20)
            assertEquals(listOf(EventKind.START, EventKind.AUTHENTICATING, EventKind.CONNECTED), VPNRepository(context).state.value.events.map { it.kind })
            assertFalse(VPNRepository(context).state.value.incomplete)
        } finally { context.noBackupFilesDir.deleteRecursively() }
    }

    @Test fun savedPasswordDisplaysMaskAndSavingBlankPreservesCredential() {
        var saved: String? = null
        compose.setContent { VPNApp(ViewState(Profile(username = "test-only"), true), false, {}, {}, { _, password -> saved = password }, {}, {}) }
        compose.onNodeWithText("设置").performClick()
        compose.onNodeWithText("****").assertIsDisplayed()
        compose.onNodeWithText("保存配置").performScrollTo().performClick()
        compose.runOnIdle { assertEquals("", saved) }
        compose.onNodeWithText("密码").performClick()
        compose.onNodeWithText("****").assertDoesNotExist()
        compose.onNodeWithText("密码").performTextInput("replacement-test-only")
        compose.onNodeWithText("保存配置").performScrollTo().performClick()
        compose.runOnIdle { assertEquals("replacement-test-only", saved) }
        compose.onNodeWithText("****").assertIsDisplayed()
        compose.onNodeWithText("密码").performClick()
        compose.onNodeWithText("保存配置").performScrollTo().performClick()
        compose.runOnIdle { assertEquals("", saved) }
        compose.onNodeWithText("****").assertIsDisplayed()
    }

}

package com.xd.vpn.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
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
        compose.onNodeWithText("最近 24 小时").assertExists()
        compose.onNodeWithText("分享诊断报告").performScrollTo().assertIsDisplayed()
    }
    @Test fun connectedSettingsCannotEditCredentials() {
        compose.setContent { VPNApp(ViewState(Profile(username = "test-only"), true, Snapshot(phase = Phase.CONNECTED)), false, {}, {}, { _, _ -> }, {}, {}) }
        compose.onNodeWithText("断开").assertIsDisplayed()
        compose.onNodeWithText("设置").performClick()
        compose.onNodeWithText("用户名").assertIsNotEnabled()
        compose.onNodeWithText("保存配置").performScrollTo().assertIsNotEnabled()
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
        } finally { context.noBackupFilesDir.deleteRecursively() }
    }

}

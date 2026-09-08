package com.xd.vpn.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.xd.vpn.android.core.Profile
import com.xd.vpn.android.service.XDVpnService
import com.xd.vpn.android.ui.VPNApp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val app get() = application as VPNApplication
    private val repo get() = app.repository
    private var awaitingConsent by mutableStateOf(false)
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }
    private val vpnPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        awaitingConsent = false
        if (result.resultCode == RESULT_OK) launchVPN() else repo.message("未获得系统 VPN 授权，可以再次点击连接。")
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val state by repo.state.collectAsStateWithLifecycle()
            VPNApp(state, awaitingConsent, connect = ::connect, disconnect = ::disconnect, save = ::save, autoConnect = ::setAutoConnect, share = ::share)
        }
    }
    private fun connect() {
        val state = repo.state.value
        if (awaitingConsent || state.busy) return
        // The UI offers the settings page first; this is the last line of defence before the service reads storage.
        if (!state.hasPassword || runCatching { state.profile.validated() }.isFailure) { repo.message("请先在设置页填写并保存服务器、用户名和密码。"); return }
        val request = VpnService.prepare(this)
        if (request == null) launchVPN() else { awaitingConsent = true; vpnPermission.launch(request) }
    }
    private fun disconnect() { startService(Intent(this, XDVpnService::class.java).setAction(XDVpnService.STOP)) }
    private fun save(profile: Profile, password: String) {
        app.scope.launch {
            repo.busy(true)
            val secret = password.takeIf { it.isNotEmpty() }?.toByteArray()
            try { withContext(Dispatchers.IO) { repo.save(profile, secret) } }
            catch (error: CancellationException) { throw error }
            catch (error: IllegalArgumentException) { repo.message(error.message ?: "请检查配置。") }
            catch (_: Exception) { repo.message("保存失败，请解锁设备并检查密码后重试。") }
            finally { secret?.fill(0); repo.busy(false) }
        }
    }
    private fun setAutoConnect(enabled: Boolean) {
        app.scope.launch {
            repo.busy(true)
            try {
                withContext(Dispatchers.IO) { repo.setAutoConnect(enabled) }
                if (repo.state.value.snapshot.phase.active) startService(Intent(this@MainActivity, XDVpnService::class.java).setAction(XDVpnService.PREFERENCE))
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { repo.message("自动连接偏好未能保存，请重试。") }
            finally { repo.busy(false) }
        }
    }
    private fun share() {
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, repo.report()), "分享连接诊断"))
    }
    private fun launchVPN() {
        if (VpnService.prepare(this) != null) { repo.message("系统 VPN 授权已失效，请重新连接。"); return }
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        try { ContextCompat.startForegroundService(this, Intent(this, XDVpnService::class.java).setAction(XDVpnService.CONNECT)) }
        catch (_: Exception) { repo.message("系统暂时无法启动 VPN，请保持应用前台后重试。") }
    }
}

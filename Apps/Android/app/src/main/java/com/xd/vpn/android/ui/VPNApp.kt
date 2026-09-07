package com.xd.vpn.android.ui

import android.os.SystemClock
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.xd.vpn.android.BuildConfig
import com.xd.vpn.android.core.*
import com.xd.vpn.android.data.ViewState
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val Brand = Color(0xFF227858)
private val Idle = Color(0xFF626D7A)
private val Connecting = Color(0xFF397ADE)
private val Connected = Color(0xFF26976B)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VPNApp(state: ViewState, busy: Boolean, connect: () -> Unit, disconnect: () -> Unit, save: (Profile, String) -> Unit,
    autoConnect: (Boolean) -> Unit, share: () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) darkColorScheme(primary = Color(0xFF79D9AD), background = Color(0xFF121815), surface = Color(0xFF1D2721))
        else lightColorScheme(primary = Brand, background = Color(0xFFF2F4F3), surface = Color.White)
    MaterialTheme(colorScheme = scheme) {
        var tab by rememberSaveable { mutableIntStateOf(0) }
        val titles = listOf("连接", "设置", "连接质量")
        val icons = listOf(Icons.Outlined.Shield, Icons.Outlined.Tune, Icons.Outlined.Insights)
        Scaffold(containerColor = scheme.background,
            topBar = { TopAppBar(title = { Text(if (tab == 0) "XD VPN" else titles[tab], fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = scheme.background)) },
            bottomBar = {
                NavigationBar(containerColor = scheme.surface) {
                    titles.forEachIndexed { index, title -> NavigationBarItem(selected = tab == index, onClick = { tab = index },
                        icon = { Icon(icons[index], contentDescription = null) }, label = { Text(title) },
                        colors = NavigationBarItemDefaults.colors(indicatorColor = scheme.primary.copy(alpha = .1f))) }
                }
            }) { padding ->
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
                Column(Modifier.widthIn(max = 640.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    when (tab) {
                        0 -> Home(state, busy, connect, disconnect, autoConnect)
                        1 -> SettingsPage(state, busy, save)
                        2 -> QualityPage(state, share)
                    }
                    Spacer(Modifier.height(4.dp))
                }
            }
        }
    }
}
@Composable private fun Panel(content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
    }
}
@Composable private fun Detail(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        SelectionContainer(Modifier.weight(1f)) { Text(value, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.End, style = MaterialTheme.typography.bodyMedium) }
    }
}
@Composable private fun Note(text: String) { Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall) }
@Composable private fun Home(state: ViewState, busy: Boolean, connect: () -> Unit, disconnect: () -> Unit, autoConnect: (Boolean) -> Unit) {
    val snapshot = state.snapshot
    val color = when (snapshot.phase) { Phase.CONNECTED -> Connected; Phase.CONNECTING, Phase.RECOVERING -> Connecting; else -> Idle }
    val buttonColor = if (snapshot.phase.active) color else MaterialTheme.colorScheme.primary
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.Language, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(6.dp)); Note("工作网络"); Spacer(Modifier.weight(1f)); Note("Android 验证版 ${BuildConfig.VERSION_NAME}")
    }
    Panel {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Orbit(snapshot.phase, color)
            Text(snapshot.phase.title, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, color = color, textAlign = TextAlign.Center)
            Text(if (snapshot.phase.active) "连接状态和恢复记录可在连接质量页查看。" else "连接公司网络，安全访问工作资源。", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            Button(onClick = if (snapshot.phase.active) disconnect else connect, enabled = !busy && snapshot.phase != Phase.STOPPING,
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), shape = RoundedCornerShape(14.dp), colors = ButtonDefaults.buttonColors(containerColor = buttonColor)) {
                if (snapshot.phase in setOf(Phase.CONNECTING, Phase.RECOVERING)) { CircularProgressIndicator(Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp); Spacer(Modifier.width(10.dp)) }
                Text(if (snapshot.phase.active) "断开" else "连接 VPN", style = MaterialTheme.typography.titleMedium)
            }
        }
    }
    Panel {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("自动连接", modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            Switch(state.profile.autoConnect, autoConnect, enabled = state.hasPassword && !busy && snapshot.phase != Phase.STOPPING, modifier = Modifier.semantics { contentDescription = "自动连接" })
        }
        Note(when {
            !state.profile.autoConnect -> "开启后保存自动连接偏好；仍需点击「连接 VPN」开始连接。"
            state.armed && snapshot.phase.active -> "本轮连接允许自动恢复；手动断开后暂停，须再次点击连接。"
            else -> "已保存偏好。点击「连接 VPN」后启用本轮自动恢复。"
        })
    }
    Panel { Detail("服务器", state.profile.server); Detail("隧道地址", snapshot.address) }
    snapshot.message?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    Note("首次连接会请求系统 VPN 授权。连接期间显示系统 VPN 标识和状态通知。")
}
@Composable private fun Orbit(phase: Phase, color: Color) {
    val spinning = phase in setOf(Phase.CONNECTING, Phase.RECOVERING, Phase.STOPPING)
    val rotation = if (spinning) {
        val transition = rememberInfiniteTransition(label = "连接进度")
        val angle by transition.animateFloat(0f, 360f, infiniteRepeatable(tween(1800, easing = LinearEasing)), label = "圆弧旋转")
        angle
    } else 0f
    Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(154.dp).rotate(rotation)) {
            drawCircle(color.copy(alpha = .06f))
            drawCircle(color.copy(alpha = .1f), radius = size.minDimension / 2 - 7.dp.toPx(), style = Stroke(1.dp.toPx()))
            if (spinning) drawArc(color, -90f, 100f, false, topLeft = Offset(7.dp.toPx(), 7.dp.toPx()), size = Size(size.width - 14.dp.toPx(), size.height - 14.dp.toPx()), style = Stroke(4.dp.toPx(), cap = StrokeCap.Round))
        }
        Icon(if (phase == Phase.CONNECTED) Icons.Outlined.VerifiedUser else Icons.Outlined.Shield,
            contentDescription = phase.title, modifier = Modifier.size(64.dp), tint = color)
    }
}
@Composable private fun SettingsPage(state: ViewState, busy: Boolean, save: (Profile, String) -> Unit) {
    var server by remember(state.profile.server) { mutableStateOf(state.profile.server) }
    var username by remember(state.profile.username) { mutableStateOf(state.profile.username) }
    // Deliberately not rememberSaveable: passwords never enter saved state or Android backup.
    var password by remember { mutableStateOf("") }
    val focusManager = LocalFocusManager.current
    var passwordFocused by remember { mutableStateOf(false) }
    val showSavedPassword = state.hasPassword && password.isEmpty() && !passwordFocused
    val enabled = !state.snapshot.phase.active && !busy
    Text("VPN 配置", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
    Panel {
        OutlinedTextField(server, { server = it }, label = { Text("HTTPS 服务器地址") }, enabled = enabled, modifier = Modifier.fillMaxWidth(),
            singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
        OutlinedTextField(username, { username = it }, label = { Text("用户名") }, enabled = enabled, modifier = Modifier.fillMaxWidth(),
            singleLine = true, keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
        OutlinedTextField(if (showSavedPassword) "****" else password, { password = it }, label = { Text("密码") },
            placeholder = { Text(if (state.hasPassword) "留空保持原密码" else "请输入密码") },
            enabled = enabled, modifier = Modifier.fillMaxWidth().onFocusChanged { passwordFocused = it.isFocused }, singleLine = true,
            visualTransformation = if (showSavedPassword) VisualTransformation.None else PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false))
        Button(onClick = { save(state.profile.copy(server = server, username = username), password); password = ""; focusManager.clearFocus() }, enabled = enabled,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(12.dp)) { Text("保存配置") }
    }
    Note("密码通过 Android Keystore 加密保存在本机，设备首次解锁后可供隧道后台读取。")
    Note("支持 AnyConnect 用户名/密码认证，暂不支持 SSO、MFA、客户端证书及终端合规检查。")
    if (state.snapshot.phase.active) Note("请先断开 VPN，再修改连接配置。")
    state.snapshot.message?.let { Note(it) }
}
@Composable private fun QualityPage(state: ViewState, share: () -> Unit) {
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    val lifecycle = LocalLifecycleOwner.current
    LaunchedEffect(lifecycle) {
        lifecycle.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { now = SystemClock.elapsedRealtime(); delay(1_000) }
        }
    }
    val summary = Quality.summarize(state.events, System.currentTimeMillis(), state.incomplete)
    val snapshot = state.snapshot
    val elapsed = snapshot.connectedAt?.let { ((now - it).coerceAtLeast(0) / 1000) }
    Panel {
        Text("当前连接", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Detail("连接时长", elapsed?.let { "%02d:%02d:%02d".format(it / 3600, it / 60 % 60, it % 60) } ?: "—")
        Detail("传输方式", snapshot.transport)
        Detail("自动恢复", if (state.profile.autoConnect && state.armed) "已启用" else "已暂停")
        Detail("上行 / 下行包", "${snapshot.txPackets} / ${snapshot.rxPackets}")
    }
    Panel {
        Text("最近 24 小时", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) { Text("${summary.successes}", style = MaterialTheme.typography.headlineLarge, color = MaterialTheme.colorScheme.primary); Note("恢复成功") }
            Column(horizontalAlignment = Alignment.CenterHorizontally) { Text("${summary.failures}", style = MaterialTheme.typography.headlineLarge); Note("恢复失败") }
        }
        Detail("最近恢复耗时", summary.lastDurationMs?.let { "%.1f 秒".format(it / 1000.0) } ?: "—")
        if (summary.incomplete) Note("部分历史记录缺失或已裁剪，统计可能不完整。")
        Note(if (summary.failures > 0 || snapshot.phase == Phase.FAILED) "若恢复持续失败，请检查当前网络和账号，查看以下事件后手动重新连接。" else "恢复记录由 VPN 服务保存。包计数不等于业务成功，请实际访问内网业务确认。")
    }
    var expanded by rememberSaveable { mutableStateOf(false) }
    Panel {
        TextButton(onClick = { expanded = !expanded }, modifier = Modifier.fillMaxWidth()) {
            Text(if (expanded) "收起详细事件" else "查看详细事件"); Spacer(Modifier.weight(1f)); Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
        }
        if (expanded) {
            if (state.events.isEmpty()) Note("暂无连接事件。")
            val date = remember { SimpleDateFormat("MM-dd HH:mm:ss", Locale.ROOT) }
            state.events.takeLast(64).asReversed().forEach { Note("${date.format(Date(it.wall))}  ${it.kind.label}") }
        }
        OutlinedButton(onClick = share, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Icon(Icons.Outlined.IosShare, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("分享诊断报告") }
    }
}

package com.xd.vpn.android.ui

import android.os.SystemClock
import android.provider.Settings
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.xd.vpn.android.BuildConfig
import com.xd.vpn.android.core.*
import com.xd.vpn.android.data.ViewState
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// Match Apps/iOS/App/ConnectionOrbitView.swift and Sources/XDVPN/Theme.swift.
private val Brand = Color(0xFF227858)
private val Mint = Color(0xFFDAEFE3)
private val Warning = Color(0xFFD9822B)

/** The four looks of the iOS ConnectionOrbitView; a failed session reads as idle there too. */
enum class Appearance(val color: Color, val icon: ImageVector, val progress: Boolean) {
    IDLE(Color(0xFF626D7A), Icons.Outlined.PowerSettingsNew, false),
    CONNECTING(Color(0xFF326CB0), Icons.Outlined.Autorenew, true),
    CONNECTED(Brand, Icons.Filled.VerifiedUser, false),
    DISCONNECTING(Color(0xFF626D7A), Icons.Outlined.PowerSettingsNew, true);
    companion object {
        fun of(phase: Phase) = when (phase) {
            Phase.CONNECTING, Phase.RECOVERING -> CONNECTING
            Phase.CONNECTED -> CONNECTED
            Phase.STOPPING -> DISCONNECTING
            Phase.IDLE, Phase.FAILED -> IDLE
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VPNApp(state: ViewState, busy: Boolean, connect: () -> Unit, disconnect: () -> Unit, save: (Profile, String) -> Unit,
    autoConnect: (Boolean) -> Unit, share: () -> Unit, observeStats: () -> AutoCloseable = { AutoCloseable {} }) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) darkColorScheme(primary = Color(0xFF79D9AD), background = Color(0xFF121815), surface = Color(0xFF1D2721))
        else lightColorScheme(primary = Brand, background = Color(0xFFF2F4F3), surface = Color.White)
    val hold = busy || state.busy
    MaterialTheme(colorScheme = scheme) {
        var tab by rememberSaveable { mutableIntStateOf(0) }
        var configurationAlert by rememberSaveable { mutableStateOf(false) }
        // Same gate as iOS VPNModel.needsConfiguration: the service can only start from a saved, valid profile.
        val needsConfiguration = !state.hasPassword || runCatching { state.profile.validated() }.isFailure
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
                        0 -> Home(state, hold, connect = { if (needsConfiguration) configurationAlert = true else connect() }, disconnect, autoConnect)
                        1 -> SettingsPage(state, hold, save)
                        2 -> QualityPage(state, share, observeStats)
                    }
                    Spacer(Modifier.height(4.dp))
                }
            }
        }
        if (configurationAlert) AlertDialog(onDismissRequest = { configurationAlert = false },
            title = { Text("尚未配置 VPN") },
            text = { Text("请先在「设置」中填写服务器地址、用户名和密码并保存，再连接 VPN。") },
            confirmButton = { TextButton(onClick = { configurationAlert = false; tab = 1 }) { Text("去设置") } },
            dismissButton = { TextButton(onClick = { configurationAlert = false }) { Text("取消") } })
    }
}
@Composable private fun Panel(content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
    }
}
@Composable private fun Title(text: String) = Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
@Composable private fun Detail(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        SelectionContainer(Modifier.weight(1f)) { Text(value, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.End, style = MaterialTheme.typography.bodyMedium) }
    }
}
@Composable private fun Note(text: String) { Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall) }
/** iOS shows notices as an info label with a footnote underneath. */
@Composable private fun Notice(title: String, detail: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Info, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(6.dp))
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
        }
        Note(detail)
    }
}
@Composable private fun Message(text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(Icons.Outlined.Info, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(6.dp))
        SelectionContainer { Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}
@Composable private fun Home(state: ViewState, hold: Boolean, connect: () -> Unit, disconnect: () -> Unit, autoConnect: (Boolean) -> Unit) {
    val snapshot = state.snapshot
    val appearance = Appearance.of(snapshot.phase)
    val active = snapshot.phase.active
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.Language, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(6.dp)); Note("工作网络"); Spacer(Modifier.weight(1f)); Note("Android 验证版 ${BuildConfig.VERSION_NAME}")
    }
    Panel {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Orbit(appearance)
            Text(snapshot.phase.title, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, color = appearance.color, textAlign = TextAlign.Center)
            Text(if (active) "连接状态和恢复记录可在连接质量页查看。" else "连接公司网络，安全访问工作资源。", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            val idle = appearance == Appearance.IDLE
            Button(onClick = if (active) disconnect else connect, enabled = !hold && snapshot.phase != Phase.STOPPING,
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = if (idle) MaterialTheme.colorScheme.primary else appearance.color,
                    contentColor = if (idle) MaterialTheme.colorScheme.onPrimary else Color.White)) {
                if (appearance.progress) { CircularProgressIndicator(Modifier.size(16.dp), color = LocalContentColor.current, strokeWidth = 2.dp); Spacer(Modifier.width(10.dp)) }
                Text(if (active) "断开" else "连接 VPN", style = MaterialTheme.typography.titleMedium)
            }
        }
    }
    Panel {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("自动连接", modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            Switch(state.profile.autoConnect, autoConnect, enabled = state.hasPassword && !hold && snapshot.phase != Phase.STOPPING, modifier = Modifier.semantics { contentDescription = "自动连接" })
        }
        Note(state.autoConnectDescription)
    }
    Panel { Detail("服务器", state.profile.server); Detail("隧道地址", if (active) snapshot.address else "—") }
    val blocked = state.blocked
    when {
        snapshot.message != null -> Message(snapshot.message)
        blocked != null && !active -> Message("自动连接已暂停：${blocked.message}")
    }
    Note("首次连接会请求系统 VPN 授权。连接期间显示系统 VPN 标识和状态通知。")
}
@Composable private fun Orbit(appearance: Appearance) {
    val context = LocalContext.current
    // "Remove animations" sets the animator scale to zero; keep the arc still, like iOS with Reduce Motion.
    val reduceMotion = remember { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
    val rotation = if (appearance.progress && !reduceMotion) {
        val transition = rememberInfiniteTransition(label = "连接进度")
        transition.animateFloat(0f, 360f, infiniteRepeatable(tween(2_000, easing = LinearEasing)), label = "圆弧旋转").value
    } else 0f
    val color = appearance.color
    val glow = if (isSystemInDarkTheme()) color.copy(alpha = .22f) else Mint
    Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(160.dp)) {
            val middle = Offset(size.width / 2, size.height / 2)
            fun ring(diameter: Float, tint: Color, stroke: Stroke) = drawCircle(tint, diameter / 2, middle, style = stroke)
            val orbit = 125.dp.toPx()
            when (appearance) {
                Appearance.CONNECTED -> {
                    drawCircle(Brush.radialGradient(0.4f to glow, 1f to Color.Transparent, center = middle, radius = 80.dp.toPx()), 80.dp.toPx(), middle)
                    ring(115.dp.toPx(), color.copy(alpha = .14f), Stroke(1.dp.toPx()))
                    ring(145.dp.toPx(), color.copy(alpha = .07f), Stroke(1.dp.toPx()))
                }
                Appearance.CONNECTING, Appearance.DISCONNECTING -> ring(orbit, color.copy(alpha = .12f), Stroke(2.5.dp.toPx()))
                Appearance.IDLE -> ring(orbit, color.copy(alpha = .2f), Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 6.dp.toPx()))))
            }
            if (appearance.progress) {
                val inset = (size.width - orbit) / 2
                drawArc(color, -90f + rotation, 83f, false, topLeft = Offset(inset, inset), size = Size(orbit, orbit), style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round))
            }
            val core = 91.dp.toPx()
            drawCircle(if (appearance == Appearance.CONNECTED) color else color.copy(alpha = .08f), core / 2, middle)
            ring(core, color.copy(alpha = .1f), Stroke(1.dp.toPx()))
        }
        Icon(appearance.icon, contentDescription = null, modifier = Modifier.size(38.dp), tint = if (appearance == Appearance.CONNECTED) Color.White else color)
    }
}
@Composable private fun SettingsPage(state: ViewState, hold: Boolean, save: (Profile, String) -> Unit) {
    // Keyed on the saved values: a save replaces the draft, while tab switches and rotation keep it.
    var server by rememberSaveable(state.profile.server) { mutableStateOf(state.profile.server) }
    var username by rememberSaveable(state.profile.username) { mutableStateOf(state.profile.username) }
    // Deliberately not rememberSaveable: passwords never enter saved state or Android backup.
    var password by remember { mutableStateOf("") }
    val focusManager = LocalFocusManager.current
    var passwordFocused by remember { mutableStateOf(false) }
    val showSavedPassword = state.hasPassword && password.isEmpty() && !passwordFocused
    val enabled = !state.snapshot.phase.active && !hold
    Title("VPN 配置")
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
@Composable private fun RowScope.Metric(title: String, count: Int, color: Color) {
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Note(title)
        Text("$count", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = color)
    }
}
@Composable private fun QualityPage(state: ViewState, share: () -> Unit, observeStats: () -> AutoCloseable) {
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    val lifecycle = LocalLifecycleOwner.current
    val currentObserveStats by rememberUpdatedState(observeStats)
    LaunchedEffect(lifecycle) {
        lifecycle.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            val subscription = currentObserveStats()
            try {
                while (true) { now = SystemClock.elapsedRealtime(); delay(1_000) }
            } finally { subscription.close() }
        }
    }
    val summary = Quality.summarize(state.events, System.currentTimeMillis(), state.incomplete)
    val snapshot = state.snapshot
    val connected = snapshot.phase == Phase.CONNECTED
    val elapsed = snapshot.connectedAt?.takeIf { connected }?.let { (now - it).coerceAtLeast(0) }
    val clock = remember { SimpleDateFormat("HH:mm:ss", Locale.ROOT) }
    Panel {
        Title("当前连接")
        Detail("状态", snapshot.phase.title)
        Detail("连接时长", elapsed?.let(Quality::duration) ?: "—")
        Detail("传输方式", if (connected) snapshot.transport else "—")
        Detail("自动恢复", state.recoveryStatus)
    }
    Panel {
        Title("最近 24 小时 · 此设备")
        if (state.events.isEmpty()) {
            Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Outlined.Insights, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("暂无连接记录", style = MaterialTheme.typography.titleMedium)
                Note("连接 VPN 后自动记录，无需保持 App 打开。")
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Metric("完成恢复", summary.completed, MaterialTheme.colorScheme.onSurface)
                Metric("成功", summary.successes, MaterialTheme.colorScheme.primary)
                Metric("失败", summary.failures, if (summary.failures > 0) Warning else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (snapshot.phase == Phase.RECOVERING) Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Autorenew, null, Modifier.size(18.dp), tint = Appearance.CONNECTING.color)
                Spacer(Modifier.width(6.dp)); Text("正在恢复连接", style = MaterialTheme.typography.bodyMedium, color = Appearance.CONNECTING.color)
            }
            summary.last?.let { last ->
                Detail("最近一次", if (last.kind == EventKind.RECOVERY_OK) "恢复成功" else "恢复失败")
                Detail("恢复耗时", summary.lastDurationMs?.let(Quality::duration) ?: "未完整记录")
                Detail("记录时间", clock.format(Date(last.wall)))
            }
        }
        Note("按结束时间统计，取消不计为失败。恢复耗时包含已观测到的断网等待；起点缺失时不估算。")
    }
    Panel {
        Title("连接提示")
        if (state.incomplete) Notice("部分历史记录缺失", "这里只统计仍保留的记录。")
        val blocked = state.blocked
        val message = snapshot.message
        when {
            blocked != null -> Notice("自动恢复已暂停", blocked.message)
            snapshot.phase == Phase.FAILED && message != null -> Notice("连接已中断", message)
            snapshot.phase == Phase.RECOVERING && state.events.lastOrNull()?.kind == EventKind.OFFLINE ->
                Notice("等待网络恢复", "请确认 Wi-Fi 或蜂窝网络可用；恢复后会继续尝试连接。")
            snapshot.phase == Phase.RECOVERING && state.events.lastOrNull()?.kind == EventKind.COOLDOWN ->
                Notice("等待下一次自动重试", "短时间内连接尝试过多，正在等待重试额度恢复；无需反复点击连接。")
            snapshot.phase == Phase.RECOVERING -> Notice("正在恢复连接", "正在尝试恢复，可在详细事件中查看进度。")
            state.armed && !snapshot.phase.active -> Notice("等待系统恢复连接", "网络恢复后会自动尝试连接，可查看详细事件了解进度。")
            else -> Note(if (state.events.isEmpty()) "有连接记录后显示异常及处理建议。" else "暂无需要处理的异常。")
        }
    }
    var expanded by rememberSaveable { mutableStateOf(false) }
    Panel {
        TextButton(onClick = { expanded = !expanded }, modifier = Modifier.fillMaxWidth()) {
            Text(if (expanded) "收起详细事件" else "查看详细事件"); Spacer(Modifier.weight(1f)); Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
        }
        if (expanded) {
            Detail("最近采样 · 上行 / 下行包", snapshot.statsAt?.let { "${snapshot.txPackets} / ${snapshot.rxPackets}" } ?: "尚未采样")
            snapshot.statsAt?.let { Note("采样时间：${clock.format(Date(it))}；缓存样本不代表最终流量。") }
            if (state.events.isEmpty()) Note("暂无连接事件。")
            val date = remember { SimpleDateFormat("MM-dd HH:mm:ss", Locale.ROOT) }
            state.events.takeLast(64).asReversed().forEach { Note("${date.format(Date(it.wall))}  ${it.kind.label}") }
        }
        OutlinedButton(onClick = share, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Icon(Icons.Outlined.Share, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("分享诊断报告") }
        Note("这里只反映隧道连接与恢复，不代表内网业务可用性；包计数不等于业务成功。")
    }
}

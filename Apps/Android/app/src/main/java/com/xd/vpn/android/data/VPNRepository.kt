package com.xd.vpn.android.data

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import com.xd.vpn.android.core.*
import com.xd.vpn.android.BuildConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

data class ViewState(val profile: Profile, val hasPassword: Boolean, val snapshot: Snapshot = Snapshot(), val armed: Boolean = false,
    val blocked: Failure? = null, val busy: Boolean = false, val events: List<QualityEvent> = emptyList(), val incomplete: Boolean = false) {
    /** Same wording as the "自动恢复" row on the iOS quality page. */
    val recoveryStatus: String get() = when {
        blocked != null -> "已暂停，需处理异常"
        !profile.autoConnect -> "已关闭"
        armed && snapshot.phase.active -> "已启用"
        armed -> "等待系统恢复连接"
        else -> "下次手动连接后启用"
    }
    /** Mirrors the footnote under the iOS "自动连接" toggle. */
    val autoConnectDescription: String get() = when {
        !hasPassword -> "先在设置中保存账号，即可开启自动连接。"
        !profile.autoConnect -> "开启后保存自动连接偏好；仍需点击「连接 VPN」开始连接。"
        armed && snapshot.phase.active -> "本轮连接允许自动恢复；手动断开后保持断开。"
        else -> "下次连接后启用自动恢复；手动断开后保持断开。"
    }
}
class VPNRepository(context: Context) {
    private val store = SecureStore(context)
    private val boot = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
    private var gate = store.loadGate()
    private val history = store.loadHistory()
    // History is diagnostics, not a gate: persist it off the calling thread, in order, and only ever widen gaps.
    private val historyWriter = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "XDVPN-history") }
    private var historyDamaged = false // historyWriter thread only
    private var pending: String? = history.first.lastOrNull { it.kind == EventKind.RECOVERY_START }?.recovery?.takeIf { id ->
        history.first.none { it.recovery == id && it.kind in setOf(EventKind.RECOVERY_OK, EventKind.RECOVERY_FAILED, EventKind.CANCEL) }
    }
    private val mutable = MutableStateFlow(ViewState(store.loadProfile(), store.hasPassword(), armed = gate.armed, blocked = gate.blocked,
        events = history.first, incomplete = history.second || store.damaged))
    val state = mutable.asStateFlow()
    @Synchronized fun save(profile: Profile, password: ByteArray?) {
        check(!mutable.value.snapshot.phase.active)
        val valid = profile.validated()
        persistGate(gate.stop())
        store.save(valid, password)
        mutable.value = mutable.value.copy(profile = valid, hasPassword = true, snapshot = Snapshot(message = "配置已保存，点击连接开始验证。"))
    }
    @Synchronized fun setAutoConnect(enabled: Boolean) {
        val current = mutable.value
        check(current.hasPassword)
        val profile = current.profile.copy(autoConnect = enabled)
        store.save(profile, null)
        mutable.value = current.copy(profile = profile)
    }
    /** UI work in flight, such as saving; connect and the switch stay on hold while true. */
    @Synchronized fun busy(value: Boolean) { mutable.value = mutable.value.copy(busy = value) }
    private fun persistGate(value: RecoveryPolicy) {
        if (value.armed) store.saveGate(value) else store.disarmGate(value)
        gate = value; mutable.value = mutable.value.copy(armed = gate.armed, blocked = gate.blocked)
    }
    @Synchronized fun manualStart() {
        mutable.value.profile.validated(); check(mutable.value.hasPassword)
        persistGate(gate.manualStart())
        pending?.let { record(EventKind.CANCEL, it) }; pending = null
        mutable.value = mutable.value.copy(snapshot = Snapshot(phase = Phase.CONNECTING))
        record(EventKind.START)
    }
    @Synchronized fun mayResume(): Boolean = gate.canResume(mutable.value.profile.autoConnect)
    @Synchronized fun beginAttempt(requireAutomatic: Boolean = false): Failure? {
        if (requireAutomatic && !mayResume()) return Failure.NETWORK
        val next = gate.begin(System.currentTimeMillis())
        persistGate(next)
        return next.blocked
    }
    /** Milliseconds the service must wait before the next cold attempt; 0 when it may proceed. */
    @Synchronized fun cooldown(): Long = gate.cooldown(System.currentTimeMillis())
    @Synchronized fun cooling(milliseconds: Long) {
        record(EventKind.COOLDOWN)
        update { it.copy(phase = Phase.RECOVERING, message = "连接重试过于频繁，等待约 ${(milliseconds + 999) / 1000} 秒后自动重试。") }
    }
    @Synchronized fun stopIntent() {
        // Change memory even when storage fails; never submit credentials after a local stop.
        val next = gate.stop(); gate = next
        try { persistGate(next) } catch (_: Exception) { mutable.value = mutable.value.copy(armed = false, incomplete = true) }
        record(EventKind.CANCEL, pending); pending = null
    }
    @Synchronized fun fail(failure: Failure) {
        finishRecovery(false)
        if (failure.blocks) persistGate(gate.block(failure)) else persistGate(gate.stop())
        mutable.value = mutable.value.copy(snapshot = mutable.value.snapshot.copy(phase = Phase.FAILED, message = failure.message, connectedAt = null, address = "—", transport = "—"))
        record(EventKind.PAUSED)
    }
    @Synchronized fun password(): ByteArray = store.password()
    @Synchronized fun update(transform: (Snapshot) -> Snapshot) { mutable.value = mutable.value.copy(snapshot = transform(mutable.value.snapshot)) }
    @Synchronized fun stopped() { mutable.value = mutable.value.copy(snapshot = Snapshot()) }
    @Synchronized fun message(text: String) = update { it.copy(message = text) }
    @Synchronized fun recovering(unknownStart: Boolean = false) {
        if (pending == null) {
            pending = UUID.randomUUID().toString()
            record(EventKind.RECOVERY_START, pending, if (unknownStart) -1 else SystemClock.elapsedRealtime())
        }
        update { it.copy(phase = Phase.RECOVERING) }
    }
    @Synchronized fun connected() {
        finishRecovery(true)
        update { it.copy(phase = Phase.CONNECTED, connectedAt = it.connectedAt ?: SystemClock.elapsedRealtime(), message = null) }
        record(EventKind.CONNECTED)
    }
    private fun finishRecovery(success: Boolean) {
        pending?.let { record(if (success) EventKind.RECOVERY_OK else EventKind.RECOVERY_FAILED, it) }
        pending = null
    }
    @Synchronized fun record(kind: EventKind, recovery: String? = null, elapsed: Long = SystemClock.elapsedRealtime()) {
        val current = mutable.value
        if (current.events.lastOrNull()?.kind == kind && kind in setOf(EventKind.OFFLINE, EventKind.TLS, EventKind.DTLS, EventKind.COOLDOWN)) return
        val full = current.events + QualityEvent(kind, System.currentTimeMillis(), elapsed, boot, recovery)
        val incomplete = current.incomplete || full.size > 2048
        val bounded = full.takeLast(2048)
        mutable.value = current.copy(events = bounded, incomplete = incomplete)
        historyWriter.execute {
            try { store.saveHistory(bounded, incomplete || historyDamaged) }
            catch (_: Exception) { historyDamaged = true; synchronized(this) { mutable.value = mutable.value.copy(incomplete = true) } }
        }
    }
    @Synchronized fun report(): String {
        val s = mutable.value; val summary = Quality.summarize(s.events, System.currentTimeMillis(), s.incomplete)
        val date = SimpleDateFormat("MM-dd HH:mm:ss", Locale.ROOT)
        return buildString {
            appendLine("XD VPN Android ${BuildConfig.VERSION_NAME} 连接诊断")
            appendLine("状态：${s.snapshot.phase.title}；传输：${s.snapshot.transport}")
            appendLine("最近 24 小时恢复：成功 ${summary.successes} 次 / 失败 ${summary.failures} 次")
            appendLine("最近恢复耗时：${summary.lastDurationMs?.let(Quality::duration) ?: if (summary.last == null) "暂无记录" else "未完整记录"}")
            appendLine("自动恢复：${s.recoveryStatus}")
            appendLine("上行包 ${s.snapshot.txPackets} / 下行包 ${s.snapshot.rxPackets}")
            if (summary.incomplete) appendLine("历史记录不完整")
            appendLine("以下最多 64 条；不包含服务器、用户名、密码、Cookie 或原始引擎日志。")
            s.events.takeLast(64).forEach { appendLine("${date.format(Date(it.wall))} ${it.kind.label}") }
        }
    }
}

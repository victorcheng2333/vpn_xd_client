package com.xd.vpn.android.core

enum class EventKind(val label: String) {
    START("手动连接"), AUTHENTICATING("正在认证"), ESTABLISHING("建立隧道"), CONNECTED("隧道已连接"),
    RECOVERY_START("开始恢复"), RECOVERY_OK("恢复成功"), RECOVERY_FAILED("恢复失败"), CANCEL("手动断开或系统撤销"),
    OFFLINE("等待物理网络"), TLS("使用 TLS"), DTLS("使用 DTLS"), PAUSED("自动恢复已暂停"),
    PROCESS_RESTART("服务进程重新启动"), STORAGE_ERROR("历史记录不完整")
}
data class QualityEvent(val kind: EventKind, val wall: Long, val elapsed: Long, val boot: Int, val recovery: String? = null)
data class QualitySummary(val successes: Int, val failures: Int, val lastDurationMs: Long?, val incomplete: Boolean)
object Quality {
    fun summarize(events: List<QualityEvent>, now: Long, incomplete: Boolean): QualitySummary {
        val starts = events.filter { it.kind == EventKind.RECOVERY_START }.associateBy { it.recovery }
        val completed = events.filter { it.wall <= now && now - it.wall <= 86_400_000 && it.kind in setOf(EventKind.RECOVERY_OK, EventKind.RECOVERY_FAILED) && it.recovery != null }.distinctBy { it.recovery }
        val last = completed.lastOrNull()
        val start = last?.let { starts[it.recovery] }
        val duration = if (last != null && start != null && last.boot >= 0 && last.boot == start.boot && start.elapsed >= 0 && last.elapsed >= start.elapsed) last.elapsed - start.elapsed else null
        return QualitySummary(completed.count { it.kind == EventKind.RECOVERY_OK }, completed.count { it.kind == EventKind.RECOVERY_FAILED }, duration,
            incomplete || completed.any { starts[it.recovery] == null })
    }
}
data class Snapshot(val phase: Phase = Phase.IDLE, val address: String = "—", val transport: String = "—", val connectedAt: Long? = null,
    val txPackets: Long = 0, val rxPackets: Long = 0, val txBytes: Long = 0, val rxBytes: Long = 0, val message: String? = null)

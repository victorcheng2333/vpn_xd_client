package com.xd.vpn.android.core

enum class EventKind(val label: String) {
    START("手动连接"), AUTHENTICATING("正在认证"), ESTABLISHING("建立隧道"), CONNECTED("隧道已连接"),
    RECOVERY_START("开始恢复"), RECOVERY_OK("恢复成功"), RECOVERY_FAILED("恢复失败"), CANCEL("手动断开或系统撤销"),
    OFFLINE("等待物理网络"), TLS("使用 TLS"), DTLS("使用 DTLS"), PAUSED("自动恢复已暂停"),
    AUTH_SERVER_ERROR("网关返回认证错误"), AUTH_REPEAT_PASSWORD("密码提交后网关再次返回表单，已暂停"),
    AUTH_FORM_LIMIT("认证表单次数超限"), AUTH_GROUP_REQUIRED("认证组无有效默认选项"),
    AUTH_UNSUPPORTED_TEXT("网关要求暂不支持的文本字段"), AUTH_UNSUPPORTED_PASSWORD("网关要求暂不支持的密码或多因素字段"),
    AUTH_UNSUPPORTED_SELECT("网关要求暂不支持的选择字段"), AUTH_UNSUPPORTED_FIELD("网关要求暂不支持的认证字段"),
    AUTH_GATEWAY_REJECTED("网关拒绝认证请求"),
    PROCESS_RESTART("服务进程重新启动"), STORAGE_ERROR("历史记录不完整")
}
data class QualityEvent(val kind: EventKind, val wall: Long, val elapsed: Long, val boot: Int, val recovery: String? = null)
/** `last` is the newest completed recovery in the window; `lastDurationMs` is null when its start was not observed on this boot. */
data class QualitySummary(val successes: Int, val failures: Int, val lastDurationMs: Long?, val incomplete: Boolean, val last: QualityEvent? = null) {
    val completed get() = successes + failures
}
object Quality {
    fun summarize(events: List<QualityEvent>, now: Long, incomplete: Boolean): QualitySummary {
        val starts = events.filter { it.kind == EventKind.RECOVERY_START }.associateBy { it.recovery }
        val completed = events.filter { it.wall <= now && now - it.wall <= 86_400_000 && it.kind in setOf(EventKind.RECOVERY_OK, EventKind.RECOVERY_FAILED) && it.recovery != null }.distinctBy { it.recovery }
        val last = completed.lastOrNull()
        val start = last?.let { starts[it.recovery] }
        val duration = if (last != null && start != null && last.boot >= 0 && last.boot == start.boot && start.elapsed >= 0 && last.elapsed >= start.elapsed) last.elapsed - start.elapsed else null
        return QualitySummary(completed.count { it.kind == EventKind.RECOVERY_OK }, completed.count { it.kind == EventKind.RECOVERY_FAILED }, duration,
            incomplete || completed.any { starts[it.recovery] == null }, last)
    }
    /** Same wording as the iOS quality page. */
    fun duration(milliseconds: Long): String {
        val seconds = (milliseconds / 1000).coerceAtLeast(0)
        return when {
            seconds < 1 -> "不到 1 秒"
            seconds < 60 -> "$seconds 秒"
            seconds < 3600 -> "${seconds / 60} 分 ${seconds % 60} 秒"
            else -> "${seconds / 3600} 小时 ${seconds % 3600 / 60} 分"
        }
    }
}
data class Snapshot(val phase: Phase = Phase.IDLE, val address: String = "—", val transport: String = "—", val connectedAt: Long? = null,
    val txPackets: Long = 0, val rxPackets: Long = 0, val txBytes: Long = 0, val rxBytes: Long = 0, val message: String? = null)

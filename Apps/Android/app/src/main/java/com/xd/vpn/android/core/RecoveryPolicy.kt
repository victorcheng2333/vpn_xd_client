package com.xd.vpn.android.core

/** Persist begin() before any cold credential submission. Successful connections do not erase budget. */
data class RecoveryPolicy(val armed: Boolean = false, val blocked: Failure? = null, val attempts: List<Long> = emptyList()) {
    fun manualStart() = RecoveryPolicy(armed = true)
    fun stop() = copy(armed = false)
    fun block(failure: Failure) = copy(armed = false, blocked = failure)
    fun canResume(autoConnect: Boolean) = armed && autoConnect && blocked == null
    /**
     * Milliseconds to wait before the next cold attempt; 0 when one may start now. Rate limiting is temporary:
     * it never becomes a persisted block and never disarms recovery (same as iOS RecoveryPolicy.Cooldown).
     * Future timestamps after a clock rollback keep counting (fail closed); each wait is capped to one window
     * so the caller re-evaluates instead of sleeping on a bad clock.
     */
    fun cooldown(now: Long): Long {
        val recent = attempts.filter { now - it < WINDOW }
        return if (recent.size >= LIMIT) (recent.min() + WINDOW - now).coerceIn(1L, WINDOW) else 0L
    }
    fun begin(now: Long): RecoveryPolicy {
        check(armed && blocked == null) { "恢复未获授权" }
        check(cooldown(now) == 0L) { "冷认证额度冷却中" }
        return copy(attempts = attempts.filter { now - it < WINDOW } + now)
    }
    companion object {
        const val WINDOW = 300_000L
        const val LIMIT = 3
        fun classify(result: Int, authenticated: Boolean, authRejected: Boolean, certificateRejected: Boolean, settingsRejected: Boolean): Failure = when {
            certificateRejected -> Failure.CERTIFICATE
            authRejected -> Failure.AUTH
            settingsRejected -> Failure.SETTINGS
            result == -1 && authenticated -> Failure.SESSION // -EPERM after cookie = expired CONNECT session
            result == -1 -> Failure.AUTH
            else -> Failure.NETWORK
        }
    }
}

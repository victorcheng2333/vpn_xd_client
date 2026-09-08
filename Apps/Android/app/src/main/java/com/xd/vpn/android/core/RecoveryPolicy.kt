package com.xd.vpn.android.core

/** Persist begin() before any cold credential submission. Successful connections do not erase budget. */
data class RecoveryPolicy(val armed: Boolean = false, val blocked: Failure? = null, val attempts: List<Long> = emptyList()) {
    fun manualStart() = RecoveryPolicy(armed = true)
    fun stop() = copy(armed = false)
    fun block(failure: Failure) = copy(armed = false, blocked = failure)
    fun canResume(autoConnect: Boolean) = armed && autoConnect && blocked == null
    fun begin(now: Long): RecoveryPolicy {
        check(armed && blocked == null) { "恢复未获授权" }
        // Future timestamps are retained when the wall clock moves backwards: fail closed.
        val recent = attempts.filter { now - it < 300_000L }
        return if (recent.size >= 3) block(Failure.BUDGET) else copy(attempts = recent + now)
    }
    companion object {
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

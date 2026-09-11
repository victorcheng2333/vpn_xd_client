package com.xd.vpn.android.core

/** Main-thread confined; one pending timer only, and no timer while observation is inactive. */
class StatsPoller<T : Any>(
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val request: (T) -> Unit,
) {
    private var source: T? = null
    private var pending: Runnable? = null
    private var closed = false

    fun update(observed: Boolean, available: T?) {
        if (closed) return
        val next = available.takeIf { observed }
        if (source === next) return
        pending?.let(cancel)
        pending = null
        source = next
        if (next == null) return
        val tick = object : Runnable {
            override fun run() {
                // A callback already dequeued before cancellation cannot restart the old schedule.
                if (pending !== this) return
                request(next)
                if (pending === this) schedule(this, INTERVAL_MS)
            }
        }
        pending = tick
        schedule(tick, 0) // The first observation and each replacement engine request a fresh sample.
    }

    fun close() {
        update(false, null)
        closed = true
    }

    companion object { const val INTERVAL_MS = 5_000L }
}

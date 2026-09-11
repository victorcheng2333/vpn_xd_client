package com.xd.vpn.android.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Process-local observation only: subscribing never starts a service or arms recovery. */
class StatsDemand {
    private val observers = mutableSetOf<Any>()
    private val mutable = MutableStateFlow(false)
    val active = mutable.asStateFlow()

    @Synchronized fun acquire(): AutoCloseable {
        val token = Any()
        observers.add(token)
        mutable.value = true
        // Tokens retain neither a UI callback nor an Activity. Overlapping Activities during rotation
        // may subscribe independently, and repeated disposal must not release another observer.
        return AutoCloseable { release(token) }
    }

    @Synchronized private fun release(token: Any) {
        observers.remove(token)
        mutable.value = observers.isNotEmpty()
    }
}

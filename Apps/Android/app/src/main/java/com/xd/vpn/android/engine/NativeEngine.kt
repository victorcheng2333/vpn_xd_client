package com.xd.vpn.android.engine

import com.xd.vpn.android.core.Profile

interface NativeCallbacks {
    fun protectSocket(fd: Int): Boolean
    fun verifyCertificate(chain: Array<ByteArray>, hostname: String): Boolean
    fun configureTunnel(fields: Array<String>, dns: Array<String>, includes: Array<String>, excludes: Array<String>, domains: Array<String>, mtu: Int): Int
    fun onEvent(code: Int)
    fun onStats(txPackets: Long, rxPackets: Long, txBytes: Long, rxBytes: Long)
}
/** start() is called once on the service worker; controls never touch vpninfo. */
class NativeEngine(profile: Profile, password: ByteArray) {
    private var handle: Long
    private var started = false
    init { handle = create(profile.server.toByteArray(), profile.username.toByteArray(), password); check(handle != 0L) }
    fun start(callbacks: NativeCallbacks): IntArray {
        val current = synchronized(this) { check(!started && handle != 0L); started = true; handle }
        return try { run(current, callbacks) } finally { synchronized(this) { destroy(handle); handle = 0 } }
    }
    @Synchronized fun cancel() { if (handle != 0L) control(handle, 0, 0) }
    @Synchronized fun network(value: Long) { if (handle != 0L) control(handle, 1, value) }
    @Synchronized fun stats() { if (handle != 0L) control(handle, 2, 0) }
    @Synchronized fun refreshNetwork(value: Long) { if (handle != 0L) control(handle, 3, value) }
    private external fun create(server: ByteArray, username: ByteArray, password: ByteArray): Long
    private external fun run(handle: Long, callbacks: NativeCallbacks): IntArray
    private external fun control(handle: Long, action: Int, network: Long)
    private external fun destroy(handle: Long)
    companion object { init { System.loadLibrary("xdvpn") } }
}

package com.xd.vpn.android.service

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.*
import android.os.*
import androidx.core.app.NotificationCompat
import com.xd.vpn.android.*
import com.xd.vpn.android.core.*
import com.xd.vpn.android.engine.*
import java.net.InetAddress
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class XDVpnService : VpnService(), NativeCallbacks {
    private val repo get() = (application as VPNApplication).repository
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "XDVPN-engine") }
    private val cancelled = AtomicBoolean(false)
    private val networkLock = Object()
    private val tunLock = Any()
    private val networks = mutableMapOf<Network, NetworkCapabilities>() // main looper only
    private val addresses = mutableMapOf<Network, Set<InetAddress>>() // main looper only
    @Volatile private var selected: Network? = null
    @Volatile private var engine: NativeEngine? = null
    private var tunnel: ParcelFileDescriptor? = null
    private var appliedPlan: NetworkPlan? = null // guarded by tunLock
    private var running = false
    private var registered = false
    private var destroyed = false
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    private val notifications by lazy { getSystemService(NotificationManager::class.java) }
    private var refreshRequired = false
    private val chooseNetwork = Runnable { val force = refreshRequired; refreshRequired = false; selectNetwork(force) }
    private val statsTick = object : Runnable {
        override fun run() { if (running && !cancelled.get()) { engine?.stats(); main.postDelayed(this, 5_000) } }
    }
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            networks[network] = capabilities
            main.removeCallbacks(chooseNetwork); main.postDelayed(chooseNetwork, 300)
        }
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
            val current = properties.linkAddresses.map { it.address }.toSet()
            val previous = addresses.put(network, current)
            // Only a local address change strands the gateway sockets. DNS, route or MTU churn on the
            // same link must not force a CSTP reconnect; the first delivery describes the link as selected.
            if (network == selected && previous != null && previous != current) {
                refreshRequired = true
                main.removeCallbacks(chooseNetwork); main.postDelayed(chooseNetwork, 300)
            }
        }
        override fun onLost(network: Network) {
            networks.remove(network); addresses.remove(network)
            if (network == selected) selectNetwork(false)
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            STOP -> { stopByUser(); return START_NOT_STICKY }
            PREFERENCE -> { if (!running) stopSelf(); return restartMode() }
            CONNECT, null -> Unit
            else -> { if (!running) stopSelf(); return START_NOT_STICKY }
        }
        if (running) return restartMode()
        val manual = intent?.action == CONNECT
        if ((!manual && !repo.mayResume()) || prepare(this) != null) { stopSelf(); return START_NOT_STICKY }
        try {
            showForeground()
            cancelled.set(false); running = true
            val request = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build()
            connectivity.registerNetworkCallback(request, callback, main); registered = true
            main.post(statsTick)
            worker.execute { runSession(manual) }
        } catch (_: Exception) {
            cancelled.set(true)
            runCatching { repo.fail(Failure.STORAGE) }
            cleanup()
        }
        return restartMode()
    }
    private fun restartMode() = if (running && repo.state.value.profile.autoConnect) START_STICKY else START_NOT_STICKY
    private fun runSession(manual: Boolean) {
        var acquired = false
        var failure: Failure? = null
        try {
            // Also serializes two service instances while a destroyed instance drains DNS/native cleanup.
            while (!cancelled.get() && !acquired) acquired = sessionOwner.tryAcquire(200, TimeUnit.MILLISECONDS)
            if (!acquired || cancelled.get()) return
            if (manual) repo.manualStart() else { repo.record(EventKind.PROCESS_RESTART); repo.recovering(unknownStart = true) }
            var requireAutomatic = !manual
            while (!cancelled.get()) {
                if (!awaitNetwork()) break
                if (requireAutomatic && !repo.mayResume()) { failure = Failure.NETWORK; break }
                if (!awaitCooldown()) break
                failure = repo.beginAttempt(requireAutomatic)
                requireAutomatic = true
                if (failure != null) break
                val password = repo.password()
                val current = try { NativeEngine(repo.state.value.profile, password) } finally { password.fill(0) }
                // Publish under the same monitor used by stop/network, so cancellation cannot miss a new engine.
                synchronized(networkLock) {
                    engine = current
                    current.network(selected?.networkHandle ?: 0)
                    if (cancelled.get()) current.cancel()
                }
                val result = try { current.start(this) } finally { synchronized(networkLock) { if (engine === current) engine = null } }
                if (cancelled.get()) break
                failure = RecoveryPolicy.classify(result[0], result[1] != 0, result[2] != 0, result[3] != 0, result[4] != 0)
                if (failure.blocks || !repo.mayResume()) break
                repo.recovering()
                // Bound cold authentication frequency even on fast CONNECT-401 responses.
                synchronized(networkLock) { if (!cancelled.get()) networkLock.wait(2_000) }
                failure = null
            }
        } catch (_: Exception) { if (!cancelled.get()) failure = Failure.STORAGE }
        catch (_: LinkageError) { if (!cancelled.get()) failure = Failure.SETTINGS }
        finally {
            val terminal = failure
            if (terminal != null && !cancelled.get()) {
                try { repo.fail(terminal) } catch (_: Exception) { repo.stopIntent(); repo.update { it.copy(phase = Phase.FAILED, message = Failure.STORAGE.message) } }
            }
            val owns = acquired
            main.post {
                cleanup()
                if (cancelled.get() && owns) repo.stopped()
                if (owns) sessionOwner.release()
            }
        }
    }
    private fun awaitNetwork(): Boolean {
        synchronized(networkLock) {
            // The callback delivers existing networks shortly after registration; do not log a spurious offline wait.
            if (selected == null && !cancelled.get()) networkLock.wait(1_500)
            if (selected == null && !cancelled.get()) repo.record(EventKind.OFFLINE)
            while (selected == null && !cancelled.get()) networkLock.wait()
            return !cancelled.get()
        }
    }
    /** The cold-attempt budget is rate limiting, not a failure: wait visibly and let a manual stop interrupt. */
    private fun awaitCooldown(): Boolean {
        synchronized(networkLock) {
            while (!cancelled.get()) {
                val wait = repo.cooldown()
                if (wait == 0L) return true
                repo.cooling(wait)
                networkLock.wait(wait)
            }
            return false
        }
    }
    private fun selectNetwork(force: Boolean) {
        if (!running || cancelled.get()) return
        val next = networks.filterValues { it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) }
            .maxByOrNull { (n, caps) ->
                (if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 100 else 0) +
                    (if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) 30 else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) 20 else 10) +
                    (if (n == selected) 1 else 0)
            }?.key
        val changed = next != selected
        if (!changed && !force) return
        synchronized(networkLock) {
            selected = next
            setUnderlyingNetworks(next?.let { arrayOf(it) } ?: emptyArray())
            if (force && !changed) engine?.refreshNetwork(next?.networkHandle ?: 0) else engine?.network(next?.networkHandle ?: 0)
            networkLock.notifyAll()
        }
        if (repo.state.value.snapshot.phase == Phase.CONNECTED) { repo.recovering(); refreshNotification() }
        if (next == null) repo.record(EventKind.OFFLINE)
    }
    private fun stopByUser() {
        cancelled.set(true)
        repo.stopIntent() // durable intent first, command pipe second
        if (running) { repo.update { it.copy(phase = Phase.STOPPING) }; refreshNotification() }
        synchronized(networkLock) { engine?.cancel(); networkLock.notifyAll() }
        if (!running) { repo.stopped(); cleanup() }
    }
    override fun onRevoke() { main.post { stopByUser() } }
    override fun onDestroy() {
        destroyed = true
        cancelled.set(true)
        synchronized(networkLock) { engine?.cancel(); networkLock.notifyAll() }
        if (registered) { connectivity.unregisterNetworkCallback(callback); registered = false }
        main.removeCallbacks(chooseNetwork); main.removeCallbacks(statsTick)
        worker.shutdown()
        super.onDestroy()
    }
    private fun cleanup() {
        running = false
        main.removeCallbacks(chooseNetwork); main.removeCallbacks(statsTick)
        if (registered) { connectivity.unregisterNetworkCallback(callback); registered = false }
        synchronized(tunLock) { tunnel?.close(); tunnel = null; appliedPlan = null }
        networks.clear(); addresses.clear(); selected = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (!destroyed) stopSelf()
    }
    override fun protectSocket(fd: Int): Boolean = !cancelled.get() && protect(fd)
    override fun verifyCertificate(chain: Array<ByteArray>, hostname: String) = !cancelled.get() && PlatformTrust.verify(chain, hostname)
    override fun configureTunnel(fields: Array<String>, dns: Array<String>, includes: Array<String>, excludes: Array<String>, domains: Array<String>, mtu: Int): Int {
        return try {
            val plan = NetworkPlan.create(fields.toList(), dns.toList(), includes.toList(), excludes.toList(), domains.toList(), mtu)
            synchronized(tunLock) {
                if (cancelled.get()) return -1
                val existing = tunnel
                // Re-establishing identical settings replaces the system VPN interface and resets every app's
                // sockets on each transport reconnect. Hand the worker another descriptor of the live interface instead.
                if (existing != null && plan == appliedPlan) return ParcelFileDescriptor.dup(existing.fileDescriptor).detachFd()
                val builder = Builder().setSession("XD VPN").setMtu(plan.mtu).setBlocking(false)
                    .setConfigureIntent(openAppIntent()).setUnderlyingNetworks(selected?.let { arrayOf(it) } ?: emptyArray())
                if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
                plan.addresses.forEach { builder.addAddress(it.address, it.prefix) }
                plan.routes.forEach { builder.addRoute(it.address, it.prefix) }
                plan.dns.forEach { builder.addDnsServer(it) }
                plan.domains.forEach { builder.addSearchDomain(it) }
                val newTun = builder.establish() ?: return -1
                if (cancelled.get()) { newTun.close(); return -1 }
                val duplicate = try { ParcelFileDescriptor.dup(newTun.fileDescriptor).detachFd() } catch (error: Exception) { newTun.close(); throw error }
                existing?.close(); tunnel = newTun; appliedPlan = plan
                repo.update { it.copy(address = plan.addresses.joinToString(" / ") { address -> address.address }) }
                duplicate // JNI worker closes duplicate; service keeps interface alive across cold recovery.
            }
        } catch (_: Exception) { -1 }
    }
    override fun onEvent(code: Int) {
        if (cancelled.get()) return
        when (val event = NativeEvent.from(code) ?: return) {
            NativeEvent.RECOVERING -> repo.recovering()
            NativeEvent.CONNECTED -> repo.connected()
            NativeEvent.TLS, NativeEvent.DTLS -> { repo.update { it.copy(transport = event.name) }; event.kind?.let(repo::record) }
            else -> event.kind?.let(repo::record)
        }
        main.post { refreshNotification() }
    }
    override fun onStats(txPackets: Long, rxPackets: Long, txBytes: Long, rxBytes: Long) {
        if (!cancelled.get()) repo.update { it.copy(txPackets = txPackets, rxPackets = rxPackets, txBytes = txBytes, rxBytes = rxBytes) }
    }
    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun notification(): Notification = NotificationCompat.Builder(this, CHANNEL)
        .setSmallIcon(R.drawable.ic_shield).setContentTitle("XD VPN")
        .setContentText(repo.state.value.snapshot.phase.title).setContentIntent(openAppIntent()).setOngoing(true).setOnlyAlertOnce(true)
        .addAction(0, "断开", PendingIntent.getService(this, 1, Intent(this, XDVpnService::class.java).setAction(STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        .setCategory(NotificationCompat.CATEGORY_SERVICE).build()
    private fun refreshNotification() { if (running && !cancelled.get()) notifications.notify(NOTIFICATION, notification()) }
    private fun showForeground() {
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "VPN 连接状态", NotificationManager.IMPORTANCE_LOW))
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        else startForeground(NOTIFICATION, notification())
    }
    companion object {
        const val CONNECT = "com.xd.vpn.android.CONNECT"
        const val STOP = "com.xd.vpn.android.STOP"
        const val PREFERENCE = "com.xd.vpn.android.PREFERENCE"
        private const val CHANNEL = "vpn_connection"
        private const val NOTIFICATION = 1
        private val sessionOwner = Semaphore(1)
    }
}

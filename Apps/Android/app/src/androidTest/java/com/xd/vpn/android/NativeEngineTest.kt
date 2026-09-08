package com.xd.vpn.android

import android.content.Context
import android.net.ConnectivityManager
import androidx.test.platform.app.InstrumentationRegistry
import com.xd.vpn.android.core.Profile
import com.xd.vpn.android.engine.*
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.*

/** Local synthetic TLS only. Test-only callback trust is never linked into the application. */
class NativeEngineTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val assetContext get() = InstrumentationRegistry.getInstrumentation().context
    private fun profile(port: Int = 1) = Profile("https://127.0.0.1:$port", "test-only")
    private fun engine(port: Int = 1) = NativeEngine(profile(port), "synthetic-not-a-real-password".toByteArray())
    private fun network() = context.getSystemService(ConnectivityManager::class.java).activeNetwork!!.networkHandle
    private open class Callbacks : NativeCallbacks {
        val certificateCalls = AtomicInteger(0)
        override fun protectSocket(fd: Int) = true
        override fun verifyCertificate(chain: Array<ByteArray>, hostname: String): Boolean { certificateCalls.incrementAndGet(); return PlatformTrust.verify(chain, hostname) }
        override fun configureTunnel(fields: Array<String>, dns: Array<String>, includes: Array<String>, excludes: Array<String>, domains: Array<String>, mtu: Int) = -1
        override fun onEvent(code: Int) {}
        override fun onStats(txPackets: Long, rxPackets: Long, txBytes: Long, rxBytes: Long) {}
    }
    private fun run(engine: NativeEngine, callback: Callbacks): IntArray {
        val executor = Executors.newSingleThreadExecutor()
        return try { executor.submit(Callable { engine.start(callback) }).get(15, TimeUnit.SECONDS) }
        finally { engine.cancel(); executor.shutdown(); assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS)) }
    }
    @Test fun cancelBeforeNativeWorkerStarts() {
        val engine = engine(); engine.cancel()
        val result = run(engine, Callbacks())
        assertEquals(-4, result[0]); assertEquals(0, result[1])
        engine.cancel(); engine.network(0) // no use-after-free after worker destroys handle
    }
    @Test fun cancelWhileWaitingForPhysicalNetwork() {
        val engine = engine(); val executor = Executors.newSingleThreadExecutor()
        try {
            val result = executor.submit(Callable { engine.start(Callbacks()) })
            Thread.sleep(150); engine.cancel()
            assertEquals(-4, result.get(2, TimeUnit.SECONDS)[0])
        } finally { engine.cancel(); executor.shutdownNow() }
    }
    @Test fun systemTrustRejectsUnknownCertificateBeforeAnyHttp() {
        Gateway().use { gateway ->
            val engine = engine(gateway.port); engine.network(network())
            val callbacks = Callbacks(); val result = run(engine, callbacks)
            assertEquals(1, callbacks.certificateCalls.get()); assertEquals(1, result[3]); assertEquals(0, result[1]); assertEquals(0, gateway.requests.get())
        }
    }
    @Test fun ipIdentityRejectsWrongHostBeforeTrustCallback() {
        Gateway(wrongHost = true).use { gateway ->
            val engine = engine(gateway.port); engine.network(network())
            val callbacks = object : Callbacks() { override fun verifyCertificate(chain: Array<ByteArray>, hostname: String): Boolean { certificateCalls.incrementAndGet(); return true } }
            val result = run(engine, callbacks)
            assertEquals(1, result[3]); assertEquals(0, callbacks.certificateCalls.get()); assertEquals(0, gateway.requests.get())
        }
    }
    @Test fun failedSocketProtectionNeverConnects() {
        Gateway().use { gateway ->
            val engine = engine(gateway.port); engine.network(network())
            val result = run(engine, object : Callbacks() { override fun protectSocket(fd: Int) = false })
            assertNotEquals(0, result[0]); assertEquals(0, gateway.connections.get()); assertEquals(0, gateway.requests.get())
        }
    }
    @Test fun connect401IsExpiredCookieNotRejectedPassword() {
        Gateway().use { gateway ->
            val engine = engine(gateway.port); engine.network(network())
            val result = run(engine, object : Callbacks() { override fun verifyCertificate(chain: Array<ByteArray>, hostname: String) = true })
            assertEquals(-1, result[0]); assertEquals(1, result[1]); assertEquals(0, result[2]); assertEquals(0, result[3]); assertTrue(gateway.requests.get() >= 2)
        }
    }
    @Test fun repeatedPasswordFormIsRejectedWithoutResubmission() {
        Gateway(forms = true).use { gateway ->
            val engine = engine(gateway.port); engine.network(network())
            val result = run(engine, object : Callbacks() { override fun verifyCertificate(chain: Array<ByteArray>, hostname: String) = true })
            assertEquals(1, result[2]); assertEquals(0, result[1]); assertEquals(1, gateway.passwordSubmissions.get())
        }
    }
    @Test fun stagedUsernameThenPasswordReachesAuthenticatedState() {
        Gateway(staged = true).use { gateway ->
            val engine = engine(gateway.port); engine.network(network())
            val result = run(engine, object : Callbacks() { override fun verifyCertificate(chain: Array<ByteArray>, hostname: String) = true })
            assertEquals(1, result[1]); assertEquals(0, result[2]); assertEquals(1, gateway.passwordSubmissions.get())
            assertEquals(1, gateway.usernameSubmissions.get())
        }
    }
    inner class Gateway(wrongHost: Boolean = false, private val forms: Boolean = false, private val stall: Boolean = false, private val staged: Boolean = false) : AutoCloseable {
        val connections = AtomicInteger(0); val requests = AtomicInteger(0); val passwordSubmissions = AtomicInteger(0)
        val usernameSubmissions = AtomicInteger(0)
        private val executor = Executors.newCachedThreadPool()
        @Volatile private var closed = false
        private val server: SSLServerSocket
        val port get() = server.localPort
        init {
            val keyText = assetContext.assets.open("test-only-key.pem").bufferedReader().readText().replace(Regex("-----[^-]+-----|\\s"), "")
            val key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(Base64.getDecoder().decode(keyText)))
            val certificate = assetContext.assets.open(if (wrongHost) "wrong-host-cert.pem" else "test-only-cert.pem").use { CertificateFactory.getInstance("X.509").generateCertificate(it) }
            val store = KeyStore.getInstance("PKCS12").apply { load(null); setKeyEntry("test", key, "test".toCharArray(), arrayOf(certificate)) }
            val manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, "test".toCharArray()) }
            val ssl = SSLContext.getInstance("TLS").apply { init(manager.keyManagers, null, null) }
            server = ssl.serverSocketFactory.createServerSocket(0, 8, InetAddress.getByName("127.0.0.1")) as SSLServerSocket
            executor.execute {
                while (!closed) {
                    val socket = try { server.accept() as SSLSocket } catch (_: Exception) { break }
                    connections.incrementAndGet()
                    executor.execute { socket.use { runCatching { handle(it) } } }
                }
            }
        }
        private fun handle(socket: SSLSocket) {
            if (stall) { Thread.sleep(10_000); return }
            socket.soTimeout = 5_000
            val input = socket.inputStream.bufferedReader()
            val output = socket.outputStream
            while (!closed) {
                val first = input.readLine() ?: break
                if (first.isEmpty()) continue
                var length = 0
                while (true) {
                    val line = input.readLine() ?: return
                    if (line.isEmpty()) break
                    if (line.startsWith("Content-Length:", true)) length = line.substringAfter(':').trim().toInt()
                }
                val chars = CharArray(length); var n = 0
                while (n < length) { val got = input.read(chars, n, length - n); if (got < 0) return; n += got }
                if (String(chars).contains("synthetic-not-a-real-password")) passwordSubmissions.incrementAndGet()
                if (String(chars).contains("<username>test-only</username>")) usernameSubmissions.incrementAndGet()
                chars.fill(' ')
                requests.incrementAndGet()
                if (first.startsWith("CONNECT ")) {
                    output.write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray()); output.flush(); return
                }
                val stagedInput = if (usernameSubmissions.get() == 0) "text\" name=\"username" else "password\" name=\"password"
                val body = if (staged && passwordSubmissions.get() == 0) "<config-auth><auth id=\"main\"><form method=\"post\" action=\"/auth\"><input type=\"$stagedInput\"/></form></auth></config-auth>"
                    else if (forms) "<config-auth><auth id=\"main\"><form method=\"post\" action=\"/auth\"><input type=\"text\" name=\"username\"/><input type=\"password\" name=\"password\"/></form></auth></config-auth>"
                    else "<config-auth><auth id=\"success\"/><session-token>test-session-only</session-token></config-auth>"
                val data = body.toByteArray()
                output.write("HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: ${data.size}\r\n\r\n".toByteArray()); output.write(data); output.flush()
            }
        }
        override fun close() { closed = true; server.close(); executor.shutdownNow(); executor.awaitTermination(6, TimeUnit.SECONDS) }
    }
}

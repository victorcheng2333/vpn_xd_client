package com.xd.vpn.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import com.xd.vpn.android.core.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** All files are credential-protected, excluded from backup, and atomically replaced. */
class SecureStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "vpn").apply { mkdirs() }
    private val alias = "com.xd.vpn.android.password.v1"
    var damaged = false; private set
    private fun read(name: String): JSONObject? {
        val file = AtomicFile(File(root, name))
        return try { JSONObject(file.openRead().use { require(it.channel.size() <= 2 * 1024 * 1024); String(it.readBytes(), Charsets.UTF_8) }) }
        catch (_: java.io.FileNotFoundException) { null }
        catch (_: Exception) { damaged = true; null }
    }
    private fun write(name: String, json: JSONObject) {
        val file = AtomicFile(File(root, name)); val stream = file.startWrite()
        try { stream.write(json.toString().toByteArray()); file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream); throw error }
    }
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "Missing device key" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
            generateKey()
        }
    }
    fun loadProfile(): Profile {
        val o = read("profile.json") ?: return Profile()
        return runCatching { Profile(o.getString("server"), o.getString("username"), o.optBoolean("autoConnect")).validated() }
            .getOrElse { damaged = true; Profile() }
    }
    fun hasPassword(): Boolean = read("profile.json")?.optString("secret").orEmpty().isNotEmpty()
    fun save(profile: Profile, password: ByteArray?) {
        val previous = read("profile.json")
        val record = JSONObject().put("server", profile.server).put("username", profile.username).put("autoConnect", profile.autoConnect)
        if (password != null) {
            require(password.size in 1..4096 && !password.contains(0))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key(true)); updateAAD(alias.toByteArray()) }
            record.put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            record.put("secret", Base64.encodeToString(cipher.doFinal(password), Base64.NO_WRAP))
        } else {
            require(previous != null && previous.has("secret"))
            record.put("iv", previous.getString("iv")).put("secret", previous.getString("secret"))
        }
        write("profile.json", record)
    }
    fun password(): ByteArray {
        val o = read("profile.json") ?: error("Missing profile")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, Base64.decode(o.getString("iv"), Base64.NO_WRAP)))
            updateAAD(alias.toByteArray())
        }
        return cipher.doFinal(Base64.decode(o.getString("secret"), Base64.NO_WRAP))
    }
    /** Missing gate is disarmed. If an atomic safety write fails, remove both base/backup gates. */
    fun disarmGate(gate: RecoveryPolicy) {
        require(!gate.armed)
        try { saveGate(gate) } catch (error: Exception) {
            val file = AtomicFile(File(root, "recovery.json"))
            file.delete()
            check(!file.baseFile.exists() && !File(root, "recovery.json.bak").exists()) { "Cannot persist stop intent" }
            throw error
        }
    }
    fun loadGate(): RecoveryPolicy {
        val o = read("recovery.json") ?: return RecoveryPolicy()
        return runCatching {
            val a = o.getJSONArray("attempts")
            require(a.length() <= 3)
            RecoveryPolicy(o.getBoolean("armed"), o.optString("blocked").takeIf { it.isNotEmpty() }?.let(Failure::valueOf), List(a.length()) { a.getLong(it) })
        }.getOrElse { damaged = true; RecoveryPolicy(blocked = Failure.STORAGE) }
    }
    fun saveGate(gate: RecoveryPolicy) = write("recovery.json", JSONObject().put("armed", gate.armed)
        .put("blocked", gate.blocked?.name ?: "").put("attempts", JSONArray(gate.attempts)))
    fun loadHistory(): Pair<List<QualityEvent>, Boolean> {
        val o = read("quality.json") ?: return emptyList<QualityEvent>() to damaged
        return runCatching {
            val a = o.getJSONArray("events"); require(a.length() <= 2048)
            List(a.length()) { i -> val e = a.getJSONObject(i)
                QualityEvent(EventKind.valueOf(e.getString("kind")), e.getLong("wall"), e.getLong("elapsed"), e.getInt("boot"), e.optString("recovery").takeIf { it.isNotEmpty() })
            } to o.optBoolean("incomplete")
        }.getOrElse { damaged = true; emptyList<QualityEvent>() to true }
    }
    fun saveHistory(events: List<QualityEvent>, incomplete: Boolean) = write("quality.json", JSONObject().put("incomplete", incomplete).put("events",
        JSONArray(events.map { JSONObject().put("kind", it.kind.name).put("wall", it.wall).put("elapsed", it.elapsed).put("boot", it.boot).put("recovery", it.recovery ?: "") })))
}

package com.xd.vpn.android.engine

import android.net.http.X509TrustManagerExtensions
import java.io.ByteArrayInputStream
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

object PlatformTrust {
    private val trust by lazy {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(null as KeyStore?) }
        X509TrustManagerExtensions(factory.trustManagers.filterIsInstance<X509TrustManager>().single())
    }
    fun verify(chain: Array<ByteArray>, host: String): Boolean = runCatching {
        require(chain.size in 1..16 && chain.all { it.size in 1..1_048_576 } && host.isNotBlank())
        val factory = CertificateFactory.getInstance("X.509")
        val certs = chain.map { factory.generateCertificate(ByteArrayInputStream(it)) as X509Certificate }.toTypedArray()
        trust.checkServerTrusted(certs, certs[0].publicKey.algorithm, host).isNotEmpty()
    }.getOrDefault(false)
}

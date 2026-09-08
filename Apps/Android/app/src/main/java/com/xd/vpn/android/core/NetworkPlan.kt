package com.xd.vpn.android.core

import java.net.InetAddress

data class IpPrefix(val address: String, val prefix: Int)
data class NetworkPlan(val addresses: List<IpPrefix>, val routes: List<IpPrefix>, val dns: List<String>, val domains: List<String>, val mtu: Int) {
    companion object {
        fun ipv4(value: String): Boolean = value.split('.').let { parts ->
            parts.size == 4 && parts.all { it.isNotEmpty() && it.length <= 3 && it.all(Char::isDigit) &&
                (it == "0" || !it.startsWith('0')) && (it.toIntOrNull() ?: 256) in 0..255 }
        }
        fun ipv6(value: String): Boolean = value.contains(':') && value.length <= 45 &&
            value.all { it in "0123456789abcdefABCDEF:." } &&
            runCatching { InetAddress.getByName(value).address.size == 16 }.getOrDefault(false)
        fun mask(value: String): Int {
            require(ipv4(value)) { "无效 IPv4 掩码" }
            val bits = value.split('.').joinToString("") { it.toInt().toString(2).padStart(8, '0') }
            require(!bits.contains("01")) { "不连续掩码" }
            return bits.count { it == '1' }
        }
        private fun domain(value: String): Boolean = value.length in 1..253 && value.split('.').all { label ->
            label.length in 1..63 && !label.startsWith('-') && !label.endsWith('-') &&
                label.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' }
        }
        fun create(fields: List<String>, dns: List<String>, includes: List<String>, excludes: List<String>, splitDns: List<String>, mtu: Int): NetworkPlan {
            require(fields.size == 6 && fields.all { it.length <= 2048 })
            require(listOf(dns, includes, excludes, splitDns).all { it.size <= 256 && it.all { s -> s.length <= 512 } })
            val address = fields[0]; val netmask = fields[1]; val address6 = fields[2]
            val netmask6 = fields[3]; val search = fields[4]; val pac = fields[5]
            require(ipv4(address) && address != "0.0.0.0" && address.split('.')[0].toInt() in 1..223 && !address.startsWith("127.")) { "需要网关 IPv4 地址" }
            require(pac.isEmpty() && excludes.isEmpty()) { "不支持 PAC 或全隧道排除路由" }
            require(mtu in 576..9000)
            val addresses = mutableListOf(IpPrefix(address, mask(netmask)))
            val routes = mutableListOf(IpPrefix("0.0.0.0", 0))
            if (address6.isNotEmpty()) {
                val parts = (if (address6.contains('/')) address6 else if (netmask6.contains('/')) "$address6/${netmask6.substringAfterLast('/')}" else "$address6/${netmask6.ifEmpty { "128" }}").split('/')
                require(parts.size == 2 && ipv6(parts[0]) && parts[0] != "::" && parts[0] != "::1" && !parts[0].startsWith("ff", true))
                val prefix = parts[1].toIntOrNull() ?: -1
                require(prefix in 1..128 && mtu >= 1280)
                addresses += IpPrefix(parts[0], prefix)
                routes += IpPrefix("::", 0)
            }
            // No IPv6 address/route/DNS/allowFamily => Android blocks the absent family.
            require(dns.isNotEmpty() && dns.all { ipv4(it) || ipv6(it) }) { "需要有效数字 DNS 地址" }
            val supportedDns = dns.filter { ipv4(it) || addresses.size > 1 }.distinct()
            require(supportedDns.isNotEmpty())
            val domains = (search.split(Regex("[ ,;]+")) + splitDns).filter { it.isNotEmpty() }.distinct()
            require(domains.size <= 32 && domains.all(::domain))
            return NetworkPlan(addresses, routes, supportedDns, domains, mtu)
        }
    }
}

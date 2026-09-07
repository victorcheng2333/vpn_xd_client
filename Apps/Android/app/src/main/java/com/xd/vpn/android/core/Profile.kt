package com.xd.vpn.android.core

import java.net.URI

data class Profile(val server: String = "https://vpn.xindong.com:8443", val username: String = "", val autoConnect: Boolean = false) {
    fun validated(): Profile {
        val address = server.trim().let { if (it.contains("://")) it else "https://$it" }
        val user = username.trim()
        require(address.toByteArray().size <= 2048 && user.toByteArray().size in 1..256 &&
            listOf(address, user).none { text -> text.any { Character.isISOControl(it) } }) { "请填写用户名，并检查字段长度和换行符。" }
        val uri = runCatching { URI(address) }.getOrNull()
        require(uri != null && uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.rawUserInfo == null &&
            uri.rawQuery == null && uri.rawFragment == null && (uri.port == -1 || uri.port in 1..65535)) {
            "请输入有效的 HTTPS VPN 地址，不能包含凭据、查询参数或片段。"
        }
        return copy(server = address, username = user)
    }
}

enum class Phase(val title: String) {
    IDLE("尚未连接"), CONNECTING("正在连接"), CONNECTED("已连接"), RECOVERING("正在恢复"), STOPPING("正在断开"), FAILED("连接已暂停");
    val active get() = this in setOf(CONNECTING, CONNECTED, RECOVERING, STOPPING)
}

enum class Failure(val message: String, val blocks: Boolean) {
    AUTH("账号认证被拒绝或需要暂不支持的认证方式，请检查设置后手动连接。", true),
    CERTIFICATE("服务器证书校验失败，请检查网关证书或联系 IT。", true),
    SETTINGS("网关网络配置暂不支持，请联系 IT 检查地址、路由、DNS 或 PAC。", true),
    STORAGE("本机安全存储不可用，请解锁设备并重新保存配置。", true),
    BUDGET("五分钟内已启动三次连接，自动连接已暂停，请检查后手动连接。", true),
    NETWORK("连接中断，请检查当前网络后重试。", false),
    SESSION("网关会话已失效，正在尝试重新认证。", false)
}

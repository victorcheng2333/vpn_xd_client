# Android 开发验证记录 — 2026-09-07

基线：`main@d162185`；开发：`codex/android-support`；以下为首轮版本0.1.0验证，min API28 / target API36。

后续 0.1.1 最终 APK 与真机结果见 [Android 真机验收记录](DEVICE-VERIFICATION-2026-09-07.md)。

## 结果

| 检查 | 结果 |
| --- | --- |
| 原生引擎 arm64-v8a + x86_64 | 通过；OpenConnect9.21 / OpenSSL3.6.2 / libxml2 2.15.4 / NDK28.2.13676358 |
| debug APK / R8 release未签名APK | 通过；开发APK已安装并在Android16模拟器打开 |
| JVM策略测试 | 12/12通过 |
| Android12，API32，arm64模拟器 | 13/13设备测试通过 |
| Android16，API36，arm64模拟器 | 13/13设备测试通过 |
| Android lintDebug / release lintVital | 通过，零error；保留9项warning（固定依赖的新版本提醒和预期的用户CA信任） |
| 两种APK的全部原生库 | 四个ELF/每APK全部通过 ABI、ELF LOAD 与 ZIP entry 16KB对齐；包括AndroidX传递原生依赖 |
| Gradle Wrapper JAR | 与Gradle官方SHA-256一致，分发zip也固定SHA-256 |
| 原生符号检查 | 最终libxdvpn.so无fork/exec/system/popen外部进程API |
| 三个页面与可访问性 | 首屏/设置/连接质量实际截图已检查；设备测试覆盖页签、配置禁用和分享入口 |
| Git差异 | `git diff --check`通过；不改macOS/iOS运行时代码或既有工作流 |

## 已验证的关键行为

- 配置URL、字段长度/控制字符、IPv4掩码、双栈地址/前缀、MTU和不支持网络策略的拒绝。
- IPv4全隧道时不配置IPv6地址/路由/DNS/allowFamily，避免意外允许无隧道IPv6；这部分为规划逻辑测试，尚未做真实流量泄漏测试。
- 自动开关不授予连接意图；五分钟三次预算；成功连接不抹掉预算；时钟倒退不刷新预算。
- Keystore AES-GCM在设备上加解密、重新实例化后读取、密码留空保留、文件中不出现合成明文密码。
- 等待网络时取消、调用worker前取消、worker销毁后重复控制安全。
- 真实原生引擎连接本机临时TLS网关：系统拒绝未知根证书、IP主机名不匹配在信任回调前拒绝、socket保护失败在connect前拒绝；均未发送HTTP认证。
- 合成网关发出Cookie后返回CONNECT401，结果保留“已认证”标记，与密码拒绝区分；重复密码表单仅提交一次密码。
- 真实VpnService通过模拟器测试授予的VPN app-op启动前台服务，证书失败持久化暂停；模拟系统再启动不会重新认证。
- 真实VpnService握手中手动断开，取消后返回空闲、持久化撤回意图；再次系统启动不重连。Android16的systemExempted权限链已实际运行。
- 关闭自动连接偏好后，下一次冷认证不消耗预算；损坏恢复文件不会授权重连。
- 最近24小时恢复统计、重复完成去重、取消不算失败、跨设备启动和未知起点不虚构耗时。

首轮测试仅使用合成凭据和127.0.0.1临时服务。后续已连接 Android 真机并验收，详见上述真机记录。

## 首轮结束时尚待验收（后续进展见真机记录）

| 项目 | 状态 |
| --- | --- |
| 真实网关认证、系统TUN数据传输、实际内网业务 | 未验证，需授权测试账号和Android手机 |
| DTLS可用网络/TLS回退的真实流量 | 实现已编译，尚待实测 |
| Wi-Fi/蜂窝切换、飞行模式、DNS变化、NAT64/IPv6-only物理网络 | 尚待真机验证 |
| 锁屏5/30分钟、隔夜、耗电、OEM后台限制 | 尚待真机验证 |
| 系统进程终止/START_STICKY自动恢复 | 持久化门禁与模拟系统启动已测，真实系统低内存终止与重建尚未测 |
| API28最低版本、x86_64设备运行 | 编译覆盖，已加远端CI矩阵；本轮未运行远端CI |
| Linux从空缓存完整构建 | 已提供CI脚本，本轮本机构建为macOS arm64 |
| 商店/企业正式签名、发布 | 未配置，未上传或发布 |

手动断开的生效时间受正在进行的系统DNS调用退出影响；DNS使用Android公共同步按网络解析API，命令管道可取消TLS/认证/主循环，但不能强制中断系统解析线程。待在弱网/换网真机矩阵中测量最坏耗时；没有通过强杀线程释放正在使用的native指针。

Android16官方镜像在本地手建AVD中出现系统状态栏图标裁剪，系统Launcher也有同样现象；应用内容和底部导航布局已检查，不将该模拟器系统栏现象归因于应用。

## 复现与本地证据

```sh
bash Apps/Android/scripts/check.sh
# 使用可丢弃模拟器，不能对保存真实配置的手机运行这些合成配置测试。
ANDROID_SERIAL=emulator-5554 Apps/Android/gradlew -p Apps/Android :app:connectedDebugAndroidTest
```

本轮构建/测试日志在`.build/verification/`；实际截图在`.build/screenshots/`。JVM、lint、设备报告由Gradle写入`app/build/reports/`。这些生成物不进入Git。

## 首轮 0.1.0 APK 校验和（非最终交付包）

- `debug/app-debug.apk`：80,084,137 bytes；SHA-256 `478411302e69a49c9b12e1441a50f431a7ea039b40858eb44b52b7e569a32d1c`。
- `release/app-release-unsigned.apk`：17,096,110 bytes；SHA-256 `edca2b33412cd7e76bc4d207893d174839759f9dd991968dd5ca6f6fd6f87746`。

# Android、macOS、Windows 上传链路审计

审计基线：`455166c77c09b9bb5032f0a3666c6cee6bbc0ec7`，2026-09-18。本轮检查生产代码、固定版本依赖和隔离测试，不连接真实 VPN，不修改系统网络，不发布构建。

后续实施：用户已授权四端修复和发布，目标为桌面/Android 1.1.27（38）、iOS TestFlight 内测 0.1.0（10）。下文保留修复前证据；修复实现及验证见末节。

**三个端都没有 iOS 原先的额外 socketpair 上传桥丢包点；但都存在 MTU 变化未同步到系统接口的条件性缺口。** Android 初次 DTLS 建立就可能触发，macOS/Windows 主要在接口已建立后的传输切换或重新协商时触发。目前没有三个端与 AnyConnect 的同条件持续上传测速，不能据此称三个端实际都慢，也不能量化损失。

| 平台 | 上传数据路径 | iOS 式临时背压丢包 | MTU 同步结论 |
| --- | --- | --- | --- |
| Android | 系统 TUN fd → 原生 OpenConnect | 没有额外逐包 Kotlin/JNI/socketpair 桥；引擎队列满会暂停读取 | 先建 TUN 后握手 DTLS，后者调小 MTU 没有通知系统；首次连接和后续握手均可能受影响 |
| macOS | 内核 utun → OpenConnect 独立进程 | 无 iOS 数据桥；Swift/权限助手 socket 传控制消息 | 初次 DTLS 成功通常先确定 MTU 再建接口；接口存在后的 MTU 下降及 TLS 重连 MTU 变化缺少接口更新 |
| Windows | Wintun ring → OpenConnect 独立进程 | 上传队列满暂停消费 ring；下行 ring 满会保留包重试 | 与 macOS 类似；接口仍按旧 MTU 发包时，超过引擎新 MTU 的包会被明确丢弃 |

这里排除的是特定桥接缺陷，不代表系统队列永不丢包，也不代表其他吞吐瓶颈已全部排除。

## 1. Android：初始配置早于最终 DTLS MTU

代码证据：

- [`XDVpnService.kt:224–245`](../../Apps/Android/app/src/main/java/com/xd/vpn/android/service/XDVpnService.kt)：`Builder.setMtu(...).setBlocking(false).establish()` 创建系统 TUN，再返回复制的 fd；不逐包经过 Kotlin。
- [`engine.c:181–207`](../../Apps/Android/native/engine.c)：`apply_settings` 把 fd 交给 `openconnect_setup_tun_fd`；TLS 重连回调会重新应用设置。
- 同文件 `272–274`：先 `apply_settings`，再 `openconnect_setup_dtls`；`progress:209–216` 只处理连接事件，没有 MTU 变化处理。
- OpenConnect 9.21 `dtls.c:628–662` 的 `dtls_detect_mtu` 更新内存中的 `ip_info.mtu`，不调用重新配置回调。已有 fd 导致主循环跳过延迟创建 TUN。

结果是系统接口可以继续产生旧 MTU 的上行包，而 `mainloop.c:58–69`、`tun.c:503–519` 按引擎的新长度分配/读取。存在读短包、丢包和 TCP 重传风险；尚未在 Android 真机触发并量化。

初始设置可改为使用引擎的 setup-tun 回调，等 DTLS 初步确定 MTU 后再建立接口；仍须处理运行中的 MTU 变化。当前 `NetworkPlan` 把 MTU 纳入方案相等性，MTU 改变会调用 `Builder.establish()` 替换接口，不能省略 fd 切换、旧接口在途数据和业务连接的回归。[Android 官方接口说明](https://developer.android.com/reference/android/net/VpnService.Builder#establish())明确描述了新旧接口交接。

## 2. macOS：正常首次握手与后续变化必须分别判断

[`TunnelEngine.swift:65–83`](../../Sources/VPNCore/TunnelEngine.swift) 启动 OpenConnect 子进程；[`Profile.swift:68–78`](../../Sources/VPNCore/Profile.swift) 不传 `--script-tun`、`--no-dtls` 或自定义队列长度。`LocalSocket.swift` 的 AF_UNIX 流式 socket 用于有界 JSON 控制消息，不承载 VPN IP 数据。

固定源码的正常初始流程：`cstp.c:322` 设置延迟建接口原因 → `main.c:2444` 启动 DTLS → `dtls_mainloop` 维持延迟直到握手结束 → `mainloop.c:202–214` 创建 TUN → `library.c:1567–1595` 导出当前 MTU 并运行 connect 脚本。`tun.c:322–356` 直接打开内核 utun。因此不能把 Android 的初始时序问题直接套在 macOS 上。

缺口发生在接口已经存在之后：

1. TLS 先承担流量，随后 DTLS 重试成功，或 DTLS 重握手探测到更小 MTU；`dtls_detect_mtu` 只改变引擎内存，不更新 utun。
2. TLS 重连重新取得不同 MTU；上游 `ssl.c:1240–1243` 调用 reconnect hook，但本项目 [`NetworkScriptRunner.swift:98–117`](../../Sources/VPNCore/NetworkScriptRunner.swift) 只处理服务器路由后返回，没有更新接口 MTU。其注释与固定 vpnc-script 一致：脚本的 reconnect 本身也不重新调用 `do_ifconfig`。

修复应在引擎确认 MTU 变化后通知受管网络层，校验接口归属，只更新本次 utun 的 MTU 并读回；无需重跑完整路由和 DNS 配置。同步失败必须停止或恢复一致状态，不能继续静默使用不同 MTU。

已直接编译未修改的 `dtls.c`、`tun.c` 做隔离验证，DPD 对端由替身模拟 1280 字节路径上限，结果为：

```text
late-DTLS: ip_info.mtu=1440->1280 probes=52 read_calls=52 reconnected=0 script=0 changed_log=1
no-change control: mtu=1280 unchanged_log=1 reconnected=0 script=0
stale-interface-size packet: original=1440 delivered=1280 header_total_length=1440 (datagram simulation)
```

最后一项用数据报 fd 模拟接口输出：生产 `os_read_tun` 交付 1280 字节，IP 头总长度仍是 1440。它验证读取长度不匹配的后果，不是实际 utun/Android TUN 的丢包率。没有建立真实接口或 VPN。复现命令为 `bash .build/cross-platform-upload-audit/run-dtls-mtu-probe.sh`，见[脚本](../../.build/cross-platform-upload-audit/run-dtls-mtu-probe.sh)、[结果](../../.build/cross-platform-upload-audit/dtls-mtu-probe-result.txt)。

## 3. Windows：超新 MTU 的上行包会被直接丢弃

[`EngineProcess.cs:306–318`](../../Apps/Windows/XDVPN.Platform/EngineProcess.cs) 启动原生 CLI，控制管道与 C# 不逐包传送流量。[`build-engine.sh:17–27`](../../Apps/Windows/scripts/build-engine.sh) 固定 OpenConnect 9.21、Wintun 0.14.1，使用 **GnuTLS**；Android/macOS/iOS 使用 OpenSSL，不能假设所有端都是同一加密后端。

生产 [`patch-openconnect.py`](../../Apps/Windows/native/patch-openconnect.py) 处理控制管道、脚本启动和 Wintun 错误分类，没有补齐 MTU 通知。

- 上游 `wintun.c:179–215` 的 `os_read_wintun` 用 `WintunReceivePacket` 消费系统上行包。若包长大于当前可读长度，则打印超长包错误、释放 ring 包并返回失败，没有把截断的包交出去。
- [`network.ps1:289–298`](../../Apps/Windows/scripts/network.ps1) 在 connect 阶段读取并设置 MTU；`303–313` 的 reconnect 复用旧状态并更新路由，既不读取新 `INTERNAL_IP4_MTU`，也不重新设置 MTU。`Verify-Network` 对照的仍是旧状态，不能发现“引擎 MTU 已变、接口 MTU 未变”。
- CLI 初次正常 DTLS 的延迟建接口机制与 macOS 相同；已有接口后的下降才暴露这个缺口。

隔离实验已从固定源码应用实际 Windows 补丁，再编译其中 `os_read_wintun`、`os_write_wintun` 和原始 `tun_mainloop` 的函数体；Wintun 驱动、队列和 fd 监控使用替身。5 项通过：1400 字节包遇 1280 字节引擎 MTU 会丢弃并释放；1280 字节包可交付；32 包上行队列满后暂停读取、其余 68 包未消费；下行 ring 满时保留原包；ring 恢复后原包送达。

实验文件与结果在 [本地隔离实验目录](../../.build/cross-platform-upload-audit/windows/README.md)。这是生产函数逻辑验证，不是 Windows 驱动测试或吞吐测试。本机没有 MSYS2 UCRT64，未运行要求该环境的 `test-native-control.sh`。

## 4. 同时发现 iOS 修复还有一个分支遗漏

OpenSSL `openssl-dtls.c:645–669` 的 `PSK-NEGOTIATE` 分支会按加密开销降低 MTU；它先输出 `DTLS MTU reduced to %d`，再赋值。随后输出 `Established DTLS connection`，最后才调用 `dtls_detect_mtu`。如果最后的探测不再改变值，就没有 `Detected MTU` 通知。

当前 [`OCEngine.m:44–52`](../../Apps/iOS/OpenConnectAdapter/OCEngine.m) 对握手成功只更新传输标签，仅在 `Detected MTU` 时应用设置，因此仍可能漏掉上述变化。Windows 的 GnuTLS 分支也有同类顺序。直接把新日志加入同一个匹配条件还不够，因为此时赋值尚未发生。

这不否定已完成的 socket 背压修复及探测通知修复，但意味着 TestFlight 0.1.0 (9) 不能称为覆盖了所有 MTU 变化来源。是否与用户网关、剩余上传差距有关仍需会话证据。

## 5. 已排除的简单解释与下一步

共同上游代码已具备常规背压：`mainloop.c:76–86` 队列满暂停读取；`dtls.c:437–448` 写不出时重新入队，真正出错后回退 TLS；`cstp.c:1081–1109` 保留 TLS 当前包等待写出。不要把 iOS 的 socket 缓冲参数直接复制到三端。

Android `build-engine.sh:71–106` 对原生库及 JNI 使用 `-O2`；macOS `scripts/build-openconnect.sh:95` 也为 `-O2`，且已核对本机产物版本及 Makefile。Android Debug 和桌面端 UI Debug 不能等同于 iOS Swift PacketPump 的 `-Onone` 数据路径。Windows 原生库独立于 C# 构建；脚本未固定 CFLAGS，本轮没有核实已发布二进制的实际编译参数。

三个端默认都尝试 DTLS，但不保证网络允许、网关支持或实际成功。官方说明 UDP 数据通道通常更适合吞吐，TCP 套 TCP 会受重传影响；队列默认 32 包，盲目增加会增加延迟。[OpenConnect 手册](https://www.infradead.org/openconnect/manual.html)。不同后端、网关策略和网络条件仍须通过实测区分。

建议后续按以下顺序实施和验收：

1. **补齐 MTU 通知。** 在 OpenSSL/GnuTLS 完成所有 MTU 计算后统一比较并通知，覆盖初次握手、PSK 开销调整、DPD 探测、TLS 重连、延迟 DTLS 成功。分别接到 Android/iOS 设置层和桌面接口更新层。
2. **验证接口切换。** 相同值不反复配置；变化后系统和引擎 MTU 一致；失败有明确处理；保留地址/路由归属检查。重点回归 Android 新旧 fd 切换和桌面 reconnect。
3. **做各端 A/B。** 同一设备、账号、网关、路由、网络、固定测速终点，用 Release 交替对比 XD 和 AnyConnect 至少 3 轮；记录真实数据通道、双方接口 MTU、上传中位数、重传、CPU 和中断。增加“先 TLS 后 DTLS”与恢复后的同样测试，避免只测初连。

现有 Android 2026-09-07/08 真机记录主要验证 TLS、业务和恢复，并明确保留 DTLS 真机待测；本轮没有新增三端的实际 Mbps 证据。生产代码保持审计基线，本报告列出的缺口尚未在本轮修复。

## 6. 后续实施与发布验收（2026-09-18）

共同修复位于 `scripts/patch-openconnect-mtu.py`，四端构建均应用此补丁并计入缓存配方。引擎记录已应用 MTU，在主循环入口及协议处理后、读取 TUN 前核对最终值；不依赖日志字符串，因此覆盖 OpenSSL/GnuTLS 的 PSK 开销调整、MTU 探测及 TLS/DTLS 重连。移动端使用返回成功/失败的专用同步回调，桌面调用完整刷新环境后的 `mtu` hook。更新失败停止会话；相同值不重复通知；变化时释放未消费的读缓冲，Windows TAP 尚有异步读时则停止并由正常关闭路径回收。fd 安装失败不标记已同步，也不保留虚假的活动 fd；外部 fd 交接会清空旧读缓存，避免重连增大 MTU 后仍使用较小缓冲。

- Android：初建改为引擎 setup-tun 回调；完成首次 DTLS 尝试后再建立系统接口。运行中的变化通过原设置路径交接 fd；相同网络方案沿用既有系统接口。
- iOS：删除基于 `Detected MTU` 的设置更新，改为专用回调，保留已有上传背压和批量收包修复。
- macOS：校验本会话 journal、标记、PID、utun、IPv4 和接口索引后，通过 ioctl 更新并读回 MTU；reconnect 同样同步，不重跑完整路由/DNS。
- Windows：校验接口归属和旧状态，更新 MTU 后读回并保存 journal；失败撤销 ready。原生 hook 的命令/环境分配失败不再误报成功。

发布前本机已完成：共同 native guard 回归（含 Windows 分支）；macOS arm64 引擎完整重建及 238 项 Release Swift 测试；Android 两 ABI 编译、Debug/R8 Release、lint、24 项 JVM 和 API 32 模拟器 10 项原生引擎测试；iOS 138 项逻辑检查、真实包泵回归、模拟器原生设置回调与本地 TLS 双向传包/恢复、iPhoneOS App/Extension 构建；Windows 实际脚本配替身网络接口的新增 12 组回归，以及原生脚本失败注入。Windows 完整编译、PowerShell 5.1 和 SYSTEM 服务由发布 CI 继续验收。

用户追加要求的 Android 真机调试已完成：PKX110 / Android 16 保留配置覆盖安装，首次连接与手动断开重连均成功；两次 TLS 会话的引擎 MTU 和独立内核 ioctl 读数均为 1472，业务 HEAD 返回 HTTP 200，结束恢复未连接状态。详见 `Apps/Android/MTU-VERIFICATION-2026-09-18.md`。此次真机及模拟器/隔离验证不代替真实 DTLS 路径和吞吐验收；切换瞬间已在途的旧尺寸数据仍可能重传。具体安装包是否已发布以 GitHub Release、TestFlight 远端状态及各自产物回执为准。

发布构建补充：`v1.1.27` 的 Windows GCC 检查发现测试替身中的格式化指针触发严格告警；新鲜 Android CI 同时发现既有 Gradle Wrapper SHA-256 多一个字符。已修正测试替身、Wrapper 校验和和 CI SDK 初始化，正式安装包目标递增为 `v1.1.28 / build 39`，不移动旧标签。产品 MTU 修复逻辑不变；Android 上述真机验证针对 `1.1.27-dev.38`，iOS `0.1.0 (10)` 使用同一修复逻辑。

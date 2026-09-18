# iOS 上传慢：调查与修复记录（2026-09-17）

已在客户端代码中定位并修复两处可能影响上传的缺陷：本地发包缓冲满时直接丢包，以及 DTLS 探测到更小 MTU 后未同步给 iOS。第一处已通过真实 socket 的受控实验复现；第二处已核对固定版本引擎源码，并用实际进度回调验证设置通知缺失。用户补充修复前后两轮测速：XD 上传 20.1 → 28.0 Mbps，实测值增长 39.3%；相对各轮 AnyConnect，上传差距从 42.4% 缩小到 13.6%。用户确认修复后使用 Xcode Debug、已脱离调试器，尚无 Release 真机结果。当前证据与修复方向一致，但构建配置、5G 波动及缺失的传输诊断仍限制因果判断，不能将增长幅度全部归因于代码修改。

2026-09-18 补充：[跨平台审计](2026-09-18-cross-platform-upload-audit.md) 发现 PSK 握手按加密开销调小 MTU 的另一条分支，若后续探测没有再次改变数值，当前 `Detected MTU` 通知修复仍会遗漏。此条件性缺口尚未修复，也未证实用户网关触发；不能把本次探测同步修复理解为已覆盖所有 MTU 变化来源。

后续经用户授权，0.1.0（10）候选源码已改为主循环检查最终 MTU 的专用回调，覆盖上述遗漏；模拟器原生回调、会话恢复及 iPhoneOS 构建已通过。实际 TestFlight 发布状态以远端结果为准，见跨平台记录的实施节。

## 用户补充的旧版测速基线

用户明确说明两张截图属于旧版本测试。客户端对应关系按用户“xd vpn vs anyconnect”的排列理解，截图自身没有显示 VPN 客户端名称。

| 截图指标 | 图 1：XD VPN 旧版 | 图 2：AnyConnect | 比较 |
| --- | ---: | ---: | --- |
| 上传 | 20.1 Mbps | 34.9 Mbps | XD 少 14.8 Mbps，低 42.4%，为对方的 57.6% |
| 下载 | 117.4 Mbps | 119.4 Mbps | XD 低约 1.7% |
| Ping | 51 ms | 52 ms | 相差 1 ms |
| 状态栏网络 / 运营商 | 5G / 电信 | 5G / 电信 | 显示相同网络类型和运营商 |
| 应用显示信号 | −69 dBm | −50 dBm | 读数相差 19 dB；测量类型与准确性未核实 |
| 截图系统时间 | 12:42 | 12:43 | 仅说明截屏时钟，不作为测速起止时间 |
| 测速节点 | 此图未显示 | Shanghai Internet Server | 未确认固定了相同测速节点 |

两次结果的差异集中在上传，支持继续优先验证上传桥接修复。它与已复现的上行背压缺陷相容，但不能单独证明因果关系。信号读数、未确认的测速节点，以及缺失的 TLS/DTLS、VPN 网关与路由信息，使这组数据尚不足以隔离客户端影响；也不能用 19 dB 读数差直接换算上传带宽差。

第二图还显示 Jitter 47.46 ms、Loss 0%。截图未说明这些值的统计口径，不能用该 Loss 值排除 XD 本地桥接丢弃或上传重传。本组仅作为旧版基线，修复后结果另列如下。

## 用户补充的修复后 Debug 真机测试

用户说明第二组为“修改之后真机调试”，并明确构建为 **Xcode Debug、已脱离调试器运行**，随后再次强调测速前已断开调试器。因此不将本轮剩余差距归因于调试器附加。仍按图片顺序对应 XD VPN、AnyConnect；尚未取得确切版本/构建号、实际 TLS/DTLS、MTU 和桥接计数。

| 截图指标 | 图 1：修复后 XD VPN Debug | 图 2：本轮 AnyConnect | 比较 |
| --- | ---: | ---: | --- |
| 上传 | 28.0 Mbps | 32.4 Mbps | XD 少 4.4 Mbps，低 13.6%，达到对方的 86.4% |
| 下载 | 123.0 Mbps | 122.1 Mbps | XD 高约 0.7%，本轮基本持平 |
| Ping | 49 ms | 78 ms | XD 本轮低 29 ms，尚不足以断言长期延迟更优 |
| Jitter | 46.01 ms | 43.33 ms | 页面统计口径未核实 |
| Loss | 0% | 0% | 不替代本地桥接和业务重传计数 |
| 应用显示信号 | −56 dBm | −62 dBm | 读数仍有差异 |
| 测速节点名称 | Shanghai Internet Server | Shanghai Internet Server | 名称相同，尚未核实节点 IP 和 VPN 路由 |
| 状态栏网络 / 运营商 | 5G / 电信 | 5G / 电信 | 相同显示类型 |
| 截图系统时间 | 12:46 | 12:47 | 不作为测速起止时间 |

前后 XD 上传增加 7.9 Mbps（39.3%），AnyConnect 则从 34.9 降至 32.4 Mbps（−7.2%）。各轮客户端差值从 14.8 缩小到 4.4 Mbps。前后对照支持继续沿已修复的上传路径验证，但网络环境也在变化，不能把 39.3% 称为剥离网络波动后的净修复收益。

仓库 [`generate-project.py`](../../Apps/iOS/scripts/generate-project.py) 与实际 Xcode 工程均将 Debug 的 Swift 优化设为 `-Onone`，Release 为 `-O`，默认 Run 为 Debug。脱离调试器不会改变已编译代码的优化级别。PacketPump/PacketCodec 位于 Swift 数据路径，因此构建配置是下一轮必须控制的变量；还没有测量能证明剩余 4.4 Mbps 来自 Debug。嵌入的 OpenConnect/OpenSSL 库由独立脚本按 `-O2` 构建，不应将整个加密引擎误称为未优化。

下一轮先用相同修复的 Release 构建、脱离调试器，在固定测速节点交替测试至少 3 轮，记录各轮诊断增量。若仍有稳定上传差距，再依据是否有桥接丢弃/频繁背压、是否为相同传输协议和 MTU 决定继续优化的位置。暂不为单轮差距修改内核队列长度、MTU 或线程优先级。

已额外完成 iPhoneOS Release 无签名构建，日志确认 App 和 PacketTunnel 均使用 Swift `-O`，构建结果为 `BUILD SUCCEEDED`。产物位于 `Apps/iOS/.build/upload-performance-release/Build/Products/Release-iphoneos/XDVPN.app`；这是编译验证产物，不能视为 Release 真机测速通过。用户随后授权提交、推送并发布 TestFlight；Apple 预检确定本次内测构建为 0.1.0 (9)，组为「iOS 真机验证」。实际发布结果由对应归档的 `result.json` 和 Apple 远端状态记录。

## 1. 已复现：上传桥接遇到短暂拥塞就丢包

上传路径为：iOS `packetFlow.readPackets` → Swift `PacketPump` → `AF_UNIX/SOCK_DGRAM` socketpair → OpenConnect → TLS/DTLS → 网关。

旧 `PacketPump.readPackets()` 对一个批次逐包调用非阻塞 `send()`。任何发送失败都直接计为丢弃，随后立即读取下一批；没有保留 `EAGAIN/EWOULDBLOCK/ENOBUFS` 对应的数据。`OCEngine` 创建 socketpair 后没有设置收发缓冲。在 OpenConnect 暂停读取、等待外网可写或线程调度落后时，这些失败不表示包无效，而表示暂时没有空间。对 TCP 上传，这种本地丢包可能引起重传和拥塞窗口收缩。

在本机 Darwin socket 上测得默认 `SO_SNDBUF=2048`、`SO_RCVBUF=4096` 字节。受控测试先让消费者暂停，再提交 64 个 1400 字节 IP 包，每包另加 4 字节地址族前缀：

| 实验 | 当场成功写入 | 丢弃 | 消费者恢复后 |
| --- | ---: | ---: | --- |
| 旧 PacketPump + 4096 字节接收缓冲 | 2/64 | 62/64 | 丢弃的包无法由桥接补回 |
| 新 PacketPump + 相同小缓冲 | 首批仍会填满缓冲 | 0/64 | 64 个包完整、按序送达 |
| 独立 socket 容量实验，收发缓冲设为 256 KiB | 64/64 | 0/64 | 本轮突发无需等待 |

前两项直接运行生产 `PacketPump`，用测试 `PacketFlowIO` 提供数据；第二项让消费者每约 1 ms 读取一个包。旧实现先得到失败结果，再应用修复得到通过结果。新实现也已在 iOS 26.5 模拟器通过。这里的 62/64 是刻意暂停消费者后的本地实验结果，**不是用户 iPhone 的实测丢包率**。

修复在 [`PacketPump.swift`](../../Apps/iOS/PacketTunnel/PacketPump.swift) 与 [`OCEngine.m`](../../Apps/iOS/OpenConnectAdapter/OCEngine.m)：

- socketpair 两端申请 256 KiB 收发缓冲。若系统限制申请值，等待重试仍然有效，诊断记录实际获配大小。
- 遇到暂时背压时保留当前包和剩余批次，暂停下一次 `readPackets`；排空后再读取。每批最多保留 512 包且不超过 2 MiB，异常超限单独计数。
- 重试从 1 ms 退避到最多 16 ms；发送取得进展即重置。没有待发数据时不启动重试。没有采用可写事件源：本机实验发现 Darwin datagram 在返回 `ENOBUFS` 时，kqueue 仍会报告可写，可能导致忙等。
- 每轮处理最多 64 包以让出队列；下载与 TCP ACK 按批次写入 `packetFlow`，减少逐包调用。

## 2. 已确认的条件性缺陷：DTLS 调小 MTU 后，系统仍使用旧值

XD VPN 申请 MTU 1400，随后用网关下发值配置 iOS；不能把申请值等同于最终 MTU。固定依赖 OpenConnect 9.21 的 `openssl-dtls.c:dtls_try_handshake()` 在握手后调用 `dtls.c:dtls_detect_mtu()`。探测可以降低 `ip_info.mtu`，但不会调用 `openconnect_set_reconnected_handler` 注册的回调。当前外部 tun fd 已经建立，库的延迟建 TUN 逻辑也不会替本客户端重新应用 NE 设置。

旧适配层只在初次连接和 TLS 重连时应用设置，因而可能出现“引擎按较小包长读取、iOS 继续生成较大包”的不一致。它能影响上传，但本次没有真实 DTLS 抓包来证明用户恰好触发了这一条件。

修复使用既有的引擎进度回调：识别固定版本的 MTU 变化通知，在同一引擎 worker 同步应用最新网络设置；更新失败则取消不一致的会话。不记录原始日志或格式化参数。MTU 未变化时不重新应用。Swift 待发批次也在重试前核对新 MTU。

`EngineProgressTests.m` 调用实际生产进度回调，以设置接收替身验证“变化必须通知、未变不通知、应用失败停止”。旧代码在“变化必须通知”处失败，修复后通过。该测试验证回调衔接；并非完整 DTLS 网关/路径 MTU 端到端测试。切换时已经进入内核桥接缓冲的旧尺寸数据仍须由传输协议处理，真机需观察重传是否收敛。

## 3. 与 AnyConnect 对比时仍须核实的差异

| 项目 | XD VPN 当前证据 | AnyConnect 官方资料 | 对本次判断的影响 |
| --- | --- | --- | --- |
| 上传缓冲与背压 | 已复现旧实现丢弃暂时发不出的包；本轮修复 | 未获得官方客户端内部发包实现 | 可确认 XD 自身缺陷，不能编造官方缓冲参数 |
| 数据通道 | 新配置优先 DTLS；旧配置的 `useDTLS=false` 会保留；启用也不保证协商成功 | DTLS 不可用时可回退 TLS；Cisco 建议 DTLS/IKEv2 以提高吞吐 | 必须记录测速时双方实际通道；本轮未强行覆盖旧配置 |
| MTU | 网关下发 + 引擎 DTLS 探测；本轮补齐探测后的 NE 设置同步 | SSL VPN 流程中使用 `X-DTLS-MTU`；DTLS 失败时调整为 `X-CSTP-MTU` | 对照双方 MTU 和大包重传，不能仅凭“上传慢”统一改成某个更小值 |

Cisco 的协议性能建议见 [AnyConnect Performance/Scaling Reference，Tunnel Protocol Selection](https://www.cisco.com/c/en/us/support/docs/security/anyconnect-secure-mobility-client/215331-anyconnect-implementation-and-performanc.html)。官方 MTU 流程见 [Understanding the AnyConnect SSL VPN Connection Flow](https://www.cisco.com/c/en/us/support/docs/security/anyconnect-secure-mobility-client-v4x/222430-understanding-the-anyconnect-ssl-vpn-con.html)。这些是 Cisco 的通用 SSL VPN 资料，不是对用户当前 iOS 客户端版本的实测。

OpenConnect 的内部默认队列为 32 包，这与本项目额外 socketpair 的默认小缓冲不同。官方说明默认队列可在合适硬件上跑满千兆，盲目加大队列会增加延迟。本轮保留库内队列长度，先修正有证据的适配问题。见 [OpenConnect 手册，`--queue-len` 与传输说明](https://www.infradead.org/openconnect/manual.html)。

## 4. 验证与真机验收

发布前已完成：138 项配置、路由、恢复、诊断兼容检查；真实 socket 的上传背压、顺序、内存边界、停止与晚到回调、下行批量写入、IPv6 策略及 MTU 变化回归；iOS 26.5 模拟器运行；真实 OpenConnect 与本地 TLS 网关双向传包和切网恢复；iPhoneOS App/Extension Debug 与 Release 无签名构建。MTU 通知测试另按上一节说明验证。用户另行提供的修复后 Debug 真机结果见上文；Release 真机效果仍待内测验证。

复现命令（仓库根目录）：

```sh
bash Apps/iOS/scripts/test.sh
bash Apps/iOS/scripts/test-packet-pump.sh <SIMULATOR_UDID>
bash Apps/iOS/scripts/test-engine-progress.sh <SIMULATOR_UDID>
bash Apps/iOS/scripts/test-native-session.sh <SIMULATOR_UDID> recovery
bash Apps/iOS/scripts/build.sh iphoneos
```

真机按以下口径对比旧 XD、修复版 XD 与 AnyConnect：同一 iPhone、同一 Wi-Fi 或蜂窝网络、同一账号与网关、相同路由范围、相同上传终点；每项至少交替测 3 次。记录客户端版本/构建号、实际 TLS/DTLS/IKEv2 通道、MTU、文件大小、耗时、上传 Mbps 和中断次数。若用测速网站，应固定测速服务器；优先使用已确认流经隧道的公司内网测试终点。

每次测试前后在 XD 的“连接质量 → 分享诊断报告”记录增量。本轮报告新增本地桥接字节、实际缓冲大小、背压重试、排队峰值，以及队列超限/无效或超 MTU/IPv6 策略/socket 错误/系统写入失败的分类计数。IPv6 策略丢弃不能当成上传拥塞；背压重试本身也不等于丢包。已有传输标签来自引擎事件，完整通道判断必要时与网关会话或抓包交叉确认。

建议验收：常规上传时队列超限及 socket 错误丢弃的增量为 0；MTU 同步后不再持续丢弃超长包；没有新增长断流、恢复异常或明显延迟。速度以三轮中位数比较：可暂以达到同条件 AnyConnect 的 90% 作为工程目标，这只是建议阈值，尚非达成结果。若本地丢弃消失而速度仍低，下一步依据实际通道、重传和网关负载继续区分 DTLS 回退、路径 MTU、路由或服务器限速。

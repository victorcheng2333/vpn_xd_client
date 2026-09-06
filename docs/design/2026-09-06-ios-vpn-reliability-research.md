# iOS VPN 配置、休眠恢复与移动网络切换调研

调研日期：2026-09-06。对象：Cisco Secure Client（AnyConnect）与 **Hillstone Secure Connect**，不包含 Hillstone Access Client。用户描述两款均为最新版；未取得设备的精确 iOS/App 版本、配置和日志，本文不是对用户设备的故障定因。

## 1. 结论及难度判断

移动端可靠性明显比当前桌面接入难。真正增加成本的是外层网络、系统进程生命周期、认证有效期和耗电之间的协调。原生 UI 仍可独立开发，OpenConnect 能处理协议并不代表已经解决 iOS 恢复问题。

| 工作 | 相对难度 | 需要解决的问题 |
| --- | --- | --- |
| 独立原生 UI、统一风格 | 中 | 手机/平板布局、权限和状态语义 |
| libopenconnect 接入 Extension | 高 | iOS 构建、公开 packetFlow 桥接、TLS 信任、内存和取消 |
| 移动网络恢复 | 很高 | 地址/DNS/NAT 变化、无网络、UDP 受限、会话失效、并发事件 |
| 不打开 VPN App 的后台恢复 | 很高 | 系统 On Demand、Extension 冷启动、锁屏凭据、网关认证条件 |
| 可交付的稳定性验证 | 高且耗时 | 真机长时间休眠、不同网络和系统版本、能耗对照 |

这些等级是结合本项目现状的工程判断，不是工期统计。PoC 通过前不提供精确倍数或上线时间。目标应是“条件允许时自动恢复业务访问，需人工操作时明确解释”，不能承诺网络切换零丢包、原业务 TCP 永不重置或 iOS 永不终止隧道。

## 2. Cisco 与 Hillstone 的 profile 差异：已知与未知

必须分清三种对象：

| 名称 | 含义 |
| --- | --- |
| 系统 VPN 配置 | App 经系统 API 保存的 VPN 连接配置；通常对应“允许添加 VPN 配置”授权 |
| Apple 配置描述文件 `.mobileconfig` | 手动安装或 MDM 下发的配置载体，可含 VPN、证书等 payload |
| Cisco XML 客户端 profile | Cisco 自身的连接/策略配置，可由网关下发或导入；不是 Apple 描述文件 |

Apple 的 `NETunnelProviderManager` 对应系统保存的 VPN 配置；既可由 App API 创建，也可来自配置描述文件。因而“没有手动安装描述文件”不能推出“没有系统 VPN 配置”。本项目可以采用 App 内授权并创建配置的流程，不要求用户先下载 `.mobileconfig`。[Apple NETunnelProviderManager](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager)

Cisco 官方同时支持用户创建连接和管理式配置；并没有所有用户都必须手动安装 Apple 描述文件的要求。[Cisco iOS 支持矩阵与配置说明](https://www.cisco.com/c/en/us/td/docs/security/vpn_client/anyconnect/Cisco-Secure-Client-5/release/notes/release-notes-apple-ios-cisco-secure-client-release-5-0.html)

Hillstone 官方当前 iOS 下载页标注 Secure Connect 支持 SSLVPN 和 ZTNA，列出的版本为 5.4.1.12360（2025-11-17）；App Store 对应 5.4.1，更新说明没有解释休眠重连。**没有找到足以确认其当前 iOS 网络实现与配置创建机制的公开技术资料**。不能用旧 Access Client/BYOD 文档替代，也不能仅凭 ZTNA 字样断言它不走系统隧道。[Hillstone 下载页](https://www.hillstonenet.com.cn/support-and-training/hillstone-secure-connect/) · [App Store](https://apps.apple.com/cn/app/hillstone-secure-connect/id1664686950)

对用户所见差异，配置的创建/下发方式或接入模式不同是待核实解释，不是已证实结论。安装 profile 本身也不会获得“永远后台运行”的能力。

## 3. 官方、社区与 GitHub 的实际证据

| 来源 | 时间/版本与观察 | 能说明什么、不能说明什么 |
| --- | --- | --- |
| [Cisco iOS 发布说明](https://www.cisco.com/c/en/us/td/docs/security/vpn_client/anyconnect/Cisco-Secure-Client-5/release/notes/release-notes-apple-ios-cisco-secure-client-release-5-0.html) | CSCwr66462：休眠断开后 On Demand 偶发卡在断开中；列为 5.1.11.423 已修复。CSCwf31283：On Demand/DisconnectOnSuspend 异常；列为 5.1.11.347 已修复 | 这类客户端故障确实存在过；不能说已修复旧 bug 就是用户最新版的原因 |
| [Apple 社区用户反馈](https://discussions.apple.com/thread/256188934) | 搜索索引可见 iPhone 17/iOS 26 用户描述 Cisco 休眠后掉线 | 只有检索摘要，正文抓取未成功；缺少日志和定因，证据较弱 |
| [Tailscale #8183](https://github.com/tailscale/tailscale/issues/8183) | 2023-05-21，iOS 16.4.1a/Tailscale 1.40.0；隔夜醒来内网与 DNS 不通，打开 App 后恢复；issue 已关闭 | 相似的历史症状；不等于当前版本仍有此问题，也不是 Cisco/Hillstone 的直接证据 |
| [Amnezia #3068](https://github.com/amnezia-vpn/amnezia-client/issues/3068) | 2026-08-27，iOS 26.6.1/5.0.1.5；VLESS/Xray 连接一段时间后插件退出、反复重启；issue 仍开放 | 说明需要区别进程退出和普通断网；没有证实休眠或内存是原因，协议也不同 |
| [Apple DTS 分析](https://developer.apple.com/forums/thread/840958) | 2026-08，报告涉及 iOS 26.5.2；Apple 从 sysdiagnose 确认系统 nesessionmanager 超出内存限额被终止，导致隧道拆除；报告者观察到 On Demand 随后重建 | 存在系统层原因；并非所有设备或后续系统版本的普遍结论 |
| Hillstone Secure Connect | 检索官方页面、商店、社区及 GitHub，未找到可核实的当前 iOS 休眠重连专项 issue/修复记录 | 公开证据不足，不能据此断言没有 bug，也不能借用其他 Hillstone 产品的故障归因 |

Cisco 的策略行为也可能与“醒来必定立刻连接”的预期不同：`DisconnectOnSuspend` 释放会话后需手动或 On Demand 触发；iOS Network Roaming 关闭时，重连尝试约 20 秒后停止，开启时无客户端规定的重连时限。这些策略仍受系统及网关认证约束。[Cisco 移动端管理指南](https://www.cisco.com/c/en/us/td/docs/security/vpn_client/anyconnect/Cisco-Secure-Client-5/admin/guide/b-cisco-secure-client-admin-guide-5-1/b_AnyConnect_Administrator_Guide_4-4_chapter_01101.html)

排查用户现有两款 App 时，应对照实际配置/网关会话日志和断开原因，区分：没有触发连接、正在恢复、认证过期、隧道已连但 DNS 不通、Extension 被终止。不要直接建议无限延长会话超时或反复提交密码。

## 4. 推荐实现实践

以下为基于公开接口与成熟客户端源码形成的本项目方案，尚未完成 iOS 实现或真机验证。

### 4.1 将恢复分成两层

- **Extension 仍在运行**：本端恢复协调器处理路径变化、传输失败、认证恢复与数据泵状态，不依赖主 App 的计时器。
- **Extension 已退出**：由已保存、用户启用的 On Demand 规则在满足条件时请求系统启动；新的 Extension 从配置和 Keychain 重建会话，不能依赖旧进程内存。

On Demand 是条件触发，不意味着每次解锁立即连接。Apple 文档中的 Always On 是受监督设备的 IKEv2 管理能力，不能宣称本项目自定义 OpenConnect 隧道具有同等能力。无交互认证是自动建立会话的必要条件；需要 MFA/生物识别的流程必须转为等待用户操作。[Apple VPN 部署说明](https://support.apple.com/guide/deployment/vpn-overview-depae3d361d0/web)

### 4.2 网络事件驱动，恢复操作串行

使用 Extension 内的 `NWPathMonitor` 作为事件来源，结合实际 TLS/DTLS socket 错误、协议心跳和超时判断。Wi-Fi 接口未变也可能地址、DNS 或出口变化；路径显示可用不代表网关可达。合并重复通知，避免设置隧道路由又触发自身无限重连。

一个串行协调器拥有连接状态；C worker 独立运行。连接代次标识用于丢弃晚到回调，同一时刻只允许一个恢复尝试。取消、停止和配置更新优先于自动恢复。无路径时等待路径事件并暂停无效尝试；有路径时使用有上限的指数退避和随机抖动。认证拒绝、证书错误不走普通网络重试。

WireGuard 的 Apple 适配源码使用串行队列、路径监视和暂时离线状态，iOS 路径改变时会更新端点与 socket，离线后恢复则重启后端。这支持上述生命周期组织方式；其协议恢复机制及 TUN fd 获取方法不直接复制到 OpenConnect。[WireGuardAdapter.swift](https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/WireGuardAdapter.swift)

### 4.3 分级恢复，区分外层连接与认证

在引擎 API 允许且实测通过的路径中，优先恢复现有认证会话、更新网关 DNS/外层 socket；失败后再冷启动会话。Cookie 是否可续用由网关决定；有效期届满或需要交互认证时明确等待用户。不要把每次 Wi-Fi/蜂窝切换都实现为完整密码登录。

公司网关支持时验证 DTLS 数据通路，以及 UDP 被阻断后的 TLS 回退。不能把 OpenConnect 的 TLS/DTLS 恢复等同于 WireGuard 漫游，也不能假定它自动具备 MPTCP/QUIC 无缝迁移。重新连接成功不保证既有业务 TCP 长连接保持。

### 4.4 状态真实、停止可靠

分别维护用户连接意图、NE 系统状态、协议会话状态；业务探测只作为带时间戳的健康指标。UI 区分等待网络、恢复中、需要登录、已断开；没有探测样本时不展示“内网正常”。业务验证须确认请求实际穿过隧道，不能把 provider 自身直连网关当成内网可用证明。

恢复过程中适当设置 `reasserting`，成功后清除；它是系统状态信号，不会替客户端执行重连。[Apple reasserting](https://developer.apple.com/documentation/networkextension/netunnelprovider/reasserting)

用户手动断开时先保存禁用有效 On Demand 规则，确认成功后停止；保留用户偏好和暂停状态，但不因 App 再启动就无条件取消暂停。保存失败要明确反馈。认证不可自动恢复时需验证如何停止系统反复拉起，不能仅靠进程内重试计数；P1 必须覆盖该路径，未解决前不启用无人值守自动连接。

### 4.5 睡眠、资源和认证的边界

`disconnectOnSleep = false` 默认不主动要求睡眠断开，但不保证网络不断或进程常驻。处理系统 `sleep`/`wake` 回调并及时完成 completion，同时用网络和会话事件恢复；不能假定每次锁屏/解锁都收到固定顺序回调。[Apple disconnectOnSleep](https://developer.apple.com/documentation/networkextension/nevpnprotocol/disconnectonsleep) · [NEProvider](https://developer.apple.com/documentation/networkextension/neprovider)

按组织政策选择锁屏后可读的 Keychain 属性；`AfterFirstUnlockThisDeviceOnly` 在重启后的首次解锁前不可用。App Group 不存放密码或 Cookie；不能为后台恢复绕过认证政策。[Apple Keychain](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)

数据包队列、日志和 IPC 快照有明确上限，优先使用协议机制而非持续高频探测。内存预算按目标真机验证；不要把网上历史 15/50 MB 数字当永久平台契约。Apple DTS 明确建议按设备和系统测试。[Apple 内存限制讨论](https://developer.apple.com/forums/thread/73148?page=2)

### 4.6 IPv6、门户网络与未来 Android

外层网关解析和连接须支持 IPv4/IPv6、IPv6-only/NAT64，不硬编码 NAT64 前缀或只缓存 IPv4 地址。测试 Wi-Fi NAT64 时关闭蜂窝，避免实际流量从蜂窝绕过测试网络。[Apple IPv6 指南](https://developer.apple.com/support/ipv6/)

公共 Wi-Fi 认证页、DNS 失败、网关不可达分别记录；不把所有失败都显示为密码错误，也不为联网而静默改变公司的分流/全隧道保护政策。

Android 复用事件和验收定义，独立实现 VpnService 生命周期、网络回调、socket protect、凭据与后台策略。iOS/macOS/Android 不共享恢复 controller；iOS 的 On Demand 不与 Android Always-on 视为同一能力。[Android VPN 开发指南](https://developer.android.com/develop/connectivity/vpn)

## 5. 对现有计划的调整与验收

将 **On Demand 可行性、锁屏恢复和网络切换提前到 P1**，与最小真实隧道一起验证。P2 再完善 UI 和用户开关。只有用户手动打开 App 才恢复，不能算满足此次需求。

| 验收场景 | 重点观察 |
| --- | --- |
| Wi-Fi ↔ 蜂窝、两个 Wi-Fi 出口、Wi-Fi 同接口换 IP | 是否重新解析/建立传输，是否产生并发连接与错误登录 |
| 断网 30 秒/5 分钟、飞行模式恢复、快速反复切换 | 等待/退避、取消响应、资源上限 |
| 锁屏 5 分钟/30 分钟/隔夜，直接打开内网业务 App | 不先打开 VPN App，验证规则触发与实际内网请求 |
| App 退出、Extension 被系统终止、设备重启 | 冷启动恢复、首次解锁限制；各类停止原因分别记录 |
| Cookie/网关空闲会话过期、MFA、错误密码/证书 | 可恢复则恢复；需交互则停止无效认证循环 |
| UDP 阻断、IPv6-only/NAT64、公共 Wi-Fi 登录页 | TLS 回退、DNS/路由正确、错误分类 |
| 手动断开、撤销 VPN 授权、切换其他 VPN | 不被自身 On Demand 立即拉回，停止/清理正确 |
| 长时间流量与空闲对照 | 内存峰值、崩溃/退出、能耗与恢复耗时 |

记录：从新路径可用或 On Demand 触发至首个真实内网请求成功的 P50/P95、人工干预次数、恢复原因、认证次数、停止原因和能耗对照。分网络/设备/系统版本统计，不用单次演示代替通过率。具体耗时与能耗阈值在 P1 得到基线后确定。

本调研形成时只完成资料和设计；后续已实现 [iOS 验证版 0.1.0](../../Apps/iOS/README.md)，但没有操作用户手机、修改网关策略或完成真实移动端 VPN 连接验证。Hillstone 内部实现、用户两款 App 的具体断线原因，以及公司网关是否允许无人值守重新认证仍待实际验证。

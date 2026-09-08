# XD VPN iOS 验证版 0.1.0

这是独立的 iOS/iPadOS 17+ 原生验证工程，包含 SwiftUI App 和 Packet Tunnel Extension。**已完成实体 iPhone 签名安装、真实内网访问、后台飞行模式恢复、连接质量统计和正常断开验证；最新重连修复版另通过 Wi-Fi/蜂窝双向切换与两次短锁屏业务验证，长时间锁屏及长期恢复行为仍待验收。** macOS 工程、助手和运行时代码未改，Android 尚未建立工程。

## 已实现

- 服务器、用户名、密码配置；认证组输入已移除，旧配置中的组值保持兼容。App 内申请添加系统 VPN 配置。
- 与 macOS 同源的应用图标；连接中使用蓝色旋转圆弧，连接成功使用绿色盾牌。
- App/Extension 共享钥匙串持久引用；凭据只在本设备首次解锁后可读，不存入配置或诊断文件。
- OpenConnect 9.21 + OpenSSL 3.6.2 独立交叉构建；Extension 内调用库，不运行命令行程序。
- 公共 `packetFlow` 经非阻塞 datagram socketpair 桥接 IP 包；显式处理 Darwin 地址族前缀、MTU、丢包与背压。
- 服务端 IPv4/IPv6 地址、分流路由、DNS/搜索域和 MTU 转成 NE 设置。证书由系统 SecTrust 验证完整链和主机名，禁止忽略证书错误。
- TLS、可选 DTLS；库内会话重连，换网合并通知后使用命令管道暂停/恢复并刷新缓存的网关地址。每个 C 会话只由一个 worker 操作。
- 系统唤醒只唤起引擎检查链路，不再无条件拆除 TLS；启用 30 秒 DPD，失活判定由引擎处理。切网请求在认证/网络设置期间保留，待主循环处理；相同网络设置不重复下发，路径日志记录使用中的物理接口。此修复的真机切网验收见验证记录。
- 首页「自动连接」只保存偏好，不会因开启而连接 VPN。用户点击「连接 VPN」后，按该偏好启用系统恢复；关闭开关不主动断开当前连接。手动「断开」先暂停系统恢复，重新打开 App 或重新开启开关都不连接，须再次点击连接。旧版本域名规则保持原范围，直到用户主动修改新开关。主 App 不使用后台保活计时器。
- 自动冷启动五分钟最多三次。成功认证后隧道 CONNECT 返回 401 时，在此预算内重新认证、更新失效会话；账号认证拒绝及证书错误仍持久化暂停，防止 Extension 重启后继续提交密码。系统规则禁用失败时，持久化门禁仍会拒绝继续认证；是否存在系统重复拉起须真机验收。
- 最近 64 条连接事件文本、真实桥接包计数和系统分享。手动 HTTPS 内网探测入口已移除，业务可用性由实际内网访问验证。诊断不保留引擎原始日志、密码、Cookie 或 Token。

- 「连接质量」页显示当前连接时长、传输方式、自动恢复状态，最近 24 小时已完成的恢复成功/失败次数、最近恢复耗时和异常操作建议；详细日志与分享报告保留在页内。没有测速、延迟/丢包图、P95 或主动业务探测。
- 质量事件由 Packet Tunnel 扩展记录并写入 App Group，主 App 仅在页面可见且前台时刷新读取。使用独立的手动连接/断开标记续接系统恢复，重复通知不重复计数，取消不算失败。耗时采用同次设备启动内的单调时钟；未观测到断网起点或跨设备重启时不估算。最多保留 2048 条结构化事件，统计窗口为最近 24 小时，历史损坏或裁剪时提示不完整。

首版没有 SSO/MFA、客户端证书、HostScan/CSD、PAC 代理支持。新配置默认使用当前公司网关要求的 IPv4 全隧道和 DTLS 优先策略，DTLS 不可用时可回退 TLS；这两项技术选项不再展示在设置页。全隧道由网关下发的 0.0.0.0/0 路由实现并阻断网关未提供的 IPv6；**不再使用 `includeAllNetworks` 系统强制**。真机验证表明开启该强制后个人热点对 Wi-Fi/USB 客户端的 DHCP 不再应答（Mac configd 记录 `DHCP en0: INIT-REBOOT timed out / server not responding`），恢复 `excludeLocalNetworks=true` 也无效，只有停止手机 VPN 才恢复。代价是隧道重建期间系统不再拦截非隧道流量。升级后须先在 App 中断开、重新保存配置再连接，才会更新已有系统 VPN 配置。2026-09-08 真机验收：手机 VPN 保持连接时，Mac 经 Wi-Fi/USB 热点 0.6 秒取得地址并在 1.8 秒内恢复自身 VPN，手机端恢复 9 次全部成功（见验证记录）。旧配置中明确保存的路由/传输策略仍保留。IPv6 单栈全隧道、混合全/分流及全隧道显式排除路由仍拒绝。需要这些功能的网关不属于当前验证范围。企业根证书须已被系统信任，服务器应发送完整中间证书链；SecTrust 网络获取在回调中关闭。

## 本地构建

需要完整 Xcode（本轮使用 Xcode 26.6）和 Python 3。脚本只构建 arm64 真机与 arm64 模拟器，各 SDK 的静态库独立保存。使用 Xcode 工程不需要安装 XcodeGen、CocoaPods 或 Homebrew。

从仓库根目录执行：

```sh
Apps/iOS/scripts/build.sh iphonesimulator
Apps/iOS/scripts/build.sh iphoneos
Apps/iOS/scripts/test.sh
```

原生会话失效回归（先启动 arm64 模拟器）：`bash Apps/iOS/scripts/test-native-session.sh <SIMULATOR_UDID>`。脚本只监听本机，使用临时证书和虚构 Cookie 验证登录成功后的 CONNECT 401，退出时自动清理。

切网竞态回归：`bash Apps/iOS/scripts/test-native-session.sh <SIMULATOR_UDID> recovery`。真实引擎在初次网络设置回调期间收到断网/恢复，须合并为一次重连、完成双向 CSTP 数据回送，并在连续健康唤醒后保持连接。仅测试程序信任回环网关的临时证书。

两条 build 命令均为**无签名构建**，不能直接安装到实体 iPhone。默认输出：

```text
Apps/iOS/.build/xcode-iphonesimulator/Build/Products/Debug-iphonesimulator/XDVPN.app
Apps/iOS/.build/xcode-iphoneos/Build/Products/Debug-iphoneos/XDVPN.app
```

工程的构建阶段自动构建固定版本引擎，并核对下载 SHA-256。首次构建需要下载依赖；`XDVPN_SOURCE_CACHE` 可指向已有源码压缩包目录，只复制并校验，不链接其他客户端产物。源码、补丁和构建缓存均在本 iOS 目录中。日志中未使用 AppIntents 的元数据提示不影响构建。

如添加/移除源文件，执行 `python3 Apps/iOS/scripts/generate-project.py` 重新生成工程；修改项目配置应同步修改生成器。签名私有配置不进入版本控制。

图标生成命令：`xcrun swift Apps/iOS/scripts/icon.swift Apps/iOS/Assets.xcassets/AppIcon.appiconset`，输出 1024 × 1024 不透明 PNG。

## 安装到 iPhone

**覆盖安装前先断开 VPN 并暂停按需恢复，确认手机可正常上网。** 全隧道开启时替换 App/Extension 可能留下系统流量拦截，阻断新版开发者在线验证。若已发生，在系统 VPN 设置关闭按需连接并断开 XD VPN；仍不恢复时删除该 VPN 配置并重启设备。不要在断网状态反复覆盖安装。

1. 将 `Configuration/Signing.example.xcconfig` 复制为 `Configuration/Signing.local.xcconfig`，填写实际 `DEVELOPMENT_TEAM`、唯一 `XDVPN_BUNDLE_ID` 和 `XDVPN_APP_GROUP`。
2. 在 Xcode 打开 `XDVPN.xcodeproj`，选择 `XDVPN-iOS` scheme 和连接的 iPhone，确认 App/PacketTunnel 两个 target 使用同一个开发团队。
3. 开发者账号及 provisioning profile 必须包含 Network Extensions（packet-tunnel-provider）、App Groups 和共享 Keychain 权限；App ID 与 Extension ID 分别为配置值及其 `.PacketTunnel` 后缀。让 Xcode 完成匹配签名后 Run。
4. 在手机打开设置页，填写本人获授权的测试账号。保存并允许添加 VPN 配置，先在首页保持「自动连接」关闭，手动连接验证。

2026-09-06 真机检查：已连接并配对实体 iPhone 17 Pro（iOS 26.6.1），开发者模式启用，Xcode 已将其识别为可运行目标。实际启用签名的构建在 App 和 PacketTunnel 两个 target 均报 `requires a development team`，尚未安装或运行。

已按用户选择检查 Tools UG：Xcode 的 Apple Accounts 页面显示 Admin，但 `Certificates, Identifiers, & Profiles` 标红不可用；工程 Signing & Capabilities 的 Team 菜单只有 Personal Team，没有 Tools UG。因此目前无法为此团队生成匹配的开发签名。需由 Tools UG 的 Account Holder 检查会员/协议状态及当前账号的开发资源访问。Apple 说明个人会员邀请的 App Store Connect 用户不属于其开发者团队，不能据 Admin 身份推定具备签名权限；Tools UG 的具体后台原因尚未确认（[Apple 角色与访问说明](https://developer.apple.com/help/account/access/roles/)）。本机当前可用签名 identity 为 0。后续可恢复团队开发资源访问后使用自动签名，或由团队提供有效的开发证书及对应私钥、App 和 Extension 的开发描述文件（包含测试设备及所需权限）后使用手动签名；手动签名不要求操作者具有后台证书管理权限。签名就绪后继续安装、连接及换网/锁屏验收。不能将无签名构建视为真机验证通过。

## 2026-09-07 真机验证进展

Tools UG 开发签名现已可用。已在独立 `codex/ios-support` worktree 完成 App 与 PacketTunnel 自动签名、描述文件权限核验，并在 iPhone 17 Pro（iOS 26.6.1）成功安装、启动及检查真实首屏。修复了 Xcode 空缓存首次构建时 pkgconf 宿主工具误继承 iOS 部署目标的问题；修复后完整签名构建及 39 项本地逻辑检查通过。

上文 2026-09-06 的签名阻塞为历史记录，当前已解除。后续调试已修复证书误用解析后 IP 校验及状态通知刷新循环，补齐 IPv4 全隧道支持；49 项本地逻辑检查通过。后续已完成 102 项配置、路由、恢复与连接质量检查。iPhone 已完成真实认证及 TLS 隧道连接、后台飞行模式恢复、质量统计持久化和手动断开后正常上网；用户确认内网业务正常，后台恢复时主 App 没有跳到前台。Wi-Fi/蜂窝切换、长时间锁屏等完整矩阵仍待测试。详见 [本轮真机验证记录](DEVICE-VERIFICATION-2026-09-07.md)。

## 建议首次验收顺序

| 次序 | 操作 | 验收观察 |
| --- | --- | --- |
| 1 | 手动连接，打开仅内网可访问的 HTTPS 地址 | 系统连接、隧道地址、真实上/下行包和业务响应均正确 |
| 2 | 在允许/禁止 UDP 的受控网络验证默认传输策略 | 允许 UDP 时观测 DTLS；禁止 UDP 时能使用 TLS |
| 3 | 已连接时 Wi-Fi ↔ 蜂窝，断网后恢复 | 不重复并发登录，恢复事件可解释，业务重新可用 |
| 4 | 首页开启「自动连接」，确认仍未连接，再点击「连接 VPN」 | 首次连接由按钮触发；之后锁屏 5/30 分钟或隔夜后，直接打开内网业务 App，验证系统恢复 |
| 5 | 手动断开 | 网络变化或重新打开 App 后仍暂停，重新点击连接才重新启用 |
| 6 | 使用测试环境验证过期会话/错误证书等 | 停止无效认证，界面解释原因，不持续提交错误密码 |

新「自动连接」使用系统 Connect 规则，不要求输入内网域名。HTTPS 手动验证地址与按钮已移除；旧版本自动连接保存的域名与探测规则继续按原条件工作，重新开启新开关后才切换规则。系统状态和包计数不等于业务成功，请实际访问内网业务确认。

On Demand 不能保证每次解锁立即连接，网关要求 MFA、首次解锁前凭据不可用、系统终止等情况不能由客户端绕过。恢复耗时、耗电、NAT64、服务端会话策略和实际 On Demand 行为仍须真机验证。

## 已完成的验证（2026-09-06）

- arm64 iPhoneOS 与 arm64 iPhoneSimulator 引擎构建，完整 App/Extension 无签名构建通过。
- 39 项配置、路由、IPv4/IPv6 帧、持久化恢复预算的本地检查通过（详见 `scripts/test.sh`）。这些纯逻辑测试在开发 Mac 上执行，不依赖 macOS 客户端模块。
- 在 iOS 26.5 模拟器运行真实原生引擎，验证提前取消、离线等待取消、认证组选项提交和禁止重复密码提交。
- 真实 iOS 模拟器引擎连接回环地址的一次性自签名 TLS 服务：系统信任校验拒绝，服务端未收到 HTTP 认证请求。
- iPhone 17 Pro 模拟器中安装、启动并检查实际连接首屏；未将模拟器标记为可验证真实系统 VPN 的环境。
- 引擎全部静态库检查无 `fork/exec/posix_spawn/system/popen` 依赖；App 与 Extension entitlement 对齐，未引入 macOS 模块依赖。

模拟器原生回归命令（先启动指定模拟器，并构建引擎）：

```sh
Apps/iOS/scripts/test-native.sh SIMULATOR_UDID
# 可选：第二个参数传入本机临时的不受信任 HTTPS 测试服务，检查证书拒绝。
Apps/iOS/scripts/test-native.sh SIMULATOR_UDID https://127.0.0.1:TEST_PORT
# 可选第三个参数验证受信任网关证书；探测在 TLS 回调结束，不发送 HTTP/凭据。
Apps/iOS/scripts/test-native.sh SIMULATOR_UDID https://127.0.0.1:TEST_PORT https://vpn.example.com
```

截至 2026-09-07 未完成：Wi-Fi/蜂窝切换、锁屏/隔夜、IPv6-only/NAT64、Extension 系统终止与按需冷启动、耗电。完整矩阵见 [可靠性调研](../../docs/design/2026-09-06-ios-vpn-reliability-research.md)。

## 依赖与后续发布

`build-engine.sh` 固定源码及摘要，`patch-openconnect.py` 仅作用于 iOS 缓存源码：拒绝脚本/外部认证程序、只接受外部包 fd、移除身份切换。原始压缩包、修改后源码及许可证位于 `.build/engine/`，各端可独立更新版本。

公司 TestFlight 使用现有 App Store Connect 应用 XD VPN（Apple ID `6809404398`，Bundle ID `com.xd.vpn.ios.poc`），版本 `0.1.0`。上传前递增 `Configuration/Base.xcconfig` 中的构建号，以 Release 配置 Archive，使用公司团队自动签名导出到 App Store Connect。TestFlight 处理完成并可测试后才算完成发布；不提交 App Store 正式审核。保留每次构建对应的源码、OpenConnect 修改及静态链接材料。


## TestFlight 自动化

API Key 配置、一条命令发布、状态查询和中断恢复见 [TestFlight 发布说明](TESTFLIGHT.md)。

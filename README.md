# XD VPN

一个为日常办公设计的原生 macOS VPN 客户端。SwiftUI 界面，OpenConnect 连接引擎，兼容 Cisco AnyConnect 用户名／密码认证。

完整设计与实现说明见 [技术方案文档](docs/technical-solution.md)（Markdown，含架构、UI、状态机、恢复清理与质量监控等 13 张图，并注明版本基线与开发增量）。

## 多端开发

[多端架构与 iOS 接入方案](docs/design/2026-09-06-ios-support.md) 采用同仓库、独立 macOS/iOS/Android 原生客户端、统一产品与视觉规范。各端独立实现配置、权限、连接生命周期与 UI，不共享 Swift 运行时代码包。

移动端的配置授权、Cisco/Hillstone 反馈、网络切换与休眠恢复实践见 [iOS VPN 可靠性调研](docs/design/2026-09-06-ios-vpn-reliability-research.md)。On Demand 与真机恢复验证提前纳入首个技术验证阶段。

根目录仍是现有 macOS 工程。`Apps/iOS` 已建立独立 SwiftUI + Network Extension + OpenConnect 验证版 0.1.0，安装与验证步骤见 [iOS 验证版说明](Apps/iOS/README.md)。已完成 iPhone 签名安装、真实内网访问、后台飞行模式恢复及连接质量统计验证；长时间锁屏、Wi-Fi/蜂窝切换等完整矩阵仍待验收。`Apps/Android` 已建立独立 Kotlin/Compose + VpnService + JNI OpenConnect 开发验证版，三个页签、配置、恢复与质量统计对齐 iOS；构建与安装见 [Android 说明](Apps/Android/README.md)，架构与最佳实践见 [Android 技术方案](docs/design/2026-09-07-android-support.md)。Android 真实网关和物理换网验收状态见其验证记录。两端均不依赖 macOS 的 `VPNCore`。

## 直接使用

**当前源码的目标正式版本为 1.1.22（build 31）。** 安装包以 [GitHub Releases](https://github.com/victorcheng2333/vpn_xd_client/releases) 实际发布内容为准；当前发布仓库公开，可直接下载和检查更新。1.1.10 已确认存在路由校验和清理回归。

按 Mac 芯片选择对应产物；打开 DMG 后，将应用拖到旁边的「Applications」文件夹：

| Mac 芯片 | 默认输出 |
| --- | --- |
| Intel | `build/XD-VPN-1.1.22-macOS-x86_64.dmg` |
| Apple Silicon（M 系列） | `build/XD VPN 1.1.22-arm64.app`、`build/XD-VPN-1.1.22-macOS-arm64.dmg` |

1. 在「VPN 配置」中填写服务器、用户名、VPN 密码。预填地址为 `vpn.xindong.com:8443`；已保存密码时输入框显示 `******`。
2. 点击「保存配置」。密码存入 macOS 登录钥匙串，普通配置中不包含密码。
3. 在连接页点击「启用系统服务」，按提示在 macOS 系统设置中批准后台服务，返回应用后会自动检测。若提示旧授权待迁移，先断开并退出旧版，再点击「迁移旧版授权」。日常连接无需重复授权。
4. 点击「连接 VPN」。助手确认网络脚本完成、IPv4／DNS 与服务器路由核对通过后，才显示已连接、真实分配地址和本次连接时长。点击「断开连接」结束连接。

从 **1.1.13** 起，应用内置 OpenConnect 9.21、静态链接的 OpenSSL 3.6.2 和 vpnc-script，使用者**无需安装 Homebrew 或 OpenConnect**。当前系统服务、内置引擎和网络脚本随签名 App 一起分发；连接页仅在需要启用、迁移或修复时显示提示。「VPN 配置 → 高级 · 系统服务」保留移除服务入口。

两个版本均支持 macOS 14 或更新版本，主程序、系统助手及内置引擎均为对应的单一架构。Intel 用户无需自行编译。

## Auto Connect 的行为

- 菜单栏图标：未连接为带叉盾牌，已连接为带勾实心盾牌，连接／恢复中为循环箭头，失败为带感叹号盾牌。使用单色模板图标，自动适应系统菜单栏外观。
- Auto Connect 是独立保存的配置，切换开关不会立即连接或断开；开启后，应用启动时自动连接，连接中掉线后按下面的策略重试。
- 连接存活由 OpenConnect 的 DPD 探测，配置间隔为 20 秒（`--force-dpd=20`）。这是隧道存活探测，不是每 20 秒重新登录；实际失联判定还取决于最近收到的数据和探测回应。客户端没有额外定时 ping 公司业务网站。
- 物理网络断开时，已建立的会话暂停客户端主动恢复与恢复期限，不主动发送断开或 SIGUSR2。网络重新就绪后尝试恢复旧会话。手动断开、退出和引擎自行结束仍会进入清理；尚未完成的首次登录会停止并核对部分配置，等网络恢复后继续。
- 系统唤醒、Wi-Fi SSID／链路变化、物理网卡 IP／网关变化会主动触发恢复，不等待 20 秒 DPD。通过 SystemConfiguration 读取同一物理接口的有效链路与可用 IPv4／IPv6 地址，不把 VPN 的全局路由或 DNS 状态作为网络就绪条件；只有链路、DHCP 尚未分配地址或仅有自分配／链路本地地址时继续等待。CoreWLAN 与 configd 使用同一个物理配置比较入口，重复的链路／电源通知不会再请求重连。SSID 变化通知仍独立触发恢复，不读取 SSID 或 BSSID；同地址同 SSID 漫游若没有可确认的配置变化，交由 OpenConnect 自身恢复。物理配置监听失败时才使用排除虚拟接口的 NWPathMonitor 回退。
- 网络就绪后约 1 秒防抖合并连续通知，向已建立的 OpenConnect 会话发送 SIGUSR2，立即重新建立隧道。Wi-Fi 切换时即使网络一直显示可用，也会触发；等待中的重试跳过原有退避时间。
- 助手 6 在 connect／attempt-reconnect／reconnect 钩子中核对到 VPN 服务器的 IPv4 主机路由。使用当前物理接口的作用域默认路由核对网关和源地址，读取完整路由表区分同地址的作用域缓存与无作用域静态路由；切网时对本次静态路由精确删除后重建，同时更新网关与源地址并读回验证，避免同为 en0 时仍保留旧源地址导致 `EADDRNOTAVAIL`。物理出口尚未就绪时推迟恢复；断开与异常退出会删除并复核本次创建的服务器路由。已有其他来源的静态路由不接管。详见 [服务器路由恢复设计](docs/design/2026-09-06-server-route-recovery.md)。
- 物理网络就绪只表示链路与地址可用，不保证能访问互联网。新 Wi-Fi 需要网页登录或无法访问 VPN 时，恢复期限到达后先清理失效隧道，让普通上网／认证页有机会恢复；Auto Connect 关闭时保持断开，开启时按退避重试。此策略有意缩短客户端等待旧会话的时间，不承诺保留 OpenConnect 完整的 300 秒窗口。
- 同一个 VPN 进程的两次主动恢复命令至少间隔 3 秒。冷却期间收到的新网络变化会保留，等防抖和冷却都结束后处理；单调时钟保证系统时间调整不会影响这个间隔。
- 物理网络仍可用时，主动切网与 OpenConnect 自己报告的掉线统一进入恢复流程，从本轮恢复开始计时 3 秒；仍未成功则停止旧进程、等其清理，Auto Connect 开启时再重新登录。关闭 Auto Connect 也会清理超时的失效隧道，但不会重新登录。重复掉线消息、重复网络通知和后续恢复命令不会延长本轮期限。初次登录期间切换网络，也会清理旧握手后重试。3 秒是等待旧会话的预算，网络就绪、防抖、清理和新登录仍各自需要时间。意外进程退出后的自动重试使用 3、6、12、24、48、60 秒退避。
- 已建立的会话在切网／掉线恢复中出现接口或路由配置失败时，等待旧进程清理后立即重新登录，不再将此类恢复错误直接视为永久失败，也不额外等待恢复期限或重试退避。若网络仍不可用则等网络恢复；如果全新登录仍出现配置错误，则停止并提示检查安装。认证和证书错误继续停止重试。
- 网络恢复、物理网络变化或系统唤醒会重置重试次数。新网络上的首次尝试若仍失败，从 3 秒重新等待，不沿用旧网络累计到的 60 秒退避。
- 忽略 utun 等 VPN 虚拟网卡、全局 DNS 和额外路由变化，避免 VPN 修改自己的网络配置引发重连循环。
- 睡眠或离线时暂停重试；网络恢复后再开始。1 秒是启动恢复的等待时间，不是保证 1 秒内连接完成，实际仍取决于 Wi-Fi、DHCP、VPN 服务端及认证。
- 密码错误、证书错误、需要额外认证或权限助手失联时停止本次自动重试，并显示可操作的错误提示，保留 Auto Connect 配置。
- **手动连接、断开或取消连接都不会改变 Auto Connect 配置**。手动断开只结束本次连接并取消待执行的重试／恢复任务；之后网络变化或系统唤醒也不会自动连上，直到再次点击连接或重启应用。重启后仍按保存的配置自动连接。
- 单独关闭 Auto Connect 不会断开当前连接。
- 未配置 VPN、删除密码或移除系统授权也不会改写 Auto Connect 配置；实际连接仍需先补齐配置、密码和授权。
- 关闭窗口后应用仍保留在菜单栏，连接与自动重连继续运行。菜单栏弹出紧凑面板，可查看状态／地址／时长，连接、断开、切换 Auto Connect，或打开连接、配置及日志。
- 选择「退出并断开」或按 Cmd-Q，会立即移除本应用菜单栏图标并退出。权限助手收到 shutdown／通道关闭后独立清理自己启动的 OpenConnect，完成后退出；不依赖 UI 等待最后一条状态回执。保留 Auto Connect 偏好供下次启动使用。
- 关闭窗口（红色 ×）继续留在菜单栏；这与退出应用不同。应用有单实例保护，重复打开同一客户端不会再创建菜单图标。其他 bundle ID 的同名 VPN 应用独立运行。
- Auto Connect 不是开机启动功能；本版未添加登录启动开关。
- 偏好与本次连接意图分离的设计说明见 [docs/design/2026-09-05-auto-connect-preference.md](docs/design/2026-09-05-auto-connect-preference.md)。

## 连接日志

「连接日志」页面的「打开日志目录」可打开 `~/Library/Logs/XD VPN/`。当前文件是 `activity.jsonl`，历史文件为 `activity.1.jsonl` 至 `activity.3.jsonl`。最多保留 4 个文件、每个 1 MiB；最新记录写满后轮转，重启应用仍保留历史。「复制日志」复制当前列表，「清空本次列表」不删除文件日志；需要删除历史时可在日志目录中删除这些文件。

每条 JSON 记录带 UTC 毫秒时间、应用版本、应用会话和连接尝试标识、事件来源、处理前状态及 Auto Connect 开关。记录物理通知的来源和变化字段名、重复通知被忽略、主动恢复／新登录请求、恢复超时、睡眠唤醒，以及脱敏后的 OpenConnect 输出。引擎诊断另带 PID、阶段、错误类别和可识别的 errno；路由诊断包含修改前、目标及读回结果的网关和源地址。未知错误、DTLS 失败、脚本超时、信号与退出状态均保留；重复通知与普通输出只写文件，不重置恢复计时。

文件目录权限为 0700、文件为 0600。日志包含诊断所需的服务器／本机地址、utun、PID 和清理记录路径；不保存 VPN 密码、Cookie、Token、认证正文或 SSID／BSSID。敏感输出保留脱敏占位记录，超长行带截断提示。App 后台串行写入，失败时提示且保留内存日志，不阻断 VPN；正常退出先排空写入，最多等 1 秒。

助手另在 `/Library/Logs/XD VPN/helper-<用户 UID>/helper.jsonl` 保存独立日志，最多 4 个 4 MiB 文件，目录和文件仅 root 可读写。App 退出或通信断开后，助手仍保存后续进程退出与清理结果；错误和停止事件执行刷盘。写入失败会告知 App 并写统一日志，不以静默丢弃代替记录。普通诊断严重级别不直接改变连接状态。版本 4 没有这些引擎输出，因此需要升级助手才能采集。

## 连接质量与告警（1.1.9）

侧栏「连接质量」显示此 Mac 最近 24 小时已保留事件的连接成功率、成功连接耗时 P95、恢复次数与连接耗时散点图。没有样本时显示「—」。成功率为成功 /（成功 + 失败），不包含尚未结束、用户取消、退出或切网中止的尝试；同一隧道恢复成功不会增加登录成功次数。恢复耗时写入日志，包含期间的离线与睡眠等待；这些场景有独立原因分类。

本地规则每 30 秒评估：近 10 分钟连续 3 次完成尝试失败、至少 5 次完成尝试且成功率低于 80%、至少 3 次引擎中断或意外结束，以及近 24 小时发现上次应用缺少正常退出记录。主动切网、物理离线和睡眠引起的恢复不触发频繁中断规则；同一次中断随后进程退出不会重复计数。告警在面板显示，首次触发和解除写入日志；重复评估不重复写入。退出记录缺失仅为异常退出线索，不能证明发生了崩溃。

仍使用原有 `activity*.jsonl`，新增 `schemaVersion=2`、构建号、系统版本和封闭字段的 `quality` 事件。`quality` 包含事件 UUID、Unix 秒时间戳、连接 ID、类型、原因和可选毫秒耗时；重启从轮转文件恢复，旧版日志可读取但不倒推不存在的质量指标。轮转可能让统计不足 24 小时，部分文件损坏时会提示统计不完整。日志仍只保存在本机；本版没有集中上传、消息通知、业务探测或崩溃堆栈采集。

后续集中 Dashboard、业务质量和崩溃分析的接入边界见 [质量监控设计](docs/design/2026-09-06-quality-monitoring.md)。

## 配置与密码

- 只保存一个 profile，可以修改名称、服务器、账号及认证组。
- 修改同一账号的配置时，密码留空会保留已保存的密码；更换服务器、账号或认证组必须重新填写密码。
- 「忘记已保存密码」从钥匙串删除该 profile 的密码。连接期间不允许修改配置。
- 密码使用 Security.framework 存入 `com.xd.vpn.credentials` 服务，本机钥匙串解锁时可读取，不同步到 iCloud。
- 服务器证书和主机名正常验证，没有跳过 TLS 校验的开关。内置引擎使用 macOS 自带的 `/etc/ssl/cert.pem`，不读取构建机的 Homebrew 证书目录，也不自动合并钥匙串中的自定义 CA。该信任集合可能与 Homebrew 汇总的证书包不同；企业私有 CA 场景尚未支持，不能假定与旧版等价。

## 编译、测试与线上发布

完整操作见 [GitHub Release 发布与更新](docs/releasing.md)，包含版本约定、公司签名、Apple 公证、GitHub Secrets 和客户端私有仓库配置。

```bash
# 日常开发，输出 build/dev/<架构>/XD VPN.app
bash scripts/build.sh
bash scripts/test.sh -c release
python3 -m unittest discover -s Tests/ReleaseTests -v
bash scripts/test-packaging.sh

# 测试分发：默认 test 渠道，显式构建号；产物名带 -test.32
BUILD_NUMBER=32 bash scripts/package.sh
```

正式发布默认在本机执行 `bash scripts/release.sh prepare v1.1.22`，完成 ARM／Intel 构建、测试、公司签名和 Apple 公证后，再用 `bash scripts/release.sh publish v1.1.22` 上传 GitHub Release。需要先提交代码并创建匹配标签，发布前推送版本提交和标签。GitHub Actions 保留手动发布入口。两条流程均强制签名与公证，验证实际票据、内嵌版本、渠道和源码提交后才发布；开发／测试包禁止进入正式 Release，已发布版本禁止覆盖。

客户端菜单「检查更新…」及侧栏版本号可打开更新窗口，正式版启动时按 24 小时间隔检查 GitHub Latest。私有仓库使用只存本机钥匙串的只读 Token；下载包通过大小和 SHA-256 校验后才可用于安装。升级前断开并退出，拖入 Applications，按提示升级系统助手；不自动替换运行中的应用或助手。

需要 Xcode 或支持 Swift 6 的 Command Line Tools。引擎由固定 SHA-256 的 OpenConnect／OpenSSL／vpnc-script 源码构建，支持 macOS 14+。构建缓存按架构和工作区路径隔离；可设置 `ARCHS=arm64` 或 `ARCHS=x86_64` 交叉构建。`CONFIGURATION` 控制编译优化，与 `BUILD_CHANNEL` 独立。

`scripts/test.sh` 使用 `.build/openconnect/<本机架构>/runtime` 中的引擎和脚本，缺少时先运行 `bash scripts/build-openconnect.sh`。引擎验收可运行 `python3 scripts/verify-bundled-engine.py '<应用路径>' --arch arm64`；在 Apple Silicon 上运行 Intel 产物需要 Rosetta，Intel 真机与 macOS 14 的实际 VPN 兼容仍需实机验收。

## 实现结构

```text
Sources/
  XDVPN/          SwiftUI 页面、菜单栏、钥匙串、连接状态管理
  XDVPNHelper/    按需启动的管理员权限助手
  VPNCore/        输入校验、OpenConnect 进程管理、通信及重试策略
Tests/
  VPNCoreTests/   命令参数、通信、凭据边界与进程清理测试
  XDVPNTests/     Auto Connect、取消授权、网络恢复与退出状态测试
scripts/          编译、测试、矢量图标生成
```

系统服务使用 macOS 14+ 的 `SMAppService` 注册，助手位于签名 App 内的 `Contents/Library/LaunchServices/com.xd.vpn.helper`，由 launchd 通过 XPC 按需启动。首次需管理员在系统设置批准后台服务；新安装不写 sudoers，不通过 sudo 或 AppleScript 提权。App 必须位于 `/Applications`，开发用临时签名构建不能启用特权服务。

App 与服务在激活 XPC 连接前双向约束公司 Developer ID、Team ID、精确应用／助手标识，并拒绝可调试或禁用库校验的签名。服务从内核 XPC 凭据获取调用者 UID，握手核对协议版本、构建标识及 App 路径。接口只有固定 VPN 控制、状态查询与旧版迁移，不接受客户端指定的程序、脚本、PID 或用户身份。每次启动引擎前复核完整 App 签名及引擎内容，升级后需重新注册服务。引擎和清理程序从校验过的 root 私有副本运行，防止 App 替换影响活动连接的清理。

服务一次仅允许一个控制连接拥有隧道，拒绝其他连接操作或在清理中抢占。通信失效或服务收到停止信号时，保留会话锁直到现有引擎停止及清理流程完成。日常移除服务先等待会话结束，再注销 SMAppService。

OpenConnect 在助手中以前台子进程运行。密码经双向验证的 XPC 和引擎 stdin 传递，不放入命令行、环境变量、日志或临时文件。root 会话锁避免上次退出清理与下次启动重叠。应用关闭通信或崩溃时，助手只向自己创建的 OpenConnect PID 发出 SIGINT；8 秒后仍未结束则向同一 PID 发 SIGTERM，40 秒后仍无响应才向同一 PID 发 SIGKILL，普通停止信号不发送到整个进程组。重连前的 attempt-reconnect 阶段只执行原生服务器路由更新和读回核验，不再启动仅重复路由工作的 vpnc-script；物理出口尚未就绪时暂缓，真实路由错误仍报告失败。其他阶段的网络脚本由固定助手入口启动，在执行任何脚本代码前以 posix_spawn 建立独立进程组；脚本超过 15 秒时结束该脚本组。reconnect 超时返回非致命结果，保留现有会话由 OpenConnect 继续恢复；connect 超时仍按配置失败清理。disconnect 在脚本前先删除本次 IPv4/DNS 状态、保留归属标记，脚本结束后再次删除并复核；即使脚本超时，只要原生复核通过就正常结束断开。这些时间是本客户端的停止预算。连接状态只由已知规则改变；其他引擎输出经脱敏后作为独立诊断写入助手与 App 的滚动日志，界面最多显示 300 条状态与错误。普通 stderr 错误不会直接触发 UI 拆隧道。

助手在脚本写入前，将本次 PID、utun、分配地址和 DNS 记录到 root 私有目录，并写入独立的会话归属标记。disconnect 钩子执行前后、以及 OpenConnect 退出后，均通过 SystemConfiguration API 核对并删除本次 `State:/Network/Service/utunN/{IPv4,DNS}` 残留；这一步不执行 route、DNS 查询或 shell。归属不匹配、地址／DNS 被更改、接口已被其他连接复用或删除结果未通过复核时，报告具体 PID、utun、键名及记录目录，并阻止未清理时继续登录。退出后给接口异步销毁最多 2 秒，每次重读归属与地址；清理失败后再次连接先重试。新助手也会检查本客户端的私有遗留记录；助手和脚本的共享锁、存活 PID、同名接口和归属检查共同保护仍在使用的配置。旧版本 3 的无锁记录至少等待 60 秒，避免清理仍在运行的旧脚本。详情见 [清理设计与边界](docs/design/2026-09-06-network-cleanup.md)。

旧版迁移必须在新服务可用后由连接页的「迁移旧版授权」明确发起。它核验固定旧路径、规则内容、进程和全部旧会话锁，先撤销旧 sudoers，再将旧助手／运行时移入 `/Library/PrivilegedHelperTools/.xdvpn-legacy-backups/` 的 root 私有备份。冲突或中途失败恢复原文件，不修改其他授权规则。详见 [迁移设计与验收边界](docs/design/2026-09-07-service-management-xpc.md)。

## 验收与限制

自动化测试覆盖输入边界、密码传输、不可信参数不经 shell 执行、套接字身份检查、连接建立识别、错误分类、子进程正常清理、Auto Connect 取消／恢复、睡眠／同为在线的 Wi-Fi 切换、网络通知合并、恢复超时后顺序重建、路由变化过滤、权限安装脚本解析、退出偏好等。测试使用本地替身进程；另有内置 OpenConnect 对 `127.0.0.1:1` 的失败路径测试，不访问公司 VPN。

自动化测试覆盖离线暂停、在线恢复、手动断开，以及慢清理子进程超过 TERM 升级期限、OpenConnect 异常退出／不响应、配置删除失败、误删保护和重复清理。另运行内置 vpnc-script 的实际逻辑，以隔离文件与命令替身重现路由处理阻塞、尚未执行 scutil 的路径，再验证助手的原生清理策略。动态存储写入测试使用可注入存储；没有删除真实 VPN 的系统键，也没有切换本机 Wi-Fi。本轮另覆盖服务器路由的网关／源地址更新、内核缓存重建、归属保护、修改意图持久化及异常退出清理。历史版本 1.1.11 的首次真实连接、服务器路由添加与完整枚举核验、百度 HTTPS 及 VPN DNS 响应均已通过。本轮已完成新版系统服务升级、真实 VPN 连接、内网页面访问、手动断开清理、约 20 秒 Wi-Fi 中断恢复和短暂睡眠／唤醒恢复；长时间睡眠、Intel 真机及 macOS 14 真机的实网兼容仍未覆盖。详细记录见 [验证记录](VERIFICATION.md)。

该版本针对示例中的用户名／密码认证。需要短信验证码、交互式 MFA、浏览器 SSO、设备证书或 CSD/HostScan 的服务器不在当前支持范围；不会把公司二次认证绕过去。日志遇到额外认证要求会停止重试。示例脚本也提示，公司 VPN 可能无法在办公网络内使用。

开发参考：[公司示例脚本](https://git.tapsvc.com/-/snippets/92/raw/master/bin/xd-vpn)、[OpenConnect 官方手册](https://www.infradead.org/openconnect/manual.html)。

内置引擎的独立验收：`python3 scripts/verify-bundled-engine.py "build/XD VPN 1.1.22-arm64.app" --arch arm64`（Intel 对应改为 `x86_64`）。它将引擎移动到带空格的临时目录，禁止读取 Homebrew 与工作区，验证本机 TLS 信任链／主机名校验及连接失败路径，不建立 VPN。需要允许启动子沙箱和本机回环通信。

应用内保留第三方许可证；分发 DMG 不附带源码归档和重建脚本，构建用源码仍缓存在 `.build/openconnect/downloads/`。构建选项依据 [OpenConnect 官方构建说明](https://www.infradead.org/openconnect/building.html)，许可证见 [OpenConnect 官方许可证](https://www.infradead.org/openconnect/licence.html)。

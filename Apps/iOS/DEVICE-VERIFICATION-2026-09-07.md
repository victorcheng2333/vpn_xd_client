# iOS 真机验证记录（2026-09-07）

本轮已完成签名构建、实体 iPhone 安装、启动、真实 VPN 认证和 TLS 隧道连接；用户确认内网业务已正常。切网、锁屏、DTLS 和长时间恢复验收仍待完成。

## 环境与结果

- 分支：`codex/ios-support`，基线 `2ea28ed`；独立 worktree：`/Users/chengfei/Documents/dev/vpn_xd_client-ios-support`。
- 设备：iPhone 17 Pro，iOS 26.6.1（23G83），USB 已配对，开发者模式启用。
- 团队：Tools UG（`KQY8A3BNVG`）；使用现有 Apple Development 证书和 Xcode 自动签名。
- App：`com.xd.vpn.ios.poc`；扩展：`com.xd.vpn.ios.poc.PacketTunnel`；App Group：`group.com.xd.vpn.ios.poc`。
- App 与 PacketTunnel 描述文件均包含该测试设备；所需 Network Extension / App Group 权限在描述文件允许集合中，App ID 匹配。
- 完整 arm64 iPhoneOS Debug 签名构建成功，`codesign --verify --deep --strict` 通过。
- 10:42 真机安装与启动成功；10:43 仍观测到主 App 进程；Xcode 真机截图确认首屏正常显示「尚未连接」，三个 Tab 可见、文字及按钮无裁切。
- 39 项现有 iOS 配置、路由、包处理与恢复逻辑检查通过；权限一致性和平台依赖检查通过。这些逻辑检查在 Mac 上执行。

## 本轮修复

新 worktree 的空缓存触发 pkgconf 宿主工具首次构建失败。Xcode 构建阶段导出 `IPHONEOS_DEPLOYMENT_TARGET`，即使脚本切换到 Mac SDK，clang 仍生成 iOS 可执行文件，configure 的运行探测被系统终止。

在仅构建宿主工具的子 shell 中清除移动平台部署目标，并显式通过 macOS SDK 选择 clang。原失败日志保留；修复后同一真机 Xcode 构建成功，产出的 pkgconf `LC_BUILD_VERSION` 为 `MACOS`，实际执行 `--version` 返回 `3.0.6`。

## 证据

本机忽略目录 `Apps/iOS/.build/validation-20260907/`：

- `device-build.log`：修复前首次构建失败。
- `device-build-fixed.log`：修复后完整签名构建成功。
- `logic-tests.log`：39 项逻辑检查和权限/依赖检查。
- `signing-check.json`：App/Extension 签名及描述文件检查。
- `install.json`、`launch.json`：CoreDevice 真机安装和启动结果。
- `app-processes.json`：仅本应用的后续进程检查。
- `device-launch.png`：真实 iPhone 首屏截图。

`Configuration/Signing.local.xcconfig` 已按本机团队配置，保持 Git 忽略。

## 首次安装时计划的实网验收（连接与业务验证现已完成）

1. 手机设置中输入本人获授权的测试账号和仅内网可访问的 HTTPS 地址；先关闭按需恢复，保存并允许系统添加 VPN 配置，手动连接。
2. 连接后刷新诊断，核对真实上/下行包、隧道地址和内网 HEAD 响应；HTTP 401/403/302 仅证明收到服务响应，不等同业务授权成功。
3. 对比 DTLS 开关、Wi-Fi/蜂窝切换及断网恢复，记录恢复耗时和业务结果。
4. 验证手动断开保持暂停，再验收按需恢复、锁屏和冷启动。

本记录不将成功签名、安装或首屏显示视为 VPN 连接成功。

## 11:16–11:31 连接失败调试与修复

### 证书域名误判

手机最初显示证书不受信任/过期/域名不匹配。网关返回的 `*.xindong.com` 证书处于有效期且链完整，单独 SecTrust 验证通过；同一 OCEngine 桥接代码在 Mac 上复现 `NSOSStatusErrorDomain/-67602`（主机名不匹配）。

根因：`openconnect_get_hostname()` 可返回解析后的网关 IP，原实现错误地用它匹配 DNS 证书。改为 `openconnect_get_dnsname()`；OpenConnect 9.21 的公开头文件明确此 API 用于证书验证回调。保留系统完整证书链、有效期和域名校验；没有跳过证书验证。补充不含凭据的错误域/错误码及链数量诊断。

证书回归使用同一桥接实现和本机固定版本的 macOS OpenConnect 库：有效域名证书接受、自签名证书拒绝、使用 IP 导致域名不匹配时拒绝。所有探测均在证书回调终止 TLS，不提交 HTTP 或账号密码；本地自签名服务确认没有收到 HTTP。此项是 Mac 原生桥接回归，不是 iOS 模拟器运行结果。修复后手机实际认证成功。

### 网关 IPv4 全隧道兼容

证书修复后，真机事件进入「正在建立隧道」，随后被验证版的单地址族全隧道限制拒绝。公司网关下发 IPv4 默认路由，没有提供 IPv6 隧道。

新增「全隧道模式」，本机该配置已启用并保存。通过 `NEVPNProtocol.includeAllNetworks` 执行系统全隧道约束；IPv4-only 网关下为 IPv6 设置仅本地阻断地址和默认路由，包桥接明确丢弃 IPv6，不向 IPv4 网关转发，也不将阻断地址展示为网关分配地址。系统蜂窝、APNs 和设备通信例外沿用系统规则。显式排除路由、IPv6 单栈全隧道及混合全/分流策略仍拒绝，避免悄悄改变网关策略。全隧道模式与网关分流模式不一致时给出明确错误。

此策略使用 [Apple 的全隧道路由接口](https://developer.apple.com/documentation/networkextension/nevpnprotocol/includeallnetworks)。Apple 说明 `includeAllNetworks` 不遵循显式 `excludedRoutes`，因此当前实现对这类配置拒绝执行（[Apple 工程师说明](https://developer.apple.com/forums/thread/832079)）。IPv6 阻断路径已完成逻辑检查；尚未用外部 IPv6 服务进行完整的流量泄漏验收。

### 状态通知循环

设备 CPU 报告显示旧版在约 130 秒内使用 90 秒 CPU。符号化调用栈为状态通知 → `VPNModel.load()` → `refreshDiagnostics()` → `SharedStore.read()`；重新加载管理器又产生状态通知，造成循环。

通知处理改为只响应当前管理器的连接对象并刷新状态/诊断，不重新加载所有配置；加载入口增加防重入保护。修复后采集约 11 秒 Time Profiler：129 个运行采样、约 0.129 秒采样权重，没有出现旧的 `VPNModel.load()` 刷新调用链。该短时记录含用户交互/切换应用，不等同受控耗电或长期稳定性测试。

### 真机结果

- 11:28:33：真实证书验证、用户名密码认证和隧道建立成功，系统状态「已连接」，传输为 TLS。
- 设备诊断确认上行 365 包、下行 326 包；29:03 的诊断仍为已连接。丢弃计数包含刻意阻断的 IPv6，不能直接解释为链路丢包率。
- 用户随后明确确认「内网业务已正常」。这是用户在手机上的业务验证结果；本轮没有另外发起自动 HTTPS HEAD 业务探测。
- 49 项配置、路由、帧处理和恢复检查通过，含旧配置兼容、全隧道选择持久化、IPv4-only 的 IPv6 阻断、双栈转发、冲突排除路由/混合策略拒绝。
- 修复后的 iPhoneOS 签名构建、安装和实际连接通过。手机保留连接状态。

新增证据：`certificate-regression.log`、`certificate-fixed-build.log`、`device-before-full-tunnel.json`、`full-tunnel-build.log`、`device-connected.json`、`app-cpu-before.ips`、`app-cpu-fixed.trace`、`app-cpu-fixed.xml`、`app-cpu-summary.json`。

### Debug 诊断入口

仅 Debug 构建支持显式启动参数 `--debug-export-vpn` 或 `--debug-connect-saved-vpn`；后者仅使用已在手机保存的配置/钥匙串凭据。`--debug-enable-full-tunnel` 可在上述调试连接前保存全隧道选项。普通启动不自动执行这些动作，Release 不编译该入口。

显式调试启动后最多 30 次按秒导出非敏感状态至 App Documents 的 `debug-vpn-validation.json`，内容不含用户名、密码、Cookie、Token；诊断导出方便避开本机 CoreDevice 共享容器导出的错误。后续真机调试可以直接读取该文件。

## 合并主分支与 iOS 界面更新

仓库主分支实际为 `main`，不存在 `master`。合并本地主分支 `3f6a5a6` 至 `codex/ios-support`，合并提交 `064bd60`，无冲突。

- 新增 1024 × 1024 不透明 App Icon，沿用 macOS 深绿底色、薄荷色盾牌与电源符号，iOS 使用满版图形和系统圆角。资源加入项目生成器及 App Resources。
- 移除认证组输入，保留已保存配置及引擎认证组选项兼容。
- 连接中/恢复中采用 macOS 相同蓝色 `#326CB0` 和两秒一周旋转圆弧；已连接使用绿色 `#227858`，断开中使用灰色 `#626D7A`。后台和减少动态效果模式暂停圆弧动画。
- iPhoneOS 签名构建及 iPhoneSimulator 构建通过；签名严格验证通过；49 项现有逻辑检查通过。
- iPhone 17 Pro 模拟器检查连接中与已连接画面，间隔截图确认圆弧位置变化；设置页无认证组输入。预览状态仅在模拟器启动参数下启用，不是真实 VPN 连接结果。

### 覆盖安装后的网络故障（重启后网络恢复）

新版已在真机成功安装，但启动被 iOS 拒绝，用户确认提示「无法验证 App／开发者」，随后反馈手机无法正常上网。包签名和描述文件检查正常，设备已登记，进程检查未见 App 或 PacketTunnel 运行。

本次覆盖安装前未先断开仍连接的全隧道，这是安装流程遗漏。现象与全隧道更新时系统保留网络拦截的问题一致（[Apple 开发者论坛](https://developer.apple.com/forums/thread/774231)），尚未通过设备系统日志确定完整因果。已请用户在系统设置停用按需连接并断开 VPN，必要时删除该系统 VPN 配置以恢复网络。用户反馈仍无法上网，下一步删除配置后重启，先验证蜂窝联网。新版真机启动和重新连接尚未通过，不能以此前版本业务成功替代新版验收。

本轮构建日志为 `ui-device-build.log`、`ui-simulator-build.log`；真机安装结果为 `ui-device-install.json`。

### 网络恢复与模拟器补验

用户确认重启 iPhone 后网络恢复。按用户要求，随后停止真机安装及连接验证，仅在模拟器继续检查；新版的真机开发者验证、启动和 VPN 重连留待用户返回后继续。

iPhone 17（iOS 26.5）模拟器补验：默认未连接画面、蓝色连接中动画、绿色已连接状态及设置页均正常；蓝色连接中画面在浅色和深色外观下检查，之后已恢复浅色。设置页无认证组输入；预览连接状态下配置编辑被禁用。模拟器屏幕中的「已连接」由预览参数提供，不代表真实 VPN。

保存的截图：`ui-connecting-light.png`、`ui-connecting-dark.png`、`ui-connected-light.png`，位于同一本机忽略的验证目录。

## 12:28 起新版真机复验

- 设备已恢复联网，开始复验时发现 App 已卸载；重新安装原签名构建，未在活动隧道上覆盖安装。
- 12:29:22 解锁后启动成功，开发者验证阻塞已解除。首屏截图确认新版未连接样式及布局正确。
- 用户重新填写凭据并保存系统 VPN 配置。第一次认证成功，但保存的全隧道选项仍为关闭，网关下发默认路由后按策略拒绝。通过现有 Debug 启动参数保存全隧道选项后重试，没有修改二进制或重新安装。
- 12:31:07 真实认证和 TLS 隧道建立成功；12:31:19 诊断为已连接，上行 100 包、下行 83 包。IPv4 全隧道下的 IPv6 阻断生效路径记录正常；该计数不代表额外完成流量泄漏测试。
- 真机截图确认绿色盾牌、真实隧道地址和「按需恢复已暂停」，无模拟器预览参数。首次/已连接画面分别保存为 `ui-device-idle.png`、`ui-device-connected.png`。
- 本轮证据另含 `ui-resumed-install.json`、`ui-resumed-launch.json`、`ui-resumed-state.json`、`ui-device-connect-launch.json`、`ui-device-connected.json`，均在本机忽略的验证目录。
- 用户确认「内网访问 ok」，随后确认「断开后上网正常」。12:34:33 系统停止隧道，最终统计上行 2332 包、下行 2526 包。
- 12:34:59 重新启动 App 仅导出诊断；12:35:09 读取结果为「尚未连接」，未自动重连。诊断保留的 TLS 和包计数属于刚结束的会话，不表示仍连接。
- 手动连接、业务访问、正常断开和重新打开 App 保持断开这条验收链路通过。设备保留已断开状态，按需恢复未启用。新增证据 `ui-device-disconnected.json` 和 `ui-device-disconnected-launch.json`。换网、锁屏及长时间按需恢复不在本轮通过范围内。

## 首页自动连接与文案整理

- 按用户反馈将主按钮简化为「断开」，移除设置页「连接后启用按需恢复」及域名输入，在主按钮下方提供一个「自动连接」开关。
- 自动连接是系统 On Demand 能力的产品入口，显式开启后使用 `NEOnDemandRuleConnect`，联网请求可由系统触发 VPN；无需常驻主 App。关闭开关只关闭后续自动触发；手动断开先持久化禁用系统规则再停止隧道，偏好保留但自动连接暂停，App 重启不撤销暂停。
- 新配置字段 `autoConnect` 可选，缺失时保留旧 `onDemand`、域名和探测条件，避免升级或普通保存扩大触发范围。主动修改新开关才切换为新的规则。开关直接保存已存在的配置，不会顺带保存尚未提交的用户名/服务器/密码编辑。
- 61 项配置、路由、恢复和规则检查通过，新增 12 项覆盖默认关闭、旧配置解码、域名范围保持、显式关闭覆盖旧开关、无域名启用、Wi-Fi/蜂窝规则及手动验证 URL 不影响新自动连接规则。
- iPhone 17 模拟器检查通过：首页首屏显示「断开」及「自动连接」，设置页没有旧按需恢复开关和域名输入。模拟器未配置账号，因此开关禁用并显示先保存账号的说明。
- iPhoneOS 签名构建和模拟器构建通过；具备系统钥匙串访问权限的环境下严格签名校验通过。本次构建日志：`auto-connect-device-build.log`、`auto-connect-simulator-build.log`。真机在此次修改期间已断开，新的自动连接开关尚未在真机运行验证，不能用前一版手动连接结果代替。
- 界面证据：`auto-connect-home.png`、`auto-connect-settings.png`。

## 12:55–13:07 设置精简与开关语义真机回归

- 用户要求去掉 HTTPS 内网验证地址、全隧道模式和 DTLS 开关。设置页最终只保留服务器、用户名、密码和保存操作；移除手动 HEAD 探测执行代码和诊断入口。路由/传输能力保留，新配置默认公司网关所需全隧道、DTLS 优先及 TLS 回退。旧配置显式策略保持兼容，缺失全隧道字段时使用公司默认值。
- 用户明确纠正「自动连接」是配置开关，不能开启即连接。修正为未连接时只保存偏好；点击「连接 VPN」才启动并按偏好启用系统恢复；手动断开后保持暂停。13:02 导出确认 `autoConnect=true`、`automaticConnectionActive=false`、系统状态「尚未连接」，用户确认设置页正确。
- 修复保存偏好时连接主按钮短暂变灰/闪烁：独立 `savingAutoConnect` 状态，主按钮与连接动画不再使用配置保存状态；同时连接/断开/保存操作等待已在进行的偏好保存任务，避免配置写入交错。用户在最终真机版本上确认「不再闪烁，仍未连接」。
- 密码行为已由用户真机确认：实际保存后展示 `****`；空配置仍显示「密码」，与用户名使用相同系统占位色。占位星号不作为真实密码提交，未修改时保留原钥匙串引用。
- 63 项配置/路由/恢复/系统规则检查通过，最终 iPhoneOS 签名构建与模拟器构建通过，严格签名校验通过。
- 调试连接过程中 USB 已识别但 CoreDevice 通道不可用，重启用户级 CoreDeviceService 后恢复。每次覆盖安装前均读取设备状态并确认隧道与系统自动连接都已停止。13:05:54 最终覆盖安装成功；首次启动短暂遭 iOS 安全校验拒绝，13:06:18 重试启动成功，无需再次修改签名或重装。收尾导出时设备调试通道已不可用，最终交互回归以用户反馈为证，不将之前导出的快照冒充最终实时状态。
- 证据目录内保存 `controls-final-install.json`、`controls-final-launch.json`、`controls-preference-only.json`、`controls-before-flash-fix.json`；构建日志为 `controls-device-build.log`、`controls-simulator-build.log`。较早版本开启即连接的记录为已纠正的历史行为，不是最终产品语义。

## 13:08 起飞行模式后恢复失败修复

- 用户报告开关飞行模式后不能自动恢复。13:12:26–13:12:30 的真机记录显示：重新启动隧道、认证、进入建立隧道阶段，随后提示「认证被拒绝或会话已过期」并持久化暂停恢复。13:14:38 的新导出确认已断开、系统自动恢复关闭。
- 代码核对发现：OpenConnect 9.21 在 HTTP CONNECT 收到 401 时返回 `-EPERM`，旧 provider 将该返回值与密码表单拒绝统一判为永久暂停。进入建立隧道事件意味着 `openconnect_obtain_cookie` 已成功；因此这次错误发生在会话建立阶段，不能直接推断为密码错误。旧记录在每次 extension 启动时清空，未保留飞行模式前完整过程；无法据此确定网关令会话失效的原因。
- OCEngine 现在明确记录认证完成标志。认证成功之后的 CONNECT 401 走受限的冷重连，重新从手机钥匙串读取凭据、获取新会话；实际认证表单拒绝、认证阶段权限错误、证书错误仍暂停。沿用五分钟最多三次冷启动的持久化预算，未取消重复认证限制。
- 最近 64 条事件跨 extension 重启保留，但每次会话的地址、传输、计数重新初始化。Debug 导出增加独立 `exportedAt`，区分导出时间和最近事件时间。
- 69 项逻辑检查通过。原生取消/认证表单测试通过；新增 loopback 假网关让真实 iOS 模拟器 OpenConnect 完成认证，再返回 CONNECT 401，验证 `authenticationCompleted=true` 且 `authenticationFailed=false`。该测试只使用虚构会话和凭据，仅测试可执行文件信任本地临时证书；生产证书验证逻辑未修改。复现命令见 README。
- iPhoneOS 签名构建及严格签名校验通过。确认断开后于 13:14:51 覆盖安装；13:15:37 使用已保存凭据启动调试连接，13:15:39 建立 TLS。13:15:46 导出为已连接、自动恢复启用，上行 85 / 下行 80 包。
- 修复版之后的事件显示 13:16:26 和 13:16:44 两次新建隧道，均于约一秒内建立 TLS；13:17:08 导出仍已连接，上行 3036 / 下行 3778 包。此次读取使用只导出诊断的启动参数，没有触发手动连接。随后用户针对飞行模式恢复后的业务复验明确确认「内网访问没有问题」，本轮自动恢复及内网访问真机验收通过；长期稳定性和连续多次快速切网不在本轮验收范围内。
- 证据：`airplane-failed.json`、`airplane-before-install.json`、`airplane-install.json`、`airplane-fixed-baseline.json`、`airplane-postflight.json`、`airplane-device-build.log`、`airplane-native-session.log`，位于本机忽略的验证目录。

## 连接质量页与后台统计

- 按用户确认，将原「诊断」标签升级为「连接质量」：当前系统状态、连续连接时长、TLS/DTLS、自动恢复是否生效；最近 24 小时恢复成功/失败、最近一次结果与耗时；异常操作建议、详细日志与分享报告。没有增加测速、延迟/丢包曲线、P95、内网探测地址或新的后台模式。
- 新增 Common/ConnectionQuality.swift 结构化状态机。扩展为质量历史的唯一写入者；主 App 在显式连接/断开时另写质量统计意图，记录独立会话 ID 和操作时间，不改变 VPN 行为。系统自动重启沿用原会话，重复网络/引擎事件合并为一次恢复；用户取消及手动断开不算失败。
- 质量数据通过 App Group 原子写入，沿用首次解锁后可用的文件保护。页面仅可见且前台时每五秒读取；主 App 进入后台或切换标签即取消读取循环，时长显示也暂停刷新。没有通过拉起主 App 采集后台事件。
- 同次设备启动内采用 mach_continuous_time 的单调时间计算等待/恢复时长；用启动时间识别设备重启。若扩展被终止前没有记录恢复起点，或跨设备重启导致时间不可比，则显示「未完整记录」。不会把扩展重启推断为崩溃，也不会把恢复后的冷连接用时当作整段断网耗时。
- 统计按最近 24 小时的结束事件计算，取消单列；最多保存 2048 条事件，损坏或裁剪时显示历史不完整。主 App 保存实际断开时间，避免扩展已停止时，同一个取消在次日刷新或再次连接时被重新计入。
- 102 项配置、路由、包处理、恢复和质量逻辑检查通过；新增 33 项覆盖重复回调、初次离线等待、已知/未知起点、跨扩展恢复、跨设备重启、系统时间变化、真实手动取消时间、窗口边界、容量上限和空记录。
- 模拟器检查浅色/深色、有记录预览和详细日志入口；预览明确标注「模拟器预览数据」，数据不落盘，未设置任何虚构密码。空记录检查使用仅导航到质量页的启动参数，不生成统计样本。模拟器不能验证真实 VPN 后台恢复。
- iPhoneOS 与 iPhoneSimulator 构建通过。设备查询显示 iPhone 17 Pro unavailable，USB 列表也未见 iPhone；本轮尚未覆盖安装到真机，未执行新版真实飞行模式统计和手动断开计数验收。已请用户断开 VPN 并连接、解锁设备后继续。
- 本机忽略的证据目录保存 quality-logic-tests.log、quality-device-build.log、quality-simulator-build.log，以及 quality-light.png / quality-dark.png。真机安装仍须先确认 VPN 与系统自动恢复已停止；读取诊断不得默认激活 App，以免干扰后台测试。

## 13:52 起连接质量页真机复验

- 13:52:33 新鲜只读导出确认系统「尚未连接」、`automaticConnectionActive=false`，随后覆盖安装连接质量版本。启动参数显式设置 `--no-activate`，CoreDevice 返回 `activatedWhenStarted=false`。
- 13:53:35 新版导出确认质量历史为空，没有将旧诊断日志回填为虚构统计，自动连接偏好仍开启但系统自动恢复未启用。用户确认空状态正确，随后手动连接成功。
- 13:54:37 真机截图确认连接质量页显示「已连接」、18 秒、TLS、自动恢复已启用，完成恢复/成功/失败均为 0，连接成功 1 次。用户确认界面正常。
- 13:55:00 基线导出保留首次连接成功记录，并新增一次 13:54:57 扩展重新启动后的恢复成功；会话 ID 沿用原连接，恢复起点未记录，因此没有伪造耗时。此前 13:54:50 执行过不激活主 App 的只读调试启动，两者时间相邻，现有日志不能确定重启原因；此记录不计作后续受控飞行模式测试的结果。
- CoreDevice 直接复制 App Group 文件仍返回「File paths cannot contain '..'」错误。后台飞行模式测试期间停止所有主 App 启动命令，以用户内网访问反馈、测试后真机页面和最终断开后的持久化导出核对统计。

- 用户按要求将主 App 留在后台，飞行模式且关闭 Wi-Fi 后恢复网络，明确确认「内网恢复正常，App 没有跳到前台」。13:54:50 基线采集之后直到 13:58:59 手动断开后的最终采集，没有再执行任何主 App 启动命令。
- 13:57:29 真机截图为完成恢复 4、成功 4、失败 0；最近一次恢复成功时间 13:56:18，耗时「不到 1 秒」。最终持久化导出确认三组新增事件：13:55:56 传输恢复（0.456 秒）；13:56:16–17 扩展重启后恢复（起点未记录、耗时为空）；13:56:17–18 传输再次恢复（0.384 秒）。每组有不同的开始/结束事件，与原始隧道日志对应，不是同一回调重复入账。一次飞行模式操作可包含多次隧道恢复过程；最近耗时只属于最后一次，不能解释为整个飞行模式断网时间。没有足够证据推断中间每次路径切换或扩展终止的具体系统原因。
- 用户手动断开并确认「断开后上网正常」。13:58:32 仅新增一个 `disconnected(user)`；最终仍为连接成功 1、恢复成功 4，连接/恢复失败及取消均为 0，活动统计会话和异常均已清空。
- 13:58:59 以 `--no-activate --debug-export-vpn` 重新启动主 App；13:59:30 新鲜导出确认「尚未连接」、`autoConnect=true`、`automaticConnectionActive=false`。质量历史跨主 App 重启保留，未因打开 App 重新启用系统自动连接。
- 本轮真实连接、质量页显示、后台断网后内网访问、无主 App 自动前台激活、恢复事件持久化、正常断开及再次打开保持断开均通过。长时间锁屏、设备重启、低电量和失败网络下的持久恢复不属于本轮真机通过范围；已有模拟器/逻辑回归不能替代这些真机场景。
- 新增本机忽略证据：quality-preinstall-state.json、quality-install.json、quality-installed-state.json、quality-baseline.json、quality-final.json、各次 launch.json，以及 quality-device-connected.png / quality-device-postflight.png。产品代码未因本轮验证发生修改。

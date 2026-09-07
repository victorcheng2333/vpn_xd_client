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
- 本轮证据另含 `ui-resumed-install.json`、`ui-resumed-launch.json`、`ui-resumed-state.json`、`ui-device-connect-launch.json`、`ui-device-connected.json`，均在本机忽略的验证目录。业务访问与手动断开后的联网结果待用户反馈。

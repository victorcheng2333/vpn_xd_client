# 验证记录

## 当前交付：1.1.8

2026-09-06。根据 Claude 运行质量报告修复 CoreWLAN 重复通知触发恢复，并增加 App 滚动文件日志。本轮不修改 VPNCore／系统助手，保留助手要求 4。

- configd 和 CoreWLAN link／power 共用物理快照比较；Active、IP、网关等实际未变化时不进入恢复流程。SSID 变化通知独立保留，不读取 SSID 或 BSSID。VPN 写入的无关路由字段也不会产生空快照变化。
- 重复通知仅写文件，不刷屏、不重置恢复计时。真正的变化、唤醒、新连接／恢复请求及恢复超时保留来源与原因，已有助手归一化消息标为 helper 来源。日志中的 reconnect.requested 表示 App 已发送请求，不单独证明底层信号已执行。
- 主 App 在 ~/Library/Logs/XD VPN 写入 activity.jsonl，最多 4 个 1 MiB 文件，跨启动保留。后台串行写入，正常退出等待排空，最多等 1 秒。目录 0700、文件 0600；拒绝活动日志的符号链接、硬链接及 FIFO，写入失败不会改变 VPN 状态。
- 「连接日志」新增「打开日志目录」，复制和清空仍针对本次列表，清空按钮提示保留文件日志。只写 App 诊断与已有助手消息，不采集原始 stderr、认证响应、配置、密码或 Wi-Fi 标识。助手本身过滤掉的 DTLS 失败信息、App 退出后的助手日志仍不在范围内。

验证：

- 初轮 App Debug 测试 **80 项通过**，记录 `.build/network-quality-app-tests.log`；随后补充 FIFO／退出保护，最终源码以 Release 测试。
- 最终 **124 项测试均有通过记录**。沙箱内运行 123 项，121 项通过、2 项既有 Unix socket bind 检查因环境限制失败，另 1 项 configd 只读检查暂未运行；随后获得权限，单独复跑这 3 项系统检查全部通过。记录 `.build/network-quality-tests-verified.log` 与 `.build/network-quality-system-tests.log`，逐项合并结果 `.build/network-quality-final-test-results.json`。第一次全量沙箱外请求遇到自动审批超时，未实际执行；没有改弱这些系统检查。
- 新增 12 项测试覆盖：多来源相同通知去重、相同 IP 的 SSID 通知、VPN 无关字段过滤；Auto Connect 开／关时，20 轮通知跨过多轮防抖／冷却均无额外命令；真正网关变化随后被第二来源复述只发一次恢复；持久诊断原因与凭据排除；跨启动追加、轮转限制、并发整行记录、权限、常见认证字段省略、链接／FIFO 拒绝、文件写入故障不影响连接及退出刷盘。
- Release 生产构建、Info.plist 版本、App 和助手严格签名验证、ZIP 完整性、`git diff --check` 通过。构建 `.build/network-quality-build.log`，打包 `.build/network-quality-package-verified.log`。本次复用 1.1.7 已验证的图标和助手，内置助手 4 与 1.1.7 文件 SHA256 完全一致；助手／VPNCore 源码与本轮开始时摘要一致。摘要 `.build/network-quality-helper-baseline.json`、`.build/network-quality-source-hashes.json`。

交付：`dist/XD VPN 1.1.8.app`、`dist/XD-VPN-1.1.8-macOS-arm64.zip`，build 11。已只读确认本机助手为 4，更新 App 无需再次升级助手或系统授权。

本轮没有启动新版、替换正在运行的 App／助手、切换 Wi-Fi、读取真实 VPN 凭据或改动真实网络配置。测试日志只写临时目录。特定 AP 的真实每 60 秒通知仍需更新后观察；同地址同 SSID 漫游若没有可确认的配置变化或 SSID 通知，仍交由 OpenConnect 自身恢复。详情见 `docs/design/2026-09-06-network-notifications-and-logs.md`。

## 历史交付：1.1.7

2026-09-06。根据用户提供的 Claude review 修复三个主要缺口，沿用其事故证据，不把自动化通过当作实网验收完成。

- `attempt-reconnect`／`reconnect` 的 15 秒 watchdog 超时返回非致命结果，不再经 OpenConnect 通用 Script error 触发助手主动拆隧道。真实非零脚本错误、初次 connect 失败和原生清理失败仍报告错误。
- disconnect 在运行 vpnc-script 之前清除本次 IPv4/DNS 状态并保留归属标记，脚本结束后再次删除并复核；脚本超时但原生复核成功时正常结束断开。手动断开期间通用脚本错误由最终清理决定，不误报登录配置失败。
- 接口退出检查等待最多 2 秒，每次重读归属、地址和 DNS，兼顾异步销毁与接口复用保护。失败日志包含 PID、utun、具体键和记录目录。再次连接先重试之前的清理，成功后才启动新隧道。
- 新助手连接前检查自己的遗留日志目录。助手和网络脚本持共享记录锁，扫描只处理可独占、记录 PID 不再存在的目录；继续核对归属和同名接口。旧版本 3 无锁目录等待至少 60 秒。不会强杀旧进程、绕过归属检查或全局清空 DNS。
- 现有物理网络恢复后的 3 秒期限保持不变：Auto Connect 关闭时也清理超时隧道，但不重新登录。物理就绪不是互联网可达的证明，不能承诺保留引擎完整 300 秒重连窗口。
- 助手要求升级为 **4**；界面区分「已授权但助手需升级」和「助手损坏／授权缺失」，说明已有授权保留、权限范围不变，并在升级成功后回到连接页。未建隧道的退出消息不再宣称完成网络清理。构建／测试缓存按工作区绝对路径区分。

验证：

- Debug 完整 **112 项通过，0 失败**，记录 `.build/review-fixes-tests-verified.log`；随后对锁的生命周期作显式保活和诊断补充，再以最终源码复跑 Release：**112 项通过，0 失败**，记录 `.build/review-fixes-release-tests.log`。
- 新增 13 项回归：包装器真实 watchdog 超时及返回值、disconnect 前后双重清理、初次 connect 失败、原生失败仍致命、真正脚本错误不掩盖、归属冲突诊断、接口延迟销毁／期间归属改变、活跃助手／脚本锁保护、遗留 PID／标记／删除失败、旧记录等待、同一助手失败后重试，以及授权升级分类等。
- 首轮沙箱内清理测试为 21 项通过、1 项失败：既有 configd 只读检查无法连接系统服务。获准在沙箱外复跑后完整通过；没有通过跳过该测试消除失败。相关记录 `.build/review-fixes-core-tests.log`。
- `bash -n`、`git diff --check` 通过。Release 构建、图标、应用与助手 ad-hoc 签名、严格签名验证、Info.plist、未授权脚本入口拒绝和 ZIP 完整性检查通过。沙箱内 iconutil 失败后，在沙箱外正常完成打包。记录 `.build/review-fixes-build.log`、`.build/review-fixes-package-verified.log`；源码摘要 `.build/review-fixes-source-hashes.json`。

交付：`dist/XD VPN 1.1.7.app`、`dist/XD-VPN-1.1.7-macOS-arm64.zip`，bundle ID `com.xd.vpn`，构建版本 10，内置助手 4。

本轮只读确认已安装助手为 **3**，没有替换当前应用／root 助手，没有提交真实 VPN 凭据、切换 Wi-Fi 或修改真实网络状态。使用新版需先断开并退出旧版，打开 1.1.7 后点击「升级系统助手」。真实公司 VPN 的关 Wi-Fi 30–60 秒后恢复、离线手动断开、需认证／无互联网的新 Wi-Fi、百度与公司域名及 DNS／路由状态仍需验收。自动化中的写入只针对临时文件、测试偏好和注入的动态存储，实际 configd 仅作读取。

## 历史交付：1.1.6（存在后续 review 所列缺口）

2026-09-06。根据用户提供的故障时间线和 OpenConnect 上游修复，重做异常退出后的清理保障。1.1.5 的“离线立即断开”方案撤回，不能作为该故障已解决的证据。

- 已独立复验 Foundation 信号行为：`Process.terminate()` 使孙进程收到 TERM；`kill(parentPID, SIGTERM)` 后孙进程完成原任务。实验只创建本地临时进程，记录在 `.build/cleanup-signal-evidence.log`。
- 核对上游 MR !425 和 9.21 的 script.c：网络脚本在独立进程组运行。使用 Homebrew 将本机 OpenConnect 从 9.12 升级为 **9.21**，所需依赖随包升级；保留旧安装目录，没有重启现有 VPN 进程。日志在 `.build/cleanup-engine-upgrade.log`。
- 已建立会话的物理断网现在只暂停主动恢复及其期限，等网络就绪再尝试恢复。不主动发送离线 disconnect；手动断开／退出、未完成登录的取消以及进程自行退出仍有清理保障。
- 助手停止信号均使用指定 OpenConnect PID，不再调用 Process.interrupt/terminate。网络脚本通过固定的 root 内部入口、posix_spawn 独立进程组和 15 秒预算执行；不响应的 OpenConnect 在 8 秒接收指定 PID 的 TERM、40 秒后才接收指定 PID 的 KILL。脚本超时后只终止该脚本组，随后原生清理。
- 脚本写入前记录本次 PID、utun、地址和 DNS，并建立会话归属标记。disconnect 钩子结束后和父助手收到进程退出后均核对本次动态服务键；删除不依赖 DNS／网关／shell，并读回核实。归属、内容或接口复用校验失败时不删除不明配置，报告清理错误并停止同一助手继续登录。
- **完整测试 99 项通过，0 失败**：60 项状态机、3 项模型／进程恢复集成、12 项网络清理、5 项网络监听与安装脚本、15 项原核心、4 项权限。记录在 `.build/cleanup-tests-verified.log`。
- 清理回归包含真实父子孙进程：慢清理跨过 TERM 期限后仍完成、子进程异常退出、不响应后只结束父 PID、清理失败先发 failure 再发 stopped 且拒绝下一次登录。配置测试覆盖正常脚本已清理、部分写入、重复清理、其他 VPN／Wi-Fi 保留、utun 复用、归属／DNS／地址不匹配及删除未生效。
- 本机 vpnc-script 的实际控制流在隔离文件／命令替身中运行，复现无默认网关时 route 阶段阻塞、尚未运行 scutil 删除的路径；停止该脚本后，助手的配置清理策略可独立移除测试残留键。此测试不操作真实路由或 configd 网络键；实际 SystemConfiguration 只做了缺失键读取验证。
- Release 构建、应用与助手 ad-hoc 签名、严格签名验证、Info.plist 与 ZIP 完整性验证通过，记录在 `.build/cleanup-build.log` 与 `.build/cleanup-package-verified.log`。助手版本已升到 **3**，普通 sudoers 规则不包含内部网络脚本入口。

交付：`dist/XD VPN 1.1.6.app`、`dist/XD-VPN-1.1.6-macOS-arm64.zip`，bundle ID `com.xd.vpn`，构建版本 9。退出旧版后打开新版，在「系统授权」更新一次助手；已安装的版本 2 不包含本次兜底，不能跳过更新。

1.1.6 打包完成当时，没有更新已安装的 root 助手、提交公司 VPN 凭据或切换实际 Wi-Fi；当时的 1.1.4 与 OpenConnect 会话 PID 保持不变，升级引擎后百度请求返回 HTTP 200。随后用户已运行 1.1.6 并安装助手 3；2026-09-06 本轮只读版本检查确认已安装助手为 3，前述历史状态不再代表当前安装。没有删除旧客户端助手、sudoers 或 Hillstone 卸载任务。

仍需在版本 3 助手下验收真实 Wi-Fi 关闭 30–60 秒再恢复，以及离线手动断开时的百度／公司域名与 DNS／路由状态。此次自动化验证不等于已完成实网故障复现。该兜底只处理本次可确认归属的 utun IPv4/DNS 动态键；持久 DNS、自定义脚本和助手本身被强杀后的跨启动恢复尚不在范围内。设计、证据来源和边界见 `docs/design/2026-09-06-network-cleanup.md`。

## 撤回方案：1.1.5

以下保留当时的检查记录。其测试未覆盖真实清理脚本阻塞及进程组信号，不能据此认定用户报告的问题已修复；本轮 1.1.6 已撤回离线立即断开的策略。

2026-09-06。修复离线后旧隧道持续占用网络、恢复依赖 VPN 全局网络状态的问题。

- 本机只读检查：当前默认路由经 utun4，默认 DNS 为公司 DNS 172.24.4.79；Wi-Fi 自身的 DNS 来自路由器，未设置静态 DNS。因此即使访问百度，也会受到 VPN 路由／DNS 失效影响。检查时旧版 1.1.4 已正常连通，`https://www.baidu.com` 返回 HTTP 200；没有捕获用户此前重启前的故障现场，不能认定唯一原因已由实网复现。
- 代码确认：原离线分支取消恢复期限但不停止 OpenConnect，网络就绪由全局 NWPathMonitor 决定。改为用 SystemConfiguration 的物理 en 接口链路与可用地址判断就绪，排除 VPN 虚拟接口与仅链路本地／自分配地址；CoreWLAN 通知也读取当前物理状态，首次启动即读取状态。物理监听注册失败时才使用排除 `.other` 的 NWPathMonitor 回退。
- 离线立即发出断开请求，等待旧子进程退出与 vpnc-script 清理，Wi-Fi 恢复不会提前启动新进程。Auto Connect 开启时清理后等待物理网络就绪再重新登录；关闭时同样清理失效隧道但保持断开。网络仍可用时保留 3 秒旧会话恢复机会，超时清理不再受 Auto Connect 开关限制。
- 尚未发送连接指令时统一处于准备状态，离线会取消待执行登录，避免向离线网络发送延迟指令或等待不存在的子进程清理。清理中手动停止只取消重启意图，不重复发出停止信号；旧会话延迟到达的连接成功事件不会打断清理。
- 在独立旧代码副本上运行断网回归用例，6 项选中测试共出现 17 条失败断言，记录在 `.build/offline-baseline-regression.log`。基线以 HEAD 的状态机与监听代码为基础，保留本轮开始时已有的 Messages.swift 常量修正以便编译；未覆盖工作区源码。
- 最终完整测试 **87 项通过，0 失败**（60 项状态机、3 项进程恢复集成、5 项网络与脚本、15 项核心、4 项权限），记录在 `.build/offline-tests-verified.log`。新增本地子进程用临时文件模拟默认路由／DNS 占用，验证长于清理时间的离线、清理中 Wi-Fi 恢复、连续两次重新登录、关闭 Auto Connect 后第三次离线清理；替身拒绝在旧配置未释放时开始新连接。
- 只读运行实际 PhysicalNetworkMonitor：SystemConfiguration 与 CoreWLAN 注册均成功，现有 VPN 运行时正确识别物理网络可用，记录在 `.build/offline-physical-probe.log`。此检查未切换网络。
- Release 构建、主程序／助手 ad-hoc 签名、`codesign --verify --deep --strict`、Info.plist 与 ZIP 完整性检查通过，记录在 `.build/offline-build.log`、`.build/offline-package-verified.log`。复用 1.1.4 图标。打包助手和已安装助手均为版本 2，无需更新系统授权。
- 默认构建缓存仍包含旧目录 `vpn_xd_client-astra`，本次使用 `.build/offline-recovery` 和独立模块缓存完成构建与测试，没有清除既有缓存。

交付：`dist/XD VPN 1.1.5.app`、`dist/XD-VPN-1.1.5-macOS-arm64.zip`，bundle ID `com.xd.vpn`，构建版本 8。断开并退出旧版后打开新版，配置和钥匙串沿用。

本次没有替换正在运行的 1.1.4、更新已安装助手、读取 VPN 密码或断开实际 Wi-Fi；旧版应用与 OpenConnect PID 保持不变。网络清理由既有 OpenConnect/vpnc-script 执行，本次未加入强制清空全机 DNS、删除其他 VPN 路由或修复历史孤立配置的功能。模拟测试验证清理请求与进程顺序，不证明真实脚本在所有网络状态下都能还原系统配置。

待实网验收：新版连接后关闭 Wi-Fi 30–60 秒，确认日志出现清理并进入等待；恢复 Wi-Fi 后检查百度与公司域名、自动登录恢复。再关闭 Auto Connect 重复，预期清理后保持断开，Wi-Fi 的普通上网可用。若仍失败，应在重启前保留连接日志以及 `scutil --dns`、`scutil --nwi`、`netstat -rn -f inet` 的只读输出，区分残留 DNS、路由与实际脚本清理失败。

## 历史版本：1.1.4

2026-09-05。将旧会话恢复窗口从 10 秒缩短为 3 秒。

- 1.1.3 的真实会话日志显示：23:44:15 开始恢复旧会话，23:44:25 达到 10 秒期限后清理并重新登录，同一秒新隧道建立。该次主要耗时来自恢复窗口。
- 将统一的旧会话恢复预算改为 3 秒，网络变化、唤醒和引擎自然掉线沿用同一恢复入口。仍在旧进程清理完成后才发起新登录；明确的接口／路由错误继续直接进入清理，不额外等待预算。手动断开和 Auto Connect 配置语义保持不变。
- 3 秒是为旧会话保留恢复机会的策略选择，并非协议要求或实网测得的最优值。实际断网到可用的总时间还包含网络就绪、防抖、进程清理和新登录。
- 完整测试 75 项通过，0 失败，记录在 `.build/fast-recovery-tests-verified.log`。既有恢复集成测试改用生产默认期限，验证不会提前放弃旧会话，并能在 6 秒测试限时内完成旧进程清理和新登录；其余状态机与错误恢复用例通过。
- Release 编译、主程序／助手 ad-hoc 签名、`codesign --verify --deep --strict`、Info.plist 和 ZIP 完整性检查通过，记录在 `.build/fast-recovery-build.log` 与 `.build/fast-recovery-package-verified.log`。

交付：`dist/XD VPN 1.1.4.app`、`dist/XD-VPN-1.1.4-macOS-arm64.zip`，bundle ID `com.xd.vpn`，构建版本 7。兼容现有版本 2 权限助手。

本次没有切换实际 Wi-Fi 或替换当前运行的 1.1.3；3 秒策略的真实网络恢复表现尚需实测。

## 历史版本：1.1.3

2026-09-05。修复 Wi-Fi 切换时接口／路由错误导致自动恢复停止的问题。

- 从正在运行的 1.1.2 会话日志确认：23:28:22 和 23:28:25 已触发网络恢复；23:28:25 报告「网络接口或路由配置失败」并退出；23:28:34 手动登录成功。自动连接配置仍为开启。问题发生在恢复错误处理阶段，网络变化通知已经送达。
- 已建立会话在恢复中出现这一明确的接口／路由错误时，保留本次连接意图，等待旧进程退出清理后立即发起新登录，即使原权限助手将退出标记为不可重试。离线时等待网络恢复；清理期间手动取消或关闭 Auto Connect 会取消待执行登录。
- 仅识别权限助手固定的规范化接口／路由错误消息，兼容已安装的版本 2 助手。初次／全新登录的配置错误、密码错误与证书错误仍停止重试，避免把持续故障变成重复登录。恢复期限触发的清理也不会被同类错误取消。
- 先新增回归用例复现原问题，修复前 4 条断言失败，记录在 `.build/wifi-recovery-reproduction.log`；修复后完整测试 75 项通过，0 失败（51 项状态机、2 项恢复集成、15 项核心、4 项权限、3 项网络过滤与脚本语法）。记录在 `.build/wifi-recovery-tests-verified.log`。
- 新增进程集成测试向本地替身发送真实 SIGUSR2，模拟脚本失败及延迟清理，验证旧进程结束前不会开始第二次登录、无需手动操作便恢复连接、手动停止后仍保留偏好并保持停止。沿用 10 秒恢复期限，测试确认明确失败后不等待该期限或 3 秒退避。
- Release 编译、主程序／助手 ad-hoc 签名、`codesign --verify --deep --strict`、Info.plist 和 ZIP 完整性检查通过。构建记录在 `.build/wifi-recovery-build.log`，打包验证在 `.build/wifi-recovery-package-verified.log`。

交付：`dist/XD VPN 1.1.3.app`、`dist/XD-VPN-1.1.3-macOS-arm64.zip`，bundle ID `com.xd.vpn`，构建版本 6。现有系统授权可继续使用，无需更新权限助手。

本次读取了真实会话日志，但没有切换实际 Wi-Fi、替换正在运行的 1.1.2 或重新发起公司 VPN 登录；新版真实切网恢复速度仍需实测。

## 历史版本：1.1.2

2026-09-05。将 Auto Connect 持久配置与本次连接意图分开。

- 只有用户切换开关才写入 Auto Connect 配置。手动连接、断开、取消、认证失败、助手退出，以及缺少配置／密码／授权都不会关闭该配置。开启开关只保存偏好，不直接发起连接。
- 手动断开取消本次连接、延迟重试和恢复任务；网络变化或唤醒不会重新拉起。再次手动连接可继续按配置重试，重启应用会重新读取保存的配置。启动自动连接任务也检查取消状态，避免用户先点断开后仍出现延迟登录。
- 主窗口与菜单栏开关统一为配置入口，断开清理期间也可编辑，不再要求先安装授权；实际连接仍保留原有配置、密码与授权检查。
- 完整测试 66 项通过，0 失败（43 项状态机、1 项恢复集成、15 项核心、4 项权限、3 项网络过滤与脚本语法）。记录在 `.build/auto-connect-tests-verified.log`。新增覆盖保存开关不连接、手动断开后保持停止、重新手动连接、重启读取偏好、启动任务取消及断开期间切换配置；原有恢复集成测试确认偏好保留时替身进程仍保持停止。
- 原 `.build` 缓存包含旧目录路径，改用 `.build/auto-connect` 构建目录和独立模块缓存。受限执行中的两项本地 Unix socket 测试失败，允许本地通信后完整复验通过。测试未连接公司 VPN。
- Release 编译成功，记录在 `.build/auto-connect-build.log`。复用 1.1.1 的图标，主程序／助手 ad-hoc 签名、`codesign --verify --deep --strict`、Info.plist 校验和 ZIP 完整性检查通过。助手仍为版本 2，授权兼容性未改变。

交付：`dist/XD VPN 1.1.2.app`、`dist/XD-VPN-1.1.2-macOS-arm64.zip`，bundle ID `com.xd.vpn`，构建版本 5。

本次没有启动交付应用或替换正在运行的客户端；真实公司 VPN 的睡眠／切网与路由恢复仍需实网验收。

## 历史版本：1.1.1

2026-09-05。本次落实重试逻辑审阅中的前三项：统一恢复超时、恢复命令冷却、网络变化后重置退避。

- 主动网络变化与引擎 DPD／连接失效消息进入同一个恢复入口。网络可用且 Auto Connect 开启时，本轮恢复最多尝试 10 秒，随后请求清理旧进程并在退出回执后重新登录。重复消息和网络通知不会重置期限。
- 保留 1 秒防抖，另用单调时钟限制同一进程两次恢复命令至少间隔 3 秒。冷却期间保留最新变化；成功恢复不会提前解除冷却。手动断开会取消待执行恢复与超时任务。
- 网络恢复、物理网络变化及唤醒重置重试次数；新网络上的首次失败从 3 秒开始等待。
- 完整测试 57 项通过，0 失败（34 项状态机、1 项恢复集成、15 项核心、4 项权限、3 项网络过滤与脚本语法）。记录在 `.build/retry-tests-verified.log`。首次受限执行时两个现有本地 Unix socket 测试失败；允许本地通信后完整复验通过。
- 新增集成测试运行实际本地替身进程，串起状态机和 TunnelEngine，验证自行发现掉线 → 恢复超时 → 旧进程清理完成 → 新进程登录 → 手动断开后不再启动。没有使用真实 VPN 密码或连接公司服务器。
- Release 编译成功。受限环境中的 iconutil 返回 Invalid Iconset，本次复用 1.1.0 的现有 AppIcon.icns 完成组包；图标内容未修改。主程序／助手 ad-hoc 签名、`codesign --verify --deep --strict`、Info.plist 校验和 ZIP 完整性检查通过。
- 1.1.0 与 1.1.1 打包助手 SHA-256 相同：`750ed5bcc4278fea123ea54160d127a83ce7fdf7eefa5ca5503ee84db29b2ead`。沿用版本 2 助手及已安装授权，不需要为本次更新重装权限助手。

交付：`dist/XD VPN 1.1.1.app`、`dist/XD-VPN-1.1.1-macOS-arm64.zip`，bundle ID `com.xd.vpn`，构建版本 4。

本次没有启动交付应用、替换正在运行的客户端、安装系统文件或切换实际网络。真实公司 VPN 的睡眠／切网恢复速度尚需使用新版实测；10 秒仍是当前沿用的恢复预算，并非实网调优结论。

## 历史版本：1.1.0

2026-09-05，macOS 26.6.2 / Apple Silicon / Swift 6.3.3 / OpenConnect 9.12。

- `bash scripts/test.sh`：46 项测试全部通过，0 失败。包括 24 项连接状态测试、15 项原有核心测试、4 项权限与会话锁测试、3 项物理网络过滤与安装语法测试。
- 新增事件注入验证：睡眠时暂停、离线唤醒等网络就绪、Wi-Fi 连续在线时切换、通知防抖合并、等待中的退避立即恢复、10 秒会话恢复期限（测试注入缩短时间）、成功时取消期限、超时清理后重新登录、握手中切网、手动取消与退出后无延迟登录。
- 网络配置过滤验证：物理接口地址／网关／链路变化有效；utun、全局 DNS、物理接口的 AdditionalRoutes 变化不触发恢复循环。
- 权限验证：sudo 用户身份与参数约束、规则用户名注入拒绝、用户可写文件／符号链接拒绝、会话锁互斥与释放通过。生成的安装 shell 用 `sh -n` 检查，专用 sudoers 规则用 `visudo -cf` 检查；没有执行真实 root 安装。
- Release 构建、主程序／权限助手 ad-hoc 签名验证通过。打包助手 `--version` 输出 2。
- 原生应用启动与「系统授权」页实际检查通过，显示尚未安装授权，无启动管理员弹窗。
- 原生应用 Cmd-Q 退出实际检查通过，进程列表确认新版 `com.xd.vpn` 进程消失。另一款 `/Applications/XD VPN.app`（`com.chengfei.xdvpn`）及原有 OpenConnect PID 保持不变。
- 菜单栏紧凑面板已编译打包，自动化 UI 工具未能直接打开该菜单栏弹窗；面板的实际展开外观仍待人工验收。
- `unzip -t dist/XD-VPN-1.1.0-macOS-arm64.zip` 通过。

交付：`dist/XD VPN 1.1.0.app`、`dist/XD-VPN-1.1.0-macOS-arm64.zip`，bundle ID `com.xd.vpn`。

本次没有安装 root 授权文件、读取真实 VPN 密码、接入公司 VPN、切换本机 Wi-Fi 或令电脑睡眠。首次使用需在应用内安装一次授权；真实授权持久性、公司认证、DNS／路由及睡眠／切网恢复，尚需实网验收。已有模拟测试不代表实网连接已通过。

## 历史版本：1.0.0

2026-09-05，本机 macOS 26.6.2 / Apple Silicon / Swift 6.3.3 / OpenConnect 9.12。

- `bash scripts/test.sh`：28 项测试全部通过，0 失败。
- 已安装 OpenConnect 的本机回环失败路径通过；没有向公司 VPN 提交账号或密码。
- `bash scripts/build.sh`：Release 构建成功，主程序、权限助手和图标均已打包。
- `codesign --verify --deep --strict`：通过，本机 ad-hoc 签名。
- 实际打开原生应用检查首页、VPN 配置、连接日志、空账号保存校验及退出。
- 最终首页再次检查：状态卡、配置卡、密码说明及 Auto Connect 均完整显示。

交付应用：`dist/XD VPN.app`，bundle ID `com.xd.vpn`。

尚需用户凭据验证：真实管理员授权、公司 VPN 登录、企业 DNS 与路由、真实断网／睡眠后的恢复。自动化测试中的认证成功和网络恢复场景使用替身进程及事件，不代表已接入公司 VPN。

## 1.0.1 菜单栏图标更新

- 改为带叉盾牌／带勾实心盾牌／循环箭头／带感叹号盾牌，区分离线、在线、处理中和失败。
- 四种系统符号均在本机以 18 pt、浅色及深色背景渲染检查，通过。
- Release 编译、应用签名及 ZIP 完整性检查通过。
- 新版另存于 `dist/XD VPN 1.0.1.app`，当前运行中的旧版及 OpenConnect 进程保持原 PID，未为界面更新中断 VPN。
- 本次没有修改自动重连逻辑；README 补充了 20 秒 DPD 存活探测的说明。

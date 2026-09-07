# 验证记录

## 2026-09-07：修复已安装系统服务启动失败，完成旧授权实机迁移

- test.25 安装后，launchd 重复退出 `78 / EX_CONFIG`，实际助手日志为「运行副本目录权限异常」。本机 `/private/var/run` 为正常的 `root:daemon 0775`，与此前执行副本要求的不可组写父目录冲突。提交 `05253e0` 将执行副本迁到严格验证的 `/Library/PrivilegedHelperTools/com.xd.vpn.runtime`（root:wheel 0700），没有放宽可执行内容权限。旧锁目录只接受可信系统组的组写模式，锁文件与旧授权文件仍严格验证。
- ARM 与 Intel（Rosetta）各 **212 项完整回归通过，0 失败**，含运行目录与迁移路径安全拒绝用例；日志 `.build/test26-final-{arm,intel}.log`。Intel 筛选测试遇到 SwiftPM 宿主架构发现问题，后续使用完整未筛选的 Intel XCTest 复验通过。
- `build/XD-VPN-1.1.19-test.26-macOS-arm64.dmg`，4,575,529 字节，SHA-256 `382b579eeef808d930992852220fa3958715118291a60badda926c9bfba2598f`。App 公证 `d25cb292-4d72-47f3-be58-9ba105e0dbc6`、DMG 公证 `4dd65ffd-2b06-4484-b7a9-5243dfeaf535` 均 Accepted、staple 成功；只读挂载后 Gatekeeper、签名、版本、架构及运行副本验证通过。记录 `.build/test26-verification.json`。
- 已将 `/Applications/XD VPN.app` 原子替换为 test.26，原 test.25 备份为 `build/installed-backups/XD VPN-test25.app`。新 `probe` 命令使用实际双向签名 XPC 检查，确认后台服务已启动、构建一致且空闲。旧版退出 78 的记录不代表新进程仍失败。
- 实机重新注册时观察到注销完成后立即 register 返回 Operation not permitted；后台日志显示 `disabled, allowed, notified`。正常界面再次启用成功，无新增批准要求。后续提交加入有限的状态同步重试，首次注册及批准／签名拒绝不重试。
- 用户明确授权后，实际从连接页完成旧授权迁移。旧规则、旧助手、旧引擎三个固定目的路径均已不存在，恢复备份父目录为 root:wheel 0700；`probe` 确认 `legacyAuthorization=false`。配置和钥匙串不变。
- 实际 `--service-command smoke` 通过：公司签名及构建匹配、独占空会话、断连清理、过期构建拒绝、清理后重新创建会话。日志 `.build/test26-installed-smoke.log` 与 `.build/test26-after-migration-probe.log`。实际界面服务提示隐藏、主按钮恢复「连接 VPN」，自动连接与开机启动均关闭。
- 未启动真实 VPN 引擎、读取 VPN 密码或操作实际 Wi-Fi；网络连接、切换和退出时 DNS／路由还原仍需实网验收。未推送或发布正式 Release。

## 2026-09-07：新版界面本地测试包 test.25 公证完成

- 产物：`build/XD-VPN-1.1.19-test.25-macOS-arm64.dmg`，4,570,206 字节；源提交 `9df6d5f61e13415983f9664ed0967957bd2474f1`。包含 SMAppService／XPC 新架构及独立授权页移除后的界面。测试渠道，不发布 GitHub Release。
- 本机 `xdvpn-notary` 公证 profile 已可用。App 提交 `30f781b4-c94c-4e57-b1bf-31da096e8c34`、DMG 提交 `6eb7c800-9835-43f4-ab3b-909d8eff77c6` 均返回 `Accepted`，两者已附加票据并验证成功。
- 最终 DMG 只读挂载后，公司签名、App／DMG 公证票据、版本／渠道／源码提交、主程序／助手／引擎 ARM 架构和服务 plist 均通过检查。Gatekeeper 返回 `accepted`、`source=Notarized Developer ID`；实际执行 `verify-bundle` 验证权限收紧后的运行副本签名通过。内置引擎隔离验证通过。
- SHA-256：`31dfb51ff6620f464a0e2e24e5165a1901f738985dfd0bfa8aa26755a598aafb`。日志 `.build/test25-build.log`、`.build/test25-package.log`、`.build/test25-engine-verification.log`，复核结果 `.build/test25-verification.json`。
- 此轮仅生成本地测试包，未替换运行中的应用、注册系统服务、迁移旧授权或连接真实 VPN；这些实机项目仍待用户安装后验收。

## 2026-09-07：移除独立系统授权页

- 删除独立页面和导航项。连接页按状态提供启用、系统批准、迁移及修复提示；服务就绪后隐藏提示，主按钮恢复「连接 VPN」。菜单栏需要处理服务时打开连接页；移除服务入口收进配置页的「高级 · 系统服务」。安装说明与运行时错误提示同步更新。
- 返回应用自动检测批准状态，较旧的异步查询结果不能覆盖新状态。批准不会自动发起新的 VPN 连接；连接活动期间禁止迁移和移除，正在注册时禁止重复提交和误发连接请求。
- ARM／Intel（Rosetta）完整 Swift 回归各 **206 项通过，0 失败**，无编译警告。其中新增 7 项服务准备流程回归，使用隔离的服务及凭据替身；14 项 Python 发布规则测试和打包保护检查通过。日志 `.build/service-setup-full-{arm,intel}.log`、`.build/service-setup-release-tests.log`、`.build/service-setup-packaging-tests.log`。
- 使用隔离演示模型实际渲染 SwiftUI 的启用、批准、迁移、正常连接和配置页面，检查四项导航、提示卡片及高级入口的排版。预览保存在 `.build/service-ui-review/`，临时渲染工具未纳入日常测试。
- 本轮未替换正在运行的应用、迁移本机旧服务或发布新安装包。新架构的实际公证、系统批准及真实 VPN 验收仍以前述待办为准，界面回归不替代这些验证。

## 2026-09-07：SMAppService 与双向签名 XPC 迁移（待系统验收）

- 分支：`codex/service-management-xpc`。保留 OpenConnect 及原有恢复、网络归属核验和清理逻辑，助手协议升级为 9。正式 Release `v1.1.19` 未替换。
- ARM 完整 Swift 回归 **199 项通过，0 失败**；Intel 经 Rosetta 执行完整回归 **199 项通过，0 失败**。日志分别为 `.build/xpc-final-arm-tests.log` 和 `.build/xpc-final-intel-tests.log`。未使用真实 VPN 账号。
- 发布规则 Python 测试 **14 项通过**；架构、最低系统、渠道及正式版本保护脚本通过。日志 `.build/xpc-release-tests.log`、`.build/xpc-packaging-tests.log`。
- 新测试覆盖内核 XPC 拒绝未签名客户端、构建／会话所有权校验、重复会话、异常断连与子进程停止、清理期间锁保留、旧授权迁移失败回滚和启动竞争。私有运行副本测试覆盖源 App 替换后内容保持、链接拒绝、权限收紧和生命周期清理。
- 已发现并修复：签名要求字符串的语法问题、停止回调滞留导致会话锁未释放，以及从可替换 App 直接运行引擎／清理脚本的风险。生产服务只执行复制后再次验证过的 root 私有运行副本。
- 运行代码提交 `319dad8` 的 ARM／Intel `1.1.19-test.24` App 均已实际完成 Tools UG Developer ID 签名。两个架构各自执行 `--service-command verify-bundle` 成功：完整包、hardened runtime 和权限收紧后的运行副本签名均通过。内置引擎的移位运行、系统依赖、可信 TLS、不可信证书／主机名不符拒绝验证通过。日志 `.build/xpc-{arm,intel}-bundle-verification.log`、`.build/xpc-{arm,intel}-engine.log`。
- **尚未通过本轮新包的 Apple 公证。** 本机 Developer ID 正常，但 `notarytool` 默认查找及指定登录钥匙串均返回找不到 `xdvpn-notary` profile；已请用户通过本机隐藏输入恢复凭据。历史 test.23 / v1.1.19 公证结果不作为新版证据。
- **尚未注册、批准或实际运行新 LaunchDaemon，尚未迁移本机旧授权。** 系统只读检查仍有旧版 App 运行，旧 sudoers／助手／引擎保留。实际 XPC smoke、服务启停、迁移和真实 VPN 网络切换／退出清理仍待验收，自动化结果不替代这些项目。

## 2026-09-07：安装包实际 Apple 公证通过

本轮对现有公司签名的 `1.1.19-test.23 / arm64` 测试包完成了实际公证，不是仅验证账号凭据，也未发布 GitHub Release。

- App 提交：`ae0c0e3c-1347-47af-bda1-c1edd48bdc7d`，Apple 返回 `Accepted`。
- DMG 提交：`80967071-59c3-47da-9819-8210350fa032`，Apple 返回 `Accepted`。
- App 公证后附加票据，再打包、签名并公证 DMG；DMG 票据验证通过。
- 只读挂载最终 DMG，其中 App 的 stapler 验证及 codesign 深度校验通过，Gatekeeper 返回 `accepted`、`source=Notarized Developer ID`。
- 最终 DMG 的 `.sha256` 校验通过。产物：`build/XD-VPN-1.1.19-test.23-macOS-arm64.dmg`。
- Apple 返回记录保存在 `build/notarization/test23-app.json` 和 `build/notarization/test23-dmg.json`，执行日志为 `.build/notarization-test23.log`。这些本地产物不提交 Git。
- 正式版本仍须在干净的版本提交及匹配标签上重新构建，不能把这个测试包重命名当正式版发布；可使用 `scripts/release.sh prepare <tag>` 完成构建、测试、公司签名与强制公证。


## 2026-09-07：GitHub Release、公司签名与版本更新

- 目标正式版本：1.1.19 / build 22；本机验收包使用 test.23，不发布正式版。
- Swift 完整测试 181 项通过（含 7 项版本更新测试）；Python 发布规则测试 7 项通过；架构、最低系统、渠道与版本保护脚本通过。
- 已经用户授权，在 Xcode Tools UG 团队创建 Developer ID Application（Team ID KQY8A3BNVG），并实际签名 ARM App、系统助手与 OpenConnect；正常系统权限下 codesign 深度校验通过，确认 hardened runtime 和安全时间戳。
- ARM 测试 DMG 创建、hdiutil verify、SHA-256 复核通过；应用内引擎的移位运行、系统依赖、可信 TLS、拒绝不可信证书和错误主机名的隔离验收通过。
- 更新测试覆盖稳定版本数字排序、草稿／预发布／降级过滤、架构选择、仓库 URL、缺失摘要、大小与 SHA-256 不匹配、私有仓库错误、Token 请求头和 CDN 重定向移除 Token。
- 发布测试覆盖标签匹配、显式构建号、渠道版本隔离、正式版本单调递增、已发布版本不可覆盖、草稿重试、资产摘要失败时禁止发布。
- GitHub workflow YAML 和 Shell 语法检查通过。线上签名、公证及 GitHub 实际发布尚未执行：仓库尚未配置所需 GitHub Secrets；本机签名测试包尚未 Apple 公证。Intel 原生构建／完整验收由 Release matrix 执行，本轮本机仅验证 ARM 成品及双架构拒绝路径。
- 操作与所需 Secrets 见 [发布文档](docs/releasing.md)。


## 当前交付：1.1.16 Intel / Apple Silicon 独立包

2026-09-06，build 19，助手协议继续为 8。按芯片分别交付，不生成通用二进制包。构建机为 Apple Silicon / macOS 26.6.2 / Swift 6.3.3。

- `bash scripts/package.sh` 已实际完成两个 Release 构建及独立 ZIP。`ARCHS=x86_64` 或 `ARCHS=arm64` 可单独构建；默认 `build.sh` 仅构建本机架构。每个 App 中主程序、助手和 OpenConnect 均只有对应架构，最低系统目标均为 14.0。完整构建日志：`.build/intel-separate-package.log`。
- Swift 使用显式目标 triple；OpenSSL 使用对应 Darwin 架构，OpenConnect 使用显式编译器架构和 build/host triple。修复上游 config.guess 使用不存在的 `/usr/bin/sh` 的问题，改由 `/bin/sh` 调用且检查结果；最终 Intel configure 日志显示 `cross compiling... yes`。构建无需运行另一架构引擎。源码、编译对象、运行文件及许可证按架构隔离，源码下载共用；编译缓存检查配方、工具链和工作区路径。
- Apple Silicon 原生 XCTest：**174 项通过，0 失败**。Intel XCTest 经 Rosetta：**174 项通过，0 失败**。记录为 `.build/intel-arm64-tests-final.log`、`.build/intel-x86_64-tests-final.log`。测试入口使用当前执行架构对应的引擎；项目全为 XCTest，禁用不使用的 Swift Testing 加载器，避免其原生宿主进程无法加载 Intel bundle 而令成功的 XCTest 命令最终报错。
- `bash scripts/test-packaging.sh`：两个实际 Mach-O 架构样例通过，7 个拒绝场景通过，覆盖混入另一架构的助手／引擎、通用二进制、错误目标架构及高于 macOS 14 的最低系统目标。记录 `.build/intel-packaging-tests.log`。
- 两个最终 ZIP 完整性及解压后的严格签名检查通过；App、助手、引擎、网络脚本与原始构建逐一核对 SHA-256，版本为 1.1.16 / build 19，两个助手执行 `--version` 均为 8。源代码重建脚本与当前仓库一致，各包的许可证版本说明匹配自身架构。记录 `.build/intel-package-verification.json`。
- 两个最终 ZIP 内的引擎分别按 arm64 原生／x86_64 Rosetta 执行隔离验收：移到带空格路径并禁止读取 Homebrew 和工作区后，版本查询与回环连接拒绝正常；可信 TLS 可发出 HTTP 请求，不可信证书及错误主机名均在发送 HTTP 前拒绝。两个引擎均仅依赖 macOS 系统库，无 `_strchrnul` 系统导入。记录 `.build/intel-arm64-engine-verification.json`、`.build/intel-x86_64-engine-verification.json`。

| 分发包 | SHA-256 |
| --- | --- |
| `dist/XD-VPN-1.1.16-macOS-x86_64-bundled.zip` | `73fa639a80ae8fbb84f912f385c9fc9d189230d46fc3ea5667db1a2f8cd2c5f6` |
| `dist/XD-VPN-1.1.16-macOS-arm64-bundled.zip` | `f2a8e426c869a8191b1fff41380074fbe67bf082ddc1a516f4d5c1d08abf3b86` |

本次没有替换已安装的 App／系统助手、读取 VPN 凭据或操作真实网络。Intel 运行验收使用 Rosetta，尚未在 Intel 真机或 macOS 14 真机进行 VPN 连接验收。产物为本地 ad-hoc 签名，未进行 Apple 公证；此交付不改变既有切网恢复的实网验收边界。

## 历史交付：1.1.15 切网恢复修正版

2026-09-06，build 18，助手要求 8。针对用户报告切换到另一 Wi-Fi 后失败、切回恢复的问题，修复日志证实的重连准备阻塞；服务器会话拒绝的完整原因仍待实网确认。

- 14:24:37，助手已经将服务器主机路由从旧源地址／网关更新到新物理网络并读回通过。随后 attempt-reconnect 钩子未返回，14:24:40 客户端的 3 秒恢复期限触发 SIGINT，OpenConnect 在等待脚本时收到 EINTR 并结束恢复。14:23 的另一次切网也出现相同模式。
- 14:24:41 至 14:25:23 的 8 次新进程均完成 TCP/TLS 及认证 POST，随后隧道 CONNECT 收到 `HTTP/1.1 401 Cookie is not acceptable`。这不同于之前的 EADDRNOTAVAIL 或路由错误；客户端日志不能判定服务端拒绝会话的具体策略，也不能证明它由提前重连引起。
- 用户回到 1.1.13 后，14:28 的切网重新登录成功，但同样先经历了 3 秒中断。现场只读摘要确认本机仍安装 1.1.14 的引擎（`1bae1427fb5c116e59b86d9aa2049e2c5e5b419586c094490b6db3f11cbffafe`）及助手；回退 App 没有回退系统引擎。因此不能仅凭 App 版本认定 OpenSSL／引擎回归。有限事件摘录保存于 `.build/wifi-recovery-incident.json`，不含认证正文或凭据，未加入分发包。
- 助手 8 的 attempt-reconnect 只执行原生服务器路由准备和核验，完成即返回。标准 vpnc-script 在这一阶段仅设置服务器路由，该函数已被托管脚本覆盖为空操作；移除多余的外部脚本启动，避免占用现有恢复预算。物理出口未就绪仍暂缓，实际路由更新失败仍返回错误。connect、reconnect、disconnect 的脚本处理及 3 秒恢复期限／清理重试策略保持既有行为。
- HTTP CONNECT 401 和明确的 Cookie 拒绝单独标记为 `session.rejected` 错误诊断，不记录 Cookie 值，也不改变认证、证书验证或重试策略。
- 禁止读取 Homebrew 的子沙箱内完成 Release 回归：**174 项通过，0 失败，无跳过**（`.build/wifi-recovery-full-tests.log`）。新增重连准备往返更新路由而不启动阻塞脚本、原生更新失败不误报成功，以及会话拒绝独立诊断；保留其他阶段脚本超时、原生清理和进程恢复测试。
- Release App／助手构建与严格签名通过（`.build/wifi-recovery-build.log`）。ZIP 解压后版本为 1.1.15 / build 18、助手 8，四个有效载荷摘要与原始 App 一致，源代码重建脚本一致。内置引擎与 1.1.14 已通过 TLS 隔离验收的二进制逐字节相同，本次未重新编译 TLS 引擎。检查记录 `.build/wifi-recovery-package-verification.json`。
- 提交前审查修正源码重建步骤：从默认含空格的解压目录复制到无空格临时目录后再构建；已实际执行准备步骤并核对复制的脚本与源包。使用说明按 arm64／x86_64 标注机型。重新打包后四个可执行载荷摘要均未改变，复用上述 174 项测试与签名验证结果。
- 分发包：`dist/XD-VPN-1.1.15-macOS-arm64-bundled.zip`，SHA-256：`be32736955a570b0522756f0bc1a776bf44d3517dbb208ca453875ed7b6605c0`。需要在「系统授权」升级到助手 8 才会使用原生恢复准备流程。

本次未操作真实 Wi-Fi、读取 VPN 密码或替换正在运行的 App／助手。必须在升级助手 8 后重新切网，才能确认真实恢复效果及 401 是否仍出现；本地回归不能证明所有服务器会话拒绝已解决。

## 历史交付：1.1.14 内置引擎修正版

2026-09-06，build 17，助手协议仍为 7。修复内置引擎评审发现的升级检测、macOS 14 系统函数引用及测试依赖遗漏。

- 授权状态在检查助手版本和 root 所有权后，比较应用内与已安装引擎、vpnc-script 的 SHA-256。内容不一致显示需要升级；缺失／不可读显示需要修复。摘要不代替原有权限检查，也不再依赖递增助手协议版本才能更新引擎。
- OpenConnect 使用显式 `OPENSSL_CFLAGS`、`OPENSSL_LIBS=-L… -lssl -lcrypto`；清除继承的编译搜索路径，libtool 使用保守的命令长度，避免沙箱 sysctl 探测失败。静态库不再嵌套 `.a` 成员，构建没有此前的归档／整数比较警告。记录 `.build/bundled-fix-engine-build.log`。
- configure 强制 `ac_cv_func_strchrnul=no`，成品包含 `openconnect__strchrnul` 兼容实现，无 `_strchrnul` 系统引用，也无未定义弱引用。编译将新系统 API 可用性警告作为错误；构建和独立验收均拦截该已知不兼容导入。新的验收脚本对 1.1.13 的缺陷引擎会明确失败（`.build/bundled-fix-old-engine-rejected.log`）。这不替代 macOS 14 真机验收。
- 在禁止读取 `/opt/homebrew` 和 `/usr/local` 的子沙箱内完成全部 Release 回归：**171 项通过，0 失败，无跳过**（`.build/bundled-fix-full-tests.log`）。包含同助手版本、同文件长度／时间戳下的引擎或脚本更新识别，缺失文件修复提示，以及内置 vpnc-script 的路由和清理检查。移除测试中的 Homebrew 路径；缺失任一测试引擎文件时，脚本启动前报错，直接 swift test 缺少测试路径也不再静默跳过。
- `dist/XD VPN 1.1.14.app` 构建及签名验证通过（`.build/bundled-fix-build.log`）。最终 ZIP 解压后，App、助手、引擎和网络脚本逐一与构建产物核对摘要，严格签名和助手版本检查通过，附带的重建脚本与当前源码一致（`.build/bundled-fix-package-verification.json`）。ZIP 为 `dist/XD-VPN-1.1.14-macOS-arm64-bundled.zip`，SHA-256：`05f5890ca5864f447641bdb7533a830477c9db227317a8237238051b7c5e4912`。
- 使用最终 ZIP 中的引擎完成移位与隔离验收：禁止读取 Homebrew 和工作区后，可信回环 TLS 可发送请求，不受信任证书及错误主机名均在发送 HTTP 前拒绝；版本查询和连接拒绝路径通过。仅加载四个系统动态库，最低部署目标 14.0（`.build/bundled-fix-engine-verification.json`）。
- 企业私有 CA 支持未增加：继续严格使用 `/etc/ssl/cert.pem`，不自动导入钥匙串证书；README 明确其信任集合可能与 Homebrew 不同。本次未更新实际安装文件、使用真实凭据或中断 VPN；实际 VPN 登录／重连和 macOS 14 真机仍待验收。当前包为 Apple Silicon、本地 ad-hoc 签名，未公证。

## 历史交付：1.1.13 内置引擎版

后续评审发现：此版本保留 macOS 15.4 的 `strchrnul` 弱引用，一项路由测试仍使用 Homebrew 脚本，且引擎更新检测没有比较内容摘要。下述 168 项测试确实在本机通过，但不能据此认定无 Homebrew 或 macOS 14 真机兼容性；改用 1.1.14 修正版。

2026-09-06，build 16，助手 7。保留 1.1.12 的连接状态 UI 更新；内置 OpenConnect 9.21、静态 OpenSSL 3.6.2 和固定版本 vpnc-script，运行和安装均不依赖 Homebrew。

- `bash scripts/test.sh -c release`：168 项通过，0 失败、无跳过（`.build/bundled-full-tests.log`）。新增完整包识别、缺失文件／符号链接拒绝、带 shell 字符的安装来源、摘要错误不替换旧安装、发布失败恢复旧引擎／助手／规则等检查。安装事务在隔离的用户目录运行；root 权限边界由独立权限检查覆盖。
- Release 构建和 App／助手／内置引擎严格签名验证通过（`.build/bundled-build.log`）。引擎 Mach-O `minos=14.0`，只有 libSystem、libz、libxml2、libiconv 四个 macOS 系统动态库；没有 Homebrew 或构建目录的动态库引用。
- 将交付包内的引擎复制到带空格的临时目录，在禁止读取 `/opt/homebrew`、`/usr/local` 和整个工作区的子沙箱内通过版本查询、可信本机 TLS、无信任根拒绝、错误主机名拒绝和回环连接失败检查。不可信证书和主机名不匹配时，没有向测试服务发送 HTTP 请求。记录 `.build/bundled-engine-verification.json`。
- TLS 使用 macOS `/etc/ssl/cert.pem`；不从 Homebrew 加载证书、动态库或配置，也不自动合并钥匙串中的自定义 CA。内置源码构建禁用 OpenSSL 动态模块和自动配置加载。
- 未安装或升级本机系统助手，未替换正在运行的客户端、读取真实 VPN 密码或重新登录公司 VPN。完整的首次管理员安装、实际 VPN 登录和 macOS 14 真机验收仍需在收件人的 Mac 上完成；当前运行验证在 Apple Silicon / macOS 26 上完成。仍为本地 ad-hoc 签名，未做 Apple 公证。

## 历史交付：1.1.11

2026-09-06，修复 1.1.10 在首次连接时路由校验失败、漏清理却报成功，以及提前显示已连接的回归。系统助手要求 **6**。

- 服务器主机路由改用 NET_RT_DUMP 完整枚举，区分同一地址的作用域缓存与无作用域静态条目，记录实际候选结果。修改自己的旧路由使用精确 RTM_DELETE + RTM_ADD；RTM_CHANGE 与普通 RTM_GET 都可能选中作用域缓存，不再用于本次静态路由的修改／核验。读表或核验失败保留预写记录，不能以查到缓存条目作为静态路由已清除的证明。
- 初次 Configured as 消息只暂存；网络脚本完成后，助手核对本次归属、IPv4、DNS 及路由，再发出 connected。脚本失败或仅有伪造完成消息不会显示已连接。
- 完整 `bash scripts/test.sh -c release`：**162 项通过，0 失败，无跳过**，记录 `.build/hotfix-release-tests.log`。新回归覆盖多条同地址路由共存下的连接／重复恢复／换网／清理、读表失败保留记录、完整／截断二进制快照，以及脚本成功／失败／没有实际配置时的连接状态。实际 macOS NET_RT_DUMP 中的源地址读取及 configd／RTM_GET 只读检查已通过；网络写入仍使用替身。
- 定向测试 `.build/hotfix-route-tests.log` 的 20 项路由检查通过。初轮普通沙箱中既有 configd 读取被拒绝，最终完整回归在获准的环境通过，未删改该检查。连接状态测试最初使用了会被密码脱敏替换的测试标记，修正测试密码后原断言通过。
- Release 构建及 App／助手严格签名验证通过，交付 `dist/XD VPN 1.1.11.app` 和 `dist/XD-VPN-1.1.11-macOS-arm64.zip`，build 14，内置助手 6。ZIP 完整性、无特权脚本入口拒绝、`git diff --check` 通过。构建／打包记录 `.build/hotfix-build.log`、`.build/hotfix-package-verified.json`；源码摘要 `.build/hotfix-source-hashes.json`。打包时已安装助手为 5；用户随后已升级到 6。

2026-09-06 11:32–11:36（北京时间），用户从 AnyConnect 切回 1.1.11 后完成只读验收：已安装助手为 6；11:32:38 真实服务器路由添加成功，完整枚举同时发现作用域缓存与本次无作用域静态条目，读回核对通过。connect 脚本于 11:32:38.797 成功结束，配置核对后才于 11:32:38.807 报告 connected。同一 OpenConnect 进程持续运行约 3 分半，期间无重连或退出；App 本地日志保存了完整过程。

当前服务器主机路由走 en0 物理网关，默认路由走 utun4。实测百度 HTTPS 返回 200，VPN 下发的 DNS 对服务器域名查询正常响应（6 ms）。上述结果验证首次真实连接和 RTM_ADD／枚举核验；没有主动切换 Wi-Fi 或断开 VPN，真实切网恢复、断开清理和内网业务长连接仍待验收。

## 历史交付：1.1.10（已确认回归，停止使用）

2026-09-06。针对 09:54 切换 Wi-Fi 后 OpenConnect 连续 `EADDRNOTAVAIL`（49）的事故修复服务器 IPv4 主机路由，并补全引擎、助手的本地诊断。保留工作区已有的 1.1.9 连接质量功能。

- 依据统一日志区分已证实的 TCP 地址不可用与推断的旧路由／源地址残留。旧隧道退出后 en0 已恢复主位，新连接 DNS 查询成功；本次不能继续认定为幽灵 DNS 键。故障时没有 RTM_GET 快照，没有把重复 ADD 的日志当成原有路由内容。
- 服务器路由读取当前物理接口的作用域默认出口，修改时同时带网关与源地址，读回验证。预写 route.json 保护修改后崩溃的清理；只管理本次记录匹配的静态路由，处理切网期间正常内核克隆，保留其他来源静态路由。PF_ROUTE 忽略同时到达的接口通知。
- 私有 vpnc-script 副本不再猜服务器路由、恢复切网前默认网关或经 networksetup 写物理服务的持久 DNS。由 configd 管理本次 IPv4 默认服务，退出时清理自己的服务键和主机路由。安装的 Homebrew 脚本未修改。
- OpenConnect 每行输出经脱敏后独立记录，包括未知错误、DTLS 失败、脚本预算、路由前后状态、信号与退出。App 保持 4 × 1 MiB；助手新增 root 私有的 4 × 4 MiB 滚动日志，App 退出后仍可保留清理结果。错误和停止刷盘；写失败有明确报告，诊断严重级别不直接触发断开。

验证：

- 最终 `bash scripts/test.sh -c release`：**157 项通过，0 失败，无跳过**。记录 `.build/route-fix-complete-release-tests.log`。包含替身路由／动态存储、实际安装脚本的隔离重放、真实父子进程、持久日志与脱敏，以及既有连接质量、恢复和授权回归。真实系统仅作 configd 和 PF_ROUTE GET 查询，当前物理出口与源地址的读取已通过。
- 早期全量测试发现新增截断提示超出日志行长度限制，已将提示计入 2048 字符预算。后续一次测试暴露原自动启动测试依赖固定次数 Task.yield 的竞态，改为有上限地等待实际连接命令；保留原断言，未修改产品自动启动逻辑。最终全量通过，不合并多轮测试数量。
- 本机已安装助手仍为 **4**，只读摘要 `ff9ef65eec35f1ecf26f1b5be4ce56f6020362a2f7a8dfe04b0a0fdf3843e114`。没有升级系统助手、重启活动 VPN、使用真实 VPN 凭据或切换 Wi-Fi。
- `APP_OUTPUT="$PWD/dist/XD VPN 1.1.10.app" bash scripts/build.sh` 构建成功，Info.plist 为 **1.1.10 / build 13**，内置助手 **5**。App／助手严格签名检查、无特权脚本入口拒绝、ZIP 完整性与 `git diff --check` 通过。记录 `.build/route-fix-build.log`、`.build/route-fix-package-verified.json`；最终 Sources／Tests／Resources 摘要保存在 `.build/route-fix-source-hashes.json`。

交付：`dist/XD VPN 1.1.10.app`、`dist/XD-VPN-1.1.10-macOS-arm64.zip`。ZIP SHA256：`f55002fe32af6f447911afb4c776ef7dbd5142323cd48cb27921bd77c657d8df`。

本轮内核 RTM_ADD／CHANGE／DELETE 均使用替身验证；真实切网、IPMonitor 默认路由恢复及公司业务连通性仍待新版运行验收。使用 1.1.10 需先断开并退出旧版，在新版「系统授权」点击「升级系统助手」安装 **5**；现有专用授权规则和配置沿用。修复范围为当前 IPv4 VPN 服务器和 en 物理接口，未接管没有归属记录的旧版或其他 VPN 静态路由。详见 [服务器路由恢复设计](docs/design/2026-09-06-server-route-recovery.md)。

## 历史交付：1.1.9

2026-09-06。增加结构化质量事件、原生「连接质量」Dashboard 和本地告警。系统助手仍为版本 4，未改认证、恢复和网络清理策略。

- 完成一次完整 `bash scripts/test.sh`：136 项通过，0 失败，包含连接取消、离线重复 connected 去重、恢复失败不重复计入登录、单调耗时、P95 分母、告警样本门槛/过期/去重，以及旧日志兼容、损坏尾行、FIFO 拒绝。
- 随后补充正常/异常退出后的跨启动恢复测试，并完成最终定向验证：`bash scripts/test.sh --filter 'ConnectionQualityTests|RollingActivityLogTests|VPNModelTests.testQuality'`，19 项通过，0 失败。此时套件共 137 项；未将两轮测试相加计数。
- 用隔离 UserDefaults、替身助手和模拟事件渲染原生界面，检查无数据、成功样本及连续失败告警状态，覆盖最小 990 × 720 窗口和较高窗口。确认无样本不显示虚假成功率，多条告警可滚动查看，24 小时图表时间轴正常。没有启动真实 VPN 连接。
- `APP_OUTPUT="$PWD/dist/XD VPN 1.1.9.app" bash scripts/build.sh`：最终 Release 打包及 `codesign --verify --deep --strict` 通过，Info.plist 为 1.1.9 / build 12。
- `git diff --check` 通过。原有未跟踪文件保持原样。

本轮验证不覆盖团队日志上报、远程 Dashboard、消息投递、业务探测或崩溃堆栈。异常退出仅根据退出记录缺失提供线索，未通过制造真实崩溃或中断当前 VPN 验收。详见 [质量监控设计](docs/design/2026-09-06-quality-monitoring.md)。

## 1.1.8

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

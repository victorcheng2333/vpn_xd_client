# XD VPN for Windows

Windows 原生预览版：WPF 界面参照 macOS 的深绿侧栏、浅色卡片和连接页布局；提供连接、VPN 配置、连接质量、日志、托盘、登录启动及自动重连。设计见 [Windows 技术方案](../../docs/design/2026-09-07-windows-support.md)。

目标为 Windows 11 x64；Windows 10 22H2 为兼容目标。0.1.3 预览版已在 Windows 完成构建、界面状态测试、离屏渲染校验与原生引擎失败路径测试。UI 按 macOS 的配色、卡片、配置引导和状态反馈调整；本轮未替换正在运行的旧版，也未操作真实 VPN 连接。详细证据与验收项目见 [VERIFICATION.md](VERIFICATION.md)。

## 发布

正式分发与 macOS、Android 共用 `Resources/Info.plist`、`v<version>` 标签及同一个 GitHub Release。下载 `XD-VPN-<version>-Windows-x64.exe`；Windows 安装器仍未签名。完整流程见 [发布文档](../../docs/releasing.md#Windows-统一发布)。下文的 preview 文件名仅用于日常本地构建。

## 构建

安装 .NET 10 SDK 和 MSYS2，在 **UCRT64** 终端安装构建依赖：

```bash
pacman -S --needed make patch tar unzip curl diffutils mingw-w64-ucrt-x86_64-gcc \
  mingw-w64-ucrt-x86_64-python mingw-w64-ucrt-x86_64-pkgconf \
  mingw-w64-ucrt-x86_64-gnutls mingw-w64-ucrt-x86_64-libxml2 \
  mingw-w64-ucrt-x86_64-zlib
bash Apps/Windows/scripts/build-engine.sh
```

再在 Windows PowerShell 中运行：

```powershell
./Apps/Windows/scripts/build.ps1
```

输出 `dist/XDVPN-Setup-windows-x64-preview.exe` 和备用 `dist/XDVPN-windows-x64-preview.zip`。包含 .NET 自包含运行时、内置 OpenConnect、官方签名 Wintun DLL、许可证、引擎源码与安装脚本。无需额外安装 .NET SDK 或其他 VPN 客户端。`-SkipEngine` 仅用于托管代码开发，不生成安装包。安装 EXE 使用 Windows 自带的 .NET Framework 4.x。

界面回归测试会使用替身服务和凭据存储，不接触真实 VPN 或个人配置；生成的页面快照位于 `.build/windows-ui-review/`：

```powershell
dotnet run --project Apps/Windows/XDVPN.UI.Tests -c Release -- .build/windows-ui-review
```

应用和安装 EXE 均内嵌 16–256 像素的多尺寸 ICO，窗口和开始菜单也使用该图标。图标按根目录 `scripts/icon.swift` 的 macOS 几何与颜色生成；重建：`./scripts/windows/generate-icon.ps1`。

工作流 `.github/workflows/windows.yml` 在 Windows 上执行构建、状态机测试、网络脚本替身测试、原生控制管道失败路径测试，以及 SYSTEM 服务安装/握手/卸载检查。测试引擎仅访问 `127.0.0.1:1`，不访问公司 VPN。工作流上传 CI artifact，不创建 Release。

开发可用 Visual Studio 打开 `XDVPN.slnx`；Core 测试可在 macOS/Linux 执行：

```bash
dotnet run --project Apps/Windows/XDVPN.Tests -c Release
```

## 安装与使用

1. 双击安装 EXE，点击「安装」并完成一次管理员授权。ZIP 手动安装需要先将来源可信的文件放在受保护目录，再显式以管理员身份运行 `Install.cmd`。安装位置固定为 `%ProgramFiles%\XD VPN`。
2. 从开始菜单打开 XD VPN，在「VPN 配置」保存服务器、账号、密码和可选认证组。
3. 密码存入当前用户的 Windows 凭据管理器；普通配置位于 `%LocalAppData%\XDVPN\settings.json`。
4. 开启 Auto Connect 后，应用启动时连接；连接中断按退避重试，物理切网先恢复原会话，超时后清理并重新登录。手动断开/取消会保持断开；关闭 Auto Connect 取消已排队重试并保留健康隧道。
5. 关闭窗口后继续在托盘运行；托盘「退出并断开」结束本次连接。快捷键：Ctrl+K 连接/取消，Ctrl+S 保存当前配置页，Ctrl+Q 退出。未配置时主按钮会打开配置页；连接期间仍可查看配置，但不可编辑。

服务安装绑定发起安装的一个 Windows 用户 SID；其他账号不能使用此控制管道。升级前先从托盘退出应用，再运行新版 Setup EXE。安装器自身提权后，在受保护的 Program Files 暂存目录解包；普通父进程在安装成功后启动客户端。ZIP 中的 `install.ps1` 仅供在可信目录中显式使用管理员 PowerShell 的安装流程，不再从用户可写目录自提权。更换绑定账号需先卸载。

双击安装目录中的 `Uninstall.cmd` 移除服务与程序。卸载会等待网络清理；清理未完成则停止卸载。个人配置、日志和凭据保留，需要删除密码时先在应用中选择「忘记已存密码」。卸载前关闭「登录后启动」。

## 重连与清理

- 控制服务用串行状态机处理连接意图与代次，实际引擎操作在另一串行队列执行，避免 DNS 等待阻塞取消和心跳。取消会中止尚未完成的启动准备。
- 物理检测比较硬件网卡地址与网关，不读取 SSID；同地址/同网关的漫游依赖 OpenConnect 的 DPD 恢复。
- 网络稳定等待 1 秒；Windows 同轮原会话恢复预算 65 秒（覆盖两次各最多 30 秒的网络脚本，重复 Lost 不延长期限）；完整登录超时 90 秒；意外失败退避 3/6/12/24/48/60 秒，带抖动，上限 60 秒。
- 密码/证书/额外认证错误停止本次重试。初次接口配置失败停止；已建立会话在恢复中配置失败，可清理后重新登录。
- 网络脚本预算 30 秒，原生等待上限 35 秒；停止引擎先发送取消，12 秒后仍未退出则终止本次 Job；再次等待退出及清理，绝不并行登录。
- `ProgramData\XDVPN\sessions` 保存每次会话的网卡 GUID 和精确路由记录。已有外部路由不接管，接口身份或 DNS 归属改变时停止清理。配置确认和 SSL 成功只建立「VPN 通道」状态；界面另行展示数据通路检查。只有绑定隧道的 DNS 回复或新入向字节才显示已有响应，具体业务可用性仍需验证。
- 服务启动时先恢复遗留会话；客户端明确退出会立即结束隧道；控制连接 EOF / 12 秒读超时只重建管道，经过 30 秒无认证请求的租约才取消连接意图。休眠冻结租约，唤醒后给客户端 30 秒续约。服务崩溃会由 Job Object 终止后代，SCM 重启后只清理，不自行重新提交凭据。

## 当前边界

- 支持 AnyConnect 的用户名/密码与可选认证组。未实现交互式 MFA、浏览器 SSO、设备证书、HostScan。
- 首版仅承载 IPv4 VPN，外层服务器也需要 IPv4；IPv6 不受本客户端保护，没有 Kill Switch。
- 质量页统计本机保留日志中的成功率、连接耗时 P95 和恢复次数；尚未移植 macOS 的全部告警与更新分发功能。
- 预览包的应用与服务尚未做企业代码签名；Wintun 使用官方签名 DLL。正式分发前仍需 Windows 实网验收与签名发布准备。

## 0.1.2 审计修复和诊断

本次对 Claude 审计逐项复核，结果见 [AUDIT-REVIEW.md](AUDIT-REVIEW.md)。核心修复包括原生控制命令唤醒、每次连接的进程所有权、终止错误分类、实际路由验证、管道续连和安装权限。恢复仍使用外部 PowerShell；65 秒是当前实现的有界兼容预算，不是达成 macOS 3 秒目标。MSYS2 依赖版本随包记录，但尚未建立全部依赖的不可变构建快照。

安装后可用管理员 PowerShell 执行以下命令，默认只读取本地状态，不切换 VPN：

```powershell
& 'C:\Program Files\XD VPN\diagnose-live.ps1' | Out-File "$env:USERPROFILE\Desktop\xdvpn-report.json" -Encoding utf8
```

用户自行连接 XD VPN 后，若要检测指定目标，可加 `-TargetUri 'https://console.tapsvc.com/nova/'`。它仅对该目标执行有界 DNS、绑定隧道源地址/接口的 TCP、TLS 和 HTTP HEAD 检查，不携带认证信息、不跟随跳转；不能代替页面登录后的业务验收。`-ProbeMtu` 另行启用到同一目标的小包/禁分片包对照，ICMP 无响应不单独判定为断网。报告包含内网地址，分享前请自行检查。

## 0.1.3 配置失败修复

0.1.2 在实际安装目录中触发了确定的兼容问题：路由校验的 PowerShell 5.1 `Add-Type` 动态编译选中了自包含 .NET 10 的 `System.dll`，导致 `System.Net.IPAddress` 引用错误，连接在网络配置阶段退出。0.1.3 改为构建时用明确的 .NET Framework 4 引用编译 `XDVPN.RouteAudit.dll`，连接时只加载同目录受安装保护的 DLL；安装前强制校验它存在并符合清单哈希。服务/客户端/安装器版本统一为 0.1.3。

回归使用真实 Windows PowerShell 5.1 子进程，把进程工作目录指向含 .NET 10 DLL 的隔离发布目录，禁止动态编译并令临时目录不可用，执行实际网络脚本的隔离配置/验证/清理。详细生产错误和四组对照见 [VERIFICATION.md](VERIFICATION.md)。

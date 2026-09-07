# XD VPN for Windows

Windows 原生预览版：WPF 界面参照 macOS 的深绿侧栏、浅色卡片和连接页布局；提供连接、VPN 配置、连接质量、日志、托盘、登录启动及自动重连。设计见 [Windows 技术方案](../../docs/design/2026-09-07-windows-support.md)。

目标为 Windows 11 x64；Windows 10 22H2 为兼容目标，均需真机验收。当前开发环境是 macOS，已完成托管代码编译与替身测试，尚未执行 Windows CI、驱动加载或真实 VPN 连接。详细证据与验收项目见 [VERIFICATION.md](VERIFICATION.md)。

## 构建

安装 .NET 10 SDK 和 MSYS2，在 **UCRT64** 终端安装构建依赖：

```bash
pacman -S --needed make patch tar unzip curl mingw-w64-ucrt-x86_64-gcc \
  mingw-w64-ucrt-x86_64-python mingw-w64-ucrt-x86_64-pkgconf \
  mingw-w64-ucrt-x86_64-gnutls mingw-w64-ucrt-x86_64-libxml2 \
  mingw-w64-ucrt-x86_64-zlib
bash Apps/Windows/scripts/build-engine.sh
```

再在 Windows PowerShell 中运行：

```powershell
./Apps/Windows/scripts/build.ps1
```

输出 `dist/XDVPN-windows-x64-preview.zip`。包含 .NET 自包含运行时、内置 OpenConnect、官方签名 Wintun DLL、许可证、源码与安装脚本。无需额外安装 .NET 或其他 VPN 客户端。`-SkipEngine` 仅用于托管代码开发，不生成可安装 ZIP。

工作流 `.github/workflows/windows.yml` 在 Windows 上执行构建、状态机测试、网络脚本替身测试、原生控制管道失败路径测试，以及 SYSTEM 服务安装/握手/卸载检查。测试引擎仅访问 `127.0.0.1:1`，不访问公司 VPN。工作流上传 CI artifact，不创建 Release。

开发可用 Visual Studio 打开 `XDVPN.slnx`；Core 测试可在 macOS/Linux 执行：

```bash
dotnet run --project Apps/Windows/XDVPN.Tests -c Release
```

## 安装与使用

1. 将 ZIP 完整解压到本地目录，双击 `Install.cmd`，完成一次管理员授权。安装位置固定为 `%ProgramFiles%\XD VPN`。
2. 从开始菜单打开 XD VPN，在「VPN 配置」保存服务器、账号、密码和可选认证组。
3. 密码存入当前用户的 Windows 凭据管理器；普通配置位于 `%LocalAppData%\XDVPN\settings.json`。
4. 开启 Auto Connect 后，应用启动时连接；连接中断按退避重试，物理切网先恢复原会话，超时后清理并重新登录。手动断开/取消会保持断开；关闭 Auto Connect 取消已排队重试并保留健康隧道。
5. 关闭窗口后继续在托盘运行；托盘「退出并断开」结束本次连接。快捷键：Ctrl+K 连接/取消，Ctrl+Q 退出。

服务安装绑定发起安装的一个 Windows 用户 SID；其他账号不能使用此控制管道。升级前先从托盘退出应用，再从新解压的安装包运行 `Install.cmd`。更换绑定账号需先卸载。

双击安装目录中的 `Uninstall.cmd` 移除服务与程序。卸载会等待网络清理；清理未完成则停止卸载。个人配置、日志和凭据保留，需要删除密码时先在应用中选择「忘记已存密码」。卸载前关闭「登录后启动」。

## 重连与清理

- 控制服务用串行状态机处理连接意图与代次，实际引擎操作在另一串行队列执行，避免 DNS 等待阻塞取消和心跳。取消会中止尚未完成的启动准备。
- 物理检测比较硬件网卡地址与网关，不读取 SSID；同地址/同网关的漫游依赖 OpenConnect 的 DPD 恢复。
- 网络稳定等待 1 秒；同轮原会话恢复预算 3 秒；完整登录超时 90 秒；意外失败退避 3/6/12/24/48/60 秒，带抖动，上限 60 秒。
- 密码/证书/额外认证错误停止本次重试。初次接口配置失败停止；已建立会话在恢复中配置失败，可清理后重新登录。
- 网络脚本预算 30 秒，原生等待上限 35 秒；停止引擎先发送取消，12 秒后仍未退出则终止本次 Job；再次等待退出及清理，绝不并行登录。
- `ProgramData\XDVPN\sessions` 保存每次会话的网卡 GUID 和精确路由记录。已有外部路由不接管，接口身份或 DNS 归属改变时停止清理。只有配置脚本的受保护确认文件存在时，界面才接受「已连接」。
- 服务启动时先恢复遗留会话；客户端退出、控制连接 EOF 或 12 秒心跳超时会结束隧道。服务崩溃会由 Job Object 终止后代，SCM 重启后只清理，不自行重新提交凭据。

## 当前边界

- 支持 AnyConnect 的用户名/密码与可选认证组。未实现交互式 MFA、浏览器 SSO、设备证书、HostScan。
- 首版仅承载 IPv4 VPN，外层服务器也需要 IPv4；IPv6 不受本客户端保护，没有 Kill Switch。
- 质量页统计本机保留日志中的成功率、连接耗时 P95 和恢复次数；尚未移植 macOS 的全部告警与更新分发功能。
- 预览包的应用与服务尚未做企业代码签名；Wintun 使用官方签名 DLL。正式分发前仍需 Windows 实网验收与签名发布准备。

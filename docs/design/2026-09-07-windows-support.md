# Windows 实现方案

目标：Windows 10 22H2 / Windows 11 x64，沿用 macOS 的单配置、AnyConnect 用户名密码认证、绿色侧栏、连接 / 质量 / 配置 / 日志页面和托盘操作。使用 .NET 10 LTS + WPF；不改动 Swift 工程。

## 架构与权限

- `XDVPN.Core`：无平台依赖的连接状态机、输入验证、消息协议、诊断分类与质量记录。以单调时间驱动，确定性测试不依赖真实网络。
- `XDVPN.App`：普通权限 WPF，Windows Credential Manager 存密码，LocalAppData 存普通配置和滚动日志，关闭窗口进入托盘，退出关闭控制连接。启动连接偏好与本次连接意图独立。
- `XDVPN.Service`：LocalSystem Windows 服务，安装时绑定一个 Windows SID；命名管道 ACL 只授权 SYSTEM 和该 SID，服务核对实际调用者，UI 核对服务端 SYSTEM 身份。单个控制连接拥有会话，EOF / 心跳超时必须断开；SCM 崩溃恢复只清理，不能自行读取密码或重连。
- `XDVPN.Platform`：命名管道限长协议、物理网卡观察、凭据与日志、OpenConnect 进程及网络脚本。
- 引擎固定 OpenConnect 9.21 源码 SHA-256，GnuTLS 使用 Windows 系统信任；Wintun 驱动使用官方签名 DLL。只从 Program Files 固定受保护目录执行。原生补丁只桥接继承的私有管道到 OpenConnect 的取消 / 暂停恢复命令，不引入跳过证书验证的路径。

## 自动重连契约

1. 手动断开 / 取消立即撤销本次连接意图，取消所有待重试；网络恢复与唤醒不能重新连接。Auto Connect 偏好保留；关闭偏好不拆除健康隧道。
2. 网络快照只比较真实硬件接口、可用 IPv4 地址和网关，忽略 Wintun、虚拟适配器、DNS 和 VPN 路由通知。周期复核补偿遗漏通知；1 秒防抖。
3. 已连接的物理网络变化立即进入恢复；通过专用控制管道请求原会话恢复。同轮恢复期限 3 秒，不因重复消息延长；恢复命令间隔至少 3 秒。
4. 期限到达后取消旧进程，等待退出与网络清理读回验证；Auto Connect 开启才重新登录。登录期间切网同样串行清理后重建。
5. 意外退出 / 暂时传输失败按 3、6、12、24、48、60 秒退避，带 ±20% 抖动且不超过 60 秒；切网与唤醒重置退避。登录 90 秒超时。
6. 离线 / 睡眠停止旧隧道并暂停登录；网络稳定后恢复。认证拒绝、证书错误、额外认证、初次网络配置失败停止本次重试，避免反复提交错误密码。已建立会话恢复配置失败允许清理后重建。
7. 每次引擎启动带独立 UUID。迟到的退出 / 连接事件无法修改新尝试。任何网络清理失败都阻止再次建立隧道，直到明确连接时成功重试清理。

## Windows 网络与清理

首版承载 IPv4 VPN，显式关闭隧道 IPv6；不承诺接管本机 IPv6，也没有 Kill Switch。VPN 服务器使用 IPv4 解析结果固定本次外层连接。认证范围与 macOS 一致，不支持交互 MFA / SSO / HostScan。

固定 PowerShell 脚本通过 Windows NetTCPIP / DnsClient 模块设置专属 Wintun 接口、地址、DNS、split include / exclude 与网关主机路由。不执行服务端提供的 shell。所有字段逐项解析；IPv4 路由数量有上限。每个外部路由写入保护目录内的会话记录后才创建；已有路由不接管。清理精确匹配接口 GUID、目的前缀和下一跳，绝不按目的地址批量删除。接口 GUID / 名称不匹配时失败关闭，不清理他人接口。

服务结束进程后再次运行幂等清理，恢复前也核验遗留记录。引擎和脚本都在 Job Object 中；服务崩溃后子进程随 Job 关闭。脚本有超时，退出必须等待脚本树结束再清理。持久记录保留至读回通过。

## 构建与验收

Windows CI 构建原生引擎、运行 Core 状态机测试、编译 WPF 和服务、打包自包含 x64 安装目录。安装脚本需要一次管理员授权，固定安装 Program Files，配置服务及受保护 ProgramData；卸载先停止并确认清理。默认只生成本地 / CI 测试产物，不发布 Release。

本机 macOS 可以执行 Core 测试及启用 Windows targeting 的编译；WPF 视觉、驱动加载、UAC、服务管道身份、真实切网、睡眠、DNS / 路由恢复必须在 Windows 真机验收。不能将编译成功等同实机通过。

参考：[WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/)、[Windows 命名管道](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)、[MIB_IF_ROW2](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/ns-netioapi-mib_if_row2)、[OpenConnect 手册](https://www.infradead.org/openconnect/manual.html)、[官方更新记录](https://www.infradead.org/openconnect/changelog.html)、[Wintun](https://www.wintun.net/)。

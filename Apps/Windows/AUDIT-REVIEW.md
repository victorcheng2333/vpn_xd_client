# Windows 0.1.2–0.1.3：Claude 审计复核与修复

范围：`codex/windows-support` 当前工作树；包括此前 UI/安装修复。本轮只进行了代码修改、隔离测试、构建与解包检查，没有切换 Hillstone、登录真实 VPN、改变实际路由/DNS，或停止安全代理。审计文本中的智能体数量和“全部证伪/全部验证”不作为结论依据。

## 0.1.3 实机反馈补充

0.1.2 新增的路由审计在安装目录触发了运行时编译错误，这是本次实现/打包遗漏。生产 PowerShell 4100 日志与普通用户的工作目录对照已证实 .NET10 `System.dll` 干扰 PS5.1 CodeDOM 的 Framework 引用；已改为随包预编译 DLL，并在实际 facade 共存的冷进程环境中验证。该错误不能归因于用户密码、安全代理或猜测的 /32 路由问题。证据见 [VERIFICATION.md](VERIFICATION.md)。

## 对原诊断的判断

不能断言“代码已经排除，最可能是企业环境”。代码中确有可复现的原生控制唤醒缺陷和多处跨层错误。修复前，C/R/EOF 控制事件在实际 libopenconnect 主循环中无法及时处理；修复后，取消/重连/父管道关闭和统计请求均可处理。这能解释长时间断开、恢复失效，但不足以独立证明业务访问失败的唯一根因。

`/32` 地址与 on-link 路由不是 Wintun 三层模型的必然错误；没有改成猜测的 Hillstone `/20` 和网关。真正修的是显式 `/0` 策略、DNS 路径、实际选路冲突、地址状态和重连后的配置验证。服务器 MTU 已进入接口配置；没有凭“无 MSS clamp”就任意降 MTU。Windows HostScan 在现有 OpenConnect `auth.c` 中明确不支持并中止认证，不是已证实的“连上后隔离”原因，因此没有加入绕过检查的 CSD 参数。

## 完整审计逐项判定

| 项目 | 复核结果及处理 |
| --- | --- |
| A1 控制异常伪造 Cleanup/Exited | 成立，已修复。Controller 只发布实际控制故障；只有拥有进程的 EngineProcess 完成实际退出与清理后才能发布 Exited。 |
| A2 stopping 丢掉终止错误 | 成立，已修复。停止中仍保留认证/证书/额外认证错误；显式用户取消和首个终止错误优先，Stop 效果保持幂等。 |
| A3 取消/超时误分类 | 成立，已修复。取消为 None；DNS、控制就绪超时为 Transport；实际清理失败才 cleaned=false。 |
| A4 特权脚本诊断缺失 | 成立，已修复可观测性。保存有界的固定阶段/错误码、接口、数字路由/DNS快照；不保留原始服务器输出或凭据。Verify 锁忙为独立退出码 75，不伪报配置损坏。 |
| A5 文案作为错误类型、终态绿色 | 成立，已修复。Status 增加可兼容的 Failure 字段，按 attempt+Failure 去重；事件大小写不再使 state.Failed 显示绿色。 |
| B1 引擎所有权与句柄竞争 | 成立，已修复。每次 attempt 拥有独立 Session、进程、Job、管道和完成任务；SafeHandle 处理 Job；finally 收尾并仅回调一次。控制写入有界，超时仅终止捕获的该次进程。 |
| B2 无 owner 空会话永不清理 | 成立，已修复确定安全的情况。仅删除空目录或唯一未占用的零字节锁；存在未知文件、network/configured/pid 或占用锁时保留并报错。未加入可能遗留路由的 force-abandon。 |
| B3 升级残留旧 DLL | 成立，已修复。先读取旧清单，对旧有且哈希匹配的托管文件差集备份/删除；失败恢复。未知文件保留，已被改动的退役文件拒绝静默删除。 |
| C 三秒与脚本预算冲突 | 成立，部分解决。Windows 专用恢复预算设为 65 秒，覆盖两段最多 30 秒脚本；超时仍清理重建，重复事件不延长。尚未迁为进程内 IP Helper 快路径，不能宣称三秒恢复。 |
| D IPC 活性等同用户意图 | 成立，已修复。30 秒认证 owner 租约独立于 12 秒管道读超时，休眠冻结、唤醒续约。保持首实例 handle；EOF 后 Broken 状态也必须 Disconnect 才能再次接受连接。续约与过期通知入队受同一锁排序。 |
| E1 用户可写源提升执行 | 成立，已修复 EXE 路径。Setup 自身提权、持有源 EXE 禁止写/删除共享，在受保护的 Program Files 随机目录解包自身资源后运行脚本；普通父进程仅在成功后启动 UI。ZIP 脚本停止自提权，显式管理员运行仍需信任脚本来源。 |
| E2 预置显式 ACL 存活 | 成立，已修复。安装器递归替换精确 DACL 和可信 owner；服务读取授权 SID/写日志前，独立检查整个数据树的 owner/授权/reparse point。网络钩子重查关键目录。 |
| F NetworkPlan 与服务测试缝 | 部分成立。已增加 IEngine、服务驱动测试缝和实际 helper 生命周期测试。network.ps1 已在首笔修改前整体解析策略，并做实际路由区间覆盖验证；缺少单独 Core NetworkPlan 属于后续分层整理。iOS 的拒绝策略不能证明 Windows 全隧道+排除必错，Windows 保留可实现的排除并拒绝冲突。 |
| G MSYS2 依赖浮动 | 成立，仍未完全解决。已随包记录 pacman 的实际版本；OpenConnect/Wintun 固定哈希不等于整个 TLS 工具链可复现。建立版本/哈希锁及可用的包快照仍待完成。 |

## 数据通路的状态边界

SSL 和配置日志仅表示通道建立。服务每 30 秒核对接口身份、地址、MTU、DNS 和实际选路，再向服务器下发的最多两个 DNS 进行源地址和接口绑定的短时探测；也观察该代次新的入向字节。首次采样或恢复后的历史字节不算新回包。DNS 拒绝响应能证明往返通信，不能证明业务解析成功。无回包为“尚未验证”，配置冲突单独告警；主窗口和托盘均不再直接给绿色业务成功提示。

接口绑定遵循 Microsoft 的 [IP_UNICAST_IF 文档](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ip-socket-options)，使用网络字节序接口索引。管道保留对象并断开当前客户端后再等待，符合 [.NET NamedPipeServerStream API](https://learn.microsoft.com/en-us/dotnet/api/system.io.pipes.namedpipeserverstream?view=net-10.0)。供应链边界参考 [MSYS2 包管理文档](https://www.msys2.org/docs/package-management/)。

## 验证与剩余验收

测试证据、产物及各组结果见 [VERIFICATION.md](VERIFICATION.md)。已增加实际本地子进程/Job/匿名管道测试、真实随机命名管道续连、真实回环 UDP DNS、真实独占文件锁、真实临时文件 ACL 往返；路由和系统服务仍使用隔离替身。测试不会运行真实 VPN 登录或安装 SYSTEM 服务。

新 EXE 的 UAC 提升安装、首次安装/升级、业务网址、真实 Wi-Fi 切换和休眠恢复仍需实机验收。诊断脚本默认只读；用户显式指定目标后才做该目标的有界网络探测。没有证据将现阶段剩余不通归咎于 CorpLink、Hillstone 或服务端，也没有把单次回包等同于业务页面正常。

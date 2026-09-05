# 设计文档：Auto Connect 持久配置与本次连接意图分离

| 项目 | 内容 |
| --- | --- |
| 日期 | 2026-09-05 |
| 版本 | 1.1.2（build 5），沿用版本 2 权限助手 |
| 状态 | 已实现，已通过单元与集成测试；真实公司 VPN 实网验收待做 |
| 涉及文件 | `Sources/XDVPN/VPNModel.swift`、`Sources/XDVPN/ContentView.swift`、`Sources/XDVPN/MenuPanelView.swift`、`Resources/Info.plist`、`Tests/XDVPNTests/VPNModelTests.swift`、`Tests/XDVPNTests/RecoveryIntegrationTests.swift`、`README.md`、`VERIFICATION.md` |

## 1. 背景与问题

1.1.1 及更早版本里，`VPNModel.autoConnect` 同时承担两个角色：

1. **持久偏好**：写入 `UserDefaults` 的 `autoConnect` 键，决定下次启动是否自动连接。
2. **本次会话的保活开关**：开关打开时立即 `connect()`；任何"不该再自动连"的场景都直接把它写成 `false`。

第二个角色导致偏好在用户不知情的情况下被改写。旧代码里共有六处隐式写入：

| 旧写入点 | 旧行为 | 用户视角的问题 |
| --- | --- | --- |
| `disconnect()` | 手动断开即关闭并持久化 `false` | "我明明开了自动连接，断开一次就没了"，重启后不再自动连 |
| `receive(.failure)` | 密码／证书等失败关闭偏好 | 改好密码后还要记得再打开开关 |
| `fail(_:)` | 助手退出、缺少 OpenConnect 等终态错误关闭偏好 | 同上 |
| `forgetPassword()` | 删除密码时关闭偏好 | 重新填密码后偏好已丢 |
| `removePrivileges()` | 移除系统授权时关闭偏好 | 重新授权后偏好已丢 |
| `init` 启动任务 | 启动时缺配置或密码直接 `setAutoConnect(false)` | 首次启动就把用户刚设的偏好抹掉 |

此外两个开关入口的行为不一致：主窗口开关在断开清理期间被禁用；菜单栏开关要求先安装授权、再有配置，否则跳转页面而不写偏好。开关"打开即连接"也让它更像一个操作按钮，而不是 macOS 里常见的设置项。

## 2. 目标与非目标

**目标**

- 只有用户显式切换开关才写入 Auto Connect 偏好，其余任何路径都不改写。
- 切换开关只保存偏好，不发起也不断开连接。
- 开启后：应用启动时自动连接；连接中掉线后按既有退避／恢复策略重试。
- 手动断开只结束本次连接，之后网络变化、系统唤醒都不再自动拉起，直到用户再次点击连接或重启应用。
- 用户先点断开、再轮到启动自动连接任务执行时，不能出现"延迟登录"。
- 两个开关入口行为一致，断开清理期间也可以修改偏好。

**非目标**

- 开机自启动（登录项）。
- 修改重试退避、恢复超时、冷却等既有策略。
- 修改权限助手或授权模型。
- 让开关在关闭时断开当前连接（README 已承诺"单独关闭 Auto Connect 不会断开当前连接"）。

## 3. 设计

### 3.1 两层状态

| 状态 | 存储 | 唯一写入者 | 语义 |
| --- | --- | --- | --- |
| `autoConnect` | `UserDefaults["autoConnect"]` + `@Published` | `setAutoConnect(_:)` | 用户的持久偏好。回答"启动时要不要连、掉线要不要重试" |
| `desiredConnection` | 内存 | `connect()` 置 `true`；`disconnect()`、`fail(_:)`、`.failure` 事件、`quit`、`.stopped` 收尾置 `false` | 本次会话的连接意图。回答"现在有没有一次正在维持的连接" |
| `generation` | 内存 `UUID` | `connect()`、`disconnect()`、`quit`、授权期间的恢复 | 意图纪元。任何异步任务只在纪元未变时才允许推进状态 |

原则：**偏好是输入，意图是运行时状态，两者互不写入**。所有自动动作（启动连接、退避重试、恢复期限、网络恢复）同时要求 `autoConnect` 与 `desiredConnection` 为真；只要用户主动取消或出现终态错误，意图即被挂起，偏好保持不变。

### 3.2 决策矩阵

| 事件 | 偏好 `autoConnect` | 意图 `desiredConnection` | 行为 |
| --- | --- | --- | --- |
| 启动（`resumeAutomatically`） | 读取，不改写 | 若偏好为真则 `connect()` 置真 | 缺配置／密码时 `connect()` 只把 `page` 设为「VPN 配置」，不改偏好 |
| 打开开关 | 写 `true` | 不变 | 不连接；若正处于 `.reconnecting`，补启恢复期限 |
| 关闭开关 | 写 `false` | `.waiting` 时置假 | 取消排队的重试与恢复期限；已建立的隧道保留 |
| 手动连接 | 不变 | 置真，纪元更新 | 无论偏好如何都可连接 |
| 手动断开／取消 | 不变 | 置假，纪元更新 | 取消连接任务、重试、恢复；等待 OpenConnect 退出 |
| 可重试退出（网络掉线） | 不变 | 不变 | 偏好为真则退避重试；为假则报"连接已结束" |
| 终态错误（密码错、证书错、助手退出） | 不变 | 置假 | 进入 `.failed`，取消所有自动任务 |
| 网络变化／系统唤醒 | 不变 | 只在为真时响应 | 意图为假时忽略，因此手动断开或失败后不会被拉起 |
| 删除密码／移除授权 | 不变 | 不变 | 下次连接由 `connect()` 的就绪检查拦住 |
| 退出应用 | 不变 | 置假 | 偏好留给下次启动 |

### 3.3 启动自动连接与竞争

启动任务是 `Task { @MainActor }`，在 `init` 返回后的下一次主线程调度才执行。用户可能在此之前已经点了断开或关闭了开关。

```swift
if autoConnect && resumeAutomatically {
    let startupGeneration = generation
    Task { @MainActor [weak self] in
        guard let self, self.autoConnect, self.generation == startupGeneration else { return }
        self.connect()
    }
}
```

两个守卫分别对应两种取消方式：`autoConnect` 处理"启动后立刻关闭开关"；`generation` 处理"启动后立刻点断开或手动连接"。复用既有的意图纪元而不是新增一个"已取消"标志，是因为 `disconnect()`、`connect()`、`quit()` 已经会更新纪元，任何新的取消路径自然被覆盖，不需要再维护第二套状态。

### 3.4 `setAutoConnect` 收敛为纯偏好写入

```swift
func setAutoConnect(_ enabled: Bool) {
    guard autoConnect != enabled else { return }
    autoConnect = enabled
    defaults.set(enabled, forKey: "autoConnect")
    if enabled {
        log("Auto Connect 已开启。下次启动时自动连接，连接中掉线后自动重试；手动断开后保持断开。")
        if state == .reconnecting { enterRecovering() }
    } else {
        retryTask?.cancel(); cancelRecoveryDeadline(); retryAt = nil
        if state == .waiting { state = .idle; desiredConnection = false }
    }
}
```

相对旧实现的三处变化：去掉"未就绪就跳转配置页并返回"的前置检查；去掉打开时的 `connect()`；新增同值短路，避免 SwiftUI 绑定重复回写时重复记日志。

### 3.5 UI

- 主窗口卡片与菜单栏面板的开关统一为 `model.setAutoConnect($0)`，不再各自做授权／配置跳转。
- 去掉主窗口开关在 `.disconnecting` 期间的禁用，断开清理时也能改偏好。
- 两处开关都加 `.help`：「仅修改自动连接配置。手动断开后，需再次点击连接或重启应用才会连接。」
- 副标题文案从"唤醒或切换 Wi-Fi 后自动恢复"改为"启动时连接、掉线后重试；手动断开后保持断开"，与新契约一致。

## 4. 备选方案

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| A. 维持旧行为，只修文案 | 否决 | 隐式改写偏好是根因，文案解决不了"断开一次就丢偏好" |
| B. 开关即意图：打开就连、关闭就断 | 否决 | 与 macOS 设置项语义冲突；关闭开关顺带断线会误伤正在使用的连接，README 也已承诺不断开 |
| C. 手动断开后仅暂停到下一次网络事件 | 否决 | "刚断开又被自动连上"正是用户最反感的场景 |
| D. 新增 `suspendedUntilRelaunch` 标志表达"手动断开后挂起" | 否决 | `desiredConnection == false` 已经是这个语义；`generation` 已覆盖启动竞争，再加标志只会多一个需要同步的状态 |
| E. 本方案：偏好与意图分离 | 采纳 | 写入点收敛为一处，自动动作统一以"偏好 && 意图"为前提 |

## 5. 兼容性与升级

- `UserDefaults` 键名不变，bundle ID `com.xd.vpn` 不变，钥匙串密码沿用。
- 1.1.1 用户若曾因手动断开被隐式关掉偏好，升级后偏好仍是 `false`，需要手动再打开一次。这是一次性成本，之后不再发生。
- 行为变化：断开后不再自动关闭开关；启动时缺配置不再抹掉偏好，而是把主窗口切到「VPN 配置」页。
- 权限助手仍为版本 2，已有授权无需重装。

## 6. 测试与验证

测试策略：所有自动动作都用"事件序列 → 助手收到的命令数与最终状态"断言，偏好断言同时检查内存值与 `UserDefaults`。

新增或改写的用例：

- 打开开关只保存偏好，不发命令，网络／睡眠事件也不触发。
- 手动断开后网络变化、唤醒都不重连；再次手动连接后掉线可重试。
- 手动断开后重启，按保存的偏好自动连接；偏好为假则不连接。
- 启动任务执行前先断开、或先关闭开关，都不会出现延迟登录。
- `resumeAutomatically: false`（非主实例／自检模式）保留偏好但不连接。
- 断开清理期间来回切换开关，不重启隧道。
- 认证失败、助手退出后偏好保留，且后续网络事件不再拉起。
- 删除密码、未配置 VPN 时可以保存偏好；重启后停在配置页。
- 恢复集成测试改为显式 `connect()`，并断言超时后偏好仍为真。

结果：66 项全部通过，0 失败（43 项状态机、1 项恢复集成、15 项核心、4 项权限、3 项网络过滤与脚本语法）。本次审阅时在 `.build/auto-connect` 构建目录复跑一遍，结果一致。Release 编译、ad-hoc 签名与 ZIP 校验记录见 `VERIFICATION.md`。

## 7. 审阅结论与遗留问题

**结论**：改动自洽。偏好写入点从七处收敛为一处；启动竞争用既有纪元机制封死；README、VERIFICATION、UI 文案与代码行为一致；版本号与产物同步到 1.1.2。可以合入。

**遗留问题**（不阻塞本次交付，建议后续处理）：

1. 未配置 VPN 时打开开关没有即时反馈。旧版会跳转配置页并弹提示，新版只写日志。建议开启时若 `!readyToConnect` 补一条 toast，说明"已保存，补齐配置后下次启动自动连接"。
2. 关闭开关会把处于 `.waiting` 的**手动离线连接**一并取消（`state == .waiting` 分支不区分等待来源）。这与"仅修改配置"的契约不完全一致。可以在 `.waiting` 分支只在存在 `retryAt` 时才置为 idle。
3. 启动时缺配置会把 `page` 设为「VPN 配置」，但不打开主窗口。用户只有主动打开窗口才会看到。可考虑在这条路径上调用 `AppDelegate.showWindow()`。
4. 关闭开关没有日志记录，排查"为什么没自动连"时少一条线索。
5. 真实公司 VPN 的睡眠／切网／路由恢复仍需实网验收；本次没有启动交付应用或替换正在运行的客户端。

## 8. 相关文档

- `README.md`「Auto Connect 的行为」段：面向用户的行为承诺。
- `VERIFICATION.md`「当前交付：1.1.2」：本次构建、签名、测试记录。

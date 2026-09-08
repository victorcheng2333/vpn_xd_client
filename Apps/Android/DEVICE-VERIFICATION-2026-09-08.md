# Android 真机验收记录 — 2026-09-08

基线 `main@945d90b`（已合入 `codex/android-support`）；本轮为 0.1.2 debug 构建，覆盖 UI 对齐 iOS、稳定性修复与代码质量整理。

## 设备与范围

- OnePlus PKX110，Android 16 / API 36，arm64-v8a；与 09-07 同一台手机，覆盖安装保留了已保存配置与 Keystore 密钥（安装前先在旧版手动断开）。
- 真实凭据由用户此前保存在手机，本轮没有读取、导出或修改。`quality.json` / `recovery.json` 通过 `run-as` 读取，只含枚举事件、时间戳和门禁状态。
- 业务探测地址沿用 `https://versions.xmxdev.com/apps`，手机自带 `curl` 发 HEAD。
- 合成认证、存储和 Compose 测试集只在可丢弃的 API 32 arm64 模拟器上运行，不在真实配置手机运行。

## 结果

| 项目 | 证据与结果 |
| --- | --- |
| JVM / 模拟器 / lint | 16 / 16 JVM 测试；17 / 17 instrumentation（新增未配置弹窗、异步历史写入）；lintDebug 零错误；两个 ABI 原生引擎重编成功，engine.c 以 `-Werror` 编译 |
| 覆盖安装 | 0.1.2 / versionCode 3 覆盖 0.1.1，原配置直接可用；`03-new-idle.png` |
| 未连接样式 | 虚线环 + 电源图标 + 灰色 `#626D7A`，与 iOS ConnectionOrbitView 一致 |
| 首次连接 | 15:09:17.7 手动连接 → 15:09:18.3 已连接（0.6 秒），事件序列 START→AUTHENTICATING→ESTABLISHING→TLS→CONNECTED，**不再出现旧版每次开头的假 OFFLINE** |
| 已连接样式 | 品牌绿实心圆 + 白色盾牌 + 双环光晕；`05-connected.png` |
| 连接质量页 | 状态 / 连接时长 / 传输方式 / 自动恢复 四行；完成恢复 / 成功 / 失败 三格（失败 > 0 橙色）；最近一次、恢复耗时、记录时间；`06-wifi-quality.png` |
| 蜂窝 → Wi-Fi | App 前台，15:09:58.370 开始恢复 → 15:10:00.704 恢复成功（2.3 秒），业务 HTTP 200 总计 0.221 秒 |
| Wi-Fi → 蜂窝 | 15:14:59 短暂 OFFLINE → 15:15:03.157 恢复成功（约 4 秒），业务 HTTP 200 总计 0.273 秒 |
| 收尾 | Wi-Fi 恢复为原来的关闭状态；VPN 保持已连接（与开始测试时一致） |

本机忽略目录 `Apps/Android/.build/verification-20260908/` 保存构建日志、instrumentation 日志、截图、`*-quality.json`、`*-recovery.json`、`*-http.txt`、`*-vpn.txt` 与验收辅助脚本 `acceptance.sh`。

## 本轮修改的依据与效果

- **每次切网都是冷认证，且这是网关行为。** 两个方向的恢复都出现 AUTHENTICATING，隧道地址由 `10.235.72.46/17` 变为 `10.235.136.46/18`，`recovery.json` 的 attempts 每次加一。带 Cookie 的热重连在 120 毫秒内退出，OpenConnect 9.21 只在 CONNECT 收到 401 时这么快返回 `-EPERM`。iOS 09-07 记录在同一网关是热重连、未重新认证，差异原因（例如网关按源 IP 或客户端类型区分）未判定，见「尚待补验」。09-07 记录的"两次切网后预算耗尽"由此解释：手动连接 + 两次切网 = 三次冷认证。
- **相同网关设置不再重建系统 TUN。** `configureTunnel` 在 `NetworkPlan` 与已应用方案相等且接口仍在时只再 `dup` 一份描述符。本轮两次切网因地址变化仍属重建，所以真机上未直接观测到复用；该路径覆盖 DPD 断链、DTLS→TLS 回退等同会话传输重连，由 JVM 测试锁定 `NetworkPlan` 相等性。
- **只有本机地址变化才强制重连。** 旧版对 `onLinkPropertiesChanged` 的任何变化都 PAUSE 引擎并重建 TUN（09-07 日志 3 分钟内 4 次 "Switch to 109"）。现在按 `LinkProperties.linkAddresses` 的地址集合比较，DNS / 路由 / MTU 抖动不触发。
- **引擎侧同步 iOS 主线修复。** `openconnect_set_dpd(30)`；"CSTP Dead Peer Detection detected dead peer" 触发恢复事件；认证或下发设置期间到达的换网请求记入 `reconnect_pending`，主循环进入时补发一次 PAUSE；同一时刻最多排队一个 PAUSE。
- **OFFLINE 事件 1.5 秒宽限**，避免注册回调尚未送达时记一条假的"等待物理网络"。
- **历史写入移出调用线程**，主线程（换网回调）不再同步写 2048 条 JSON；写失败只会把 incomplete 标为 true。
- **保存配置改用应用级协程作用域**，旋转不再取消保存或误报"保存失败"；忙碌状态进入 `ViewState.busy`。
- UI：未配置时弹窗「尚未配置 VPN → 去设置」（同 iOS main）；自动连接文案补齐"先保存账号"分支；连接质量页新增状态行、完成恢复数、最近一次结果、连接提示区和空状态；深色模式启动背景不再闪白；引擎事件改为具名常量。

## 尚待补验

- 网关对 Cookie 重连的策略：为何 Android 侧 CONNECT 401 而 iOS 侧可续用。可用同一账号在 Mac 上用 openconnect 命令行复现切网，或抓取网关侧日志；确认前不放宽五分钟三次冷认证预算。
- 同会话传输重连（DPD、DTLS 回退）下 TUN 复用的真机观测；本轮切网均伴随地址变化。
- DTLS 实际数据传输、飞行模式、锁屏 5/30 分钟、隔夜与耗电、系统回收进程、其他 OEM 与 API 28 真机、IPv6 泄漏探测，与 09-07 记录相同。
- 测试期间手机为用户日常使用状态（前台有其他应用），15:15:36 出现一次 CANCEL/START，为手机侧手动操作，不计入上述受控切网结果。

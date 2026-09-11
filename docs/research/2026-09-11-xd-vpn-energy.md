# XD VPN 三端耗电调研

XD VPN 的耗电影响主要取决于隧道维持多久、经过多少业务流量、底层是 Wi-Fi 还是蜂窝，以及连接是否稳定。当前代码存在可以直接收敛的后台工作，尤以 iOS 每 5 秒持久化诊断、Android 每 5 秒请求引擎统计最明确；但现有证据不足以给出三端通用的“多耗电百分比”。优化应先减少无效后台工作，再以真机对照测试决定是否调整保活、重连和数据转发。

本报告覆盖 macOS、iOS 和 Android，不覆盖 Windows。源码基线为 `ac0fde39724545b5df3a442e87286ba17c07d233`，核对日期为 2026 年 9 月 11 日；根版本为 1.1.25 / build 36，三端构建脚本均引用 OpenConnect 9.21 和 OpenSSL 3.6.2。当前 Mac 安装包实际为 1.1.19 / build 28，不能把源码目标版本当成设备已安装版本。对 `v1.1.19` 的回查确认，Mac 的 20 秒 DPD、30 秒质量评估和 3 秒旧会话恢复预算已经存在；后续主要变化包括权限助手与通信机制。移动端历史验收记录属于当时的开发版本，不等于当前版本能耗验收。[^1]

## 结论与判断边界

**可以确认的是工作频率和实现路径，尚不能确认的是这些工作各占多少瓦、多少电量。** 当前 Mac 两次只读快照均只发现空闲助手，未发现 XDVPN 主程序或 OpenConnect 引擎；助手显示 CPU 0.0%、累计 CPU 时间 1.75 秒，约 14.8 MiB 常驻内存。设备接电且电量 100%，没有 XD VPN 名下的睡眠阻止断言。这只说明该时刻空闲助手没有明显持续 CPU 活动，不能代表已连接状态，也不能把 0.0% 解释为零能耗。[^1]

| 场景 | 基于实现的判断 | 优先关注 |
| --- | --- | --- |
| Mac 稳定 Wi-Fi 办公 | 后台框架开销预计较轻；连接后的量级待测 | 隧道流量、DPD、30 秒质量评估 |
| iOS 稳定连接且锁屏 | 有明确可减少的诊断持久化；蜂窝下还需看无线电活动 | 每 5 秒写入、30 秒 DPD、实际传输协议 |
| Android 稳定连接且后台 | 有明确可减少的统计调度；未发现应用显式长持 WakeLock | 每 5 秒统计、30 秒 DPD、系统休眠行为 |
| 三端持续大流量 | 加解密、封装、复制、系统调用和链路效率更重要 | TLS/DTLS、流量范围、iOS 包处理 |
| 三端弱网或频繁切网 | 可能成为最明显的额外开销场景 | 握手、冷认证、DTLS 重试、业务重传 |

上表是调查优先级，不是实测的功耗排名。不能由“iOS 的复制层更多”推出 iPhone 一定比 Android 更耗电；设备、操作系统、无线网络与电池容量都会改变结果。

**建议先安排一轮小范围客户端优化：iOS 诊断改为状态变化落盘与按需查询，Android 后台停止或明显降低统计请求频率。** 保活间隔和重连预算属于第二轮实验项；完整加密协议迁移、网络引擎重写暂时缺少投入依据。

## 影响有多少应怎样量化

### 用同场景的设备增量衡量

应比较相同设备、相同业务负载下，连接 VPN 与未连接 VPN 的平均整机功率。记基线功率为 P₀，VPN 带来的功率差为 ΔP，电池可用能量为 E，则：

- 额外电量消耗速度，单位为电量百分点每小时：`100 × ΔP / E`。
- 稳态续航缩短比例：`ΔP / (P₀ + ΔP)`。
- 固定任务的额外耗能：`完成同一任务时 VPN 开启的总能量 − 关闭的总能量`。

这些关系是能量定义的推导，并非 XD VPN 测量结果。固定下载时长与固定下载字节数应分别测：吞吐下降时，即使瞬时功率差不大，也可能因任务持续更久而多耗电。

| 假设增加的平均功率 | 假设 60 Wh 笔记本电池的额外消耗 | 假设 15 Wh 手机电池的额外消耗 |
| --- | --- | --- |
| 0.1 W | 0.17 个电量百分点/小时 | 0.67 个电量百分点/小时 |
| 0.3 W | 0.50 个电量百分点/小时 | 2.00 个电量百分点/小时 |
| 1.0 W | 1.67 个电量百分点/小时 | 6.67 个电量百分点/小时 |

**这张表仅用于换算，不是预测区间，也不是任何设备的标称容量。** 例如基线为 6 W、额外功率为 0.3 W 时，稳态续航缩短约 4.8%；基线为 1 W 时，同样的 0.3 W 对应约 23.1%。这解释了为什么轻负载和锁屏待机更容易暴露小而持续的额外开销。

### 现有数字不能替代对照测试

macOS 活动监视器的 Energy Impact 是相对指标，不是瓦数，也不是电池下降百分比。iOS Power Profiler 的影响指标不能跨设备型号直接比较；Android ODPM 的功率轨道通常反映整机子系统，而非只属于 VPN。系统电池页面可用于发现线索，最终仍应以同机 A/B 差值归因。[^2][^3][^4]

目前没有三端可比的放电曲线、隧道业务字节数、保活包记录、CPU 唤醒轨迹或对照组。已有移动端验收主要证明连接与恢复可用；其中明确把隔夜、低电量或耗电留作待验收项目。因而，任何“目前固定多耗 5%—10%”或“优化后省电 80%”的说法都没有证据支持。[^15][^16]

## 三端共有的耗电来源

### 保活与无线电活动

Mac 设置 `--force-dpd=20`，iOS 与 Android 调用 `openconnect_set_dpd(..., 30)`。OpenConnect 9.21 根据最近接收时间决定何时发送 DPD；有正常接收流量时会推迟探测。未收到回应时会进一步探测，约两倍 DPD 间隔附近进入失联判定路径。因此，20/30 秒是探测参数，既不是严格的定时发包承诺，也不是每 20/30 秒重新登录。[^5][^8][^10][^14]

无业务、回应正常且进程持续获调度时，单个受探测通道可粗略估算为 Mac 每小时约 180 次、移动端约 120 次探测。TLS 控制通道与 DTLS 通道有各自的计时状态；网关下发的 Keepalive、主动探测和重新协商也会影响总包数。实际通信次数不能简单取上述数字，更不能把它当成设备从睡眠中被唤醒的次数。[^5]

手机网络通信的成本不只取决于字节数。小包也可能触发无线电从低功耗状态恢复，传输结束后还会维持一段活动状态。Android 官方文档说明，这类状态与尾部活动时间依赖无线技术和运营商；文档中的 3G 数值不能直接套用到今天的 LTE/5G。对 XD VPN 而言，锁屏、蜂窝、稀疏通信是优先实测组合。[^7]

**优化方向是验证 30、60、90 秒等参数，而非直接关闭 DPD。** Mac 已有网络事件驱动的恢复，移动端也有路径回调，可减少对短间隔轮询的依赖；但“网络接口仍可用、网关却不可达”仍需要探测。还必须确认网关 Keepalive、NAT 空闲超时与会话策略，否则仅增大客户端 DPD 可能几乎不省电，或以更长的业务中断换取表面上的安静。

### TLS 回退与 DTLS 尝试

OpenConnect 的 AnyConnect 路径先建立 HTTPS/TLS 会话，并尝试用 UDP/DTLS 承载数据；UDP 不可用时可回退到 TLS。其官方技术说明指出 TCP 隧道承载 TCP 流量存在效率问题。对大流量或丢包环境，应验证 DTLS 是否真正承载业务，而不能只看“VPN 已连接”。能效改善是待测假设，不能直接从吞吐结论推导出省电百分比。[^6]

两移动端调用 `openconnect_setup_dtls(..., 30)`，这里的 30 是 DTLS 尝试周期，与 DPD 的 30 秒含义不同。只有进入可重试的 DTLS 状态才会周期性尝试；缺少 DTLS 地址、密钥或某些能力错误时，引擎可能停止尝试。因此“当前是 TLS”不足以证明存在每 30 秒一次的失败握手。应采集回退原因和尝试次数，再决定是否在同一路径连续失败后延长尝试间隔、切网后重新探测。[^5][^11][^14]

### 业务流量与全隧道范围

经过隧道的数据需要额外封装、加解密和转发。全隧道还会处理浏览器、同步软件等其他应用的流量；其中本来就会发生的业务通信不能全部算作 VPN 新增耗电。需要比较“完成相同业务”的设备能量，区分隧道处理成本、链路绕行和额外重传。

iOS 新配置默认支持公司网关要求的全隧道，实际路由由网关下发并校验；Android 从 NetworkPlan 配置路由，Mac 使用网关配置及网络脚本。iOS 的 `includeAllNetworks=false` 不代表分流，默认路由仍可进入隧道。只有公司网关策略允许时，才评估内网路由与 DNS 分流；不得为省电擅自改变流量保护范围。[^21]

## macOS 的具体发现

### 稳定后台开销相对克制

Mac 将界面、权限助手和 OpenConnect 数据处理分开。引擎空闲时使用文件描述符等待；App 的网络监控采用 SystemConfiguration、CoreWLAN 与 NWPathMonitor 通知，而非定时访问业务网站。连接状态稳定时，OrbitView 的 30 fps 时间线被暂停；动画主要用于连接与恢复过程。自动更新检查的门槛是 24 小时，不能列为每秒级后台负担。[^8]

App 存活期间，`qualityAlertTask` 不区分是否连接或是否显示窗口，每 30 秒执行一次质量告警计算。`refreshQualityAlerts` 会过滤历史并扫描中断事件，事件数上限为 10,000；质量页显示时还有独立的 30 秒刷新。理论上后台评估约 120 次/小时，实际调度受系统影响。对正常低事件量会话，计算可能很轻；它是明确可优化的工作，而非已证实的大功耗热点。[^8]

建议将质量计算改为事件到达时更新，再根据 10 分钟、24 小时窗口的下一次过期时间安排检查。没有事件、没有待过期告警时，可以不安排周期任务；质量页使用缓存。若保留定时器，应允许容差，并避免在无人查看时重复生成相同统计。Apple 的节能指引支持事件通知、减少定时器和合并可延后的工作。[^9]

### 弱网恢复比界面更值得关注

物理网络可用时，客户端仅给旧会话约 3 秒恢复预算，然后进入停止、清理和可能的冷重连；这短于命令行配置的 300 秒引擎恢复窗口。自动重试有 3、6、12、24、48、60 秒退避，睡眠与离线时会暂停主动恢复。3 秒策略有快速释放失效隧道、恢复普通上网的价值，但在高延迟或拥塞网络中可能放大冷认证、进程启动和路由操作。[^8]

应先统计恢复超过 3 秒的会话比例、随后重新登录是否成功、每小时冷认证次数，再对特定失败类型测试 3/6/10 秒预算。不能把“全面延长重试”当作确定的节能改进，因为它也可能延长黑洞连接。睡眠暂停、通知去重和路由准确清理应继续保留。

日志通常按事件写入，并非逐数据包持久化；助手在错误、失败或停止事件才执行 `fsync`。稳定期它不是优先怀疑对象，异常事件密集时则可能与重连共同放大 I/O。可以合并重复错误，但应保留关键状态和清理失败记录。当前安装版 1.1.19 与源码版的助手生命周期不同，相关实测必须分别标记版本。[^8]

## iOS 的具体发现

### 每 5 秒写入诊断是最明确的低风险优化项

PacketTunnelProvider 在隧道启动后创建 5 秒重复定时器，未显式设置 leeway。每次 `saveSnapshot` 都更新 `updatedAt`，重新编码并以原子写入方式保存 `diagnostics.json`，即使包计数和连接状态完全不变。定时器在停止或失败时取消；`sleep` 回调本身只记录事件，并未主动取消此计时器。它独立于 App 是否在前台。[^10]

持续获调度时，相当于约 720 次写入请求/小时；这不是 720 次物理闪存刷盘或 720 次从深睡唤醒。系统可能暂停、延迟或合并工作，原子文件替换也不能等同于每次同步写到闪存。主 App 的质量页已限制为可见且 active 时每 5 秒查询一次，但扩展处理查询又会调用 `saveSnapshot`，因而前台查看还可能叠加一组写入。质量历史 `persistQuality` 已有内容去重，问题主要在诊断快照。[^10]

建议把“生成当前状态”和“持久化状态”分离：页面查询直接返回内存快照；连接、恢复、失败、停止等关键状态立即落盘；业务包计数最多每 60 秒在变化时保存一次；后台无变化不写。若需要诊断新鲜度，应区分“最后持久化时间”和“最近一次成功查询时间”，避免减少写入后被界面误判为隧道失联。

仅把周期从 5 秒调为 60 秒，理论写入请求可由 720 降至 60 次/小时，减少约 91.7%。按需与去重可以进一步减少；**91.7% 指该项调用次数，不是电池节省比例**。验收时要验证崩溃后保留关键恢复事件、锁屏恢复正常，以及打开页面后能立即看到新鲜计数。

### 大流量时可优化包处理

iOS 路径为 NEPacketTunnelFlow、Swift PacketPump、本地 Unix datagram socketpair、OpenConnect。出站逐包编码并发送；入站每次 drain 分配约 9 KB 缓冲区，最多读取 64 个包，但每包分别调用 `writePackets([packet], ...)`。编码与解码还涉及 Data/数组构造。与 Android 直接把 TUN 描述符交给引擎相比，iOS 多了一层公开 API 适配和数据搬运。[^11]

Apple 的 `writePackets` 支持数组，可将同一次已经读到的有效包组成一个有界批次提交，复用接收缓冲区，并减少可避免的中间对象。应保持当前背压与丢包计数，不为攒批次增加等待，不建立无界队列。收益主要预期出现在高包速率下，不能用来解释无流量时的主要耗电。优化后比较 CPU 秒/GB、调用次数/包、吞吐和尾延迟，同时检查大流量与切网取消是否互相阻塞。[^12]

不建议通过读取 NEPacketTunnelFlow 的私有 TUN 描述符绕过公开 API；Apple 明确指出这不是受支持的产品实现方式。[^13]

## Android 的具体发现

### 服务统计可以按需调度

XDVpnService 从启动到清理期间，每 5 秒执行 `engine.stats()`。JNI 向引擎命令管道写入 `OC_CMD_STATS`，触发本地统计回调并更新 StateFlow；不依赖质量页是否可见。持续运行且引擎处于主循环时，约为 720 次本地统计请求/小时。OpenConnect 会自行维护 DPD 截止时间，统计命令本身不是保活协议，也不是一次网络测速。[^14][^5]

建议只在可见质量页订阅期间保持 5 秒刷新，离开后取消；如需要后台统计落点，可采用 30—60 秒聚合与状态事件触发。5 秒改为 30 秒意味着该项调度从约 720 降至 120 次/小时，减少约 83.3%，仍不能直接换算为电池节省。冷却期或没有可用引擎时也无需持续请求空统计。

代码未声明 WAKE_LOCK 权限，未发现应用显式持有 WakeLock；离线等待使用条件变量/等待通知，非忙循环。`Handler.postDelayed` 的时基不计深睡，深睡会延后回调，不能说它每 5 秒强行唤醒已休眠设备。前台服务的常驻通知也不等于 CPU 始终运行。这些是避免夸大风险的关键边界。[^14][^17]

### 已有恢复保护应保留

Android 把 TUN 描述符交给原生 OpenConnect，业务包不逐包经过 Kotlin/JNI。相同网络配置会复用已有 TUN；回调只对相关地址变化强制恢复，避免 DNS/路由变化引发无谓重连。UI 质量页的 1 秒时钟已绑定 STARTED 生命周期。这些路径不宜为了形式上的“减少线程”而重写。[^14]

历史 OnePlus / Android 16 验收记录显示，两次 Wi-Fi/蜂窝切换都进入重新认证；旧会话快速失败与 CONNECT 401 相符，但 Android 与 iOS 的行为差异原因尚未判定。它证明“切网可能伴随更昂贵的冷认证”值得调查，不能证明所有 Android 设备都会这样。两移动端均有每 5 分钟最多 3 次冷认证的持久化预算，该预算应保留，并与引擎内部的旧会话重试分开统计。[^16][^18]

### 计费标记不是已确认问题

`Builder.setMetered(false)` 的官方含义是让 VPN 继承底层网络的计费属性；不是强制把蜂窝网络标成免费网络。当前代码还维护 `setUnderlyingNetworks`，因此不应把这一行列为耗电缺陷。可以在设备上验证 VPN 的实际网络能力随 Wi-Fi/蜂窝正确变化，但没有依据为省电直接删除它。[^19]

## 优化优先级与可验收收益

以下顺序按证据确定性、影响范围和实施风险排序，不是按已测得的瓦数排序。所有数值都是建议实验参数或调用次数推导。

| 优先级 | 改动 | 可先验证的收益 | 主要约束 |
| --- | --- | --- | --- |
| P1 | iOS 诊断按需返回、变化落盘 | 周期写入 720→至多 60 次/小时；空闲可更少 | 关键事件持久性、数据新鲜度 |
| P1 | Android 统计按可见性订阅 | 后台周期请求可停止，或降至 60—120 次/小时 | 页面重入立即刷新 |
| P2 | Mac 告警改事件及过期时间驱动 | 减少无事件时的 120 次/小时扫描 | 告警要按时解除 |
| P2 | 三端验证 DPD 参数 | 减少空闲通信与无线电活动的可能性 | NAT、网关 Keepalive、失联延迟 |
| P2 | 查明 DTLS 回退及失败尝试 | 减少重试；改善部分大流量任务效率 | 网络与网关支持，需实测 |
| P2 | 按失败类型调整恢复预算 | 降低无效冷认证、进程和路由重建 | 业务可恢复性与黑洞时长 |
| P3 | iOS 有界批量写包与缓冲复用 | 降低高包速率下调用和分配成本 | 丢包、延迟、取消响应 |
| P3 | 网关允许时评估路由分流 | 减少客户端处理的非办公流量 | 公司安全及路由策略 |

P1 可以在不改变隧道协议的前提下推进。建议一个改动一个实验版本，以便确定收益来自哪里；不要同时调整 DPD、DTLS 和重连时限，再把总差值归因给某一个参数。

当前应优先保留既有的原生架构，针对可定位的工作量做优化。三端均使用原生客户端和固定版本原生加密库，引擎构建已启用优化；没有证据表明界面框架是当前首要负担。完整替换 OpenConnect 或更换 VPN 协议需要额外验证公司网关兼容性，现阶段的能耗证据不足以支持这类重写。[^22]

## 真机对照实验方案

### 分开回答产品成本和实现效率

第一组比较“完全退出/未启用 VPN”与“VPN 连接”，测用户实际多付出的能耗；Mac 另加“App 开着但断开”的对照，以分离界面与后台监控。移动端应确认隧道和自动恢复是否真正停止，不能只关闭主 App。第二组比较“同一 VPN 的原版与优化版”，测实现改进；保持相同网关、路由与业务保护范围。

| 用例 | 建议时长 | 对比与记录 |
| --- | --- | --- |
| 稳定 Wi-Fi 空闲、界面隐藏 | 每状态 30—60 分钟 | 整机功率、CPU 秒、调度与写入次数 |
| 手机锁屏 Wi-Fi 待机 | 每状态 2 小时起，补隔夜 | 放电、深睡、保活和意外重连 |
| 手机锁屏蜂窝待机 | 每状态 2 小时起 | 信号、4G/5G、无线电活动、流量 |
| 固定办公任务序列 | 每轮 30—60 分钟 | 相同操作与完成结果、耗能和延迟 |
| 固定数据量的大流量任务 | 同字节数，多轮 | 总焦耳/GB、完成时间、TLS/DTLS |
| 弱网和网络切换 | 固定脚本，多轮 | 恢复耗时、失败率、冷认证、重传 |

建议每个状态至少做 3 次配对测量，随机化或交替执行 A/B 顺序；这是起步方案，方差大时增加样本。先预热并稳定设备温度，固定亮度、屏幕状态、电量区间、同步负载及网络位置，记录所有偏离。分析报告同时给平均差值和区间；若区间覆盖零，应写“该测试精度下未检出差异”，而不是宣布省电。

需要测试服务器或可控路由器来制造弱网、UDP 阻断与黑洞场景；不要在日常工作网络中随意改路由。下载测试应使用同一合法可达的内容端点并固定数据量；仅内网可达的业务无法直接做 VPN 关闭的同业务对照，可比较原版与优化版，或者另设有等价可达性的测试网络。

### 平台工具与关键限制

Mac 同时观察 XDVPN、权限助手、OpenConnect，以及整机的网络、CPU 和磁盘活动。活动监视器与 Instruments 可定位热点；`powermetrics` 可辅助观察平台支持的功率与唤醒指标，但 CPU/GPU 子系统功率不能冒充整机电池功率。释放开发负载后，再做电池供电的 A/B；当前接电且没有活动隧道的快照不能用来估算续航。[^2][^20]

iOS 应分别分析主 App 与 Packet Tunnel Extension。iOS/iPadOS 26 及以上可用 Power Profiler；旧系统采用其支持的 Instruments 能耗与性能工具。Apple 说明，充电时整体系统功率会报告为 0；Xcode 连接还会影响芯片睡眠观测。短时定位可以调试采集，锁屏/深睡结论应使用脱离 Xcode 的设备端记录，再回收分析；不能把调试器干扰当成 VPN 耗电。[^3]

Android 优先使用 System Trace / Perfetto 或 Power Profiler。官方列出的 ODPM 支持范围是 Pixel 6 及后续部分平台条件下的设备，具体轨道随硬件而变；现有验收所用 OnePlus 不能默认具备相同能力。不支持轨道时，可组合电量计、可用的电荷计数、CPU 调度和网络事件；Batterystats 可辅助归因，但 Battery Historian 已不再积极维护，不适合作为新测量体系的唯一核心。[^4][^23]

### 将能耗与可靠性共同设为验收门槛

P1 的首个验收门槛是后台确实没有多余诊断写入/统计请求，同时页面打开后立即刷新，状态事件不漏记，锁屏和切网仍可恢复。随后验证总功率或任务能量下降，改善幅度高于测量噪声。不能仅凭调用次数减少就宣布完成省电验收。

DPD、DTLS、重连和批量转发必须同时给出恢复成功率、恢复耗时分布、任务完成时间和丢包/重传变化。对公司网关优先采集实际 Keepalive、DTLS 能力、会话过期原因及匿名化错误分类；无需记录用户业务内容或凭据。只有在能耗改善且可靠性符合产品要求时，才将实验参数设为默认值。

## 证据索引与参考资料

源码位置均相对于仓库根目录 `/Users/chengfei/Documents/dev/vpn_xd_client`，固定在上述提交；它们是本地读取的项目证据。公开文档访问日期均为 2026 年 9 月 11 日。归档 Apple 指引仅用于解释通用节能机制；工具能力和计费 API 语义采用当前文档。以下脚注同时构成完整来源目录。

[^1]: 本地版本与状态证据：`Resources/Info.plist`；`Package.swift`；`Apps/iOS/Configuration/Base.xcconfig`；`Apps/Android/app/build.gradle.kts`；三端 `build-engine.sh` / `scripts/build-openconnect.sh`；`git show v1.1.19` 与相关源码差异。已安装 `/Applications/XD VPN.app/Contents/Info.plist` 为 1.1.19/28。只读 `ps`、`pmset -g batt` 与 `pmset -g assertions` 的摘要见同目录 `2026-09-11-xd-vpn-energy-evidence.json`，非连接态功耗测试。
[^2]: Apple Support， [View energy consumption in Activity Monitor on Mac](https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac)，当前 macOS Tahoe 26 指南；Energy Impact 是相对指标。
[^3]: Apple Developer， [Measuring your app’s power use with Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)，当前文档；系统版本支持、扩展分析、充电与 Xcode 连接限制。
[^4]: Android Developers， [Power Profiler](https://developer.android.com/studio/profile/power-profiler)，更新于 2026-03-06；ODPM 支持、设备级归因与电量计指标。
[^5]: OpenConnect 9.21 [官方源码包](https://www.infradead.org/openconnect/download/openconnect-9.21.tar.gz)；本地缓存 `.build/openconnect/arm64/sources/openconnect-9.21/`：`mainloop.c:166–198,424–493`，`cstp.c:508–551,1134–1192`，`dtls.c:176–198,240–265,354–405`，`ssl.c:908–910`。参数补充：[OpenConnect manual](https://www.infradead.org/openconnect/manual.html)。
[^6]: OpenConnect， [How the VPN works](https://www.infradead.org/openconnect/technical.html)，无标明更新日期；仅采用 TLS/DTLS 架构与 TCP 承载 TCP 的说明，不采用页面中陈旧的 OpenSSL 兼容版本建议。
[^7]: Android Developers， [Optimize network access](https://developer.android.com/develop/connectivity/network-ops/network-access-optimization)，更新于 2026-09-01；无线电活动及网络代际/运营商差异。页面的具体状态时间是 3G 示例。
[^8]: Mac 源码：`Sources/VPNCore/Profile.swift:68–78`；`Sources/XDVPN/VPNModel.swift:155–179,370–381,510–570,598–620`；`Sources/XDVPN/ConnectionQuality.swift:88–156`；`ConnectionStatusView.swift:68–113`；`QualityView.swift:8`；`UpdateManager.swift:24–28`；`Sources/VPNCore/EngineDiagnostics.swift:138–149`；`PhysicalNetworkMonitor.swift`。
[^9]: Apple Developer， [Minimize Timer Use](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html)，归档 Energy Efficiency Guide，2016 年时代文档；定时器、事件通知与容差的通用机制。
[^10]: iOS 诊断源码：`Apps/iOS/PacketTunnel/PacketTunnelProvider.swift:75–78,262–270,293–295,333–342,371–382`；`Apps/iOS/Common/SharedStore.swift:19–21`；`Apps/iOS/App/ConnectionQualityView.swift:9–12,94–101`；`Apps/iOS/App/VPNModel.swift:282–296`；`Apps/iOS/OpenConnectAdapter/OCEngine.m:219–220`。
[^11]: iOS 包处理源码：`Apps/iOS/PacketTunnel/PacketPump.swift:30–61`；`Apps/iOS/Common/PacketCodec.swift`；`Apps/iOS/OpenConnectAdapter/OCEngine.m:233–258`。
[^12]: Apple Developer， [writePackets(_:withProtocols:)](https://developer.apple.com/documentation/networkextension/nepackettunnelflow/writepackets%28_%3Awithprotocols%3A%29)，当前 API 文档；支持包数组，协议数组须一一对应。具体批量大小与收益为本报告建议，非 Apple 基准结果。
[^13]: Apple Developer Forums，Apple DTS 工程师关于 [Get file descriptor of VPN TUN interface](https://developer.apple.com/forums/thread/13503) 的答复，2015 年与 2021 年；指出通过私有描述符绕过 Packet Flow 不受支持。
[^14]: Android 源码：`Apps/Android/app/src/main/java/com/xd/vpn/android/service/XDVpnService.kt:38–40,74–78,135–170,183–224,238–239`；`engine/NativeEngine.kt:33–36`；`Apps/Android/native/engine.c:193–219,255–283,299–307`；`Apps/Android/app/src/main/AndroidManifest.xml`；`ui/VPNApp.kt:256–267`；`data/VPNRepository.kt:101,120–130`。
[^15]: 本地验收记录：`Apps/iOS/DEVICE-VERIFICATION-2026-09-07.md`，含后续 09-08 增补；短锁屏、TLS 状态与剩余验证范围。其短时 Time Profiler 记录并非受控能耗测试。
[^16]: 本地验收记录：`Apps/Android/DEVICE-VERIFICATION-2026-09-08.md`，OnePlus PKX110 / Android 16、当时 0.1.2 debug；两次切网冷认证的观察及尚待补验条目。另见 `Apps/Android/VERIFICATION.md`。
[^17]: Android Developers， [Handler.postDelayed](https://developer.android.com/reference/android/os/Handler#postDelayed(java.lang.Runnable,long)) 与 [SystemClock](https://developer.android.com/reference/android/os/SystemClock)，当前 API 文档；uptime 时基与深睡延后。
[^18]: 恢复预算源码：`Apps/iOS/Common/RecoveryPolicy.swift:20–31`；`Apps/iOS/PacketTunnel/PacketTunnelProvider.swift:112–125,225–235`；`Apps/Android/app/src/main/java/com/xd/vpn/android/core/RecoveryPolicy.kt:15–26`；`service/XDVpnService.kt:96–118,145–152`。
[^19]: Android Developers， [VpnService.Builder.setMetered](https://developer.android.com/reference/android/net/VpnService.Builder#setMetered(boolean))，更新于 2026-08-03；false 继承底层计费属性。配合 [VpnService.setUnderlyingNetworks](https://developer.android.com/reference/android/net/VpnService#setUnderlyingNetworks(android.net.Network[]))，更新于 2026-08-28。
[^20]: Apple Developer， [Monitor Usage Regularly](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html)，归档 Mac 节能指南；用于活动、CPU、Instruments 与命令行定位思路，当前 Energy 面板语义见来源 2。
[^21]: 路由源码：`Apps/iOS/Common/VPNProfile.swift:12–25`；`Apps/iOS/PacketTunnel/PacketTunnelProvider.swift:135–168`；`Apps/iOS/App/VPNModel.swift:254–265`；`Apps/Android/app/src/main/java/com/xd/vpn/android/core/NetworkPlan.kt`；`service/XDVpnService.kt:203–218`；Mac `Sources/VPNCore/TunnelNetworkSession.swift`。
[^22]: 原生构建证据：`Package.swift`、`scripts/build-openconnect.sh:23–24,74–98`、`Apps/iOS/scripts/build-engine.sh:32–33,65–85`、`Apps/Android/scripts/build-engine.sh:32–33,69–94`。本报告没有测试替代协议或宣称 OpenConnect 是最省电的引擎。
[^23]: Android Developers， [Profile battery usage with Batterystats and Battery Historian](https://developer.android.com/topic/performance/power/setup-battery-historian)，当前文档；明确说明 Battery Historian 已不再积极维护，建议系统追踪、Macrobenchmark power metric 或 Power Profiler。

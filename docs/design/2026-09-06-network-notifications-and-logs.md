# 1.1.8：物理网络通知去重与文件日志

## 依据和范围

用户提供的 Claude 运行质量检查显示：部分 AP 每 60 秒复述一次 en0 link ACTIVE，随后约 1 秒就出现新的 VPN TCP 连接。代码确认 CoreWLAN 的 link／power／SSID 通知曾统一无条件触发 onChange，而 configd 路径会比较快照；该差异会把相同状态重复当作需要恢复的变化。报告显示此类事件主要是同一个 VPN 进程内的传输恢复，不应与完整重新登录或 utun 重建混为一谈。本轮没有切换 Wi-Fi 或复现特定 AP 的真实 60 秒通知。

只修改 App 的观察、日志和页面。VPNCore、XDVPNHelper 及助手要求仍为 4，保留现有离线暂停、在线恢复期限、停止与原生清理策略。

## 通知判断

- configd、CoreWLAN link／power 都进入同一个 observe 比较函数，比较物理 en 接口的 Active、Addresses、Router、SubnetMasks、PrefixLength。只有这些字段变化才交给 VPNModel 安排恢复；额外路由、虚拟接口和仅有无关字段的空记录忽略。
- 每次都更新观察到的物理可用状态；普通状态复述只输出 shouldNotify=false 的诊断。VPNModel 将其只写入文件，不更新恢复任务、不重置退避／冷却、不改变连接意图。
- SSID 变化通知独立处理，所以切到相同 IP／网关的另一网络仍有主动恢复入口；不读取任何 SSID 名称或 BSSID。BSSID 的读取受定位授权限制，不能当作现有权限下可靠可得的标识。
- 同地址、同 SSID 的漫游如果没有产生可确认的物理变化或 SSID 通知，交给 OpenConnect 自身的传输恢复／DPD。保持同一条健康连接有利于避免每分钟主动重建；无法承诺所有同址漫游都立即被 App 识别。
- 接受的变化仍走原来的防抖和冷却；同一个变化先被 CoreWLAN 捕获后再被 configd 通知，不会因第二条相同快照再安排一次恢复。

## 文件日志

主 App 实例显式注入 RollingActivityLog，测试和第二个 App 实例默认不会创建真实用户日志。只接收应用生成的诊断及已有助手归一化消息，不接触 OpenConnect 原始输出、配置或凭据。

目录为 ~/Library/Logs/XD VPN，最多 4 个 1 MiB JSONL 文件。异步串行写入，固定文件名轮转，重启后追加已有文件。目录 0700、文件 0600；拒绝活动日志的符号链接／硬链接／非普通文件，打开时使用 NONBLOCK，避免误放 FIFO 导致线程卡住。正常退出先排空队列，最多等待 1 秒。

字段包含 timestamp（UTC 毫秒）、session（本次 App 会话）、version、source、event、stateBefore（处理消息前的状态）、connection（连接尝试 UUID）、autoConnect、isError、message。物理变化仅保留字段名，不保存网卡地址、SSID 或 BSSID。reconnect.requested 表示 App 已向助手发送恢复请求；助手是否接受及后续成功／退出应结合 helper 事件判断，不能单凭请求行声称信号已经完成。

重复通知只落文件，界面继续显示重要状态。日志写入失败只显示日志状态提示，不影响连接状态或丢掉内存中的本次会话记录。「打开日志目录」查看历史文件；复制、清空按钮仍作用于当前列表，清空列表会明确保留文件日志。

范围限制：系统助手版本和错误分类未改；目前不能保留助手已经过滤掉的 DTLS 错误，也不能收集 App 退出后助手独立清理时的消息。没有接入原始 stderr 或抓包，没有新增定位权限、网络探测或常驻服务。

## 验证重点

- 让相同 link／power／configd 通知跨过多轮防抖和冷却，在 Auto Connect 开关两种状态下确认没有额外命令或失败；随后相同地址的 SSID 通知应触发恢复。
- 真实网关、链路变化被接受，同一快照随后由另一来源复述被忽略。
- 模型连同日志验证 ignored、reconnect.requested、helper 状态及退出记录，确认凭据、配置字段和值未写入。
- 重启追加、会话区分、轮转总量、并发整行写入、权限、认证字段省略、符号链接／硬链接／FIFO 拒绝、日志失败不影响 VPN。

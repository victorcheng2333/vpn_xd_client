# ServiceManagement / XPC 迁移

目标：保留 OpenConnect、恢复状态机及归属核验清理逻辑，用 macOS 14+ 的 SMAppService LaunchDaemon 和双向签名约束 XPC 替代 sudoers 启动与临时 socket。

## 边界

- 服务、引擎、脚本随公司签名 App 分发。注册前和服务启动时验证完整包；临时签名构建可运行单元测试，但不能注册特权服务。
- XPC 两端在 resume 前设置 Apple Developer ID / Team ID / 精确代码标识要求；服务只接受非 root 用户。身份来自 XPC 内核凭据，不接收客户端传入的 UID、路径、PID、脚本或 shell。
- 握手比较协议版本、构建标识及包位置，避免连接到另一份 App 或升级前仍在运行的服务。
- 同时仅允许一个控制连接拥有隧道；失联后持有会话及旧版兼容锁直到原有 TunnelEngine 完成清理。重连只通过现有固定命令接口。
- 服务启动时复制完整 App 到 `/Library/PrivilegedHelperTools/com.xd.vpn.runtime` 下随机创建的 root 私有目录，再校验副本公司签名及其与源 App 的构建／引擎指纹。逐层检查父目录，专用目录使用 0700，不依赖 `/private/var/run` 的权限（macOS 可使用 root:daemon 0775）。引擎与清理脚本只从此副本执行；副本拒绝链接、移除其他用户权限及 set-id 位。源 App 被替换会阻止新的连接，但不会改变活动隧道的清理程序。正常退出清理副本；异常强杀可能留下仅 root 可访问的副本，不能在未确认无活动子进程时清除。
- 卸载前关闭并等待会话清理；服务收到 SIGTERM 同样先清理，LaunchDaemon 退出预算覆盖现有 40 秒停止预算。
- 旧授权仅通过明确迁移动作处理。在核对固定路径、备份及全部旧版会话锁后撤销旧 sudoers，再移除旧助手和运行时。新安装不写 sudoers。保留仅 root 可访问的迁移备份，迁移失败恢复旧文件。

## 验证

签名接受／拒绝、协议及构建不匹配、未握手命令、越权连接、重复会话、失联清理、清理中重入、畸形及超长报文、注册各状态、旧版迁移路径／锁／回滚；继续运行现有全部引擎、恢复、清理与发布测试。实际注册需 macOS 用户批准，真实 VPN 验收需单独记录，不能由 mock 测试替代。

参考：Apple SMAppService、NSXPCConnection.setCodeSigningRequirement 文档。

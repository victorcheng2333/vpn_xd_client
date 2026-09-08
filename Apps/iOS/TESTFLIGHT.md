# iOS TestFlight 自动发布

目标：[XD VPN / 6809404398](https://appstoreconnect.apple.com/apps/6809404398/testflight)。
`Configuration/TestFlight.json` 固定 App、团队、Bundle ID 和 App Group。
整个流程只使用 TestFlight，不创建或提交 App Store 正式版本。

## 一次性配置

需要完整 Xcode、Python 3 和 API Key 对应的签名、上传及 TestFlight 管理权限。

```sh
python3 -m venv Apps/iOS/.build/release-venv
Apps/iOS/.build/release-venv/bin/pip install -r Apps/iOS/scripts/requirements-testflight.txt
cp Apps/iOS/Configuration/TestFlight.local.example.json Apps/iOS/Configuration/TestFlight.local.json
chmod 600 Apps/iOS/Configuration/TestFlight.local.json
```

在被 Git 忽略的 `TestFlight.local.json` 填写 Key ID、Issuer ID、仓库外 `.p8` 的路径和已有外部测试组 ID。
配置文件只记录私钥路径，不复制私钥。环境变量 `ASC_KEY_PATH`、`ASC_KEY_ID`、`ASC_ISSUER_ID` 可覆盖本机值。
需确保 API Key 有 App Manager 或 Admin 等可管理 TestFlight 的权限，并具备 Xcode 自动签名需要的开发者资源访问。

`uses_non_exempt_encryption` 必须由团队确认后填写布尔值。`false` 表示未使用非豁免加密，不等于没有加密。
脚本没有默认答案；不会通过推断 OpenSSL 用途或复制历史值替团队声明。
使用非豁免加密时可另配 `encryption_declaration_id` 关联声明，Apple 合规审核仍须完成。
加密实现、用途或分发范围变动时需重新核对声明。既有远端声明与本机配置冲突时脚本中止。

先在 Connect 完成测试描述、反馈邮箱、审核联系人和必要的审核专用 VPN 账号。
脚本复用已有资料，只校验完整性，不把审核账号密码输出或保存到日志。

## 日常发布

从仓库根目录执行，先更新 `Apps/iOS/TEST-NOTES.txt` 测试说明（1–4000 字符），并提交待发布源码。

```sh
# 只读预检，显示下一个构建号和审核资料是否完整
Apps/iOS/.build/release-venv/bin/python Apps/iOS/scripts/release-testflight.py plan

# 测试 → Release 归档 → 签名验证 → 上传 → 等待处理 → 声明 → 测试说明 → 外测组 → Beta 提审
Apps/iOS/.build/release-venv/bin/python Apps/iOS/scripts/release-testflight.py release \
  --version 0.1.0 --notes-file Apps/iOS/TEST-NOTES.txt --submit-review --notify-testers
```

默认使用 `zh-Hans` 测试说明；可用 `--locale` 指定。`--build` 可显式指定 1–9999 的构建号；省略时查询本版本全部远端构建及本地归档后递增。
本机有进程锁，CI 有并发锁；不要同时从不同电脑/本机和 CI 发布相同版本，以免跨主机抢占构建号。
App 和 PacketTunnel 构建号一致，不修改 macOS 版本。

`--submit-review` 明确允许提交 TestFlight Beta Review；`--notify-testers` 允许启用 Apple 审核通过后的自动通知。
不带通知参数时保留已有通知设置。脚本复用现有外测组，不创建公开链接或扩大测试员名单。
首个构建仍需要 Apple 审核。返回 `WAITING_FOR_BETA_REVIEW` 表示已提交而非已可测试；
仅 `IN_BETA_TESTING` 报告 `testable: true`。可追加 `--wait-review 3600` 有限等待，或之后运行 status。

## 查询与中断恢复

```sh
Apps/iOS/.build/release-venv/bin/python Apps/iOS/scripts/release-testflight.py status --version 0.1.0 --build 6

# 对精确指定的已上传版本继续执行，不再归档/上传
Apps/iOS/.build/release-venv/bin/python Apps/iOS/scripts/release-testflight.py resume \
  --version 0.1.0 --build 6 --notes-file Apps/iOS/TEST-NOTES.txt --submit-review --notify-testers
```

默认等待 Apple 处理最多 1800 秒，可用 `--timeout` 调整。超时可 resume；不要盲目换号再传。
读取 API 对限流和临时服务错误有有限重试；写请求不自动重试，网络错误后先查询远端结果。
远端同版本构建已存在、本地归档已存在、包标识/签名/摘要不符或 Internal Only 包都不会继续上传。
Beta 被拒时不自动重提，先检查拒绝原因。已有审核中的构建不重复提交或改写测试说明。

本地输出在 `Apps/iOS/.build/testflight/<version>-<build>/`，包括归档、源码提交、二进制摘要、上传意图、上传回执和 `result.json`。
上传日志仅本机保留，不上传带账号元数据的完整 Xcode 日志。
低层 `testflight.py check/archive/verify/upload` 仍可单独使用；自动化推荐使用 `release-testflight.py`。

## GitHub Actions

`.github/workflows/ios-testflight.yml` 在 main 手动触发，同一脚本支持 release 和 resume。
Secrets：`IOS_ASC_KEY_ID`、`IOS_ASC_ISSUER_ID`、`IOS_ASC_PRIVATE_KEY`（`.p8` 全文）。
仓库 Variables：`IOS_BETA_GROUP_ID`、团队确认后的 `IOS_USES_NON_EXEMPT_ENCRYPTION`（`true`/`false`）；
非豁免加密需要关联声明时另设 `IOS_ENCRYPTION_DECLARATION_ID`。
私钥写入 runner 临时目录，权限 0600，结束后删除。
工作流只能在包含此工作流的 main 提交上运行；本机配置不会自动同步到 GitHub。

参考：[Apple API](https://developer.apple.com/documentation/appstoreconnectapi)、
[Beta 审核](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)、
[加密声明](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/)。

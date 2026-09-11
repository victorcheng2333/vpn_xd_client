# XD VPN 项目记忆

## iOS 发布范围（用户明确要求，2026-09-11）

- iOS **只提 TestFlight 内测**，不提外测审核，不分发到外测组，不提交 App Store 正式版。
- 用户说“发布一版”“重新提”“联合发布”时，iOS 仍遵守内测范围。只有用户明确更改此偏好，才能改变分发范围。
- 使用现有内部组「iOS 真机验证」，组 ID：`417e48d2-cf7f-41eb-b06c-cc4b5ccc0b20`。执行前通过 Apple API 确认组属于当前 App 且 `isInternalGroup=true`。
- 发布脚本使用 `--audience internal`，导出设置启用 `testFlightInternalTestingOnly`；处理完成后确认远端 `buildAudienceType=INTERNAL_ONLY`，只关联内部组。
- 不传 `--submit-review`、`--notify-testers`、`--wait-review`，不使用 `test-ug` 外测组。macOS、Android、Windows 的正式发布范围独立遵循用户要求。
- 构建号先查询远端和本地发布记录再递增，不重复上传已使用的编号。内测发布流程见 [Apps/iOS/TESTFLIGHT.md](Apps/iOS/TESTFLIGHT.md)。

历史记录：误按外测提交的 iOS `0.1.0 (7)` 已移除外测关联并作废，Apple 返回内外测状态均为 `EXPIRED`。后续构建按上述内测规则发布。

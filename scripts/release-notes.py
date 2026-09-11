#!/usr/bin/env python3
import os
import subprocess
from version import metadata

info = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print(f'''XD VPN {info['version']}（build {info['build']}）

- 减少后台诊断和连接质量统计的无效唤醒。Windows、macOS、Android 使用同一个版本、源码提交和 GitHub Release，所有安装包经版本及 SHA-256 校验后一起发布。
- macOS：连接质量历史由固定周期扫描改为在事件和时间窗口到期时更新，减少后台工作，同时保留告警产生与解除。macOS 14+，Apple Silicon 下载 arm64 DMG，Intel 下载 x86_64 DMG；使用公司 Developer ID 签名并完成 Apple 公证。
- Android：仅在连接质量页可见且 VPN 已连接时采样统计，离开页面、进入后台或连接恢复时停止统计轮询；页面和诊断报告明确显示统计观测时间。Android 9+，下载 `XD-VPN-{info['version']}-Android.apk`，支持 arm64-v8a / x86_64；沿用此前 APK 的签名，可覆盖升级并保留配置。下载后需允许安装未知来源应用。
- Windows：本次同步版本，功能沿用 1.1.25。下载 `XD-VPN-{info['version']}-Windows-x64.exe`。支持 Windows 11 x64（Windows 10 22H2 为兼容目标），内置 .NET 运行时、OpenConnect 和官方签名 Wintun。安装器尚未做代码签名，可能提示发行者未知；升级前从托盘退出旧版，再运行安装器。
- 本轮优化不调整 VPN 保活、认证、路由或断线恢复策略；实际节电比例仍需同机对照测量。
- 升级前断开 VPN 并退出旧版。macOS 将 DMG 中的应用拖入 Applications，按提示重新注册系统服务；配置和钥匙串密码沿用。
- macOS 应用内更新只识别本平台 DMG，并校验文件大小和 SHA-256。Windows、Android 暂无应用内更新，请从本页下载新版本。iOS 仍通过 TestFlight 单独分发，本次 GitHub Release 不包含 iOS 构建。

源码提交：{commit}
''')

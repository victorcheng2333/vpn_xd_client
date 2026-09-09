#!/usr/bin/env python3
import os
import subprocess
from version import metadata

info = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print(f'''XD VPN {info['version']}（build {info['build']}）

- Windows、macOS、Android 首次统一使用同一个版本、源码提交和 GitHub Release。所有平台构建及版本、SHA-256 校验通过后一起发布。
- Windows：下载 `XD-VPN-{info['version']}-Windows-x64.exe`。支持 Windows 11 x64（Windows 10 22H2 为兼容目标），内置 .NET 运行时、OpenConnect 和官方签名 Wintun。包含此前 Windows 预览版的配置失败修复、安装校验与回滚、断线恢复和连接状态改进。安装器尚未做代码签名，可能提示发行者未知；升级前从托盘退出旧版，再运行安装器。
- macOS：macOS 14+，Apple Silicon 下载 arm64 DMG，Intel 下载 x86_64 DMG。使用公司 Developer ID 签名并完成 Apple 公证；本次同步版本和发布流程，功能与 1.1.24 一致。
- Android：Android 9+，下载 `XD-VPN-{info['version']}-Android.apk`，支持 arm64-v8a / x86_64。本次同步版本和发布流程，功能与 1.1.24 一致；沿用此前 APK 的签名，可覆盖升级并保留配置。下载后需允许安装未知来源应用。
- 升级前断开 VPN 并退出旧版。macOS 将 DMG 中的应用拖入 Applications，按提示重新注册系统服务；配置和钥匙串密码沿用。
- macOS 应用内更新只识别本平台 DMG，并校验文件大小和 SHA-256。Windows、Android 暂无应用内更新，请从本页下载新版本。iOS 仍通过 TestFlight 单独分发，本次 GitHub Release 不包含 iOS 构建。

源码提交：{commit}
''')

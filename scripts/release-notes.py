#!/usr/bin/env python3
import os
import subprocess
from version import metadata

info = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print(f'''XD VPN {info['version']}（build {info['build']}）

- macOS 14+；Apple Silicon 下载 arm64，Intel 下载 x86_64。公司 Developer ID 签名，已完成 Apple 公证。macOS 功能与 1.1.23 相同，仅同步版本号。
- 新增 Android 安装包 `XD-VPN-{info['version']}-Android.apk`（Android 9+，arm64-v8a / x86_64）：连接、设置、连接质量三页与 iOS 对齐；AnyConnect 用户名/密码认证、IPv4 全隧道、DTLS 优先 TLS 回退、五分钟三次冷认证预算、脱敏诊断分享。下载后需允许安装未知来源应用；覆盖安装此前的测试包会保留配置。Android 版本暂不在应用内检查更新，请从本页下载新版本。
- Android 稳定性：网关设置未变时不再重建系统 VPN 接口；只有本机地址变化才强制重连，DNS/路由抖动不再打断隧道；DPD 30 秒；认证期间的换网请求不再丢失。
- 同步 iOS 主线修复：未配置时引导到设置页、保留认证与配置期间的切网请求、避免健康唤醒反复重连。iOS 仍通过 TestFlight 分发。
- 升级前先断开 VPN 并退出旧版；macOS 将 DMG 中的应用拖入 Applications，按提示重新注册系统服务并完成批准；配置和钥匙串密码沿用。
- macOS 应用内更新只识别本平台 DMG，并校验文件大小和 SHA-256；公开发布仓库可直接检查更新。

源码提交：{commit}
''')

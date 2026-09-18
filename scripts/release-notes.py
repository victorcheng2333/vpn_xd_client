#!/usr/bin/env python3
import os
import subprocess
from version import metadata

info = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print(f'''XD VPN {info['version']}（build {info['build']}）

- 修复上传链路的 MTU 同步，覆盖 DTLS 握手、路径探测及 TLS/DTLS 重连。各端在继续读取上传数据前同步系统接口；设置失败会终止不一致的会话。
- macOS：为已建立的 utun 补齐 MTU 更新和读回校验，保留本会话路由与 DNS。支持 macOS 14+；Apple Silicon 下载 arm64 DMG，Intel 下载 x86_64 DMG。应用使用公司 Developer ID 签名并完成 Apple 公证。
- Android：首次创建系统隧道延后到 DTLS 初步协商完成，并补齐运行中的 MTU 更新和 fd 交接。Android 9+，APK 支持 arm64-v8a / x86_64，沿用此前测试签名，可覆盖升级。
- Windows：同步已建立 Wintun 的 MTU，校验接口归属及更新结果，避免系统仍生成超过引擎新 MTU 的上传包。支持 Windows 11 x64（Windows 10 22H2 为兼容目标），内置 .NET、OpenConnect 和官方签名 Wintun。安装器尚未做代码签名，升级前从托盘退出旧版。
- 已完成代码及隔离回归；实际上传改善幅度仍需同一设备、网络、网关和测速终点与 AnyConnect 对照，不承诺固定加速比例。
- 升级前断开 VPN 并退出旧版。macOS 将 DMG 中的应用拖入 Applications，按提示重新注册系统服务；配置和钥匙串密码沿用。
- macOS 应用内更新只识别本平台 DMG，并校验文件大小和 SHA-256。Windows、Android 暂无应用内更新，请从本页下载新版本。iOS 仍通过 TestFlight 单独分发，本次 GitHub Release 不包含 iOS 构建。

源码提交：{commit}
''')

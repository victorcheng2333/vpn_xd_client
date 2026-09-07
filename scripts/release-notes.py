#!/usr/bin/env python3
import os
import subprocess
from version import metadata

info = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print(f'''XD VPN {info['version']}（build {info['build']}）

- macOS 14+；Apple Silicon 下载 arm64，Intel 下载 x86_64。
- 公司 Developer ID 签名，已完成 Apple 公证。
- VPN 后台服务改由 macOS 管理，通过双向身份校验的 XPC 与应用通信；继续内置 OpenConnect，无需另行安装。
- 连接页统一处理首次启用、旧授权迁移和升级修复，移除独立的系统授权页面。
- 修复系统服务启动超时，以及覆盖升级后重新注册失败的问题。
- 应用内更新下载会自动校验文件大小和 SHA-256。
- 升级前断开 VPN 并退出旧版，将 DMG 中的应用拖入 Applications；按应用提示重新注册系统服务并完成 macOS 批准。
- 配置和钥匙串密码沿用；不会自动替换运行中的应用或系统助手。
- 公开发布仓库可直接检查更新；私有仓库支持在本机钥匙串保存只读 GitHub Token。

源码提交：{commit}
''')

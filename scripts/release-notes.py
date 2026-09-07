#!/usr/bin/env python3
import os
import subprocess
from version import metadata

info = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print(f'''XD VPN {info['version']}（build {info['build']}）

- macOS 14+；Apple Silicon 下载 arm64，Intel 下载 x86_64。
- 公司 Developer ID 签名，已完成 Apple 公证。
- 应用内更新下载会自动校验文件大小和 SHA-256。
- 升级前断开 VPN 并退出旧版，将 DMG 中的应用拖入 Applications；按应用提示重新注册系统服务并完成 macOS 批准。
- 配置和钥匙串密码沿用；不会自动替换运行中的应用或系统助手。
- 私有发布仓库需要 GitHub 访问权限；客户端更新设置支持本机钥匙串保存只读 Token。

源码提交：{commit}
''')

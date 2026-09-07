#!/usr/bin/env python3
import os
import subprocess
from version import metadata

info = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print(f'''XD VPN {info['version']}（build {info['build']}）

- macOS 14+；Apple Silicon 下载 arm64，Intel 下载 x86_64。
- 公司 Developer ID 签名，已完成 Apple 公证。
- 修复切换 Wi-Fi、有线网络和手机热点时，恢复钩子阻塞隧道转发的问题，缩短恢复后的业务等待时间。
- 重连时直接更新并核验 VPN 网关路由；其他网络阶段通过系统 shell 执行脚本，避免新脚本首次执行检查造成额外延迟。
- 同步 iOS 修复：保留认证及配置期间的切网请求、避免健康唤醒反复重连，并修复手机 VPN 开启时的个人热点兼容性。iOS 通过 TestFlight 单独分发。
- 应用内更新下载会自动校验文件大小和 SHA-256。
- 升级前断开 VPN 并退出旧版，将 DMG 中的应用拖入 Applications；按应用提示重新注册系统服务并完成 macOS 批准。
- 配置和钥匙串密码沿用；不会自动替换运行中的应用或系统助手。
- 公开发布仓库可直接检查更新；私有仓库支持在本机钥匙串保存只读 GitHub Token。

源码提交：{commit}
''')

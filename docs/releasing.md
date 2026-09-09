# GitHub Release 发布与更新

## 版本约定

唯一版本来源是 `Resources/Info.plist`：`CFBundleShortVersionString` 使用无前导零的 `主.次.修订`，`CFBundleVersion` 使用正整数。当前目标为 **1.1.24 / build 34**；Android 的 versionName / versionCode 也直接读取同一文件。

| 渠道 | 界面版本示例 | DMG | GitHub Release / 自动更新 |
| --- | --- | --- | --- |
| development | `1.1.24-dev.34` | 默认不打包 | 不发布、不参与正式更新 |
| test | `1.1.24-test.35` | 文件名含 `-test.34` | 不发布、不参与正式更新 |
| release | `1.1.24` | 文件名只含正式版本与芯片 | 仅 `v1.1.24` 正式标签 |

开发／测试的构建号不占用正式版本，也不与正式版本比较大小。测试分发应显式使用新的构建号。正式版必须同时满足：标签匹配 plist、标签指向 HEAD、工作区干净、构建号匹配版本文件，且版本大于所有已发布的正式版本。不会回写或自动递增源文件。已发布版本禁止覆盖或降级；修复必须使用新版本。失败时仅能恢复尚未发布的同名草稿。

渠道隔离的是版本、构建目录、安装包与更新资格。各渠道仍沿用现有应用身份、VPN 配置、钥匙串和系统助手，安装测试包前应退出已运行的 XD VPN；不支持同时运行多条隧道。正式包不应被安装到测试用途机器后又当作测试分发。

## 公司签名

正式版使用 **Tools UG** 的 `Developer ID Application`，公司 Team ID 为 **KQY8A3BNVG**。本机已通过 Xcode 创建该分发证书；`Apple Development` 和 `Apple Distribution` 不作为站外分发证书使用。

`build.sh` 正式渠道会从钥匙串选择匹配公司团队的唯一 Developer ID，也可通过 `SIGNING_IDENTITY` 指定证书名称／指纹。正式包对主程序、系统助手和 OpenConnect 全部启用 hardened runtime 与安全时间戳，重新打包也会复核三个签名。开发、测试默认仍可使用 ad-hoc；设置 `SIGNING_IDENTITY` 可验证公司签名。

**GitHub 托管 runner 不会继承本机 Xcode 的登录状态或私钥。** 在仓库 Settings → Secrets and variables → Actions 配置：

| Secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | 公司 Developer ID Application 证书及对应私钥导出的、带密码的 `.p12` 文件的 Base64 |
| `APPLE_CERTIFICATE_PASSWORD` | 上述 `.p12` 导出密码 |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: Tools UG (KQY8A3BNVG)` 或该证书指纹 |
| `APPLE_TEAM_ID` | `KQY8A3BNVG` |
| `APPLE_ID` | 有公司团队权限的 Apple 账户（云端发布必需） |
| `APPLE_APP_PASSWORD` | 该账户的 App 专用密码（云端发布必需） |

不要把私钥、Token 或密码提交进仓库。公证的 App 专用密码需要由账户所有者准备；Xcode 登录本身不能代替 `notarytool` 的凭据。

本机初始化／轮换可以使用以下脚本（需要已登录且有仓库 Secrets 写权限的 `gh`）：

```bash
python3 scripts/setup-release-secrets.py --part signing
python3 scripts/setup-release-secrets.py --part notarization
```

`signing` 仅导出本机 Tools UG 的 Developer ID Application 身份，随机生成 P12 包装密码，在内存中加密并验证后通过 stdin 写入当前仓库的 GitHub Secrets，不产生私钥文件。macOS 可能要求授权导出私钥。`notarization` 必须在交互式本机终端执行，隐藏输入 App 专用密码，先调用 Apple `notarytool` 验证并保存 `xdvpn-notary` 钥匙串配置，成功后才设置公证 Secrets。脚本不打印凭据、私钥或含凭据的错误输出。默认目标固定为 `victorcheng2333/vpn_xd_client`，不会写入其他仓库。


正式 Release 必须同时完成**公司 Developer ID 签名和 Apple 公证**，本机和 GitHub Actions 一致；`NOTARIZE=0` 会被拒绝，不允许降级发布。App、系统助手和 OpenConnect 使用公司签名；App 公证并 staple 后打包 DMG，再对 DMG 签名、公证和 staple，最后生成 SHA-256。发布前重新验证 DMG／App 的公证票据、公司签名、内嵌版本、渠道、源码提交和架构，检查失败则不创建或发布 Release。

本机发布使用已存在的公司证书和 `xdvpn-notary` 钥匙串配置，无需从 GitHub 取回任何密码或私钥。GitHub 托管 runner 发布则使用上述 6 个 Secrets，导入临时钥匙串并在结束时清理；缺少公证凭据或 Apple 验证失败会中止流程。凭据验证成功仅表示可以调用公证服务，不代表任何安装包已经获得公证；安装包须有实际提交和 Accepted 结果，以及通过 stapler 验证的票据。

## 日常构建与测试

```bash
bash scripts/build.sh
bash scripts/test.sh -c release
python3 -m unittest discover -s Tests/ReleaseTests -v
bash scripts/test-packaging.sh

# 默认 package 渠道为 test，必须给构建号；不会意外产出正式包
BUILD_NUMBER=32 bash scripts/package.sh

# 只构建、分发一个芯片的公司签名测试包
BUILD_CHANNEL=test BUILD_NUMBER=32 ARCHS=arm64 \
  SIGNING_IDENTITY='Developer ID Application: Tools UG (KQY8A3BNVG)' \
  bash scripts/package.sh
```

引擎缺失时先运行 `bash scripts/build-openconnect.sh`；完整测试包含隔离的进程、socket 与本机回环测试，不使用真实 VPN 账号。第三方下载按固定 SHA-256 校验。GitHub 仅缓存下载源码，不复用可能跨工具链或跨工作区失效的编译对象。

## 本地打包、公证后上传 GitHub Release（默认流程）

先将版本文件和代码提交，保持工作区干净，并在该提交创建匹配标签。当前目标为 `v1.1.24`；正式发布必须递增版本，不能把旧测试包重命名发布。

```bash
# 在已提交的版本提交上创建标签
git tag -a v1.1.24 -m 'XD VPN 1.1.24'

# 本地构建、测试、签名、公证、打包和复核，不上传 GitHub Release
bash scripts/release.sh prepare v1.1.24

# 确保版本提交和标签均已推送到源仓库
git push origin main
git push origin v1.1.24

# 仅上传已验证的产物，再将草稿发布为正式 Latest
bash scripts/release.sh publish v1.1.24
```

`prepare` 在两份 DMG 之后调用 `scripts/release-android.sh` 构建、校验并暂存 Android APK（见下文「Android 安装包」）；使用本机钥匙串的公司 Developer ID 和公证 profile `xdvpn-notary`；如需指定其他 profile，设置 `NOTARY_KEYCHAIN_PROFILE`。两种架构都会实际执行 Swift 测试与隔离引擎验收，因此完整本地流程需要 Apple Silicon Mac 和 Rosetta。Intel Mac 可使用下面的云端原生 runner 流程。

Release 上传两种芯片的 `XD-VPN-<版本>-macOS-<架构>.dmg` 和 `XD-VPN-<版本>-Android.apk`。macOS 客户端按精确文件名只识别本平台 DMG，APK 不影响自动更新。两个 `.dmg.sha256`、`third-party-sources.tar.gz` 和 `build/release-notes.md` 保留为本地／Actions 构建产物，不作为 Release 附件上传。GitHub 自动生成的 Source code ZIP／tar.gz 链接仍会显示。本地构建默认不自动建立标签、不提交代码，也不上传 Release。

`publish` 再次核对当前版本／标签／提交以及安装包内嵌信息，验证真实公证票据和公司签名，用 `scripts/verify-release-apk.py` 复核 APK 内嵌版本与签名块，再创建草稿、上传两份 DMG 与 APK 并比较 GitHub 资产 digest。全部通过才设为正式 Latest。客户端直接使用 DMG 的 GitHub digest 校验更新下载，不依赖独立的校验文件。已发布版本不可覆盖；失败时仅可重试未发布的同名草稿。发布说明记录源码提交。构建归档中的第三方源码包提供对应 OpenConnect／OpenSSL／vpnc-script 源码，重建脚本位于同一标签的源码仓库。

## Android 安装包

`Apps/Android/app/build.gradle.kts` 直接读取 `Resources/Info.plist`：`versionName` 为正式版本（开发／测试渠道追加 `-dev.N`／`-test.N`，与 macOS 显示版本一致），`versionCode` 为构建号；构建时把版本、渠道和签名方式写入 `assets/xdvpn-version.json`，发布校验不依赖 Android SDK 即可读取。

`scripts/release-android.sh` 执行 JVM 测试、release lint、R8 打包，运行 `Apps/Android/scripts/verify-apk.py`（两个 ABI、16 KB 对齐、无测试凭据）和 `scripts/verify-release-apk.py`（文件名、内嵌版本＝标签版本、存在 v2/v3 签名块），产出 `build/XD-VPN-<版本>-Android.apk` 与 `.sha256`。

签名来源按顺序：`Apps/Android/signing.properties`（`storeFile`／`storePassword`／`keyAlias`／`keyPassword`，已在 `.gitignore`）→ 环境变量 `ANDROID_KEYSTORE_FILE`／`ANDROID_KEYSTORE_PASSWORD`／`ANDROID_KEY_ALIAS`／`ANDROID_KEY_PASSWORD` → 本机 `~/.android/debug.keystore`。**目前正式包仍使用本机开发测试签名**：这与此前发给测试手机的包是同一把钥匙，可以覆盖升级；切换到专用发布钥匙后，已安装设备必须卸载重装（配置需重新填写），请提前通知。GitHub Actions 发布不接受运行器临时生成的调试钥匙，须配置 Secrets `ANDROID_KEYSTORE_BASE64`（keystore 文件 Base64）、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，缺失时 Android 作业直接失败。

Android 客户端暂不在应用内检查更新；下载需允许安装未知来源应用。真机验收记录见 `Apps/Android/DEVICE-VERIFICATION-*.md`。

## GitHub Actions 发布（手动备用流程）

Actions → Release → Run workflow，输入已有并已推送的正式标签。工作流使用 ARM / Intel 原生 runner 构建 macOS，另有 Ubuntu 作业构建 Android APK，执行与本地相同的签名、公证和产物验证。推送标签本身不再自动触发云端发布，避免与本地发布重复竞争。签名与公证均为必需项，不能通过仓库变量关闭。

## 公证实际做了什么

公证凭据配置只运行 `notarytool store-credentials`，成功表示 Apple 账号可以调用公证服务；真正的安装包公证由 `scripts/notarize.sh` 执行：

1. 把已签名 App 压缩成 ZIP，使用钥匙串 profile `xdvpn-notary` 提交 Apple。
2. 等待 Apple 审核结果；通过后把公证票据附加到 App，并用 `stapler validate` 验证。
3. 用带票据的 App 生成 DMG，给 DMG 公司签名，再提交一次公证并附加票据。
4. 验证最终 DMG 与其中 App 的公证票据、签名及版本，最后生成 SHA-256。

2026-09-07 已用 `1.1.19-test.23 / arm64` 实际跑通上述流程：App 与 DMG 都返回 `Accepted`，DMG 中的 App 被 Gatekeeper 识别为 `Notarized Developer ID`。详细提交编号见 `VERIFICATION.md`。

## 单独本机正式打包

```bash
BUILD_CHANNEL=release RELEASE_TAG=v1.1.24 \
  NOTARY_KEYCHAIN_PROFILE=xdvpn-notary bash scripts/package.sh
```

同样要求已有匹配标签且工作区干净，默认且强制 `NOTARIZE=1`。此命令仅打包，不代替 `release.sh prepare` 中的完整测试，也不自动上传 GitHub。开发／测试包仍可以不公证，但不能进入正式 Release。

## 私有仓库与客户端更新

默认源为 `victorcheng2333/vpn_xd_client`，当前为公开仓库，可匿名检查和下载更新。正式应用每次启动时检查距离上次成功检查是否超过 24 小时；菜单「检查更新…」可随时重试，侧栏版本号也可打开更新窗口。自动检查失败不打断 VPN。开发／测试应用不检查或安装正式更新。

仅当改用私有发布仓库时，使用者需要在更新窗口的「私有仓库访问设置」中保存自己的 GitHub fine-grained Token，只授予此仓库 **Contents: Read-only**。账户必须本来就有访问该仓库的权限，组织要求 SSO 时还需要授权。Token 仅进入本机钥匙串，使用独立于 VPN 密码的服务名称，不进入配置文件、日志或安装包；只向 `api.github.com` 发送，下载重定向到 GitHub CDN 时移除 Authorization。

客户端从 GitHub `/releases/latest` 读取正式版本，按数字比较版本，忽略草稿、预发布、同版本及更旧版本；根据运行中应用架构选取 DMG。检查资产名称、仓库 URL、大小及 GitHub 的 SHA-256 digest。下载到临时文件，流式复核大小和 SHA-256 后才移入「下载」中的独立目录，失败丢弃临时文件。网络失败、无权限、限流、校验错误均明确显示，不误报为最新版。

这是**检查、下载、完整性校验并交给用户安装**的流程。不会自动替换正在运行的 VPN 或权限助手；用户需先断开并退出，再打开已验证 DMG 安装。SHA-256 用于完整性检查，发行者身份和 Gatekeeper 信任由 Developer ID／公证负责。

如果不希望所有使用者提供 GitHub Token，可另建公开的**纯安装包仓库**，设置 Actions 变量 `RELEASE_REPOSITORY=owner/distribution-repo`，并将只对目标仓库有 Contents 写权限的 `RELEASE_TOKEN` 放入源仓库 Secrets。该来源也会写进构建产物，客户端匿名读取公开源。切换来源只影响之后构建的客户端，已安装旧版本需要先从原发布源获得迁移版本。脚本不会自动改变仓库可见性，也不会上传发布凭据到客户端。

参考：[GitHub Releases API](https://docs.github.com/en/rest/releases/releases)、[Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## SMAppService / XPC 包结构与验收

应用不再提供独立的「系统授权」页。连接页根据服务状态显示启用、系统批准、旧授权迁移或修复提示；返回应用后自动检测，就绪后显示「连接 VPN」。批准本身不会自动发起新的 VPN 连接。菜单栏需要处理服务时打开连接页；移除入口在「VPN 配置 → 高级 · 系统服务」，连接活动期间不可移除。

新助手位于 `Contents/Library/LaunchServices/com.xd.vpn.helper`，配置位于 `Contents/Library/LaunchDaemons/com.xd.vpn.helper.plist`。两个文件必须进入最终 App 签名；助手和引擎要求 Tools UG Developer ID 签名及 hardened runtime。macOS 要求包含 LaunchDaemon 的 App 完成公证。不要直接从 DMG 或 build 目录注册服务；先放入 `/Applications`。

服务会在 root 私有目录中建立并再次验证运行副本，固定当前引擎和网络清理程序。替换 `/Applications` 中的 App 不会影响活动连接的清理；更新后的新连接仍需重新注册。`--service-command verify-bundle` 可在启用服务前验证公司签名、包完整性以及副本复制／权限收紧后签名仍有效。

签名／公证通过不代表系统服务已经批准。实际验收需覆盖启用、系统设置批准、构建握手、另一连接拒绝、失联清理、移除与重新注册。可从已安装 App 执行 `Contents/MacOS/XDVPN --service-command status` 或 `smoke`，诊断路径不创建 VPNModel、不读取 VPN 凭据、不启动 VPN 引擎。`register`、`unregister`、`migrate` 是明确改变本机服务状态的管理命令。

旧版授权在新服务可用之前保留；旧版仍运行或正在清理时必须阻止迁移。测试通过后仍须在真实服务器验证连接、网络切换、退出清理，不能将无网络的 smoke 结果当作真实 VPN 验收。

## Windows 独立预览发布

Windows 与 macOS、Android 共同读取 `Resources/Info.plist` 的版本和 build，使用 `windows-v<version>` 标签，不参与 macOS 自动更新的正式版本序列。App、Service、Setup 和界面版本须一致。

推送标签后，在 Actions 手动运行 **Windows Release**，输入对应标签。该流程重建引擎、执行回归与 SYSTEM 服务测试、打包 EXE 和 ZIP，并验证 GitHub 上传资产的 SHA-256 后发布 prerelease。只有发布 job 获得 contents: write；推送代码或标签本身不会触发发布。已发布版本不能覆盖，不设为 Latest。版本说明位于 `docs/releases/windows-v<version>.md`。

本地也可在干净且 HEAD 等于标签的 Windows 工作区运行（需要已构建原生引擎、.NET 10 和已登录的 GitHub CLI）：

```powershell
./scripts/release-windows.ps1 prepare -Tag windows-v1.1.24
./scripts/release-windows.ps1 publish -Tag windows-v1.1.24
```

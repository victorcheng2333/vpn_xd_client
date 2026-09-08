# XD VPN Android

版本号与 macOS 共用 `Resources/Info.plist`（正式版本 = `CFBundleShortVersionString`，versionCode = `CFBundleVersion`；开发/测试构建的 versionName 追加 `-dev.N`/`-test.N`）。Android 9+ 独立原生客户端。Kotlin / Jetpack Compose / VpnService / JNI OpenConnect；arm64-v8a 和 x86_64。UI 与 main@945d90b 的 iOS 版本对齐（含未配置时的设置引导、连接质量页的状态/提示分区），保留「连接 / 设置 / 连接质量」三个页签。

[技术方案与最佳实践](../../docs/design/2026-09-07-android-support.md) · [验证记录](VERIFICATION.md) · [真机验收 09-07](DEVICE-VERIFICATION-2026-09-07.md) · [真机验收 09-08](DEVICE-VERIFICATION-2026-09-08.md)

## 使用

1. 设置页填写 HTTPS 服务器、用户名、密码并保存。默认网关和 iOS 相同；密码留空保留已存密码。
2. 首页按需设置「自动连接」，开关只保存偏好。点击「连接 VPN」，在系统授权对话框中允许。Android 13+ 可允许通知，以便在通知栏查看状态和断开。
3. 连接成功后用实际内网业务验证可达性；系统状态和包计数不代表业务成功。
4. 「连接质量」查看当前时长、TLS/DTLS、包计数、最近24小时恢复记录；详细事件最多显示64条，系统分享不包含账号、服务器或凭据。
5. 手动断开会持久化暂停恢复。重开 App、重新开启开关不会发起连接，须再次点击连接。
6. 五分钟内超过三次冷认证时进入冷却等待（连接质量页显示「等待下一次自动重试」），到期自动重试；只有密码、证书、配置错误才会持久化暂停并需要手动连接。

支持当前 iOS 首版同范围的 AnyConnect 用户名/密码、IPv4 全隧道、可选网关双栈、DTLS 优先/TLS 回退、恢复预算、质量统计、脱敏分享。没有 SSO/MFA、客户端证书、CSD/HostScan、PAC、全隧道排除路由和 IPv6-only；遇到这些配置会明确失败。

自动连接允许前台服务内和系统重建服务后的恢复，不承诺 OEM 强制停止、设备重启或无限后台保活。Android 系统 Always-on / lockdown 已显式关闭，防止系统强制连接与当前手动断开行为冲突。详见技术方案的平台差异。

## 构建

需要 JDK17或21、Android SDK API36 / build-tools36.0.0 / NDK28.2.13676358，以及 Python3、Perl、make、curl、tar。Android Studio 可直接打开本目录；首次构建需联网下载固定源码和 Maven 依赖。macOS/Linux均使用相同脚本，不依赖 Xcode 或 macOS/iOS客户端产物。

```sh
# 使用 Android SDK 的 sdkmanager 安装；不要把 SDK 或私有签名提交到仓库。
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358"
export ANDROID_HOME=/path/to/Android/sdk
export JAVA_HOME=/path/to/jdk
cd Apps/Android
./gradlew :app:assembleDebug
bash scripts/check.sh
```

`ANDROID_NDK_HOME` 可指定同版本独立 NDK。`XDVPN_SOURCE_CACHE` 可指向已经下载的**源码压缩包**目录，复制后仍校验 SHA-256；不引用其他平台二进制。默认同时构建两个 ABI；开发引擎时可临时设置 `XDVPN_ANDROID_ABIS=arm64-v8a`，完整验收必须恢复两种 ABI。

原生依赖、宿主 pkgconf、修改后源码、未剥离调试库、APK许可证与构建 recipe 均留在 `.build/`，不进入 Git。构建脚本检查最终库没有 fork/exec/system/popen。`verify-apk.py` 逐项检查自身和 AndroidX 原生库的 ABI、ELF LOAD 与 ZIP entry 16KB 对齐，并阻止测试凭据进入应用 APK。

产物：

- `app/build/outputs/apk/debug/app-debug.apk`：开发签名，可 `adb install -r` 安装。
- `app/build/outputs/apk/release/app-release.apk`：R8 精简后的签名产物。签名来源依次为 `signing.properties`、`ANDROID_KEYSTORE_*` 环境变量、本机 `~/.android/debug.keystore`；三者都没有时只产出 `app-release-unsigned.apk`。正式发布经根目录 `scripts/release-android.sh`（由 `scripts/release.sh prepare` 调用）校验后上传 GitHub Release，见 [发布说明](../../docs/releasing.md)。

构建成功不等于真机网关验收。GitHub Release 中的 APK 目前仍使用开发测试签名（与此前测试手机上的包同一把钥匙，可覆盖升级）；专用发布钥匙与商店/企业分发尚未配置。

## 测试与 CI

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug
# 在可丢弃的模拟器中执行；使用合成密码和仅监听127.0.0.1的临时TLS网关。
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
# Linux CI 的 API28 / API36 系统服务、JNI、存储、UI矩阵
bash scripts/ci-device-test.sh 36
```

设备测试会临时给测试包设置 VPN app-op，验证实际前台服务并撤回授权；不要在保存真实 VPN 配置的手机上运行本测试集。测试密钥位于 `app/src/androidTest/assets`，仅用于本机合成网关，不进入应用 APK。证书信任绕过仅存在于协议契约测试的回调实现；生产路径始终调用 Android 信任校验和原生主机名检查。

独立工作流 `.github/workflows/android.yml` 按 Android 路径触发，使用 API28 / API36 x86_64 模拟器矩阵；不修改现有 macOS/iOS工作流。本地验证和远端 CI 执行结果分开记录。

## 代码导航

- `core/`：配置校验、网络规划、恢复预算与纯质量计算。
- `data/`：Keystore AES-GCM、原子配置/门禁/有界历史、StateFlow仓库。
- `engine/`、`native/engine.c`：Kotlin JNI契约、系统证书链、单worker库会话。
- `service/`：VpnService、NOT_VPN物理网络、前台通知、TUN持有与重建、取消清理。
- `ui/`：原生Compose页面与状态动画。
- `scripts/patch-openconnect.py`：只作用于固定9.21源码的Android补丁；不启动脚本、只接外部TUN、socket保护失败返回错误。保护回调是**本构建的局部ABI变更**，不可混用上游未修改头文件/二进制。

Service在冷恢复期间保留系统TUN以避免先放行原全隧道流量；JNI独占复制的fd。网关下发的设置与已应用的相同时（传输层重连、同地址冷恢复）不重建系统接口，只再复制一份描述符，避免每次重连都重置全系统的连接。物理网络只在本机地址变化时强制引擎重连，DNS/路由抖动不触发；引擎侧 DPD 30 秒，换网请求在认证期间也会保留，且同一时刻最多排队一次暂停命令。断开时先撤回持久化意图，再取消命令管道，等worker退出后释放fd、监听器和通知。网关DNS使用选定物理网络，TLS/DTLS新socket先protect再绑定物理Network；整个App不绕过VPN。

## 分发准备

OpenConnect、OpenSSL、libxml2许可证已包含在APK assets/licenses及`.build/engine/<ABI>/licenses`。正式分发前，应随对应版本保留并提供固定原始源码、Android补丁、完整构建步骤、需要的重链接材料和依赖清单，完成安全更新检查与渠道签名。当前未上传APK、创建Release或提交商店审核。

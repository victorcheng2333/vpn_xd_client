# Android MTU 同步修复验证 — 2026-09-18

基线为上传审计后的 `455166c`，本轮目标版本为共享版本 `1.1.27 / build 38`。本记录描述修复与本地验证，发布结果由对应 Release 单独确认。

## 修复

- 初次系统 TUN 改由 OpenConnect 的延迟 setup 回调建立，等待首次 DTLS 尝试完成或回退 TLS，使用最终协商的 MTU。系统配置成功后才发出 CONNECTED；这之前发生 TLS 重连也不会提前建立接口。
- 注册共享 `openconnect_set_mtu_changed_handler`。引擎在再次读取 TUN 前比较当前 MTU 与已应用值，同步调用 JNI → VpnService 更新；覆盖 PSK 开销调整、MTU 探测和已有接口后的传输变化，不依赖进度日志文本。
- 继续使用 `NetworkPlan` 全字段相等性：同一计划只复制既有接口 fd，变化时建立新系统接口。JNI 安装新 fd、移除旧 fd 监控后关闭旧副本；服务保留的接口描述符不由 JNI 关闭。
- 同步失败终止会话。初次非阻塞 fd 安装失败时，上游也清空内部 tun fd，避免 void setup 回调的失败被误认为接口已经建立；worker 仍持有新副本并负责最终关闭。已应用的 MTU 只在安装成功后更新。
- 重连直接安装新 fd 时也释放旧的空 TUN 读取缓存，防止重连先记录新 MTU 后，主循环看不到变化而继续使用旧尺寸缓存。
- 仅 Debug 构建记录 `Applied engine plan mtu=<数值> reused=<布尔值>`，来源明确为引擎传入的网络计划；不记录账号、凭据、地址或数据包，不把该值当作独立系统验证。

## 结果

| 检查 | 结果 |
| --- | --- |
| 共享 MTU C 回归 | 在两个 ABI 源码 patch 后由引擎构建自动执行，全部通过 |
| Android 设置/fd 隔离回归 | 通过；使用真实生产函数体、真实 socket fd，替换 JNI 对象和监控环境 |
| 原生引擎 arm64-v8a、x86_64 | 均从最终共享补丁重编通过；JNI 使用 `-O2 -Wall -Wextra -Werror` |
| JVM 回归 | 24/24，通过；含网络计划相等性及 MTU 变化导致计划不相等 |
| Debug、R8 Release APK / lintDebug / lintVitalRelease | 全部通过 |
| 两个 APK 的 ABI、ELF/ZIP 16 KB 对齐与测试凭据检查 | 全部通过，每个 APK 四个原生库 |
| API 32 arm64 临时模拟器 NativeEngineTest | 10/10，通过，0 失败/错误/跳过；只运行原生引擎测试类 |

设置/fd 隔离回归验证延迟初建、初建前重连不建接口、最终 MTU 交付、变化后新旧 fd 监控/关闭、既有接口副本仍可用、重连 MTU 升高时清空旧读取缓存、Java 配置拒绝、非阻塞安装失败、初建失败不报告连接、失败不更新已应用 MTU。非阻塞失败断言在旧补丁缓存上失败，补齐上游失败处理后通过。

模拟器新增两项实际 JNI + 本机合成 CSTP 网关测试：1280 字节 MTU 的初次配置成功后才报告连接；配置回调拒绝时标记设置错误且不报告连接。保留的八项测试覆盖取消、证书和主机名拒绝、socket 保护失败、Cookie 失效及分阶段认证。使用独立 `.build/mtu-emulator` 数据目录和 `emulator-5580`，结束后已关闭；合成仪器测试未在真实配置手机上运行。

## 用户授权的真机调试

用户追加授权 Android 真机调试后，使用 OnePlus/OPPO PKX110，Android 16 / API 36，覆盖安装本轮 `1.1.27-dev.38` Debug APK。安装前确认旧版 `0.1.2 / build 3` 与新包签名证书 SHA-256 一致，使用 `adb install -r`，未清数据、未卸载、未读取或修改账号密码及 Keystore。仅 Debug 诊断改动后重新通过 24 项 JVM 测试、Debug 构建、Debug/Release lint；最终 Debug 包还重编两 ABI 以包含读取缓存修复，fd/缓存回归通过。

| 真实设备检查 | 结果 |
| --- | --- |
| 首次连接 | 10:27:14 成功，保留的原配置直接可用；实际通道 TLS |
| MTU 独立对照 | 引擎计划 1472；只读 `SIOCGIFMTU` 查询内核 `tun0` 也为 1472 |
| 首次业务请求 | `https://versions.xmxdev.com/apps` HEAD，HTTP 200，TLS 校验结果 0，0.304 秒 |
| 一次手动断开重连 | 10:28:38 断开、10:28:43 重新连接成功；仍为 TLS；引擎和内核 MTU 再次均为 1472 |
| 重连后业务请求 | 同一 HEAD，HTTP 200，TLS 校验结果 0，0.120 秒 |
| 数据收发 | 连接质量页采样上/下行 128/111 包；追加一次成功 HEAD 后同期变为 143/123 包，第三次 HEAD 0.169 秒 |
| 收尾 | 恢复测试前的未连接状态，保留新版和原配置；移除只读 MTU 探针及临时 UI dump |

Android 16 禁止 shell 读取该接口 sysfs 和使用 `ip link` 的 netlink 查询，独立 MTU 验证改用 NDK 编译的只读 `SIOCGIFMTU` 小程序，不修改接口或系统策略。没有重启手机、切换 Wi-Fi/蜂窝、清除配置或向真机安装合成测试包。

**这不代表 DTLS 真机上传速率已验收。** 本轮真实网关会话为 TLS，没有触发运行中 DTLS MTU 变化或系统接口重建，也没有做持续上传 Mbps 或 AnyConnect 对照。还需在可用 DTLS 的网络验证接口替换及业务恢复，并用 Release 做同条件吞吐比较。

## 复现

```sh
export ANDROID_HOME=/path/to/Android/sdk
export JAVA_HOME=/path/to/jdk17
bash Apps/Android/scripts/check.sh
# 只使用可丢弃模拟器，不在保存真实 VPN 配置的手机运行仪器测试。
ANDROID_SERIAL=emulator-5580 Apps/Android/gradlew -p Apps/Android \
  :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.xd.vpn.android.NativeEngineTest
```

本地完整证据：`.build/mtu-verification-final.log`、`.build/mtu-native-device-tests.log`、`app/build/test-results/testDebugUnitTest/`、`app/build/outputs/androidTest-results/connected/`，路径均相对 `Apps/Android/`。临时产物和日志不进入 Git。

真机增量构建/检查证据：`.build/mtu-phone-build.log`、`.build/mtu-phone-build-final.log`；脱敏设备事件、MTU 日志和 HTTP 结果在 `.build/verification-20260918-mtu-phone/`。只读内核 MTU 查询结果为两次 `kernel tun0 mtu=1472`。

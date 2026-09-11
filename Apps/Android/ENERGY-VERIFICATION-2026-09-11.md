# Android 统计调度节能优化验证 — 2026-09-11

代码基线：`ac0fde39724545b5df3a442e87286ba17c07d233`。本次本地构建版本为 `1.1.25-dev.36`，min API 28 / target API 36；尚未发布。

## 改动和不变量

- 原有服务常驻的 5 秒统计定时器改为观察订阅：仅在「连接质量」页处于 `STARTED` 生命周期、服务运行且引擎已连接时保持一个 5 秒定时器；首次订阅和引擎替换立即请求样本。
- 离开页面、进入后台、离线/恢复、手动停止和服务销毁时撤销定时器。重叠 Activity 采用独立可幂等释放的订阅令牌，不持有 Activity；订阅本身不启动服务或授予自动恢复意图。
- 引擎身份和定时器身份都校验；失效回调不能采样旧引擎或重新启动已关闭的调度器。原生 `stats()` 仍由已有锁和 handle 检查保护。
- 状态、恢复事件与采样相互独立。保留已有停止时清空快照、失败时保留最近快照的行为；包计数显示采样时间，未采样显示「尚未采样」，诊断报告明确缓存值不代表最终流量。
- 未修改 JNI/C、DPD、DTLS、重连预算、路由、TUN、凭据或证书逻辑。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| JVM 单元测试 | **24/24 通过**，其中新增调度与订阅回归测试 8 项 |
| Android 16 / API 36 / arm64 设备测试 | **19/19 通过**，零失败、零跳过；包括新增生命周期与缓存语义测试 2 项 |
| `lintDebug` | 零错误；两项已有警告：Gradle 可升级、企业用户证书信任 |
| Debug APK、设备测试代码编译 | 通过 |
| Release APK / R8 / `lintVitalRelease` | 通过，沿用现有开发签名 |
| Debug 和 Release APK 原生库 | 每个 APK 的双 ABI 共 4 个库均通过 ELF LOAD / ZIP entry 16KB 对齐检查 |
| Git 空白检查 | `git diff --check -- Apps/Android` 通过 |

新增 JVM 测试覆盖：观察者重叠与重复释放、无需求/无引擎时无定时器、可见时即时请求、重复更新不重复排队、后台撤销及过期回调、引擎替换、失败后恢复、销毁后旧回调以及同步取消后不重新排队。

新增设备测试实际运行 Compose 生命周期切换、切换页签和移除 Composition，确认统计订阅正确释放/恢复，且没有调用连接操作；同时验证未采样/缓存诊断语义和订阅不改变会话状态。既有两个 `ServiceLifecycleTest` 均通过：证书失败后的持久化暂停、握手期间手动停止及系统再启动不重连。其余原生合成网关、存储与 UI 测试也全部通过。

## 隔离范围与复现

只使用仓库专用 `XDVPN_API_36` 测试 AVD 的副本和已缓存官方 Android 16 镜像，修正旧 checkout 路径后创建本地隔离数据盘，名称 `XDVPN_ENERGY_20260911`，序列号 `emulator-5580`。启动后核对名称，再安装应用/测试包；测试使用合成凭据和 `127.0.0.1` 临时网关。未接触真实手机、用户 AVD、真实 VPN 配置或公司网关。测试结束后已关闭该模拟器。

```sh
# 使用已配置的 JDK 17+ 和 Android SDK；所有依赖均来自现有离线缓存。
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:compileDebugAndroidTestKotlin --offline
./gradlew :app:assembleRelease --offline
# 只可对确认隔离的测试模拟器执行，勿用于真实配置手机。
ANDROID_SERIAL=emulator-5580 ./gradlew :app:connectedDebugAndroidTest --offline
python3 scripts/verify-apk.py app/build/outputs/apk/debug/app-debug.apk
python3 scripts/verify-apk.py app/build/outputs/apk/release/app-release.apk
```

设备测试完整日志：`.build/energy-verification/instrumentation.log`。JUnit/XML 和 HTML 报告分别在 `app/build/test-results/`、`app/build/outputs/androidTest-results/connected/`、`app/build/reports/`；这些生成物不进入 Git。

本轮证明统计调度边界和已有连接回归测试通过，尚未测量真实耗电变化，也未覆盖本次版本的 API 28 / x86_64 设备运行、真实网关切网、隔夜锁屏及 OEM 后台管理行为。

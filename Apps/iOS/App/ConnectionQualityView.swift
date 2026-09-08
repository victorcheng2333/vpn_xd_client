import SwiftUI

struct ConnectionQualityView: View {
    @ObservedObject var model: VPNModel
    var isVisible: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    private let brand = Color(hex: 0x227858)
    private var shouldRefresh: Bool { isVisible && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !shouldRefresh)) { _ in
            let now = QualityInstant.now()
            let quality = model.quality.display(intent: model.qualityIntent, at: now)
            let successes = quality.count(.recoverySucceeded, at: now.date)
            let failures = quality.count(.recoveryFailed, at: now.date)
            let cancelled = quality.count(.recoveryCancelled, at: now.date)
            List {
                Section("当前连接") {
                    value("状态", model.title)
                    value("连接时长", connectedDuration(quality, now: now))
                    value("传输方式", model.status == .connected ? model.snapshot.transport : "—")
                    value("自动恢复", model.automaticRecoveryStatus)
                }
                Section {
                    if quality.events.isEmpty {
                        ContentUnavailableView("暂无连接记录", systemImage: "chart.xyaxis.line",
                                               description: Text("连接 VPN 后自动记录，无需保持 App 打开。"))
                    } else {
                        if typeSize.isAccessibilitySize {
                            metrics(successes: successes, failures: failures, stacked: true)
                        } else {
                            metrics(successes: successes, failures: failures, stacked: false)
                        }
                        if quality.session?.phase == .recovering && model.active {
                            Label("正在恢复连接", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(Color(hex: 0x326CB0))
                        }
                        if let event = quality.lastRecovery(at: now.date) {
                            value("最近一次", event.kind == .recoverySucceeded ? "恢复成功" : "恢复失败")
                            value("恢复耗时", event.duration.map(Self.duration) ?? "未完整记录")
                            value("记录时间", event.date.formatted(date: .omitted, time: .standard))
                        }
                        value("连接记录", "成功 \(quality.count(.connectionSucceeded, at: now.date)) · 失败 \(quality.count(.connectionFailed, at: now.date))")
                        if cancelled > 0 || quality.count(.connectionCancelled, at: now.date) > 0 {
                            Text("已取消：连接 \(quality.count(.connectionCancelled, at: now.date)) 次，恢复 \(cancelled) 次")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    #if targetEnvironment(simulator)
                    Text(ProcessInfo.processInfo.arguments.contains("--preview-quality") ? "模拟器预览数据 · 最近 24 小时" : "最近 24 小时 · 此 iPhone")
                    #else
                    Text("最近 24 小时 · 此 iPhone")
                    #endif
                } footer: {
                    Text("按结束时间统计，取消不计为失败。恢复耗时包含已观测到的断网等待；起点缺失时不估算。")
                }
                Section("连接提示") {
                    if let warning = model.qualityStorageIssue {
                        notice(warning, detail: "VPN 连接不受统计写入影响。可稍后刷新或分享诊断报告。")
                    }
                    if quality.incomplete {
                        notice("部分历史记录缺失", detail: "这里只统计仍保留的记录。")
                    }
                    if let blocked = model.recoveryBlockedReason {
                        notice("自动恢复已暂停", detail: blocked)
                    } else if let issue = quality.issue {
                        let copy = Self.issueText(issue.reason)
                        notice(copy.0, detail: copy.1)
                    } else if model.onDemandActive && !model.active {
                        notice("等待系统恢复连接", detail: "网络恢复后会自动尝试连接，可查看详细日志了解进度。")
                    } else {
                        Text(quality.events.isEmpty ? "有连接记录后显示异常及处理建议。" : "暂无需要处理的异常。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    NavigationLink {
                        ConnectionDiagnosticsView(model: model)
                    } label: {
                        Label("详细日志", systemImage: "list.bullet.rectangle")
                    }
                    ShareLink(item: model.report) {
                        Label("分享诊断报告", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("这里只反映隧道连接与恢复，不代表内网业务可用性。")
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("连接质量")
        .task(id: shouldRefresh) {
            guard shouldRefresh else { return }
            while !Task.isCancelled {
                await model.refreshDiagnostics()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .refreshable { await model.refreshDiagnostics() }
    }

    @ViewBuilder private func metrics(successes: Int, failures: Int, stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            metric("完成恢复", successes + failures, color: .primary)
            metric("成功", successes, color: brand)
            metric("失败", failures, color: failures > 0 ? .orange : .secondary)
        }.padding(.vertical, 8)
    }
    private func metric(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(count)").font(.title2.bold()).monospacedDigit().foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func value(_ title: String, _ text: String) -> some View {
        LabeledContent(title) {
            Text(text).multilineTextAlignment(.trailing).foregroundStyle(.primary).monospacedDigit()
        }
    }
    private func notice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "info.circle").font(.subheadline.weight(.medium))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
    private func connectedDuration(_ quality: ConnectionQuality, now: QualityInstant) -> String {
        guard model.status == .connected, let start = quality.session?.connectedAt else { return "—" }
        return start.elapsed(to: now).map(Self.duration) ?? "未完整记录"
    }
    static func duration(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        if value < 1 { return "不到 1 秒" }
        if value < 60 { return "\(value) 秒" }
        if value < 3600 { return "\(value / 60) 分 \(value % 60) 秒" }
        return "\(value / 3600) 小时 \((value % 3600) / 60) 分"
    }
    private static func issueText(_ reason: QualityReason) -> (String, String) {
        switch reason {
        case .network: return ("等待网络恢复", "请确认 Wi-Fi 或蜂窝网络可用；恢复后会继续尝试连接。")
        case .sessionExpired: return ("正在更新连接会话", "原会话已失效，正在使用已保存的账号重新认证。")
        case .authentication: return ("账号认证失败", "请检查设置中的账号和密码，保存后手动连接。")
        case .certificate: return ("服务器证书校验失败", "请确认服务器地址和手机时间；仍失败时联系管理员。")
        case .configuration: return ("连接配置需要检查", "请检查已保存的配置；仍失败时分享诊断报告。")
        case .retryLimit: return ("等待下一次自动重试", "短时间内连接尝试过多，正在等待重试额度恢复；无需反复点击连接。")
        case .timeout: return ("连接超时", "请确认网络可用，再尝试连接。")
        case .providerRestart: return ("正在恢复后台连接", "系统重新启动了 VPN 扩展，正在恢复隧道。")
        default: return ("连接暂时中断", "正在尝试恢复，可在详细日志中查看进度。")
        }
    }
}

private struct ConnectionDiagnosticsView: View {
    @ObservedObject var model: VPNModel
    var body: some View {
        List {
            Section {
                LabeledContent("系统状态", value: model.title)
                LabeledContent("最近事件", value: model.snapshot.phase)
                LabeledContent("更新时间", value: model.snapshot.updatedAt.formatted(date: .omitted, time: .standard))
                LabeledContent("最近观测传输", value: model.snapshot.transport)
                LabeledContent("上行 / 下行包", value: "\(model.snapshot.packetsToTunnel) / \(model.snapshot.packetsFromTunnel)")
                LabeledContent("桥接丢弃包", value: "\(model.snapshot.droppedPackets)")
                Button("刷新诊断") { Task { await model.refreshDiagnostics() } }
            } footer: {
                Text("丢弃计数包含 IPv6 策略阻断及本地桥接丢弃，不是网络丢包率。")
            }
            Section("最近事件") {
                ForEach(Array(model.snapshot.events.enumerated().reversed()), id: \.offset) { _, event in
                    Text(event).font(.caption.monospaced()).textSelection(.enabled)
                }
                ShareLink(item: model.report) { Label("分享诊断报告", systemImage: "square.and.arrow.up") }
            }
        }.navigationTitle("详细日志").navigationBarTitleDisplayMode(.inline)
    }
}

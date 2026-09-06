import SwiftUI
import Charts

struct QualityView: View {
    @EnvironmentObject var model: VPNModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let snapshot = QualitySnapshot(events: model.qualityEvents, now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("此 Mac · 最近 24 小时已保留的质量事件").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("查看日志") { model.page = .activity }.buttonStyle(.borderless)
                    }
                    if !model.qualityHistoryLoaded {
                        ProgressView("正在读取历史日志…")
                    }
                    HStack(spacing: 12) {
                        metric("连接成功率", value: snapshot.successRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                               detail: "成功 \(snapshot.successes) / 完成 \(snapshot.successes + snapshot.failures)")
                        metric("连接耗时 P95", value: snapshot.connectionP95.map { String(format: "%.2f 秒", $0) } ?? "—",
                               detail: "成功连接样本 \(snapshot.successes) 次")
                        metric("恢复次数", value: "\(snapshot.recoveries)",
                               detail: "成功 \(snapshot.recovered) · 失败 \(snapshot.recoveryFailures)")
                    }
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("连接耗时 · 成功样本").font(.system(size: 13, weight: .semibold))
                            if snapshot.successes == 0 {
                                Text("暂无成功连接样本").font(.system(size: 12)).foregroundStyle(Palette.muted)
                                    .frame(maxWidth: .infinity, minHeight: 100)
                            } else {
                                Chart(snapshot.events.filter { $0.kind == .attemptSucceeded && $0.durationMS != nil }) { event in
                                    PointMark(x: .value("时间", Date(timeIntervalSince1970: event.timestamp)),
                                              y: .value("秒", (event.durationMS ?? 0) / 1000))
                                        .foregroundStyle(Palette.green)
                                }
                                .chartXScale(domain: context.date.addingTimeInterval(-86400)...context.date)
                                .chartXAxis {
                                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                                        AxisGridLine()
                                        AxisValueLabel(format: .dateTime.hour().minute())
                                    }
                                }
                                .chartYAxisLabel("秒").frame(height: 125)
                            }
                            Text("取消或被网络变化中止的尝试：\(snapshot.cancelled) 次，不计入成功率。耗时从准备助手开始，包含期间的离线与睡眠等待。")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("本地告警", systemImage: snapshot.alerts.isEmpty ? "bell" : "bell.badge")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text("每 30 秒刷新").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                            if let issue = model.logFileIssue {
                                warning("文件日志写入异常", detail: issue)
                            }
                            if model.qualityHistoryIncomplete {
                                warning("部分历史日志无法读取", detail: "以下统计只包含可读取的数据；无法确认上次退出情况。")
                            }
                            if snapshot.alerts.isEmpty {
                                Text(snapshot.events.isEmpty ? "暂无质量样本，尚不能判断连接质量。" : "当前没有触发告警规则。")
                                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }
                            ForEach(snapshot.alerts) { alert in
                                warning(alert.title, detail: alert.detail)
                            }
                            Text("规则：10 分钟内连续失败 3 次；至少 5 次完成尝试且成功率低于 80%；引擎中断或意外结束至少 3 次。异常退出提示保留 24 小时。指标离开时间窗口后自动解除。")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("统计受日志轮转限制，可能不足 24 小时。隧道建立不等于业务可用：暂未采集业务可达性、延迟、丢包或崩溃堆栈。本页仅在本机显示告警，尚未接入集中上报及消息通知。")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }.padding(.bottom, 4)
            }
        }
    }

    private func metric(_ title: String, value: String, detail: String) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func warning(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: "exclamationmark.circle").font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(Color(hex: 0x946B37)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(Color(hex: 0xFFF1DD), in: RoundedRectangle(cornerRadius: 10))
    }
}

import SwiftUI

struct ContentView: View {
    @ObservedObject var model: VPNModel
    @Environment(\.scenePhase) private var scenePhase
    private let brand = Color(red: 0.133, green: 0.471, blue: 0.345)
    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Label("工作网络", systemImage: "network").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text("iOS 验证版 0.1").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 20) {
                            Image(systemName: model.status == .connected ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                                .font(.system(size: 54)).foregroundStyle(brand)
                            Text(model.title).font(.largeTitle.bold())
                            Text(model.active ? "系统 VPN 状态；内网访问可在诊断页验证。" : "连接公司网络，验证移动端恢复能力。")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button {
                                Task { if model.active || model.onDemandActive { await model.disconnect() } else { await model.connect() } }
                            } label: {
                                HStack { if model.busy { ProgressView().tint(.white) }; Text(model.active || model.onDemandActive ? "断开并暂停恢复" : "连接 VPN") }
                                    .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 48)
                            }.buttonStyle(.borderedProminent).tint(brand).disabled(model.busy)
                        }.padding(24).frame(maxWidth: .infinity).background(.background, in: RoundedRectangle(cornerRadius: 24))
                        VStack(spacing: 16) {
                            row("服务器", model.profile.server)
                            row("隧道地址", model.active ? model.snapshot.address : "—")
                            row("按需恢复", model.onDemandActive ? "已启用" : "已暂停")
                        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
                        if let message = model.message {
                            Label(message, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("首次连接会请求添加系统 VPN 配置。按需恢复需在设置中启用，并由内网域名访问触发。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
                }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("XD VPN")
            }.tabItem { Label("连接", systemImage: "shield") }
            NavigationStack {
                Form {
                    Section("VPN 配置") {
                        TextField("HTTPS 服务器地址", text: $model.profile.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("用户名", text: $model.profile.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(model.hasPassword ? "已保存，留空保持原密码" : "密码", text: $model.password).textContentType(.password)
                        TextField("认证组（可选）", text: $model.profile.group).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }.disabled(model.active || model.onDemandActive || model.busy)
                    Section {
                        Toggle("优先使用 DTLS", isOn: $model.profile.useDTLS)
                        Toggle("全隧道模式", isOn: Binding(get: { model.profile.fullTunnel == true }, set: { model.profile.fullTunnel = $0 }))
                        if model.profile.fullTunnel == true {
                            Text("用于网关下发默认路由的配置。网关仅支持 IPv4 时，IPv6 将被阻断；系统蜂窝服务、推送与设备通信按系统规则处理。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Toggle("连接后启用按需恢复", isOn: $model.profile.onDemand)
                        if model.profile.onDemand {
                            TextField("内网域名，以逗号分隔", text: $model.profile.domains, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        TextField("HTTPS 内网验证地址（可选）", text: $model.profile.probeURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("恢复验证") } footer: {
                        Text("按需连接在域名解析或验证地址探测失败时触发，不保证每次解锁立即连接。启用后，系统可能在后台探测此地址。手动断开会暂停，重新连接才启用。")
                    }.disabled(model.active || model.onDemandActive || model.busy)
                    Section {
                        Button("保存配置") { Task { await model.save() } }.disabled(model.active || model.onDemandActive || model.busy)
                    } footer: { Text("密码保存在本机钥匙串，首次解锁后可供隧道后台读取。首版支持 AnyConnect 用户名/密码认证，暂不支持 SSO、MFA、客户端证书及终端合规检查。") }
                    if let message = model.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
                }.navigationTitle("设置")
            }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }
            NavigationStack {
                List {
                    Section("连接诊断") {
                        row("系统状态", model.title)
                        row("最近事件", model.snapshot.phase)
                        row("诊断更新时间", model.snapshot.updatedAt.formatted(date: .abbreviated, time: .standard))
                        row("最近观测传输", model.snapshot.transport)
                        row("上行 / 下行包", "\(model.snapshot.packetsToTunnel) / \(model.snapshot.packetsFromTunnel)")
                        row("桥接丢弃包", "\(model.snapshot.droppedPackets)")
                        Button("刷新诊断") { Task { await model.refreshDiagnostics() } }
                    }
                    Section {
                        Button(model.probing ? "正在验证…" : "验证内网地址") { Task { await model.probe() } }.disabled(model.probing)
                        Text(model.probeResult).font(.footnote).textSelection(.enabled)
                    } header: { Text("真实访问检查") } footer: {
                        Text("向你填写的地址发送 HTTPS HEAD 请求。HTTP 响应代表地址可达，不能单独证明所有流量经过 VPN；请使用仅内网可访问的地址。")
                    }
                    Section("恢复事件") {
                        ForEach(Array(model.snapshot.events.enumerated().reversed()), id: \.offset) { _, event in
                            Text(event).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        ShareLink(item: model.report) { Label("分享诊断报告", systemImage: "square.and.arrow.up") }
                    }
                }.navigationTitle("诊断")
            }.tabItem { Label("诊断", systemImage: "waveform.path.ecg") }
        }.tint(brand).onChange(of: scenePhase) { _, value in
            if value == .active { Task { await model.load() } }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.subheadline)
    }
}

import SwiftUI

struct ContentView: View {
    @ObservedObject var model: VPNModel
    @Environment(\.scenePhase) private var scenePhase
    #if targetEnvironment(simulator)
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--preview-quality") } ? 2 : 0
    #else
    @State private var selectedTab = 0
    #endif
    private let brand = Color(hex: 0x227858)
    private var connectionAppearance: ConnectionAppearance {
        if model.startingConnection { return .connecting }
        switch model.status {
        case .connecting, .reasserting: return .connecting
        case .disconnecting: return .disconnecting
        case .connected: return model.busy ? .disconnecting : .connected
        default: return .idle
        }
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Label("工作网络", systemImage: "network").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text("iOS 验证版 0.1").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 20) {
                            ConnectionOrbitView(appearance: connectionAppearance)
                                .frame(height: 160)
                            Text(model.title).font(.largeTitle.bold()).foregroundStyle(connectionAppearance.color)
                            Text(model.active ? "连接状态和恢复记录可在连接质量页查看。" : "连接公司网络，验证移动端恢复能力。")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button {
                                Task { if model.active || model.onDemandActive { await model.disconnect() } else { await model.connect() } }
                            } label: {
                                HStack { if connectionAppearance.showsProgress { ProgressView().tint(.white) }; Text(model.active || model.onDemandActive ? "断开" : "连接 VPN") }
                                    .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 48)
                            }.buttonStyle(.borderedProminent).tint(connectionAppearance == .idle ? brand : connectionAppearance.color).disabled(model.busy)
                        }.padding(24).frame(maxWidth: .infinity).background(.background, in: RoundedRectangle(cornerRadius: 24))
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("自动连接", isOn: Binding(get: { model.profile.automaticConnectionEnabled }, set: { enabled in
                                Task { await model.setAutoConnect(enabled) }
                            }))
                            .disabled(model.busy || model.savingAutoConnect || !model.hasPassword || model.status == .disconnecting)
                            Text(model.autoConnectDescription).font(.footnote).foregroundStyle(.secondary)
                        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
                        VStack(spacing: 16) {
                            row("服务器", model.profile.server)
                            row("隧道地址", model.active ? model.snapshot.address : "—")
                        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
                        if let message = model.message {
                            Label(message, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("首次连接会请求添加系统 VPN 配置。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
                }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("XD VPN")
                .alert("尚未配置 VPN", isPresented: Binding(get: { model.configurationAlert != nil }, set: { if !$0 { model.configurationAlert = nil } })) {
                    Button("去设置") { selectedTab = 1 }
                    Button("取消", role: .cancel) {}
                } message: { Text(model.configurationAlert ?? "") }
            }.tabItem { Label("连接", systemImage: "shield") }.tag(0)
            NavigationStack {
                Form {
                    Section("VPN 配置") {
                        TextField("HTTPS 服务器地址", text: $model.profile.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("用户名", text: $model.profile.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("密码", text: $model.password,
                                    prompt: Text(model.hasPassword ? "****" : "密码")
                                        .foregroundColor(model.hasPassword ? .primary : Color(uiColor: .placeholderText)))
                            .textContentType(.password)
                            .accessibilityLabel("密码")
                            .accessibilityHint(model.hasPassword ? "已保存密码；输入新密码可替换，留空保持原密码。" : "")
                    }.disabled(model.active || model.onDemandActive || model.busy || model.savingAutoConnect)
                    Section {
                        Button("保存配置") { Task { await model.save() } }.disabled(model.active || model.onDemandActive || model.busy || model.savingAutoConnect)
                    } footer: { Text("密码保存在本机钥匙串，首次解锁后可供隧道后台读取。首版支持 AnyConnect 用户名/密码认证，暂不支持 SSO、MFA、客户端证书及终端合规检查。") }
                    if let message = model.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
                }.navigationTitle("设置")
            }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(1)
            NavigationStack {
                ConnectionQualityView(model: model, isVisible: selectedTab == 2)
            }.tabItem { Label("连接质量", systemImage: "chart.xyaxis.line") }.tag(2)
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

import SwiftUI
import VPNCore

struct ContentView: View {
    @EnvironmentObject var model: VPNModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 22) {
                header
                switch model.page {
                case .connection: DashboardView()
                case .profile: ProfileView()
                case .authorization: AuthorizationView()
                case .activity: ActivityView()
                }
            }.padding(.horizontal, 32).padding(.top, 32).padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 990, minHeight: 720)
        .background(Palette.canvas).foregroundStyle(Palette.ink)
        .preferredColorScheme(.light)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 18).padding(.vertical, 12).background(Palette.ink, in: Capsule()).foregroundStyle(.white)
                    .padding(.bottom, 22).allowsHitTesting(false)
                    .task(id: toast) { try? await Task.sleep(for: .seconds(3)); if model.toast == toast { model.toast = nil } }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xC3E8D3)).frame(width: 40, height: 40)
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 23, weight: .medium)).foregroundStyle(Palette.sidebar)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("XD VPN").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(0.4)
                    Text("YOUR PRIVATE LINK").font(.system(size: 7, weight: .medium)).tracking(1.6).foregroundStyle(Color.white.opacity(0.4))
                }
            }.padding(.horizontal, 22).padding(.top, 57)

            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.35)).padding(.leading, 26).padding(.top, 48).padding(.bottom, 14)
            VStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { page in
                    Button { withAnimation(.easeInOut(duration: 0.15)) { model.page = page } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.icon).font(.system(size: 15)).frame(width: 18)
                            Text(page.rawValue).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                            Spacer()
                            if model.page == page { Circle().fill(Color(hex: 0xB9E6CA)).frame(width: 5, height: 5) }
                        }.padding(.horizontal, 14).frame(height: 43)
                            .background(model.page == page ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(model.page == page ? .white : .white.opacity(0.51))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 13)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "leaf").font(.system(size: 20, weight: .light)).foregroundStyle(Color(hex: 0xB5D8C1))
                Text("少一点操作，\n多一点专注。").font(.system(size: 15, weight: .light)).lineSpacing(6).foregroundStyle(.white.opacity(0.75))
                Text("让连接安静地发生。") .font(.system(size: 10)).foregroundStyle(.white.opacity(0.32))
            }.padding(.horizontal, 26).padding(.bottom, 31)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 22)
            HStack(spacing: 7) {
                Circle().fill(model.engineAvailable ? Color(hex: 0xA6D6BA) : .orange).frame(width: 5, height: 5)
                Text(model.engineAvailable ? "OpenConnect 就绪" : "需要安装连接引擎").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.1").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.25))
            }.padding(.horizontal, 24).padding(.vertical, 24)
        }.frame(width: 204).background(Palette.sidebar).foregroundStyle(.white)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                SmallLabel(text: model.page == .connection ? "A LITTLE CLOSER TO WORK" : model.page == .profile ? "MAKE IT YOURS" : model.page == .authorization ? "ONE-TIME SETUP" : "CONNECTION JOURNAL")
                Text(model.page == .connection ? "工作网络，一键就绪。" : model.page.rawValue).font(.system(size: 27, weight: .semibold)).tracking(-0.8)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer").font(.system(size: 13))
                Text("此 Mac").font(.system(size: 11, weight: .medium))
            }.foregroundStyle(Palette.muted).padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.7), in: Capsule()).overlay(Capsule().stroke(Palette.line))
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: VPNModel
    private var isConnected: Bool { model.state == .connected }
    var body: some View {
        VStack(spacing: 18) {
            if let issue = model.issue {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(issue).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("检查配置") { model.page = .profile }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                }.foregroundStyle(Color(hex: 0x946B37)).padding(13).background(Color(hex: 0xFFF1DD), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(alignment: .top, spacing: 18) {
                connectionCard
                VStack(spacing: 18) { profileCard; privacyCard }.frame(width: 226)
            }
            autoConnectCard
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 10))
                Text("凭据留在你的 Mac，连接交给 XD VPN。") .font(.system(size: 10))
                Spacer()
                Text("BUILT FOR YOUR FLOW").font(.system(size: 8, design: .monospaced)).tracking(1.2)
            }.foregroundStyle(Palette.muted.opacity(0.8)).padding(.horizontal, 2).padding(.top, 1)
        }
    }

    private var connectionCard: some View {
        Card(padding: 22) {
            VStack(spacing: 0) {
                HStack {
                    SmallLabel(text: "CONNECTION")
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(isConnected ? Palette.green : model.state.isBusy ? Color.orange : Palette.muted.opacity(0.6)).frame(width: 5, height: 5)
                        Text(isConnected ? "在线" : model.state.isBusy ? "处理中" : "离线").font(.system(size: 10, weight: .medium))
                    }.foregroundStyle(isConnected ? Palette.green : Palette.muted)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(Palette.canvas, in: Capsule())
                }
                OrbitView(connected: isConnected, busy: model.state.isBusy).frame(height: model.issue == nil ? 190 : 140)
                Text(model.state.title).font(.system(size: 23, weight: .semibold)).tracking(-0.6)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).multilineTextAlignment(.center).frame(height: 32).padding(.top, 5)
                Button {
                    if model.state.isActive { model.disconnect() }
                    else if model.readyToConnect { model.connect() }
                    else { model.page = .profile }
                } label: {
                    Label(buttonTitle, systemImage: model.state.isActive ? "power" : model.readyToConnect ? "power" : "plus")
                }.buttonStyle(PrimaryButtonStyle(destructive: model.state.isActive))
                    .frame(maxWidth: 216).padding(.top, 18).disabled(model.state == .disconnecting)
                    .keyboardShortcut("k", modifiers: .command)
                Rectangle().fill(Palette.line).frame(height: 1).padding(.top, 24).padding(.bottom, 17)
                HStack {
                    metric("连接时长") {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(duration(at: context.date)).monospacedDigit()
                        }
                    }
                    Spacer()
                    Rectangle().fill(Palette.line).frame(width: 1, height: 28)
                    Spacer()
                    metric("分配地址") { Text(model.address ?? "—").lineLimit(1).minimumScaleFactor(0.8) }
                }
            }
        }.frame(maxWidth: .infinity)
    }

    private var buttonTitle: String {
        if model.state == .disconnecting { return "正在断开…" }
        if model.state == .connected { return "断开连接" }
        if model.state.isActive { return "取消连接" }
        return model.readyToConnect ? "连接 VPN" : "配置我的 VPN"
    }
    private var subtitle: String {
        if model.state == .authorizing { return "正在启动已授权的连接助手" }
        if model.state == .waiting { return model.networkAvailable ? "Auto Connect 将在稍后再次连接" : "网络不可用，恢复后自动连接" }
        if isConnected { return "已接入工作网络，可以开始专注了" }
        if model.state.isBusy { return "正在与工作网络建立联系，请稍候" }
        return model.readyToConnect ? "你的工作网络，随时可以出发" : "保存一次配置，以后只需轻轻一点"
    }
    private func duration(at now: Date) -> String {
        guard let date = model.connectedAt else { return "00:00:00" }
        let t = max(0, Int(now.timeIntervalSince(date)))
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
    private func metric<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted)
            value().font(.system(size: 13, weight: .medium, design: .monospaced))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack { SmallLabel(text: "MY PROFILE"); Spacer(); Image(systemName: "rectangle.stack").foregroundStyle(Palette.muted).font(.system(size: 12)) }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.canvas).frame(width: 42, height: 42)
                    Image(systemName: "building.2").font(.system(size: 19, weight: .regular)).foregroundStyle(Palette.green)
                }.padding(.top, 21)
                Text(model.profile?.name ?? "我的工作网络").font(.system(size: 16, weight: .semibold)).lineLimit(1).padding(.top, 13)
                Text(model.profile?.displayServer ?? "添加你的 VPN，随时连接")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.75).padding(.top, 6)
                Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 17)
                HStack { Text("协议").foregroundStyle(Palette.muted); Spacer(); Text("AnyConnect").fontWeight(.medium) }.font(.system(size: 10))
                HStack { Text("账号").foregroundStyle(Palette.muted); Spacer(); Text(model.profile?.username ?? "待配置").lineLimit(1) }.font(.system(size: 10)).padding(.top, 12)
                Button { model.page = .profile } label: {
                    HStack { Text(model.profile == nil ? "添加配置" : "管理配置"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
                }.buttonStyle(.plain).padding(.top, 23)
            }
        }
    }
    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "key.horizontal").font(.system(size: 18, weight: .light)); Spacer(); Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).opacity(0.5) }
            Text("密码，安心记住。").font(.system(size: 13, weight: .semibold)).padding(.top, 1)
            Text("保存在 macOS 钥匙串中，\n下次连接不用再输入。") .font(.system(size: 10)).lineSpacing(4).foregroundStyle(Palette.green.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(Palette.green).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0xE8EFE5), in: RoundedRectangle(cornerRadius: 18))
    }
    private var autoConnectCard: some View {
        HStack(spacing: 15) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 20, weight: .regular)).foregroundStyle(Palette.green)
                .frame(width: 43, height: 43).background(.white, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("自动连接").font(.system(size: 13, weight: .semibold))
                    Text("AUTO CONNECT").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(Palette.muted)
                }
                Text("启动时连接、掉线后重试；手动断开后保持断开。") .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 5)
            Toggle("自动连接", isOn: Binding(get: { model.autoConnect }, set: { model.setAutoConnect($0) }))
                .labelsHidden().toggleStyle(.switch).tint(Palette.green).controlSize(.regular)
                .accessibilityLabel("Auto Connect 自动连接")
                .help("仅修改自动连接配置。手动断开后，需再次点击连接或重启应用才会连接。")
        }.padding(19).background(Color(hex: 0xEDF1E9), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color(hex: 0xE1E8DD)))
    }
}

struct OrbitView: View {
    let connected: Bool
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.height, 210.0)
            ZStack {
                Circle().fill(RadialGradient(colors: [Palette.mint.opacity(0.7), .white.opacity(0)], center: .center, startRadius: 20, endRadius: size * 0.6)).frame(width: size * 1.25, height: size * 1.25)
                ForEach(0..<3) { i in
                    Circle().stroke(Palette.green.opacity(0.055 + Double(2 - i) * 0.017), lineWidth: 1)
                        .frame(width: size * (0.58 + Double(i) * 0.19), height: size * (0.58 + Double(i) * 0.19))
                }
                Circle().fill(Palette.mint.opacity(0.45)).frame(width: size * 0.65, height: size * 0.65)
                    .scaleEffect(busy && breathe && !reduceMotion ? 1.16 : 1)
                Circle().fill(.white).frame(width: size * 0.49, height: size * 0.49)
                    .shadow(color: Palette.green.opacity(0.10), radius: 16, y: 5)
                    .overlay(Circle().stroke(Palette.green.opacity(0.08)).frame(width: size * 0.49, height: size * 0.49))
                Image(systemName: connected ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: size * 0.22, weight: .light)).foregroundStyle(Palette.green)
                    .symbolRenderingMode(.hierarchical).contentTransition(.symbolEffect(.replace))
                Circle().fill(Palette.green.opacity(0.25)).frame(width: 5, height: 5).offset(x: -size * 0.405, y: -size * 0.24)
                Circle().fill(Palette.green.opacity(0.20)).frame(width: 4, height: 4).offset(x: size * 0.43, y: size * 0.21)
                ZStack {
                    Circle().fill(connected ? Palette.green : .white).frame(width: 25, height: 25).shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                    Image(systemName: connected ? "checkmark" : busy ? "ellipsis" : "power").font(.system(size: 10, weight: .semibold)).foregroundStyle(connected ? .white : Palette.green)
                }.offset(y: size * 0.26)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityHidden(true)
            .onAppear { withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { breathe = true } }
    }
}

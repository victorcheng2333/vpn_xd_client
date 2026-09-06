import SwiftUI
import VPNCore

struct ProfileView: View {
    @EnvironmentObject var model: VPNModel
    @State private var draft = VPNProfile()
    @State private var password = ""
    @State private var reveal = false
    @State private var error: String?
    @State private var confirmForget = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.person.crop").foregroundStyle(Palette.green)
                    Text("一个配置，连接你的日常。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    Text("01 / 01").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                Card {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("连接信息").font(.system(size: 17, weight: .semibold))
                                Text("使用与你的 Cisco AnyConnect 相同的账号。") .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Text("AnyConnect").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.green)
                                .padding(.horizontal, 10).padding(.vertical, 6).background(Palette.mint.opacity(0.5), in: Capsule())
                        }
                        FieldShell(title: "配置名称") { TextField("例如：工作网络", text: $draft.name).accessibilityLabel("配置名称") }
                        FieldShell(title: "VPN 服务器", hint: "支持地址、端口和路径") {
                            TextField("vpn.xindong.com:8443", text: $draft.server).accessibilityLabel("VPN 服务器")
                        }
                        HStack(alignment: .top, spacing: 16) {
                            FieldShell(title: "用户名") { TextField("你的公司账号", text: $draft.username).accessibilityLabel("VPN 用户名").focused($focused) }
                            FieldShell(title: "认证组", hint: "选填") { TextField("使用服务器默认值", text: $draft.authGroup).accessibilityLabel("认证组") }
                        }
                        FieldShell(title: "VPN 密码", hint: model.hasPassword ? "已保存在钥匙串 · 留空则保留" : "将安全保存在本机钥匙串") {
                            HStack {
                                Group {
                                    if reveal { TextField(model.hasPassword ? "保留已保存的密码" : "输入 VPN 密码", text: $password) }
                                    else { SecureField(model.hasPassword ? "保留已保存的密码" : "输入 VPN 密码", text: $password) }
                                }.accessibilityLabel("VPN 密码")
                                Button { reveal.toggle() } label: {
                                    Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(Palette.muted)
                                }.buttonStyle(.plain).accessibilityLabel(reveal ? "隐藏密码" : "显示密码")
                            }
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.canEdit {
                            Label("断开 VPN 后即可编辑配置。", systemImage: "lock").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        HStack {
                            if model.hasPassword {
                                Button("忘记已保存密码") { confirmForget = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Button {
                                do { try model.save(draft, password: password); password = ""; error = nil }
                                catch { self.error = error.localizedDescription }
                            } label: { Label("保存配置", systemImage: "checkmark") }.buttonStyle(PrimaryButtonStyle()).frame(width: 150)
                                .keyboardShortcut("s", modifiers: .command)
                        }.padding(.top, 3)
                    }.disabled(!model.canEdit)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").font(.system(size: 13)).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("在「系统授权」中安装一次授权，之后连接无需再次输入 Mac 密码。")
                        Text("VPN 密码与 Mac 登录密码不同。公司 VPN 可能仅允许从办公网以外连接。")
                    }.font(.system(size: 10)).lineSpacing(3)
                }.foregroundStyle(Palette.muted).padding(.horizontal, 2)
                if !model.engineAvailable {
                    Card(padding: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("内置连接引擎不完整").font(.system(size: 12, weight: .medium))
                                Text("请重新下载完整的 XD VPN 应用，无需安装 Homebrew。")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Button("重新检测") { model.refreshEngine() }
                        }
                    }
                }
            }.padding(.bottom, 2)
        }.scrollIndicators(.hidden)
            .onAppear { draft = model.profile ?? VPNProfile(); model.refreshEngine() }
            .onDisappear { password = ""; reveal = false }
            .alert("忘记 VPN 密码？", isPresented: $confirmForget) {
                Button("取消", role: .cancel) {}
                Button("忘记密码", role: .destructive) {
                    do { try model.forgetPassword(); password = "" }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("将从 macOS 钥匙串移除保存的密码。下次连接前需要重新填写。") }
    }
}

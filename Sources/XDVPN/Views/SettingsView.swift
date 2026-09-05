import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(VPNManager.self) private var vpn

    var body: some View {
        TabView {
            ProfileSettingsView()
                .tabItem { Label("账户", systemImage: "person.crop.circle") }
            AuthorizationSettingsView()
                .tabItem { Label("系统授权", systemImage: "lock.shield") }
            LogView()
                .tabItem { Label("日志", systemImage: "doc.text") }
            AboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 480)
        .onAppear { Task { await vpn.refreshHelperStatus() } }
    }
}

// MARK: - Account

private struct ProfileSettingsView: View {
    @Environment(VPNManager.self) private var vpn
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var serverCertPin = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var loaded = false

    private var hasChanges: Bool {
        server != vpn.profile.server || username != vpn.profile.username
            || serverCertPin != vpn.profile.serverCertPin || !password.isEmpty
    }

    private var canSave: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (vpn.hasStoredPassword || !password.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField("服务器", text: $server, prompt: Text("vpn.example.com:8443"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                TextField("用户名", text: $username, prompt: Text("VPN 账户"))
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField(
                    "密码",
                    text: $password,
                    prompt: Text(vpn.hasStoredPassword ? "••••••••（已保存，留空则不修改）" : "VPN 密码")
                )
                .textContentType(.password)
            } header: {
                Text("VPN 账户")
            } footer: {
                Text("密码只保存在 macOS 钥匙串中，连接时通过标准输入交给 openconnect，不会写入任何文件。")
            }

            Section("高级") {
                TextField("服务器证书指纹", text: $serverCertPin, prompt: Text("可选，例如 pin-sha256:…"))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                Text("仅在服务器证书不被系统信任时需要。连接失败时应用会自动给出可信任的指纹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if vpn.hasLegacyScriptPassword && !vpn.hasStoredPassword {
                        Button("从 xd-vpn 脚本导入密码") { importLegacyPassword() }
                    }
                    if vpn.hasStoredPassword {
                        Button("清除已保存的密码", role: .destructive) {
                            vpn.clearPassword()
                            password = ""
                            show("已清除密码", error: false)
                        }
                    }
                    Spacer()
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave || !hasChanges)
                }
                if let message {
                    Label(message, systemImage: messageIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(messageIsError ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        server = vpn.profile.server
        username = vpn.profile.username
        serverCertPin = vpn.profile.serverCertPin
    }

    private func save() {
        do {
            try vpn.saveProfile(server: server, username: username, password: password, serverCertPin: serverCertPin)
            password = ""
            show("已保存", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func importLegacyPassword() {
        // Make sure the username is stored first so the keychain lookup uses it.
        vpn.profile.username = username.trimmingCharacters(in: .whitespaces)
        do {
            if try vpn.importLegacyScriptPassword() {
                show("已导入密码", error: false)
            } else {
                show("钥匙串中没有找到 xd-vpn 脚本保存的密码", error: true)
            }
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}

// MARK: - Authorization

private struct AuthorizationSettingsView: View {
    @Environment(VPNManager.self) private var vpn
    @State private var busy = false
    @State private var errorText: String?

    private var openconnectInstalled: Bool { PrivilegedHelper.openconnectPath != nil }

    var body: some View {
        Form {
            Section {
                LabeledContent("openconnect") {
                    statusLabel(
                        ok: openconnectInstalled,
                        text: PrivilegedHelper.openconnectPath ?? "未安装"
                    )
                }
                if !openconnectInstalled {
                    Text("请先在终端执行：brew install openconnect")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("授权助手") {
                    statusLabel(ok: vpn.helperStatus.isUsable, text: vpn.helperStatus.title)
                }
            } header: {
                Text("状态")
            }

            Section {
                Text("openconnect 需要 root 权限才能建立 VPN 隧道。点击「安装授权」会弹出一次系统管理员密码框，之后连接和自动重连都不再需要输入任何密码。")
                    .font(.callout)
                Text("安装内容：\n• /usr/local/libexec/xd-vpn-helper（root 拥有，只接受 connect / disconnect 两个命令）\n• /etc/sudoers.d/xd-vpn（仅允许当前用户免密运行上面这一个文件）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("原理")
            }

            Section {
                HStack {
                    if vpn.helperStatus == .notInstalled || vpn.helperStatus == .notAuthorized {
                        Button("安装授权…") { run(install: true) }
                            .buttonStyle(.borderedProminent)
                    } else if vpn.helperStatus == .outdated {
                        Button("更新授权助手…") { run(install: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    if vpn.helperStatus != .notInstalled && vpn.helperStatus != .unknown {
                        Button("移除授权…", role: .destructive) { run(install: false) }
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button {
                        Task { await vpn.refreshHelperStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重新检查")
                }
                .disabled(busy)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
    }

    private func statusLabel(ok: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func run(install: Bool) {
        busy = true
        errorText = nil
        Task {
            do {
                if install { try await vpn.installHelper() } else { try await vpn.uninstallHelper() }
            } catch let error as PrivilegedHelper.AdminError {
                if !error.cancelled { errorText = error.message }
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Log

private struct LogView: View {
    @Environment(VPNManager.self) private var vpn

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(vpn.log) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.timeFormatter.string(from: entry.time))
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .foregroundStyle(color(for: entry.kind))
                                    .textSelection(.enabled)
                            }
                            .font(.caption.monospaced())
                            .id(entry.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: vpn.log.count) {
                    if let last = vpn.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    if let last = vpn.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text("\(vpn.log.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制") {
                    let text = vpn.log.map {
                        "\(Self.timeFormatter.string(from: $0.time)) \($0.text)"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("清空") { vpn.clearLog() }
            }
            .controlSize(.small)
            .padding(8)
        }
        .frame(height: 420)
    }

    private func color(for kind: VPNManager.LogEntry.Kind) -> Color {
        switch kind {
        case .app: return .accentColor
        case .output: return .primary
        case .error: return .red
        }
    }
}

// MARK: - About

private struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            VStack(spacing: 4) {
                Text("XD VPN").font(.title2.weight(.semibold))
                Text("版本 \(version)").font(.caption).foregroundStyle(.secondary)
            }
            Text("一个好看一点的 Cisco AnyConnect 客户端，基于 openconnect。记住一个账户，一键连接，掉线自动重连。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Link("openconnect 项目主页", destination: URL(string: "https://www.infradead.org/openconnect/")!)
                .font(.caption)
        }
        .padding(30)
        .frame(height: 320)
    }
}

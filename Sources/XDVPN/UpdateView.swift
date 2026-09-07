import SwiftUI
import AppKit

struct UpdateView: View {
    @ObservedObject var updates: UpdateManager
    @State private var token = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("版本更新").font(.title2.bold())
                Spacer()
                Button("完成") { updates.showPanel = false }.keyboardShortcut(.cancelAction)
            }
            Text("当前版本：\(updates.displayVersion)").font(.headline)
            Text(updates.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if updates.busy { ProgressView().controlSize(.small) }
            HStack {
                Button("检查更新") { Task { await updates.check() } }.disabled(updates.busy)
                if let available = updates.available {
                    Link("发行说明", destination: available.pageURL)
                    Button("下载并校验 \(available.version.description)") { Task { await updates.download() } }.disabled(updates.busy)
                }
                if let file = updates.downloaded {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }
            Divider()
            Text("更新来源：\(updates.repository)").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("私有仓库访问设置") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("私有仓库需要有权访问该仓库的 GitHub Token，仅授予 Contents 读取权限；若组织要求 SSO，请先授权。Token 仅保存在本机钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField(updates.hasToken ? "已保存 Token，输入可替换" : "GitHub Token", text: $token)
                    HStack {
                        Button("保存 Token") { updates.saveToken(token); token = "" }.disabled(token.isEmpty || updates.busy)
                        if updates.hasToken {
                            Button("移除 Token") { updates.saveToken("") }.disabled(updates.busy)
                        }
                    }
                }.padding(.top, 8)
            }
        }.padding(24).frame(width: 550)
    }
}

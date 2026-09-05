import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var model: VPNModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("每一次连接，都有迹可循。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Button { model.copyLog() } label: { Label("复制日志", systemImage: "doc.on.doc") }.buttonStyle(.borderless)
                Button { model.clearLog() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("清空日志")
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        SmallLabel(text: "THIS SESSION")
                        Spacer()
                        Text("\(model.entries.count) 条记录").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.padding(20)
                    Rectangle().fill(Palette.line).frame(height: 1)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if model.entries.isEmpty {
                                    VStack(spacing: 13) {
                                        Image(systemName: "text.alignleft").font(.system(size: 25, weight: .light))
                                        Text("这里很安静").font(.system(size: 14, weight: .medium))
                                        Text("下一次连接的动态会显示在这里。") .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    }.frame(maxWidth: .infinity).padding(.vertical, 80)
                                }
                                ForEach(model.entries) { entry in
                                    HStack(alignment: .top, spacing: 13) {
                                        Text(entry.date, format: .dateTime.hour().minute().second()).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 73, alignment: .leading)
                                        Circle().fill(entry.isError ? Color.orange : Palette.green.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 4)
                                        Text(entry.message).font(.system(size: 11)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(.vertical, 14).padding(.horizontal, 20).id(entry.id)
                                    Rectangle().fill(Palette.line.opacity(0.6)).frame(height: 1).padding(.horizontal, 20)
                                }
                            }
                        }.onChange(of: model.entries.count) { _, _ in if let id = model.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Label("日志只保留在本次会话中，不记录密码或认证凭据。", systemImage: "lock")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.frame(maxHeight: .infinity)
    }
}

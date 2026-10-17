import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: GDClient

    @AppStorage(GDSettings.serverURL) private var serverURL = ""
    @AppStorage(GDSettings.token) private var token = ""

    @Environment(\.dismiss) private var dismiss
    @State private var isPairing = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.10:14371", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("电脑端地址")
                } footer: {
                    Text("填电脑在局域网里的 IP 和转发脚本的端口。Ghost Downloader 自身只监听 127.0.0.1，必须先用仓库里的 tools/gd-relay.py 转发出来。")
                }

                Section {
                    SecureField("配对令牌", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(action: pair) {
                        HStack {
                            Label("自动配对", systemImage: "link.badge.plus")
                            Spacer()
                            if isPairing { ProgressView() }
                        }
                    }
                    .disabled(isPairing || serverURL.trimmed.isEmpty)
                } header: {
                    Text("认证")
                } footer: {
                    Text("点“自动配对”后电脑端会弹出确认框，同意后令牌自动填入。也可以在电脑端复制浏览器扩展的配对令牌手动粘贴。")
                }

                Section {
                    Button("重新连接") {
                        client.connect(server: serverURL, token: token)
                        note("正在重新连接…", isError: false)
                    }
                    Button("断开连接", role: .destructive) {
                        client.disconnect()
                        note("已断开", isError: false)
                    }
                }

                if let message {
                    Section {
                        Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(isError ? Color.red : Color.green)
                    }
                }

                Section("关于") {
                    LabeledContent("连接状态", value: client.phase.label)
                    LabeledContent("客户端版本", value: GDClient.clientVersion)
                    LabeledContent("协议版本", value: "v\(GDClient.protocolVersion)")
                    if !client.desktopVersion.isEmpty {
                        LabeledContent("电脑端版本", value: client.desktopVersion)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func pair() {
        isPairing = true
        message = "已向电脑端发起配对，请在电脑上点同意…"

        Task {
            let newToken = await client.requestPairing(server: serverURL)
            isPairing = false
            guard let newToken else {
                note("配对失败：电脑端没有响应或已拒绝", isError: true)
                return
            }
            token = newToken
            note("配对成功，正在连接…", isError: false)
            client.connect(server: serverURL, token: newToken)
        }
    }

    private func note(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }
}

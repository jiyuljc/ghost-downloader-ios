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
                    Text("填电脑在局域网里的 IP 和转发脚本的端口，例如 192.168.0.106:14371。Ghost Downloader 自身只监听 127.0.0.1，必须先用仓库里的 tools/gd-relay.py 转发出来。如果一直连不上，先去「设置 → 隐私与安全性 → 本地网络」确认本 App 是允许的 —— iOS 会静默拦掉所有局域网连接。")
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
            let outcome = await client.requestPairing(server: serverURL)
            isPairing = false
            switch outcome {
            case .paired(let newToken):
                token = newToken
                note("配对成功，正在连接…", isError: false)
                client.connect(server: serverURL, token: newToken)
            case .rejected(let reason):
                note("电脑端拒绝了配对：\(reason)", isError: true)
            case .unreachable(let reason):
                note("连不上电脑端：\(reason)", isError: true)
            case .timedOut:
                note("等电脑端响应超时。确认电脑上弹出了配对框、并且点了同意；如果压根没弹，检查转发脚本是否在运行、以及系统设置里给本 App 的「本地网络」权限是否为开。", isError: true)
            }
        }
    }

    private func note(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }
}

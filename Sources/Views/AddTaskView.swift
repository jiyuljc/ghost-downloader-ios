import SwiftUI

struct AddTaskView: View {
    @ObservedObject var client: GDClient
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var filename = ""
    @State private var directory = ""
    @State private var isSending = false
    @State private var message: String?
    @State private var isSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section("下载地址") {
                    TextField("https://… / magnet: / ftp://", text: $urlText, axis: .vertical)
                        .lineLimit(2...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section {
                    TextField("文件名（留空由电脑端推断）", text: $filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("保存目录（留空用电脑端默认目录）", text: $directory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("可选")
                } footer: {
                    Text("目录是电脑上的路径，例如 D:\\Downloads。留空就用 Ghost Downloader 自己的默认下载目录。")
                }

                if let message {
                    Section {
                        Label(message, systemImage: isSuccess ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(isSuccess ? Color.green : Color.red)
                    }
                }
            }
            .navigationTitle("新建任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("发送") { submit() }
                            .disabled(!canSubmit)
                    }
                }
            }
        }
    }

    private var canSubmit: Bool {
        !urlText.trimmed.isEmpty && client.isUsable && !isSending
    }

    private func submit() {
        let url = urlText.trimmed
        isSending = true
        message = nil

        Task {
            // 文件名留空时由客户端用 URL 末段兜底，见 GDClient.createTask
            let result = await client.createTask(
                url: url,
                filename: filename.trimmed,
                directory: directory.trimmed
            )
            isSending = false
            isSuccess = result.ok
            message = result.displayMessage
            if result.ok {
                urlText = ""
                filename = ""
            }
        }
    }
}

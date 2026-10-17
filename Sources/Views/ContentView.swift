import SwiftUI

struct ContentView: View {
    @StateObject private var client = GDClient()
    @AppStorage(GDSettings.serverURL) private var serverURL = ""
    @AppStorage(GDSettings.token) private var token = ""

    @State private var isAddingTask = false
    @State private var isShowingSettings = false

    private var isConfigured: Bool { !serverURL.trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Ghost Downloader")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ConnectionBadge(phase: client.phase)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            isAddingTask = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(!client.isUsable)

                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
        .sheet(isPresented: $isAddingTask) {
            AddTaskView(client: client)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(client: client)
        }
        .task { reconnect() }
        .onChange(of: serverURL) { _, _ in reconnect() }
        .onChange(of: token) { _, _ in reconnect() }
    }

    @ViewBuilder
    private var content: some View {
        if isConfigured {
            TaskListView(client: client)
        } else {
            WelcomeView { isShowingSettings = true }
        }
    }

    private func reconnect() {
        guard isConfigured, !token.trimmed.isEmpty else {
            client.disconnect()
            return
        }
        client.connect(server: serverURL, token: token)
    }
}

struct WelcomeView: View {
    var onConfigure: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("还没有连接电脑端")
                .font(.title3.weight(.semibold))

            Text("这个 App 是 Ghost Downloader 的 iOS 遥控器。下载、合并、BT 全部跑在你电脑上的 Ghost Downloader 里，手机只负责提交任务和查看进度。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("开始配置", action: onConfigure)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }
}

struct ConnectionBadge: View {
    let phase: GDPhase

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: phase.symbol)
            Text(phase.label)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(phase.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(phase.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct BannerView: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(text)
                .font(.footnote)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

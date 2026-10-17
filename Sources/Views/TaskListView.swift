import SwiftUI

struct TaskListView: View {
    @ObservedObject var client: GDClient

    var body: some View {
        List {
            if let detail = client.phase.detail {
                Section {
                    Label(detail, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if client.tasks.isEmpty {
                Section {
                    emptyHint
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(client.tasks) { task in
                        TaskRow(client: client, task: task)
                    }
                } header: {
                    Text("\(client.tasks.count) 个任务")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.resubscribe() }
        .overlay(alignment: .bottom) {
            if let banner = client.banner {
                BannerView(text: banner) { client.clearBanner() }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: client.isUsable ? "tray" : "wifi.slash")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(client.isUsable ? "电脑端还没有任务" : "尚未连接到电脑端")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(client.isUsable
                 ? "点右上角 + 提交一个下载链接"
                 : "去设置里填写电脑端地址，或点“自动配对”")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
    }
}

struct TaskRow: View {
    @ObservedObject var client: GDClient
    let task: GDTaskSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: task.kind.symbol)
                    .foregroundStyle(task.kind.tint)
                Text(task.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            ProgressView(value: task.progressFraction)
                .tint(task.kind.tint)

            HStack(spacing: 10) {
                Text(task.kind.label)
                    .foregroundStyle(task.kind.tint)
                Text(GDFormat.progressLine(task))
                Spacer(minLength: 0)
                Text(GDFormat.speed(task.speedPerSecond))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !task.kind.isFinished {
                Button { run("toggle_pause") } label: {
                    Label(task.kind.isRunning ? "暂停" : "继续",
                          systemImage: task.kind.isRunning ? "pause.fill" : "play.fill")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { run("remove") } label: {
                Label("移除", systemImage: "trash")
            }
            Button { run("cancel") } label: {
                Label("删除文件", systemImage: "xmark.bin.fill")
            }
            .tint(.orange)
            if task.kind == .completed || task.kind == .failed {
                Button { run("redownload") } label: {
                    Label("重新下载", systemImage: "arrow.clockwise")
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            if !task.kind.isFinished {
                Button { run("toggle_pause") } label: {
                    Label(task.kind.isRunning ? "暂停" : "继续",
                          systemImage: task.kind.isRunning ? "pause.fill" : "play.fill")
                }
            }
            Button { run("open_file") } label: {
                Label("在电脑上打开文件", systemImage: "doc")
            }
            .disabled(!(task.canOpenFile ?? false))
            Button { run("open_folder") } label: {
                Label("在电脑上打开目录", systemImage: "folder")
            }
            .disabled(!(task.canOpenFolder ?? false))
            Button { run("remove") } label: {
                Label("从列表移除", systemImage: "trash")
            }
            Button(role: .destructive) { run("cancel") } label: {
                Label("删除任务和文件", systemImage: "xmark.bin")
            }
        }
    }

    private func run(_ action: String) {
        Task {
            let result = await client.perform(action, taskID: task.taskId)
            if !result.ok, !result.message.isEmpty {
                client.presentBanner(result.message)
            }
        }
    }
}

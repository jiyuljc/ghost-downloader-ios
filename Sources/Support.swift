import Foundation

/// `@AppStorage` 用的键，桌面端无关，纯本机持久化。
enum GDSettings {
    static let serverURL = "gd.serverURL"
    static let token = "gd.token"
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum GDFormat {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: value)
    }

    static func speed(_ value: Double) -> String {
        guard value > 0 else { return "" }
        return bytes(Int64(value)) + "/s"
    }

    /// 桌面端对未知大小用 0/-1 表示，此时不能显示 “/ 0 B”。
    static func progressLine(_ task: GDTaskSummary) -> String {
        let percent = String(format: "%.1f%%", task.progressFraction * 100)
        if task.hasKnownSize {
            return "\(percent) · \(bytes(task.received)) / \(bytes(task.sizeBytes))"
        }
        return "\(percent) · \(bytes(task.received))"
    }

    /// 从 URL 末尾推一个文件名。
    ///
    /// 浏览器扩展永远会带上解析好的 `filename`，桌面端也直接信任这个字段，
    /// 所以用户留空时我们得自己补一个，不能让 `filename` 是空串。
    static func fallbackFilename(from urlString: String) -> String {
        guard let url = URL(string: urlString), url.scheme != "magnet" else { return "" }
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return "" }
        let decoded = last.removingPercentEncoding ?? last
        // 桌面端会自己过滤非法字符，这里只做长度兜底
        return String(decoded.prefix(160))
    }
}

import SwiftUI

/// 桌面端 `toTaskSummary()` 的镜像。
///
/// 字段全部声明为可选：桌面端在任务刚创建、日志尚未补全时会发 `null`，
/// 直接强解会让整批 `task_snapshot` 解析失败。
struct GDTaskSummary: Identifiable, Hashable {
    let taskId: String
    let name: String?
    let status: String?
    let progress: Double?
    let receivedBytes: Int64?
    let fileSize: Int64?
    let speed: Double?
    let createdAt: Double?
    let canPause: Bool?
    let canOpenFile: Bool?
    let canOpenFolder: Bool?
    let fileExt: String?
    let packName: String?

    var id: String { taskId }

    var displayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? taskId : trimmed
    }

    var kind: GDStatus { GDStatus.parse(status) }

    /// 桌面端发的是百分数（0–100）。
    var progressFraction: Double { min(max((progress ?? 0) / 100, 0), 1) }

    /// 桌面端用 -1 表示不支持、0 表示未知，两者都不该当成真实大小。
    var hasKnownSize: Bool { (fileSize ?? 0) > 0 }

    var sizeBytes: Int64 { max(fileSize ?? 0, 0) }
    var received: Int64 { max(receivedBytes ?? 0, 0) }
    var speedPerSecond: Double { max(speed ?? 0, 0) }
    var created: Double { createdAt ?? 0 }
}

extension GDTaskSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case taskId, name, status, progress, receivedBytes, fileSize
        case speed, createdAt, canPause, canOpenFile, canOpenFolder, fileExt, packName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = (try? c.decode(String.self, forKey: .taskId)) ?? ""
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        progress = try? c.decodeIfPresent(Double.self, forKey: .progress)
        receivedBytes = try? c.decodeIfPresent(Int64.self, forKey: .receivedBytes)
        fileSize = try? c.decodeIfPresent(Int64.self, forKey: .fileSize)
        speed = try? c.decodeIfPresent(Double.self, forKey: .speed)
        createdAt = try? c.decodeIfPresent(Double.self, forKey: .createdAt)
        canPause = try? c.decodeIfPresent(Bool.self, forKey: .canPause)
        canOpenFile = try? c.decodeIfPresent(Bool.self, forKey: .canOpenFile)
        canOpenFolder = try? c.decodeIfPresent(Bool.self, forKey: .canOpenFolder)
        fileExt = try? c.decodeIfPresent(String.self, forKey: .fileExt)
        packName = try? c.decodeIfPresent(String.self, forKey: .packName)
    }
}

/// 对应桌面端的 `TaskStatus`（WAITING / RUNNING / PAUSED / COMPLETED / FAILED）。
enum GDStatus {
    case waiting, running, paused, completed, failed, seeding, unknown

    static func parse(_ raw: String?) -> GDStatus {
        switch (raw ?? "").lowercased() {
        case "waiting": return .waiting
        case "running": return .running
        case "paused": return .paused
        case "completed": return .completed
        case "failed": return .failed
        case "seeding": return .seeding
        default: return .unknown
        }
    }

    var label: String {
        switch self {
        case .waiting: return "排队中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .seeding: return "做种中"
        case .unknown: return "未知"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "clock"
        case .running: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .seeding: return "arrow.up.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .waiting: return .orange
        case .running: return .blue
        case .paused: return .gray
        case .completed: return .green
        case .failed: return .red
        case .seeding: return .teal
        case .unknown: return .secondary
        }
    }

    var isRunning: Bool { self == .running }
    var isFinished: Bool { self == .completed || self == .failed }
}

/// 连接状态机，直接映射桌面端 `DesktopConnectionState` 的语义。
enum GDPhase: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case unauthorized(String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .authenticating: return "认证中"
        case .connected: return "已连接"
        case .unauthorized: return "令牌无效"
        case .failed: return "连接失败"
        }
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting, .authenticating: return .orange
        case .unauthorized, .failed: return .red
        case .disconnected: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .connected: return "wifi"
        case .connecting, .authenticating: return "wifi.exclamationmark"
        case .unauthorized: return "lock.slash"
        case .failed, .disconnected: return "wifi.slash"
        }
    }

    var isConnected: Bool { self == .connected }

    var detail: String? {
        switch self {
        case .unauthorized(let message), .failed(let message): return message
        default: return nil
        }
    }
}

struct GDCreateResult {
    let status: String
    let taskId: String?
    let message: String?

    /// 桌面端语义：created = 直接入队，drafted = 进了待确认草稿。
    var ok: Bool { status == "created" || status == "drafted" }

    var displayMessage: String {
        switch status {
        case "created": return "已提交到电脑端"
        case "drafted": return "已进入待确认队列，需要回电脑端确认"
        default:
            let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "桌面端拒绝了该任务" : text
        }
    }
}

/// 桌面端 `TaskAction` 执行结果。
struct GDActionResult {
    let ok: Bool
    let message: String
}

/// 与 `app/config/cfg.py` 对齐的默认端口。
enum GDDefaults {
    /// `Browser.Port`
    static let desktopPort = 14370
    /// 我们那个局域网转发脚本的监听端口
    static let relayPort = 14371
}

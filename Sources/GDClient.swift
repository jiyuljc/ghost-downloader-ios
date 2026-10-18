import Combine
import Foundation

/// Ghost Downloader 3 的 Browser Service 客户端。
///
/// 协议来自 `app/services/browser_service.py`：WebSocket + JSON，`PROTOCOL_VERSION = 2`。
/// 握手 → `hello` → `hello_ack` → `subscribe_tasks` → 持续接收 `task_snapshot`。
///
/// 继承 `NSObject` 只为了当 `URLSessionWebSocketDelegate`：`task.resume()` 之后
/// 立刻 `send` 并不保证连接已经建立，第一条消息必须等 `didOpenWithProtocol`。
@MainActor
final class GDClient: NSObject, ObservableObject {
    static let clientVersion = "1.0.0"
    /// 必须与桌面端 `PROTOCOL_VERSION` 一致，否则会被 `protocol_mismatch` 断开。
    static let protocolVersion = 2

    @Published private(set) var phase: GDPhase = .disconnected
    @Published private(set) var tasks: [GDTaskSummary] = []
    @Published private(set) var desktopVersion = ""
    @Published private(set) var banner: String?

    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var reconnectLoop: Task<Void, Never>?

    private var endpoint: URL?
    private var token = ""
    private var wantsConnection = false
    private var didAuthenticate = false
    private var reconnectAttempts = 0

    private var createWaiters: [String: CheckedContinuation<GDCreateResult, Never>] = [:]
    private var actionWaiters: [String: CheckedContinuation<GDActionResult, Never>] = [:]
    private var pairWaiter: CheckedContinuation<String?, Never>?
    /// 握手完成后要发的第一条消息（`hello` 或 `pair_request`）。
    private var onSocketOpen: (() -> Void)?
    /// 配对时桌面端给出的明确拒绝原因。
    private var pairRejection: String?
    /// 配对时连接层的真实错误。地址写错、被权限拦下、防火墙丢包都会在这里现形。
    private var pairSocketError: String?

    /// delegate 用来在 WebSocket 真正握手完成后才发消息。
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    var isUsable: Bool { phase.isConnected }

    // MARK: - 地址解析

    /// 允许用户只填 `192.168.1.10:14371`，自动补 `ws://` 与默认端口。
    static func normalize(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "ws://" + raw }
        guard var components = URLComponents(string: raw) else { return nil }
        guard let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        // host 为 nil 或空串都算非法地址
        guard components.host?.isEmpty == false else { return nil }
        if components.port == nil { components.port = GDDefaults.relayPort }
        return components.url
    }

    // MARK: - 连接生命周期

    func connect(server: String, token rawToken: String) {
        guard let url = Self.normalize(server) else {
            wantsConnection = false
            closeSocket()
            phase = .failed("服务器地址不正确")
            return
        }
        endpoint = url
        token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        wantsConnection = true
        reconnectAttempts = 0
        openSocket(shouldSendHello: !token.isEmpty)
    }

    func disconnect() {
        wantsConnection = false
        reconnectLoop?.cancel()
        reconnectLoop = nil
        closeSocket()
        didAuthenticate = false
        phase = .disconnected
        tasks = []
        desktopVersion = ""
    }

    func presentBanner(_ text: String) { banner = text }

    func clearBanner() { banner = nil }

    func resubscribe() {
        guard didAuthenticate else { return }
        sendNow(["type": "subscribe_tasks"])
    }

    /// 触发桌面端的配对弹窗；用户在那台电脑上点同意后返回新的配对令牌。
    ///
    /// 返回细分过的结果而不是 `String?`：以前把「连不上」「超时」「被拒绝」
    /// 统一报成「电脑端没有响应或已拒绝」，根本没法排查。
    func requestPairing(server: String) async -> GDPairOutcome {
        guard let url = Self.normalize(server) else {
            phase = .failed("服务器地址不正确")
            return .unreachable("地址解析不了，检查是不是写成了 192.168.0.106:14371")
        }
        endpoint = url
        // 配对是一次性动作，不参与自动重连
        wantsConnection = false
        pairRejection = nil
        pairSocketError = nil
        openSocket(shouldSendHello: false)
        phase = .connecting

        let requestId = UUID().uuidString
        // 必须等握手完成再发，握手前的 send 不保证送达
        onSocketOpen = { [weak self] in
            self?.sendNow([
                "type": "pair_request",
                "requestId": requestId,
                "protocolVersion": Self.protocolVersion,
                "extensionVersion": Self.clientVersion,
                "clientKind": "ios_client",
            ])
        }

        let newToken = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            pairWaiter = continuation
            // 桌面端弹窗等待上限 60s，这里比它稍长一点
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 70_000_000_000)
                guard let self else { return }
                self.resumePairing(with: nil)
            }
        }

        if let newToken { return .paired(newToken) }

        // 失败时必须把 socket 关掉。桌面端在配对期间持有 `_pairRequest`，
        // 连接不断开的话它会一直留着，之后每次配对都被回「已有配对请求待处理」。
        closeSocket()

        if let rejection = pairRejection { return .rejected(rejection) }
        if let error = pairSocketError { return .unreachable(error) }
        return .timedOut
    }

    // MARK: - 业务操作

    func createTask(url: String, filename: String, directory: String) async -> GDCreateResult {
        let requestId = UUID().uuidString
        // 桌面端直接信任 payload 里的 filename，空串会让任务没有名字，
        // 所以留空时用 URL 末段兜底（浏览器扩展也是这么做的）
        let resolvedName = filename.trimmed.isEmpty
            ? GDFormat.fallbackFilename(from: url)
            : filename.trimmed
        var payload: [String: Any] = [
            // 和扩展的 `toResourceTaskOptions` 保持同一形状：
            // 文件名/size/supportsRange 由客户端给出，桌面端直接信任
            "url": url,
            "filename": resolvedName,
            "size": 0,
            "supportsRange": false,
            "headers": [String: String](),
        ]
        let folder = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folder.isEmpty { payload["path"] = folder }

        let message: [String: Any] = [
            "type": "create_task",
            "requestId": requestId,
            "source": "resource",
            "draft": false,
            "payload": payload,
        ]

        return await withCheckedContinuation { (continuation: CheckedContinuation<GDCreateResult, Never>) in
            createWaiters[requestId] = continuation
            sendNow(message)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self else { return }
                if let waiter = self.createWaiters.removeValue(forKey: requestId) {
                    waiter.resume(returning: GDCreateResult(status: "rejected", taskId: nil, message: "等待电脑端响应超时"))
                }
            }
        }
    }

    /// `action` 取值见桌面端 `TaskAction`。
    func perform(_ action: String, taskID: String) async -> GDActionResult {
        let requestId = UUID().uuidString
        return await withCheckedContinuation { (continuation: CheckedContinuation<GDActionResult, Never>) in
            actionWaiters[requestId] = continuation
            sendNow([
                "type": "task_action",
                "requestId": requestId,
                "taskId": taskID,
                "action": action,
            ])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                if let waiter = self.actionWaiters.removeValue(forKey: requestId) {
                    waiter.resume(returning: GDActionResult(ok: false, message: "等待电脑端响应超时"))
                }
            }
        }
    }

    // MARK: - WebSocket 底座

    private func openSocket(shouldSendHello: Bool) {
        guard let endpoint else { return }
        closeSocket()
        phase = shouldSendHello ? .authenticating : .connecting
        // 握手完成后再发第一条消息，其他情况（如配对）由调用方覆盖这里
        onSocketOpen = shouldSendHello ? { [weak self] in self?.sendHelloNow() } : nil

        let task = session.webSocketTask(with: endpoint)
        socket = task
        task.resume()
        startReceiveLoop(task)
        startPingLoop(task)
    }

    private func closeSocket() {
        receiveLoop?.cancel()
        receiveLoop = nil
        pingLoop?.cancel()
        pingLoop = nil
        onSocketOpen = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func sendHelloNow() {
        sendNow([
            "type": "hello",
            "protocolVersion": Self.protocolVersion,
            "token": token,
            // 注意：不要发 "development"，那会触发桌面端用内置扩展覆盖本地扩展
            "extensionVersion": Self.clientVersion,
            "clientKind": "ios_client",
            "installType": "ios",
        ])
    }

    private func sendNow(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { _ = try? await socket.send(.string(text)) }
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.handleSocketClosed(error)
                    return
                }
            }
        }
    }

    /// 长时间无数据时路由器/NAT 会静默丢弃连接，定期 ping 保活。
    private func startPingLoop(_ task: URLSessionWebSocketTask) {
        pingLoop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { return }
                task.sendPing { _ in }
            }
        }
    }

    // MARK: - 消息分发

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "hello_ack":
            didAuthenticate = true
            reconnectAttempts = 0
            desktopVersion = object["appVersion"] as? String ?? ""
            phase = .connected
            sendNow(["type": "subscribe_tasks"])

        case "task_snapshot":
            let raw = object["tasks"] as? [[String: Any]] ?? []
            tasks = raw.compactMap(decodeTask).sorted { $0.created > $1.created }

        case "create_task_result":
            finishCreate(object)

        case "task_action_result":
            finishAction(object)

        case "pair_result":
            finishPairing(object)

        case "error":
            handleError(object)

        // 这是给浏览器扩展的热重载指令，iOS 端忽略
        case "reload":
            break

        default:
            break
        }
    }

    private func decodeTask(_ object: [String: Any]) -> GDTaskSummary? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(GDTaskSummary.self, from: data)
    }

    private func finishCreate(_ object: [String: Any]) {
        let requestId = object["requestId"] as? String ?? ""
        guard let waiter = createWaiters.removeValue(forKey: requestId) else { return }
        waiter.resume(returning: GDCreateResult(
            status: object["status"] as? String ?? "rejected",
            taskId: object["taskId"] as? String,
            message: object["message"] as? String
        ))
    }

    private func finishAction(_ object: [String: Any]) {
        let requestId = object["requestId"] as? String ?? ""
        guard let waiter = actionWaiters.removeValue(forKey: requestId) else { return }
        waiter.resume(returning: GDActionResult(
            ok: object["ok"] as? Bool ?? false,
            message: object["message"] as? String ?? ""
        ))
    }

    private func finishPairing(_ object: [String: Any]) {
        let ok = object["ok"] as? Bool ?? false
        let newToken = (object["token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ok, !newToken.isEmpty else {
            let reason = object["message"] as? String ?? "配对被拒绝"
            pairRejection = reason
            phase = .failed(reason)
            resumePairing(with: nil)
            return
        }
        resumePairing(with: newToken)
    }

    private func resumePairing(with newToken: String?) {
        guard let waiter = pairWaiter else { return }
        pairWaiter = nil
        waiter.resume(returning: newToken)
    }

    private func handleError(_ object: [String: Any]) {
        let message = object["message"] as? String ?? "电脑端返回错误"
        switch object["code"] as? String {
        case "unauthorized":
            pairRejection = message
            wantsConnection = false
            closeSocket()
            phase = .unauthorized(message)
            resumePairing(with: nil)
        case "protocol_mismatch":
            pairRejection = message
            wantsConnection = false
            closeSocket()
            phase = .failed("协议版本不匹配：本机 v\(Self.protocolVersion)，电脑端 v\(desktopVersion)")
            resumePairing(with: nil)
        default:
            pairRejection = message
            banner = message
            resumePairing(with: nil)
        }
    }

    private func handleSocketClosed(_ error: Error?) {
        let wasAuthenticated = didAuthenticate
        didAuthenticate = false
        socket = nil
        receiveLoop = nil
        pingLoop?.cancel()
        pingLoop = nil

        // 连接层的错误要留下来给配对流程用，否则用户只会看到「没有响应」，
        // 分不清是地址错、被系统拦了，还是防火墙把包丢了
        if let error { pairSocketError = error.localizedDescription }
        resumePairing(with: nil)

        guard wantsConnection else {
            if phase.detail != nil { return }
            phase = .disconnected
            return
        }
        // 令牌被拒时重连没有意义，等用户改配置
        if case .unauthorized = phase { return }

        phase = .failed(error?.localizedDescription ?? "与电脑端的连接已断开")

        let delay: TimeInterval
        if wasAuthenticated {
            delay = 2
        } else {
            delay = min(30, pow(2, Double(reconnectAttempts)))
            reconnectAttempts += 1
        }
        scheduleReconnect(after: delay)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        reconnectLoop?.cancel()
        reconnectLoop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.wantsConnection else { return }
            self.reconnectLoop = nil
            self.openSocket(shouldSendHello: !self.token.isEmpty)
        }
    }
}

// MARK: - WebSocket 生命周期

extension GDClient: URLSessionWebSocketDelegate {
    /// 握手真正完成。在这之前 `send` 不保证送达，所以第一条消息要等这里。
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.socket else { return }
            let pending = self.onSocketOpen
            self.onSocketOpen = nil
            pending?()
        }
    }
}

/// 配对结果。分这么细是因为「连不上」和「被拒绝」的排查方向完全不同。
enum GDPairOutcome {
    case paired(String)
    case rejected(String)
    case unreachable(String)
    case timedOut
}

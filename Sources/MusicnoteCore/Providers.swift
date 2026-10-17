import AppKit
import Foundation

public enum ProviderState: String, Sendable {
    case notConnected, connecting, connected, expired, quotaExhausted, clientUnavailable

    public var display: String {
        switch self {
        case .notConnected: "未连接"
        case .connecting: "连接中"
        case .connected: "已连接"
        case .expired: "登录过期"
        case .quotaExhausted: "额度耗尽"
        case .clientUnavailable: "客户端不可用"
        }
    }
}

public struct ProviderStatus: Sendable {
    public var state: ProviderState
    public var account: String?
    public var plan: String?
    public var quotaNote: String?
    public init(state: ProviderState, account: String? = nil, plan: String? = nil, quotaNote: String? = nil) {
        self.state = state; self.account = account; self.plan = plan; self.quotaNote = quotaNote
    }
}

public struct ProviderModel: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var efforts: [String]
    public var defaultEffort: String?
    public var isDefault: Bool
    public var verified: Bool // false = 能力未确认

    public init(id: String, name: String, efforts: [String], defaultEffort: String?, isDefault: Bool, verified: Bool) {
        self.id = id; self.name = name; self.efforts = efforts; self.defaultEffort = defaultEffort
        self.isDefault = isDefault; self.verified = verified
    }
}

public struct ProviderTurn: Sendable {
    public var sessionId: String?
    public var systemPrompt: String
    public var text: String
    public var model: String?
    public var effort: String?
    public var outputSchema: [String: Any]?
    public init(sessionId: String?, systemPrompt: String, text: String, model: String?, effort: String?, outputSchema: [String: Any]? = nil) {
        self.sessionId = sessionId; self.systemPrompt = systemPrompt; self.text = text; self.model = model
        self.effort = effort; self.outputSchema = outputSchema
    }
}

public struct ProviderTurnResult: Sendable {
    public var sessionId: String
    public var text: String
    public var contextTokens: Int?
    public var contextWindow: Int?
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case loginRequired, quotaExhausted(String?), modelUnavailable(String), clientUnavailable(String)
    case permissionViolation(String), incomplete(String, partial: String), other(String)

    public var errorDescription: String? {
        switch self {
        case .loginRequired: "需要重新登录（官方客户端）"
        case .quotaExhausted(let r): "额度已用完" + (r.map { "，恢复时间：\($0)" } ?? "")
        case .modelUnavailable(let m): "模型不可用：\(m)，请选择其他模型"
        case .clientUnavailable(let m): "客户端不可用：\(m)"
        case .permissionViolation(let t): "模型尝试调用未授权的工具（\(t)），已中止"
        case .incomplete(let m, _): "回答未完成：\(m)"
        case .other(let m): m
        }
    }

    public var code: String {
        switch self {
        case .loginRequired: "LOGIN_REQUIRED"
        case .quotaExhausted: "QUOTA_EXHAUSTED"
        case .modelUnavailable: "MODEL_UNAVAILABLE"
        case .clientUnavailable: "CLIENT_UNAVAILABLE"
        case .permissionViolation: "PERMISSION_DENIED"
        case .incomplete: "INCOMPLETE"
        case .other: "PROVIDER_ERROR"
        }
    }
}

/// Shared adapter surface for skeleton analysis and chat. Both providers run the
/// user's own official client; this app never sees or stores credentials.
public protocol ChatProvider: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    func status() async -> ProviderStatus
    func models() async -> [ProviderModel]
    func login() async throws
    func send(_ turn: ProviderTurn, onDelta: @escaping @Sendable (String) -> Void) async throws -> ProviderTurnResult
}

// MARK: - Codex (codex app-server over stdio JSON-RPC)

public final class CodexProvider: ChatProvider, @unchecked Sendable {
    public let id = "codex"
    public let displayName = "Codex"
    let binary: String
    let sandboxDir: URL

    private var process: Process?
    private var stdin: FileHandle?
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var listeners: [UUID: ([String: Any]) -> Void] = [:]
    private var buffer = Data()
    private let lock = NSLock()
    private var resumed: Set<String> = []

    // Everything except plain conversation is disabled; a watchdog interrupts any turn
    // that still produces a tool item.
    static let disabledFeatures = ["shell_tool", "unified_exec", "apps", "plugins", "browser_use", "browser_use_external",
                                   "computer_use", "view_image", "goals", "sleep_tool", "skill_search", "tool_suggest",
                                   "code_mode_host", "skill_mcp_dependency_install", "remote_plugin"]
    static let allowedItems: Set<String> = ["agentMessage", "reasoning", "userMessage", "contextCompaction", "plan"]

    public init(binary: String, sandboxDir: URL) { self.binary = binary; self.sandboxDir = sandboxDir }

    deinit { process?.terminate() }

    private func ensureStarted() async throws {
        if let p = process, p.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw ProviderError.clientUnavailable("找不到 codex：\(binary)") }
        try? FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        var args = ["app-server"]
        for f in Self.disabledFeatures { args += ["--disable", f] }
        args += ["-c", "web_search=\"disabled\"", "-c", "agents.enabled=false",
                 "-c", "mcp_servers.node_repl.enabled=false", "-c", "mcp_servers.openaiDeveloperDocs.enabled=false"]
        p.arguments = args
        p.currentDirectoryURL = sandboxDir
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardInput = inp; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in self?.consume(h.availableData) }
        p.terminationHandler = { [weak self] _ in self?.failAll(ProviderError.clientUnavailable("codex app-server 已退出")) }
        try p.run()
        process = p; stdin = inp.fileHandleForWriting
        resumed = []
        _ = try await request("initialize", ["clientInfo": ["name": "musicnote", "title": "Musicnote", "version": "0.1"], "capabilities": NSNull()])
        notify("initialized", nil)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var messages: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { messages.append(o) }
        }
        lock.unlock()
        for m in messages { dispatch(m) }
    }

    private func dispatch(_ m: [String: Any]) {
        if let id = m["id"] as? Int, m["method"] == nil {
            lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
            if let err = m["error"] as? [String: Any] {
                c?.resume(throwing: Self.mapError(err["message"] as? String ?? "codex error"))
            } else { c?.resume(returning: m["result"] as? [String: Any] ?? [:]) }
            return
        }
        if let id = m["id"], let method = m["method"] as? String {
            // Server → client requests (approvals, user input): always decline.
            respond(id: id, result: method.contains("Approval") || method.contains("approval") ? ["decision": "decline"] : [:])
        }
        lock.lock(); let ls = Array(listeners.values); lock.unlock()
        for l in ls { l(m) }
    }

    static func mapError(_ message: String) -> ProviderError {
        let low = message.lowercased()
        if low.contains("login") || low.contains("auth") || low.contains("401") { return .loginRequired }
        if low.contains("rate limit") || low.contains("quota") || low.contains("usage limit") { return .quotaExhausted(nil) }
        if low.contains("model") && (low.contains("not") || low.contains("unsupported")) { return .modelUnavailable(message) }
        return .other(message)
    }

    private func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        stdin?.write(data); stdin?.write(Data([0x0A]))
    }

    private func notify(_ method: String, _ params: [String: Any]?) {
        var o: [String: Any] = ["method": method]
        if let params { o["params"] = params }
        write(o)
    }

    private func respond(id: Any, result: [String: Any]) { write(["id": id, "result": result]) }

    private func failAll(_ error: Error) {
        lock.lock(); let cs = pending; pending = [:]; lock.unlock()
        for c in cs.values { c.resume(throwing: error) }
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { c in
            lock.lock(); nextId += 1; let id = nextId; pending[id] = c; lock.unlock()
            write(["id": id, "method": method, "params": params])
        }
    }

    private func listen(_ f: @escaping ([String: Any]) -> Void) -> UUID {
        let id = UUID(); lock.lock(); listeners[id] = f; lock.unlock(); return id
    }
    private func unlisten(_ id: UUID) { lock.lock(); listeners[id] = nil; lock.unlock() }

    public func status() async -> ProviderStatus {
        do {
            try await ensureStarted()
            let r = try await request("account/read", ["refreshToken": false])
            guard let acct = r["account"] as? [String: Any] else { return ProviderStatus(state: .notConnected) }
            var s = ProviderStatus(state: .connected, account: acct["email"] as? String, plan: acct["planType"] as? String)
            if let rl = try? await request("account/rateLimits/read", [:]),
               let limits = rl["rateLimits"] as? [String: Any], let primary = limits["primary"] as? [String: Any],
               let used = primary["usedPercent"] as? Int {
                s.quotaNote = "本周期已用 \(used)%"
                if used >= 100 {
                    s.state = .quotaExhausted
                    if let reset = primary["resetsAt"] as? Double {
                        s.quotaNote = "额度耗尽，\(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened)) 恢复"
                    }
                }
            }
            return s
        } catch ProviderError.clientUnavailable(let m) {
            return ProviderStatus(state: .clientUnavailable, quotaNote: m)
        } catch {
            return ProviderStatus(state: .expired, quotaNote: error.localizedDescription)
        }
    }

    public func models() async -> [ProviderModel] {
        guard (try? await ensureStarted()) != nil, let r = try? await request("model/list", [:]) else { return [] }
        return (r["data"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            let efforts = (d["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            return ProviderModel(id: id, name: d["displayName"] as? String ?? id, efforts: efforts,
                                 defaultEffort: d["defaultReasoningEffort"] as? String, isDefault: d["isDefault"] as? Bool ?? false,
                                 verified: true)
        }
    }

    public func login() async throws {
        try await ensureStarted()
        let r = try await request("account/login/start", ["type": "chatgpt"])
        guard let s = r["authUrl"] as? String, let url = URL(string: s) else { throw ProviderError.other("没有拿到官方登录链接") }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        // Wait for account/login/completed (up to 10 minutes).
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var done = false
            nonisolated(unsafe) var token: UUID?
            token = listen { [weak self] m in
                guard !done, (m["method"] as? String) == "account/login/completed" else { return }
                done = true
                if let t = token { self?.unlisten(t) }
                let ok = ((m["params"] as? [String: Any])?["success"] as? Bool) ?? true
                ok ? c.resume() : c.resume(throwing: ProviderError.loginRequired)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 600) { [weak self] in
                guard !done else { return }
                done = true
                if let t = token { self?.unlisten(t) }
                c.resume(throwing: ProviderError.loginRequired)
            }
        }
    }

    public func send(_ turn: ProviderTurn, onDelta: @escaping @Sendable (String) -> Void) async throws -> ProviderTurnResult {
        try await ensureStarted()
        var threadId = turn.sessionId
        if let t = threadId, !resumed.contains(t) {
            if (try? await request("thread/resume", ["threadId": t, "cwd": sandboxDir.path])) != nil { resumed.insert(t) } else { threadId = nil }
        }
        if threadId == nil {
            var p: [String: Any] = ["cwd": sandboxDir.path, "approvalPolicy": "never", "sandbox": "read-only",
                                    "baseInstructions": turn.systemPrompt]
            if let m = turn.model { p["model"] = m }
            let r = try await request("thread/start", p)
            guard let t = (r["thread"] as? [String: Any])?["id"] as? String else { throw ProviderError.other("无法创建 Codex 会话") }
            threadId = t; resumed.insert(t)
        }
        let tid = threadId!
        nonisolated(unsafe) var text = ""
        nonisolated(unsafe) var tokens: Int?
        nonisolated(unsafe) var window: Int?
        nonisolated(unsafe) var turnId: String?
        nonisolated(unsafe) var violation: String?
        let lockText = NSLock()
        let finished: Result<Void, Error> = await withCheckedContinuation { (c: CheckedContinuation<Result<Void, Error>, Never>) in
            nonisolated(unsafe) var resolved = false
            nonisolated(unsafe) var token: UUID?
            func finish(_ r: Result<Void, Error>) {
                lockText.lock(); defer { lockText.unlock() }
                guard !resolved else { return }
                resolved = true
                if let t = token { unlisten(t) }
                c.resume(returning: r)
            }
            token = listen { [weak self] m in
                guard let method = m["method"] as? String, let params = m["params"] as? [String: Any] else { return }
                if let t = params["threadId"] as? String, t != tid { return }
                switch method {
                case "turn/started": turnId = (params["turn"] as? [String: Any])?["id"] as? String
                case "item/agentMessage/delta":
                    if let d = params["delta"] as? String { lockText.lock(); text += d; lockText.unlock(); onDelta(d) }
                case "item/started":
                    if let item = params["item"] as? [String: Any], let type = item["type"] as? String, !Self.allowedItems.contains(type) {
                        violation = type
                        if let turnId { Task { _ = try? await self?.request("turn/interrupt", ["threadId": tid, "turnId": turnId]) } }
                    }
                case "thread/tokenUsage/updated":
                    if let u = params["tokenUsage"] as? [String: Any] {
                        tokens = ((u["last"] as? [String: Any])?["inputTokens"] as? Int) ?? ((u["total"] as? [String: Any])?["inputTokens"] as? Int)
                        window = u["modelContextWindow"] as? Int
                    }
                case "error":
                    let msg = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex 错误"
                    if params["willRetry"] as? Bool != true { finish(.failure(Self.mapError(msg))) }
                case "turn/completed":
                    let t = params["turn"] as? [String: Any]
                    if let status = t?["status"] as? String, status == "failed" {
                        let msg = (t?["error"] as? [String: Any])?["message"] as? String ?? "回答失败"
                        finish(.failure(Self.mapError(msg)))
                    } else if (t?["status"] as? String) == "interrupted" {
                        finish(.failure(violation.map { ProviderError.permissionViolation($0) } ?? ProviderError.incomplete("已停止", partial: text)))
                    } else { finish(.success(())) }
                default: break
                }
            }
            Task { [weak self] in
                guard let self else { return }
                var p: [String: Any] = ["threadId": tid, "input": [["type": "text", "text": turn.text, "text_elements": []]],
                                        "approvalPolicy": "never", "sandboxPolicy": ["type": "readOnly", "networkAccess": false]]
                if let m = turn.model { p["model"] = m }
                if let e = turn.effort { p["effort"] = e }
                if let s = turn.outputSchema { p["outputSchema"] = s }
                do { _ = try await self.request("turn/start", p) } catch { finish(.failure(error)) }
            }
        }
        if case .failure(let e) = finished { throw e }
        if let v = violation { throw ProviderError.permissionViolation(v) }
        return ProviderTurnResult(sessionId: tid, text: text, contextTokens: tokens, contextWindow: window)
    }

    public func interrupt(threadId: String) async {
        // Interrupt is driven by task cancellation in the caller; nothing persistent to clean.
    }
}

// MARK: - Claude Code (claude -p, stream-json, no tools)

public final class ClaudeProvider: ChatProvider, @unchecked Sendable {
    public let id = "claude"
    public let displayName = "Claude Code"
    let binary: String
    let sandboxDir: URL

    public init(binary: String, sandboxDir: URL) { self.binary = binary; self.sandboxDir = sandboxDir }

    public func status() async -> ProviderStatus {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return ProviderStatus(state: .clientUnavailable, quotaNote: "找不到 claude：\(binary)")
        }
        nonisolated(unsafe) var out = ""
        let w = WorkerProcess(binary, ["auth", "status"])
        _ = try? await w.run { out += $0 + "\n" }
        guard let data = out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderStatus(state: .notConnected)
        }
        guard o["loggedIn"] as? Bool == true else { return ProviderStatus(state: .notConnected) }
        return ProviderStatus(state: .connected, account: o["email"] as? String, plan: o["authMethod"] as? String)
    }

    /// The CLI cannot list models; aliases documented in `claude --help` are offered,
    /// and anything else is "能力未确认".
    public func models() async -> [ProviderModel] {
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        return [
            ProviderModel(id: "default", name: "默认（客户端设置）", efforts: efforts, defaultEffort: nil, isDefault: true, verified: false),
            ProviderModel(id: "opus", name: "opus", efforts: efforts, defaultEffort: nil, isDefault: false, verified: false),
            ProviderModel(id: "sonnet", name: "sonnet", efforts: efforts, defaultEffort: nil, isDefault: false, verified: false),
            ProviderModel(id: "fable", name: "fable", efforts: efforts, defaultEffort: nil, isDefault: false, verified: false),
        ]
    }

    public func login() async throws {
        // Official login runs in Terminal so the user interacts with the real client.
        let script = "tell application \"Terminal\" to do script \"\(binary) auth login\""
        await MainActor.run {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        }
    }

    public func send(_ turn: ProviderTurn, onDelta: @escaping @Sendable (String) -> Void) async throws -> ProviderTurnResult {
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw ProviderError.clientUnavailable("找不到 claude") }
        try? FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "",
                    "--system-prompt", turn.systemPrompt]
        let session: String
        if let s = turn.sessionId { session = s; args += ["--resume", s] } else { session = UUID().uuidString.lowercased(); args += ["--session-id", session] }
        if let m = turn.model, m != "default" { args += ["--model", m] }
        if let e = turn.effort { args += ["--effort", e] }
        if let schema = turn.outputSchema, let d = try? JSONSerialization.data(withJSONObject: schema) {
            args += ["--json-schema", String(decoding: d, as: UTF8.self)]
        }
        let w = WorkerProcess(binary, args)
        w.currentDirectory = sandboxDir
        w.stdinData = Data(turn.text.utf8)
        nonisolated(unsafe) var text = ""
        nonisolated(unsafe) var resultText: String?
        nonisolated(unsafe) var structured: String?
        nonisolated(unsafe) var isError = false
        nonisolated(unsafe) var errorText = ""
        nonisolated(unsafe) var tokens: Int?
        nonisolated(unsafe) var window: Int?
        nonisolated(unsafe) var sid = session
        nonisolated(unsafe) var violation: String?
        let r = try await w.run { line in
            guard let m = decodeJSONLine(line), let type = m["type"] as? String else { return }
            switch type {
            case "system":
                if let s = m["session_id"] as? String { sid = s }
                // Only the synthetic StructuredOutput tool (added by --json-schema) is acceptable.
                if let tools = m["tools"] as? [String], let bad = tools.first(where: { $0 != "StructuredOutput" }) { violation = bad }
            case "stream_event":
                if let e = m["event"] as? [String: Any], (e["type"] as? String) == "content_block_delta",
                   let d = e["delta"] as? [String: Any], (d["type"] as? String) == "text_delta", let t = d["text"] as? String {
                    text += t; onDelta(t)
                }
            case "result":
                isError = m["is_error"] as? Bool ?? false
                resultText = m["result"] as? String
                if let so = m["structured_output"], let d = try? JSONSerialization.data(withJSONObject: so) { structured = String(decoding: d, as: UTF8.self) }
                if isError { errorText = (m["result"] as? String) ?? (m["subtype"] as? String ?? "") }
                if let usage = m["modelUsage"] as? [String: Any] {
                    for (_, v) in usage {
                        guard let u = v as? [String: Any], let cw = u["contextWindow"] as? Int, cw >= (window ?? 0) else { continue }
                        window = cw
                        tokens = (u["inputTokens"] as? Int ?? 0) + (u["cacheReadInputTokens"] as? Int ?? 0) + (u["cacheCreationInputTokens"] as? Int ?? 0)
                    }
                }
            case "rate_limit_event":
                if let info = m["rate_limit_info"] as? [String: Any], (info["status"] as? String) == "rejected" {
                    isError = true; errorText = "rate limit"
                }
            default: break
            }
        }
        if let v = violation { throw ProviderError.permissionViolation(v) }
        if isError || r.status != 0 {
            let low = (errorText + r.stderr).lowercased()
            if low.contains("login") || low.contains("auth") { throw ProviderError.loginRequired }
            if low.contains("rate limit") || low.contains("usage limit") || low.contains("quota") { throw ProviderError.quotaExhausted(nil) }
            if low.contains("model") && low.contains("not") { throw ProviderError.modelUnavailable(turn.model ?? "") }
            if !text.isEmpty { throw ProviderError.incomplete(errorText.isEmpty ? "客户端退出" : errorText, partial: text) }
            throw ProviderError.other(errorText.isEmpty ? String(r.stderr.suffix(300)) : errorText)
        }
        let final = structured ?? resultText ?? text
        return ProviderTurnResult(sessionId: sid, text: final.isEmpty ? text : final, contextTokens: tokens, contextWindow: window)
    }
}

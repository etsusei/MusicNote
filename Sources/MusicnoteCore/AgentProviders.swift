import Foundation

/// A client that can run one autonomous analysis with Musicnote's tools.
/// Codex calls them as dynamic tools; Claude Code calls them through the MCP bridge.
public protocol AgentProvider: AnyObject, Sendable {
    var id: String { get }
    func runAgent(systemPrompt: String, task: String, tools: [[String: Any]], model: String?, effort: String?,
                  scratchDir: URL, handler: @escaping @Sendable (String, [String: Any]) async -> (String, Bool),
                  onDelta: @escaping @Sendable (String) -> Void) async throws -> String
}

extension CodexProvider: AgentProvider {
    public func runAgent(systemPrompt: String, task: String, tools: [[String: Any]], model: String?, effort: String?,
                         scratchDir: URL, handler: @escaping @Sendable (String, [String: Any]) async -> (String, Bool),
                         onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        try await runAgent(systemPrompt: systemPrompt, task: task, tools: tools, model: model, effort: effort, handler: handler, onDelta: onDelta)
    }
}

/// Claude Code with only Musicnote's tools: built-in tools off (`--tools ""`), the user's MCP
/// servers, settings, skills and slash commands ignored, and the one MCP server pointed at
/// `workers/mcp_bridge.py`, which forwards each call to the app's toolbox over a private socket.
public final class ClaudeAgentProvider: AgentProvider, @unchecked Sendable {
    public let id = "claude"
    public static let serverName = "musicnote"
    let binary: String
    let sandboxDir: URL
    let python: String
    let bridgeScript: String

    public init(binary: String, sandboxDir: URL, python: String, bridgeScript: String) {
        self.binary = binary; self.sandboxDir = sandboxDir; self.python = python; self.bridgeScript = bridgeScript
    }

    static func toolName(_ name: String) -> String { "mcp__\(serverName)__\(name)" }

    public func runAgent(systemPrompt: String, task: String, tools: [[String: Any]], model: String?, effort: String?,
                         scratchDir: URL, handler: @escaping @Sendable (String, [String: Any]) async -> (String, Bool),
                         onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw ProviderError.clientUnavailable("找不到 claude") }
        guard FileManager.default.fileExists(atPath: bridgeScript) else { throw ProviderError.other("找不到 MCP 桥接脚本：\(bridgeScript)") }
        try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let socket = AgentToolSocket(tools: tools, handler: handler)
        try socket.start()
        defer { socket.stop() }

        // The token only lives in this file (owner-only) and the bridge's environment.
        let config: [String: Any] = ["mcpServers": [Self.serverName: [
            "type": "stdio", "command": python, "args": ["-I", bridgeScript],
            "env": ["MUSICNOTE_MCP_SOCKET": socket.path, "MUSICNOTE_MCP_TOKEN": socket.token],
        ]]]
        let configURL = scratchDir.appendingPathComponent("mcp.json")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL, options: .atomic)
        chmod(configURL.path, 0o600)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let names = tools.compactMap { $0["name"] as? String }.map(Self.toolName)
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "", "--strict-mcp-config", "--mcp-config", configURL.path,
                    "--allowedTools", names.joined(separator: ","),
                    "--disable-slash-commands", "--setting-sources", "",
                    "--no-session-persistence", "--system-prompt", systemPrompt]
        if let m = model, m != "default" { args += ["--model", m] }
        if let e = effort { args += ["--effort", e] }
        let w = WorkerProcess(binary, args)
        w.currentDirectory = sandboxDir
        var env = ProcessInfo.processInfo.environment
        env["MCP_TOOL_TIMEOUT"] = "900000" // transcriptions take tens of seconds
        env["MCP_TIMEOUT"] = "30000"
        w.environment = env
        w.stdinData = Data(task.utf8)

        let allowed = Set(names)
        nonisolated(unsafe) var text = ""
        nonisolated(unsafe) var resultText: String?
        nonisolated(unsafe) var isError = false
        nonisolated(unsafe) var errorText = ""
        nonisolated(unsafe) var violation: String?
        nonisolated(unsafe) var serverDown: String?
        let r = try await w.run { line in
            guard let m = decodeJSONLine(line), let type = m["type"] as? String else { return }
            switch type {
            case "system":
                guard (m["subtype"] as? String) == "init" else { return }
                if let tools = m["tools"] as? [String], let bad = tools.first(where: { !allowed.contains($0) }) { violation = bad }
                if let servers = m["mcp_servers"] as? [[String: Any]],
                   let s = servers.first(where: { ($0["name"] as? String) == Self.serverName }), (s["status"] as? String) != "connected" {
                    serverDown = s["status"] as? String ?? "unknown"
                }
            case "assistant":
                // Second line of defence: every tool the model actually calls must be ours.
                if let msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                    for c in content where (c["type"] as? String) == "tool_use" {
                        if let n = c["name"] as? String, !allowed.contains(n) { violation = n }
                    }
                }
            case "stream_event":
                if let e = m["event"] as? [String: Any], (e["type"] as? String) == "content_block_delta",
                   let d = e["delta"] as? [String: Any], (d["type"] as? String) == "text_delta", let t = d["text"] as? String {
                    text += t; onDelta(t)
                }
            case "result":
                isError = m["is_error"] as? Bool ?? false
                resultText = m["result"] as? String
                if isError { errorText = (m["result"] as? String) ?? (m["subtype"] as? String ?? "") }
            default: break
            }
        }
        if let v = violation { throw ProviderError.permissionViolation(v) }
        if let s = serverDown { throw ProviderError.other("Musicnote 工具没有连上 Claude Code（MCP 状态：\(s)）") }
        if isError || r.status != 0 {
            let low = (errorText + r.stderr).lowercased()
            if low.contains("login") || low.contains("auth") { throw ProviderError.loginRequired }
            if low.contains("rate limit") || low.contains("usage limit") || low.contains("quota") { throw ProviderError.quotaExhausted(nil) }
            throw ProviderError.other(errorText.isEmpty ? String(r.stderr.suffix(300)) : errorText)
        }
        return resultText ?? text
    }
}

import Darwin
import Foundation

/// Serves one analysis run's tools to `workers/mcp_bridge.py` over a Unix socket.
/// Only this run's bridge knows the token; requests are answered one at a time,
/// so the toolbox never runs two tools at once.
public final class AgentToolSocket: @unchecked Sendable {
    public let path: String
    public let token: String
    let tools: [[String: Any]]
    let handler: @Sendable (String, [String: Any]) async -> (String, Bool)
    private var listenFd: Int32 = -1
    private let lock = NSLock()
    private let callLock = NSLock() // one tool at a time, whatever the number of connections
    private var clients: [Int32] = []
    private var stopped = false

    public init(tools: [[String: Any]], handler: @escaping @Sendable (String, [String: Any]) async -> (String, Bool)) {
        // Short path: sun_path holds 104 bytes, and the data root can be long.
        path = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString.prefix(8)).sock").path
        token = UUID().uuidString + UUID().uuidString
        self.tools = tools
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProviderError.other("无法创建工具通道") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw ProviderError.other("工具通道路径过长") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, chmod(path, 0o600) == 0, listen(fd, 2) == 0 else { close(fd); unlink(path); throw ProviderError.other("无法打开工具通道") }
        listenFd = fd
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let fds = clients + [listenFd]
        clients = []
        lock.unlock()
        for fd in fds where fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            lock.lock()
            if stopped { lock.unlock(); close(c); return }
            clients.append(c)
            lock.unlock()
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    private func serve(_ fd: Int32) {
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                let reply = respond(Data(line))
                guard var out = try? JSONSerialization.data(withJSONObject: reply) else { return }
                out.append(0x0A)
                let sent = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
                if sent != out.count { return }
            }
        }
    }

    private func respond(_ line: Data) -> [String: Any] {
        guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let t = msg["token"] as? String, t == token else { return ["text": "ERROR UNAUTHORIZED", "ok": false] }
        switch msg["op"] as? String {
        case "list":
            return ["tools": tools]
        case "call":
            let name = msg["name"] as? String ?? ""
            let args = msg["arguments"] as? [String: Any] ?? [:]
            nonisolated(unsafe) var result: (String, Bool) = ("", false)
            let sem = DispatchSemaphore(value: 0)
            let handler = handler
            callLock.lock(); defer { callLock.unlock() }
            Task.detached { result = await handler(name, args); sem.signal() }
            sem.wait()
            return ["text": result.0, "ok": result.1]
        default:
            return ["text": "ERROR UNKNOWN_OP", "ok": false]
        }
    }
}

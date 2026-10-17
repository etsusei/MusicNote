import Foundation

public struct WorkerError: Error, LocalizedError, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public init(code: String, message: String, retryable: Bool = true) { self.code = code; self.message = message; self.retryable = retryable }
    public var errorDescription: String? { message }
}

/// Runs a helper process speaking line-delimited JSON on stdout. Logs on stderr
/// are collected for diagnostics. Task cancellation terminates the process.
public final class WorkerProcess: @unchecked Sendable {
    public let executable: String
    public let arguments: [String]
    public var stdinData: Data?
    public var environment: [String: String]?
    public var currentDirectory: URL?

    private let process = Process()
    private let lock = NSLock()
    private var stderrBuffer = Data()

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable; self.arguments = arguments
    }

    /// Runs to completion, calling `onLine` for each stdout line (on a background queue).
    @discardableResult
    public func run(onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (status: Int32, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw WorkerError(code: "MODEL_UNAVAILABLE", message: "找不到程序：\(executable)", retryable: false)
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inp

        var pending = Data()
        let lineLock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lineLock.lock(); defer { lineLock.unlock() }
            if chunk.isEmpty { return }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                if !line.isEmpty { onLine(line) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.stderrBuffer.append(chunk)
            if self.stderrBuffer.count > 200_000 { self.stderrBuffer = self.stderrBuffer.suffix(100_000) }
            self.lock.unlock()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(status: Int32, stderr: String), Error>) in
                process.terminationHandler = { [weak self] p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    // Drain anything left after exit.
                    let rest = out.fileHandleForReading.readDataToEndOfFile()
                    lineLock.lock()
                    pending.append(rest)
                    for piece in pending.split(separator: 0x0A) where !piece.isEmpty { onLine(String(decoding: piece, as: UTF8.self)) }
                    pending.removeAll()
                    lineLock.unlock()
                    let tail = err.fileHandleForReading.readDataToEndOfFile()
                    var log = ""
                    if let self {
                        self.lock.lock(); self.stderrBuffer.append(tail)
                        log = String(decoding: self.stderrBuffer.suffix(8000), as: UTF8.self)
                        self.lock.unlock()
                    }
                    cont.resume(returning: (p.terminationStatus, log))
                }
                do {
                    try process.run()
                    if let data = stdinData { inp.fileHandleForWriting.write(data) }
                    try? inp.fileHandleForWriting.close()
                } catch {
                    cont.resume(throwing: WorkerError(code: "MODEL_UNAVAILABLE", message: "无法启动 \(executable)：\(error.localizedDescription)"))
                }
            }
        } onCancel: { [process] in
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    public var isRunning: Bool { process.isRunning }
}

public func decodeJSONLine(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

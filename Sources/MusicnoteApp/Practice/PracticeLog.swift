import Foundation

/// A plain-text record of what the practice page and the audio engine do with the speed: every
/// change asked for, what the engine made of it, and how fast playback really ran afterwards.
/// For finding out why something on the page does not answer. One line per event, written at
/// once; the file starts over when it passes 2 MB.
final class PracticeLog: @unchecked Sendable {
    static let shared = PracticeLog()

    private let queue = DispatchQueue(label: "musicnote.practice-log")
    private var handle: FileHandle?
    private(set) var url: URL?
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Starts writing to `url` (appending; a file over 2 MB is started afresh).
    func open(at url: URL) {
        queue.sync {
            guard self.url != url || handle == nil else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 2_000_000 || !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            self.url = url
        }
    }

    func write(_ line: String) {
        let now = Date()
        queue.async {
            guard let handle = self.handle else { return }
            try? handle.write(contentsOf: Data("\(self.clock.string(from: now))  \(line)\n".utf8))
        }
    }
}

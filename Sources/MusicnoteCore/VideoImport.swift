import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Importing a video: its first audio track is extracted losslessly (ALAC in .m4a, original
/// sample rate and channels) into the library, and that file becomes the source. The file is
/// named after the video's content, so importing the same video again reuses it and clips of
/// one video keep one source fingerprint.
extension Pipeline {
    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "3gp"]

    public static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return true }
        guard let t = UTType(filenameExtension: ext) else { return false }
        return t.conforms(to: .movie) && !t.conforms(to: .audio)
    }

    /// The extracted audio of a video (made now, or the copy from an earlier import).
    public func extractVideoAudio(_ video: URL) async throws -> URL {
        let attrs = try FileManager.default.attributesOfItem(atPath: video.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let key = SHA256.hash(data: Data(Self.fingerprint(url: video, bytes: bytes).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let stem = video.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let out = paths.videoAudio.appendingPathComponent("\(stem)-\(key).m4a")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: paths.videoAudio, withIntermediateDirectories: true)
        let tmp = paths.videoAudio.appendingPathComponent(".\(key)-\(UUID().uuidString.prefix(6)).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try await WorkerProcess(tools.ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", video.path,
                                                      "-map", "0:a:0", "-vn", "-c:a", "alac", tmp.path]).run()
        guard r.status == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            let noAudio = r.stderr.contains("matches no streams") || r.stderr.contains("does not contain any stream")
            throw WorkerError(code: "VIDEO_AUDIO", message: noAudio ? "这个视频没有音轨：\(video.lastPathComponent)"
                                                                     : "提取视频音轨失败：\(r.stderr.suffix(300))", retryable: false)
        }
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}

import Foundation
import MusicnoteCore

/// 新增分析 from audio a song's clips already use, instead of picking the file again.
extension AppModel {
    /// Distinct audio files (by fingerprint) used by the song's clips that can still be found,
    /// most recently used first, with the clips that use each.
    func reusableSources(of song: Song) -> [(source: SourceRef, clips: [String])] {
        var out: [(source: SourceRef, clips: [String])] = []
        for clip in items(of: song.id).sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let i = out.firstIndex(where: { $0.source.fingerprint == clip.source.fingerprint }) {
                out[i].clips.append(clip.title)
            } else if Pipeline.resolve(clip.source) != nil {
                out.append((clip.source, [clip.title]))
            }
        }
        return out
    }

    /// A new clip on an audio file already in use; the selection starts fresh (first 30 s).
    func addAnalysis(to song: Song, reusing source: SourceRef) {
        let item = AnalysisItem(songId: song.id, title: "片段 \(items(of: song.id).count + 1)", source: source, trimStartUs: 0,
                                trimEndUs: Int64(min(source.durationSec, 30) * 1_000_000))
        do { try store.save(item) } catch { report(error); return }
        reload()
        route = .analysis(item.id)
    }
}

import Foundation
import MusicnoteCore

/// 新增分析 from a clip the song already has: same audio file and the same selection, instead
/// of picking the file again.
extension AppModel {
    /// The song's clips whose audio can still be found, most recently edited first; clips with
    /// the same file and selection are listed once.
    func reusableClips(of song: Song) -> [AnalysisItem] {
        var seen = Set<String>()
        return items(of: song.id).sorted { $0.updatedAt > $1.updatedAt }.filter { clip in
            guard Pipeline.resolve(clip.source) != nil else { return false }
            return seen.insert("\(clip.source.fingerprint)|\(clip.trimStartUs)|\(clip.trimEndUs)").inserted
        }
    }

    /// A new clip on the same audio as `clip`, starting with its selection.
    func addAnalysis(to song: Song, like clip: AnalysisItem) {
        let item = AnalysisItem(songId: song.id, title: "片段 \(items(of: song.id).count + 1)", source: clip.source,
                                trimStartUs: clip.trimStartUs, trimEndUs: clip.trimEndUs)
        do { try store.save(item) } catch { report(error); return }
        reload()
        route = .analysis(item.id)
    }
}

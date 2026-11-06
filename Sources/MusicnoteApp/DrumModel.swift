import Foundation
import MusicnoteCore

/// Drum patterns: the 节奏 library, extraction from a clip, and their audio for comparison.
extension AppModel {
    func drumPattern(_ id: UUID) -> DrumPattern? { drumPatterns.first { $0.id == id } }

    /// Patterns extracted from this clip, newest first.
    func drumPatterns(from analysisId: UUID) -> [DrumPattern] { drumPatterns.filter { $0.source?.analysisId == analysisId } }

    func newDrumPattern() {
        var g = DrumGroove.blank(bars: 1)
        // A starting point to edit rather than an empty grid: kick, backbeat, eighth hats.
        DrumOps.toggle(&g, lane: g.lanes[0].id, index: 0); DrumOps.toggle(&g, lane: g.lanes[0].id, index: 8)
        DrumOps.toggle(&g, lane: g.lanes[1].id, index: 4); DrumOps.toggle(&g, lane: g.lanes[1].id, index: 12)
        DrumOps.fill(&g, lane: g.lanes[3].id, every: 2, velocity: 80)
        let p = DrumPattern(title: "新节奏", bpm: 100, groove: g)
        try? store.save(p)
        reload()
        route = .drums(p.id)
    }

    func save(_ pattern: DrumPattern) {
        var p = pattern; p.updatedAt = Date()
        try? store.save(p)
        if let i = drumPatterns.firstIndex(where: { $0.id == p.id }) { drumPatterns[i] = p } else { drumPatterns.insert(p, at: 0) }
    }

    func duplicateDrumPattern(_ p: DrumPattern) {
        // The copy shares the source audio; deleting either leaves the files to the other.
        var c = DrumPattern(title: p.title + " 副本", bpm: p.bpm, groove: p.groove, source: p.source)
        c.tags = p.tags
        try? store.save(c)
        reload()
        route = .drums(c.id)
    }

    func deleteDrumPattern(_ p: DrumPattern) {
        try? store.delete(DrumPattern.self, id: p.id)
        // Its extracted audio goes too, unless a copy still uses it.
        if let dir = p.source?.audio["drums"].map({ paths.url(relative: $0).deletingLastPathComponent() }),
           !drumPatterns.contains(where: { $0.id != p.id && $0.source?.audio["drums"] == p.source?.audio["drums"] }) {
            paths.removeOwned(dir)
        }
        if route == .drums(p.id) { route = nil }
        reload()
    }

    /// Clip → drum pattern, as a job of the clip (progress and cancel on its page).
    func extractDrums(_ itemId: UUID) {
        guard let item = item(itemId) else { return }
        guard Pipeline.drumSplitAvailable else {
            alert = AppAlert(title: "需要 Logic Pro 13", message: "提取鼓节奏用 Logic Pro 13 的鼓细分模型（底鼓、军鼓、踩镲、嗵鼓、镲片、其他）。请先把 Logic Pro 更新到 13。")
            return
        }
        guard let grid = pipeline.drumGrid(item) else {
            alert = AppAlert(title: "还没有速度网格", message: "先确认这个片段的速度与小节线，节奏才能对到格子上。")
            return
        }
        let songTitle = song(item.songId)?.title ?? "未命名"
        let patternId = UUID()
        startJob(.drums, item: item, revision: item.trimRevision, body: { [weak self] job, progress in
            guard let self else { return }
            let (pattern, _) = try await self.pipeline.extractDrums(item, grid: grid, songTitle: songTitle, patternId: patternId,
                                                                   jobDir: self.paths.jobDirectory(job.id), progress: progress)
            try self.store.save(pattern)
            self.reload()
            self.route = .drums(pattern.id)
        }, onError: { [weak self] error in
            if !(error is CancellationError) { self?.report(error) }
        })
    }

    /// The extracted audio of a pattern, from its first step, when it still lines up with
    /// the pattern: same tempo and meter as extracted, files still there.
    func drumSourceAudio(_ p: DrumPattern, _ name: String) -> URL? {
        guard let src = p.source, let rel = src.audio[name], abs(p.bpm - src.bpm) < 0.01,
              src.meter == nil || src.meter == p.groove.meter else { return nil }
        let url = paths.url(relative: rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

import MusicnoteCore
import SwiftUI

/// On a clip's page: extract its drums into a pattern, and the patterns already taken from it.
struct DrumExtractSection: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem

    var body: some View {
        let patterns = model.drumPatterns(from: item.id)
        let running = model.jobs[item.id]?.type == .drums
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "鼓节奏", subtitle: "用 Logic Pro 13 把鼓拆成底鼓、军鼓、踩镲、嗵鼓、镲片、其他，对到这个片段的速度网格上，放进鼓机里改和配和弦。")
            HStack(spacing: 10) {
                Button(patterns.isEmpty ? "提取鼓节奏" : "重新提取") { model.extractDrums(item.id) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(model.jobs[item.id] != nil || !item.hasValidTiming)
                if running { Text("提取中，进度在页面上方").font(.caption12).foregroundStyle(Theme.textSecondary) }
                else if !Pipeline.drumSplitAvailable { Text("需要 Logic Pro 13").font(.caption12).foregroundStyle(Theme.warning) }
                else if !item.hasValidTiming { Text("先确认速度网格").font(.caption12).foregroundStyle(Theme.textSecondary) }
            }
            ForEach(patterns) { p in
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.4x3.fill").foregroundStyle(Theme.accent)
                    Button(p.title) { model.route = .drums(p.id) }.buttonStyle(.borderless)
                    Text("\(p.groove.bars) 小节 · \(String(format: "%g", p.bpm)) BPM").font(.caption12).foregroundStyle(Theme.textSecondary)
                    if let s = p.source, s.trimRevision != item.trimRevision || s.timingRevision != item.timingRevision {
                        Text("选区或速度网格改过，和现在的片段对不上").font(.caption12).foregroundStyle(Theme.warning)
                    }
                }
            }
        }
    }
}

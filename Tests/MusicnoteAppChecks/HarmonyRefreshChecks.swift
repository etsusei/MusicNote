import Foundation
import MusicnoteCore
import Observation

private final class Invalidation: @unchecked Sendable {
    var fired = false
}

@main
struct HarmonyRefreshChecks {
    @MainActor static func main() throws {
        // The runner supplies a disposable library. No UI or provider tasks are run.
        guard let root = ProcessInfo.processInfo.environment["MUSICNOTE_DATA_ROOT"],
              root.hasPrefix(NSTemporaryDirectory()) else {
            fatalError("Run with scripts/check_harmony_refresh.sh using a temporary library")
        }
        let model = AppModel(startServices: false)
        let source = SourceRef(fileName: "test.wav", pathHint: "/test.wav", bookmark: nil,
                               bytes: 1, durationSec: 8, sampleRate: 44100, frames: 352800, fingerprint: "test")
        var item = AnalysisItem(songId: UUID(), title: "Refresh check", source: source,
                                trimStartUs: 0, trimEndUs: 8_000_000)
        item.harmonyRevision = 1
        try model.store.save(item)
        let key = KeySignature(tonic: 0, tonicName: "C", mode: .major)
        func harmony(_ revision: Int, _ symbol: String) -> HarmonyRevision {
            let event = ChordEvent(id: "chord-01", order: 0, startUs: 0, endUs: 2_000_000,
                                   noteIds: [], noteRoles: [:], texture: .block, excludedNoteIds: [],
                                   namingPitches: [], candidates: [], symbol: symbol, namingSource: .agent,
                                   manualOverride: false, degree: nil, bassPitch: nil)
            return HarmonyRevision(analysisId: item.id, revision: revision, midiRevision: 1,
                                   timingRevision: item.timingRevision, key: key, events: [event],
                                   params: ["algorithm": revision == 0 ? "agent" : ChordGrouper.algorithm], namerVersion: "test")
        }
        try model.store.save(harmony(1, "D♭11"))
        var run = AutoRun(analysisId: item.id, trimRevision: item.trimRevision, provider: "codex",
                          model: "test", maxToolCalls: 1, maxSeconds: 1)
        var proposal = harmony(0, "Bmaj9")
        proposal.auto = AutoHarmony(runId: run.id, summary: "", chordInfo: [:], toConfirm: [], key: nil, sources: [])
        run.proposal = proposal
        try model.store.save(run)

        let adopted = Invalidation()
        let before = withObservationTracking {
            model.latestHarmony(item.id)
        } onChange: { adopted.fired = true }
        precondition(before?.events.first?.symbol == "D♭11")
        model.adoptAutoResult(item.id, run: run)
        precondition(model.alert == nil, "Adoption must succeed")
        precondition(adopted.fired, "A current-harmony reader must be invalidated when a result is adopted")
        var current = model.latestHarmony(item.id)!
        precondition(current.revision == 2 && current.events.first?.symbol == "Bmaj9")
        precondition(current.id != before?.id, "The new harmony must have a fresh card identity")
        precondition(current.events.first?.id == before?.events.first?.id,
                     "Cover reused event IDs across different harmony versions")

        let edited = Invalidation()
        withObservationTracking { _ = model.latestHarmony(item.id) } onChange: { edited.fired = true }
        current.events[0].symbol = "Bmaj7"
        model.saveHarmony(current)
        precondition(edited.fired, "Editing within the same revision must also invalidate harmony readers")
        precondition(model.latestHarmony(item.id)?.events.first?.symbol == "Bmaj7")

        let regrouped = Invalidation()
        withObservationTracking { _ = model.latestHarmony(item.id) } onChange: { regrouped.fired = true }
        try model.store.save(harmony(3, "Cmaj7"))
        model.reload()
        precondition(regrouped.fired, "Reloading program grouping must invalidate harmony readers")
        precondition(model.latestHarmony(item.id)?.events.first?.symbol == "Cmaj7")
        precondition(run.result(in: model.store)?.events.first?.symbol == "Bmaj9", "The saved proposal must remain intact")
        print("Harmony refresh checks passed (adoption, reused event IDs, edits, regrouping, saved proposal).")
    }
}

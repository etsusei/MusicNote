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
        // A finished run goes into checking; nothing changes until it is confirmed.
        model.reviewRun(item.id, run: run)
        precondition(model.harmonyDraft(item.id)?.fromModel == true, "A model result opens a draft")
        precondition(model.latestHarmony(item.id)?.events.first?.symbol == "D♭11", "Checking leaves the confirmed harmony alone")
        model.confirmDraft(item.id)
        precondition(model.alert == nil, "Confirming must succeed")
        precondition(model.harmonyDraft(item.id) == nil, "Confirming removes the draft")
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
        // 修改 on the confirmed harmony: edits stay in the draft (voicing rewrites included) until
        // 确定; 放弃 leaves everything as it was.
        var it2 = model.item(item.id)!
        let midi = MidiRevision(analysisId: item.id, revision: 1, status: .confirmed, parentRevision: nil, stem: .piano,
                                transcriber: [:], notes: [MidiNote(pitch: 60, startUs: 0, endUs: 2_000_000)])
        try model.store.save(midi)
        it2.confirmedMidiRevision = 1
        it2.timing = TimingConfirmation(trimRevision: it2.trimRevision, bpm: 120, beatOriginUs: 0, meter: .fourFour, meterConfirmed: true,
                                        barAnchorUs: 0, key: key)
        try model.store.save(it2)
        model.beginEditing(item.id)
        model.editDraft(item.id) { st, _, k in try HarmonyEdit.rename(&st, id: "chord-01", symbol: "Am7", key: k, writeVoicing: true) }
        precondition(model.harmonyDraft(item.id)?.draftNotes != nil, "Voicing rewrite waits in the draft")
        precondition(model.confirmedMidi(model.item(item.id)!)?.revision == 1, "MIDI untouched while checking")
        precondition(model.latestHarmony(item.id)?.events.first?.symbol == "Cmaj7", "Confirmed harmony untouched while checking")
        precondition(model.draftUndoCount(item.id) == 1)
        model.undoDraft(item.id)
        precondition(model.harmonyDraft(item.id)?.harmony.events.first?.symbol == "Cmaj7", "Undo inside the draft")
        model.editDraft(item.id) { st, _, k in try HarmonyEdit.rename(&st, id: "chord-01", symbol: "Am7", key: k, writeVoicing: true) }
        model.discardDraft(item.id)
        precondition(model.harmonyDraft(item.id) == nil && model.latestHarmony(item.id)?.events.first?.symbol == "Cmaj7", "Discard leaves it as it was")
        model.beginEditing(item.id)
        model.editDraft(item.id) { st, _, k in try HarmonyEdit.rename(&st, id: "chord-01", symbol: "Am7", key: k, writeVoicing: true) }
        model.confirmDraft(item.id)
        precondition(model.alert == nil, "Confirming must succeed")
        precondition(model.item(item.id)!.confirmedMidiRevision == 2, "Confirming turns the voicing rewrite into a MIDI revision")
        precondition(model.latestHarmony(item.id)?.events.first?.symbol == "Am7", "Confirming updates the progression")
        // 重选分轨 with the other stems still there: back to choosing stems, the open check dropped,
        // what was confirmed untouched; 不换了 returns to it.
        var it3 = model.item(item.id)!
        it3.separation = SeparationRecord(trimRevision: it3.trimRevision, stems: [], sharedGainDb: 0, encoder: "", logicVersion: nil,
                                          frames: 0, createdAt: Date(), candidatesDeleted: false)
        it3.state = .ready
        try model.store.save(it3)
        model.beginEditing(item.id)
        precondition(model.harmonyDraft(item.id) != nil)
        precondition(!model.reselectNeedsSeparation(model.item(item.id)!))
        model.reselectStems(item.id)
        precondition(model.item(item.id)!.state == .awaitingStem, "重选分轨 goes back to choosing stems")
        precondition(model.harmonyDraft(item.id) == nil, "The open check of the old MIDI is dropped")
        precondition(model.latestHarmony(item.id)?.events.first?.symbol == "Am7" && model.item(item.id)!.confirmedMidiRevision == 2,
                     "Confirmed harmony and MIDI stay until a new transcription")
        model.cancelReselect(item.id)
        precondition(model.item(item.id)!.state == .ready, "不换了 returns to the confirmed result")
        print("Harmony refresh checks passed (adoption, reused event IDs, edits, regrouping, saved proposal, check / edit / undo / discard / confirm, reselect stems).")
    }
}

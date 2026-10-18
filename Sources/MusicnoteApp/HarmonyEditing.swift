import Foundation
import MusicnoteCore

/// One step back in editing a model result: the proposal and draft notes before the edit.
struct ProposalUndo {
    var proposal: HarmonyRevision?
    var draftNotes: [MidiNote]?
    var edited: Bool?
}

extension AppModel {
    /// Notes the proposal is edited against: unsaved voicing rewrites, else the confirmed MIDI.
    func proposalNotes(_ run: AutoRun) -> [MidiNote] {
        run.draftNotes ?? item(run.analysisId).flatMap { confirmedMidi($0)?.notes } ?? []
    }

    /// Edits the model's result as a draft. Nothing the user owns changes until 保存.
    func editProposal(_ runId: UUID, _ f: (inout HarmonyEdit.State, BeatGrid, KeySignature?) throws -> Void) {
        guard var run = store.fetch(AutoRun.self, id: runId), let h = run.result(in: store),
              let item = item(run.analysisId), item.trimRevision == run.trimRevision, var g = item.timing?.grid else { return }
        if g.barAnchorUs == nil { g.barAnchorUs = h.barAnchorUs }
        var st = HarmonyEdit.State(harmony: h, notes: proposalNotes(run))
        do { try f(&st, g, item.timing?.key) } catch {
            alert = AppAlert(title: "改不了", message: error.localizedDescription); return
        }
        var stack = proposalUndo[runId] ?? []
        stack.append(ProposalUndo(proposal: run.proposal, draftNotes: run.draftNotes, edited: run.edited))
        if stack.count > 50 { stack.removeFirst(stack.count - 50) }
        proposalUndo[runId] = stack
        run.proposal = st.harmony
        if st.midiChanged { run.draftNotes = st.notes }
        run.edited = true
        try? store.save(run)
        dataVersion += 1
    }

    func undoProposalEdit(_ runId: UUID) {
        guard var stack = proposalUndo[runId], let last = stack.popLast(), var run = store.fetch(AutoRun.self, id: runId) else { return }
        proposalUndo[runId] = stack
        run.proposal = last.proposal
        run.draftNotes = last.draftNotes
        run.edited = last.edited
        try? store.save(run)
        dataVersion += 1
    }

    func proposalUndoCount(_ runId: UUID) -> Int { proposalUndo[runId]?.count ?? 0 }
}

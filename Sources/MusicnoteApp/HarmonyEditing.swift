import Foundation
import MusicnoteCore

/// One step back while checking: the draft as it was before the edit.
struct DraftUndo {
    var harmony: HarmonyRevision
    var draftNotes: [MidiNote]?
}

/// The clip's harmony is either confirmed or being checked (a draft). Every change goes into
/// the draft; 确定 makes it the confirmed harmony, 放弃 drops it.
extension AppModel {
    func harmonyDraft(_ itemId: UUID) -> HarmonyDraft? {
        let _ = dataVersion
        return store.all(HarmonyDraft.self, owner: itemId).max { $0.updatedAt < $1.updatedAt }
    }

    /// Notes the draft is edited against: its rewritten notes, else the confirmed MIDI.
    func draftNotes(_ d: HarmonyDraft) -> [MidiNote] {
        d.draftNotes ?? item(d.analysisId).flatMap { confirmedMidi($0)?.notes } ?? []
    }

    private func replaceDraft(_ d: HarmonyDraft) {
        for old in store.all(HarmonyDraft.self, owner: d.analysisId) { try? store.delete(HarmonyDraft.self, id: old.id) }
        try? store.save(d)
        draftUndo[d.analysisId] = nil
        dataVersion += 1
    }

    /// A model result to check (replaces any draft; the UI asks first).
    func reviewRun(_ itemId: UUID, run: AutoRun) {
        guard let h = run.result(in: store), let item = item(itemId), item.trimRevision == run.trimRevision else { return }
        replaceDraft(HarmonyDraft(analysisId: itemId, baseRevision: latestHarmony(itemId)?.revision, harmony: h, runId: run.id))
    }

    /// Opens the confirmed harmony for changes.
    func beginEditing(_ itemId: UUID) {
        guard harmonyDraft(itemId) == nil, let h = latestHarmony(itemId) else { return }
        replaceDraft(HarmonyDraft(analysisId: itemId, baseRevision: h.revision, harmony: h, runId: nil))
    }

    func editDraft(_ itemId: UUID, _ f: (inout HarmonyEdit.State, BeatGrid, KeySignature?) throws -> Void) {
        guard var d = harmonyDraft(itemId), let item = item(itemId), var g = item.timing?.grid else { return }
        if g.barAnchorUs == nil { g.barAnchorUs = d.harmony.barAnchorUs }
        var st = HarmonyEdit.State(harmony: d.harmony, notes: draftNotes(d))
        do { try f(&st, g, item.timing?.key) } catch {
            alert = AppAlert(title: "改不了", message: error.localizedDescription); return
        }
        var stack = draftUndo[itemId] ?? []
        stack.append(DraftUndo(harmony: d.harmony, draftNotes: d.draftNotes))
        if stack.count > 50 { stack.removeFirst(stack.count - 50) }
        draftUndo[itemId] = stack
        d.harmony = st.harmony
        if st.midiChanged { d.draftNotes = st.notes }
        d.updatedAt = Date()
        try? store.save(d)
        dataVersion += 1
    }

    func undoDraft(_ itemId: UUID) {
        guard var stack = draftUndo[itemId], let last = stack.popLast(), var d = harmonyDraft(itemId) else { return }
        draftUndo[itemId] = stack
        d.harmony = last.harmony
        d.draftNotes = last.draftNotes
        try? store.save(d)
        dataVersion += 1
    }

    func draftUndoCount(_ itemId: UUID) -> Int { draftUndo[itemId]?.count ?? 0 }

    /// 确定: the draft becomes the confirmed harmony; the skeleton follows (with the client that
    /// ran the analysis when it is connected, else the default).
    func confirmDraft(_ itemId: UUID) {
        guard let d = harmonyDraft(itemId) else { return }
        do {
            try DraftCommit.commit(d, store: store)
            draftUndo[itemId] = nil
            reload()
            let pid = d.runId.flatMap { store.fetch(AutoRun.self, id: $0)?.provider }
            if let pid, providerStatus[pid]?.state == .connected { generateSkeleton(itemId, providerId: pid) } else { autoSkeleton(itemId) }
        } catch {
            alert = AppAlert(title: "无法确定", message: error.localizedDescription)
        }
    }

    func discardDraft(_ itemId: UUID) {
        for d in store.all(HarmonyDraft.self, owner: itemId) { try? store.delete(HarmonyDraft.self, id: d.id) }
        draftUndo[itemId] = nil
        dataVersion += 1
    }

    /// A finished model run whose result was never checked (from before drafts existed).
    func uncheckedRun(_ itemId: UUID) -> AutoRun? {
        guard harmonyDraft(itemId) == nil, let run = latestAutoResultRun(itemId), let item = item(itemId),
              item.trimRevision == run.trimRevision, !AutoAdoption.isAdopted(run, current: latestHarmony(itemId)) else { return nil }
        return run
    }
}

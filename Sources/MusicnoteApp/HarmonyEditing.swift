import Foundation
import MusicnoteCore

/// One step back: the harmony before the edit, and the MIDI revision an edit created (if any).
struct HarmonyUndo {
    var harmony: HarmonyRevision
    var confirmedMidi: Int?
    var createdMidi: UUID?
}

extension AppModel {
    /// Applies a hand edit to the current harmony. Writing a voicing makes a new confirmed MIDI
    /// revision (older ones stay); every edit can be undone.
    func editHarmony(_ itemId: UUID, _ f: (inout HarmonyEdit.State, BeatGrid, KeySignature?) throws -> Void) {
        guard var item = item(itemId), let h = latestHarmony(itemId), var g = item.timing?.grid else { return }
        if g.barAnchorUs == nil { g.barAnchorUs = h.barAnchorUs }
        let midi = confirmedMidi(item)
        var st = HarmonyEdit.State(harmony: h, notes: midi?.notes ?? [])
        do { try f(&st, g, item.timing?.key) } catch {
            alert = AppAlert(title: "改不了", message: error.localizedDescription); return
        }
        var undo = HarmonyUndo(harmony: h, confirmedMidi: item.confirmedMidiRevision, createdMidi: nil)
        if st.midiChanged, let midi {
            let next = (midiRevisions(itemId).map(\.revision).max() ?? 0) + 1
            var m = MidiRevision(analysisId: itemId, revision: next, status: .confirmed, parentRevision: midi.revision, stem: midi.stem,
                                 transcriber: midi.transcriber.merging(["edit": "改和弦名后用标准按法改写"]) { $1 }, notes: st.notes)
            m.confirmedAt = Date()
            try? store.save(m)
            undo.createdMidi = m.id
            item.confirmedMidiRevision = next
            save(item)
            st.harmony.midiRevision = next
        }
        var stack = harmonyUndo[itemId] ?? []
        stack.append(undo)
        if stack.count > 50 { stack.removeFirst(stack.count - 50) }
        harmonyUndo[itemId] = stack
        saveHarmony(st.harmony)
    }

    func canUndoHarmony(_ itemId: UUID) -> Int {
        guard let last = harmonyUndo[itemId]?.last, latestHarmony(itemId)?.id == last.harmony.id else { return 0 }
        return harmonyUndo[itemId]?.count ?? 0
    }

    func undoHarmonyEdit(_ itemId: UUID) {
        guard var stack = harmonyUndo[itemId], let last = stack.popLast(), var item = item(itemId) else { return }
        // Only while the same harmony is current (a regroup or adoption in between ends the history).
        guard latestHarmony(itemId)?.id == last.harmony.id else { harmonyUndo[itemId] = nil; dataVersion += 1; return }
        harmonyUndo[itemId] = stack
        if let id = last.createdMidi {
            try? store.delete(MidiRevision.self, id: id)
            item.confirmedMidiRevision = last.confirmedMidi
            save(item)
        }
        saveHarmony(last.harmony)
    }
}

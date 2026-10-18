import Foundation
import MusicnoteCore

/// 灵感进行: the progression open in the floating window, the 灵感集合 list, playback.
extension AppModel {
    var inspirationList: [InspirationProgression] {
        let _ = dataVersion
        return store.all(InspirationProgression.self).filter(\.inCollection).sorted { $0.updatedAt > $1.updatedAt }
    }

    private static let workingKey = "inspirationWorkingId"

    /// The progression in the floating window (created on first use; survives restarts).
    var workingInspiration: InspirationProgression {
        let _ = dataVersion
        if let s = UserDefaults.standard.string(forKey: Self.workingKey), let id = UUID(uuidString: s),
           let p = store.fetch(InspirationProgression.self, id: id) { return p }
        let p = InspirationProgression()
        try? store.save(p)
        UserDefaults.standard.set(p.id.uuidString, forKey: Self.workingKey)
        return p
    }

    func updateInspiration(_ f: (inout InspirationProgression) -> Void) {
        var p = workingInspiration
        inspirationUndo.append(p)
        if inspirationUndo.count > 50 { inspirationUndo.removeFirst(inspirationUndo.count - 50) }
        f(&p)
        p.updatedAt = Date()
        try? store.save(p)
        dataVersion += 1
    }

    func undoInspiration() {
        guard let last = inspirationUndo.popLast() else { return }
        try? store.save(last)
        dataVersion += 1
    }

    func saveInspirationToCollection() {
        var p = workingInspiration
        p.inCollection = true
        p.updatedAt = Date()
        try? store.save(p)
        dataVersion += 1
    }

    /// A fresh progression in the window; an unsaved, empty draft is simply replaced.
    func newInspiration() {
        let cur = workingInspiration
        if !cur.inCollection { try? store.delete(InspirationProgression.self, id: cur.id) }
        var p = InspirationProgression()
        p.bpm = cur.bpm
        try? store.save(p)
        UserDefaults.standard.set(p.id.uuidString, forKey: Self.workingKey)
        inspirationUndo = []
        dataVersion += 1
    }

    /// Opens a saved progression in the floating window for editing.
    func editInspiration(_ id: UUID) {
        let cur = workingInspiration
        if !cur.inCollection && cur.chords.isEmpty { try? store.delete(InspirationProgression.self, id: cur.id) }
        UserDefaults.standard.set(id.uuidString, forKey: Self.workingKey)
        inspirationUndo = []
        dataVersion += 1
        InspirationWindow.shared.show(self)
    }

    /// Settings of a saved entry (speed, key, title) — no undo, no window.
    func updateCollectionEntry(_ id: UUID, _ f: (inout InspirationProgression) -> Void) {
        guard var p = store.fetch(InspirationProgression.self, id: id) else { return }
        f(&p)
        try? store.save(p)
        dataVersion += 1
    }

    func deleteInspiration(_ id: UUID) {
        if playingInspiration == id { stopInspiration() }
        try? store.delete(InspirationProgression.self, id: id)
        if UserDefaults.standard.string(forKey: Self.workingKey) == id.uuidString { UserDefaults.standard.removeObject(forKey: Self.workingKey) }
        dataVersion += 1
    }

    // MARK: Dragging chords in

    /// Set when a drag of chords starts, so the window can show where they will land.
    func beginChordDrag(_ p: ChordDragPayload) {
        activeChordDrag = p
        activeChordDragAt = Date()
    }

    var currentChordDrag: ChordDragPayload? {
        guard let p = activeChordDrag, let at = activeChordDragAt, Date().timeIntervalSince(at) < 120 else { return nil }
        return p
    }

    // MARK: Playback

    static let inspirationRate = 44100.0

    /// Plays the chords (as heard when they were taken) at the progression's speed; `transpose`
    /// applies its playback key (灵感集合), the window plays them as captured.
    func playInspiration(_ p: InspirationProgression, loop: Bool, transpose: Bool) {
        let rate = Self.inspirationRate
        let secPerQ = 60 / max(20, p.bpm)
        func frame(_ q: Double) -> Int64 { Int64(q * secPerQ * rate) }
        let n = transpose ? InspirationTranspose.semitones(p) : 0
        let smart = transpose && p.targetKey != nil && p.smartTranspose
        var notes: [ScheduledNote] = []
        for c in p.chords {
            let a = frame(c.startQ), b = max(a + 1, frame(c.endQ) - Int64(0.012 * rate))
            for pitch in InspirationTranspose.pitches(c, by: n, smart: smart) where (0...127).contains(pitch) {
                notes.append(ScheduledNote(startFrame: a, endFrame: b, pitch: UInt8(pitch), velocity: 84))
            }
        }
        let total = frame(p.lengthQ)
        let e = AudioEngine.shared
        e.pause()
        e.configure(sampleRate: rate)
        e.setMetronome(MetronomeConfig())
        e.setTracks([])
        e.setMidi(notes, enabled: true)
        e.setLength(total)
        e.setLoop(loop ? 0..<total : nil)
        auditionStop?.cancel()
        playAlongItem = nil
        playingInspiration = p.id
        e.play(from: 0)
    }

    func stopInspiration() {
        AudioEngine.shared.pause()
        AudioEngine.shared.setLoop(nil)
        playingInspiration = nil
    }
}

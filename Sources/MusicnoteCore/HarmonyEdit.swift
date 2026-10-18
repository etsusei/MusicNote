import Foundation

/// Hand edits to a harmony: rename (optionally writing the standard voicing into the MIDI), delete,
/// insert, and move a boundary on the eighth-note grid. Chords stay contiguous: each one ends
/// where the next begins. Pure functions; the app wraps them with saving and undo.
public enum HarmonyEdit {
    public struct State: Sendable {
        public var harmony: HarmonyRevision
        public var notes: [MidiNote]
        public var midiChanged = false
        public init(harmony: HarmonyRevision, notes: [MidiNote]) { self.harmony = harmony; self.notes = notes }
    }

    public enum EditError: Error, LocalizedError {
        case badSymbol(String), notFound, tooShort
        public var errorDescription: String? {
            switch self {
            case .badSymbol(let s): "看不懂这个和弦名：\(s)"
            case .notFound: "找不到这个和弦"
            case .tooShort: "和弦至少要有一个八分音符长"
            }
        }
    }

    /// Nearest eighth note on the grid.
    public static func snapEighth(_ us: Int64, grid g: BeatGrid) -> Int64 {
        g.us(atQ: (g.q(atUs: us) * 2).rounded() / 2)
    }

    static func eighthUs(_ g: BeatGrid) -> Int64 { Int64(g.beatUs / 2) }

    /// Renames a chord. With `writeVoicing`, the notes it covered are replaced by the standard
    /// voicing of the new name, held for the chord's whole length.
    public static func rename(_ s: inout State, id: String, symbol raw: String, key: KeySignature?, writeVoicing: Bool) throws {
        let symbol = raw.trimmingCharacters(in: .whitespaces)
        guard ChordSymbol.parse(symbol) != nil else { throw EditError.badSymbol(raw) }
        guard let i = s.harmony.events.firstIndex(where: { $0.id == id }) else { throw EditError.notFound }
        var ev = s.harmony.events[i]
        ev.symbol = symbol
        ev.manualOverride = true
        ev.namingSource = .user
        ev.degree = key.flatMap { Degrees.label(symbol: symbol, key: $0) }
        if writeVoicing, let pitches = StandardVoicing.pitches(symbol: symbol) {
            let covered = Set(ev.noteIds)
            s.notes.removeAll { covered.contains($0.id) }
            let fresh = pitches.map { MidiNote(pitch: $0, velocity: 90, velocitySource: .edited, startUs: ev.startUs, endUs: ev.endUs, edited: true) }
            s.notes.append(contentsOf: fresh)
            s.notes.sort { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
            ev.noteIds = fresh.map(\.id)
            ev.noteRoles = [:]
            ev.excludedNoteIds = []
            ev.namingPitches = pitches
            ev.bassPitch = pitches.min()
            ev.texture = .block
            s.midiChanged = true
        }
        s.harmony.events[i] = ev
    }

    /// Removes a chord; the one before it takes over its time (or the next one, for the first).
    public static func delete(_ s: inout State, id: String, grid g: BeatGrid) throws {
        guard let i = s.harmony.events.firstIndex(where: { $0.id == id }), s.harmony.events.count > 1 else { throw EditError.notFound }
        let gone = s.harmony.events.remove(at: i)
        if i > 0 { s.harmony.events[i - 1].endUs = gone.endUs; refreshMembers(&s, i - 1, g) }
        else { s.harmony.events[0].startUs = gone.startUs; refreshMembers(&s, 0, g) }
        renumber(&s)
    }

    /// Splits the chord sounding at `atUs` (snapped to an eighth) and names the new part.
    @discardableResult
    public static func insert(_ s: inout State, atUs: Int64, symbol: String, key: KeySignature?, grid g: BeatGrid, writeVoicing: Bool) throws -> String {
        let t = snapEighth(atUs, grid: g)
        let minLen = eighthUs(g) - 2_000
        guard let i = s.harmony.events.firstIndex(where: { $0.startUs <= t && $0.endUs > t }) else { throw EditError.notFound }
        let old = s.harmony.events[i]
        guard t - old.startUs >= minLen, old.endUs - t >= minLen else { throw EditError.tooShort }
        var new = old
        new.id = "edit-" + UUID().uuidString.prefix(8).lowercased()
        new.startUs = t
        s.harmony.events[i].endUs = t
        s.harmony.events.insert(new, at: i + 1)
        refreshMembers(&s, i, g)
        refreshMembers(&s, i + 1, g)
        renumber(&s)
        try rename(&s, id: new.id, symbol: symbol, key: key, writeVoicing: writeVoicing && symbol != old.symbol)
        return new.id
    }

    /// Moves where a chord starts (and where the previous one ends), snapped to an eighth.
    public static func moveStart(_ s: inout State, id: String, toUs: Int64, grid g: BeatGrid) throws {
        guard let i = s.harmony.events.firstIndex(where: { $0.id == id }), i > 0 else { throw EditError.notFound }
        let t = snapEighth(toUs, grid: g)
        let minLen = eighthUs(g) - 2_000
        guard t - s.harmony.events[i - 1].startUs >= minLen, s.harmony.events[i].endUs - t >= minLen else { throw EditError.tooShort }
        s.harmony.events[i - 1].endUs = t
        s.harmony.events[i].startUs = t
        refreshMembers(&s, i - 1, g)
        refreshMembers(&s, i, g)
    }

    /// Notes struck in a chord's span belong to it (legato tails from before don't).
    static func refreshMembers(_ s: inout State, _ i: Int, _ g: BeatGrid) {
        let ev = s.harmony.events[i]
        let m = ChordGrouper.members(s.notes, start: ev.startUs, end: ev.endUs, beatUs: g.beatUs)
        s.harmony.events[i].noteIds = m.map(\.id)
        s.harmony.events[i].namingPitches = Array(Set(m.map(\.pitch))).sorted()
        s.harmony.events[i].bassPitch = m.map(\.pitch).min()
    }

    static func renumber(_ s: inout State) {
        for k in s.harmony.events.indices { s.harmony.events[k].order = k }
    }
}

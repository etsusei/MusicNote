import Foundation
import MusicnoteCore

/// What the keys held on the keyboard spell, for the readout on the practice stage: a chord
/// name when the notes make one, an interval for two notes, the note itself for one.
public struct HeldChord: Equatable, Sendable {
    /// The big line: a chord symbol, two notes, or one note.
    public var name: String
    /// Other names the same notes go by (Am7 for C6, …), best first.
    public var others: [String]
    /// The interval of a two-note shape, or a word that the notes make no chord.
    public var detail: String?
    /// The keys, lowest first, with their octaves (C4 is middle C).
    public var notes: [String]

    public init(name: String, others: [String] = [], detail: String? = nil, notes: [String]) {
        self.name = name; self.others = others; self.detail = detail; self.notes = notes
    }

    static let intervals = ["八度", "小二度", "大二度", "小三度", "大三度", "纯四度", "三全音", "纯五度", "小六度", "大六度", "小七度", "大七度"]

    /// Nil when nothing is held. Spelled with flats or sharps as the key prefers.
    public static func describe<C: Collection>(_ pitches: C, key: KeySignature?) -> HeldChord? where C.Element == Int {
        let sorted = pitches.sorted()
        guard let bass = sorted.first else { return nil }
        let flats = Pitch.prefersFlats(key)
        let notes = sorted.map { Pitch.noteName($0, flats: flats) }
        var classes: [Int] = []
        for p in sorted where !classes.contains(Pitch.pc(p)) { classes.append(Pitch.pc(p)) }
        switch classes.count {
        case 1:
            return HeldChord(name: Pitch.name(pc: bass, flats: flats), detail: sorted.count > 1 ? "八度" : nil, notes: notes)
        case 2:
            let upper = sorted.first { Pitch.pc($0) != Pitch.pc(bass) } ?? bass
            let name = classes.map { Pitch.name(pc: $0, flats: flats) }.joined(separator: " · ")
            return HeldChord(name: name, detail: intervals[Pitch.pc(upper - bass)], notes: notes)
        default:
            let names = ChordNaming.names(pitches: sorted, key: key, limit: 3)
            guard let first = names.first else {
                return HeldChord(name: classes.map { Pitch.name(pc: $0, flats: flats) }.joined(separator: " · "), detail: "认不出和弦名", notes: notes)
            }
            return HeldChord(name: first, others: Array(names.dropFirst()), notes: notes)
        }
    }
}

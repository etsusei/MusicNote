import Foundation

/// When each chord actually sounds in the recording, for playing chords over the original.
/// Chord boundaries sit on the eighth-note grid and can be an eighth off the real strike (a
/// lone bass pickup read as an anticipation, a chord pushed a little early). Playing at the
/// boundary then lands audibly before or after the song, so each chord sounds when its tones
/// are struck together near its start; it rings until the next chord is struck.
public enum PlayAlongTiming {
    public struct Span: Equatable, Sendable {
        public var id: String
        public var startUs: Int64
        public var endUs: Int64
        public init(id: String, startUs: Int64, endUs: Int64) { self.id = id; self.startUs = startUs; self.endUs = endUs }
    }

    /// The strike of a chord: within ±0.9 eighth of its start, the group of notes struck
    /// together (35 ms) with the most of its chord tones, at least two pitches; nearest to the
    /// start on a tie. Nil when nothing like that is there (the start is used).
    public static func attack(_ ev: ChordEvent, notes: [MidiNote], beatUs: Double) -> Int64? {
        guard let spec = ev.symbol.flatMap(ChordSymbol.parse(_:)) else { return nil }
        var pcs = Set(spec.intervals.map { (spec.root + $0) % 12 })
        if let b = spec.bass { pcs.insert(b) }
        let reach = Int64(beatUs / 2 * 0.9)
        let tones = notes.filter {
            abs($0.startUs - ev.startUs) <= reach && $0.startUs < ev.endUs - 30_000
                && $0.endUs - $0.startUs > 30_000 && pcs.contains($0.pitch % 12)
        }.sorted { $0.startUs < $1.startUs }
        var groups: [[MidiNote]] = []
        for n in tones {
            if let first = groups.last?.first, n.startUs - first.startUs <= 35_000 { groups[groups.count - 1].append(n) } else { groups.append([n]) }
        }
        let best = groups.filter { Set($0.map(\.pitch)).count >= 2 }.max { a, b in
            let ca = Set(a.map { $0.pitch % 12 }).count, cb = Set(b.map { $0.pitch % 12 }).count
            if ca != cb { return ca < cb }
            return abs(a[0].startUs - ev.startUs) > abs(b[0].startUs - ev.startUs)
        }
        return best?[0].startUs
    }

    /// Sounding spans in event order. A chord whose next one follows directly rings until that
    /// one is struck; one followed by a gap stops at its own end.
    public static func spans(_ events: [ChordEvent], notes: [MidiNote], beatUs: Double) -> [Span] {
        let evs = events.sorted { $0.startUs < $1.startUs }
        var starts = evs.map { attack($0, notes: notes, beatUs: beatUs) ?? $0.startUs }
        for i in starts.indices.dropFirst() where starts[i] <= starts[i - 1] + 30_000 { starts[i] = evs[i].startUs }
        return evs.indices.map { i in
            let ev = evs[i]
            var end = ev.endUs
            if i + 1 < evs.count, evs[i + 1].startUs <= ev.endUs + 2_000 { end = starts[i + 1] }
            return Span(id: ev.id, startUs: starts[i], endUs: max(starts[i] + 30_000, end))
        }
    }
}

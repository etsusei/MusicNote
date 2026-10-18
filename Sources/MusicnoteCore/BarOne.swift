import Foundation

/// Choosing where bar 1 starts after transcription: the notes struck together near the start are
/// grouped into onsets the user can pick from.
public enum BarOne {
    public struct Onset: Sendable, Hashable {
        public var us: Int64
        public var pitches: [Int]
    }

    /// Onsets up to `untilUs`: notes starting within 60 ms of each other are one onset (at the earliest).
    public static func onsets(_ notes: [MidiNote], untilUs: Int64) -> [Onset] {
        var out: [Onset] = []
        for n in notes.filter({ $0.startUs < untilUs }).sorted(by: { $0.startUs < $1.startUs }) {
            if let last = out.last, n.startUs - last.us <= 60_000 {
                out[out.count - 1].pitches.append(n.pitch)
            } else {
                out.append(Onset(us: n.startUs, pitches: [n.pitch]))
            }
        }
        return out.map { Onset(us: $0.us, pitches: Array(Set($0.pitches)).sorted()) }
    }

    /// The onset nearest a time (the current bar 1), to preselect.
    public static func nearest(_ onsets: [Onset], to us: Int64) -> Onset? {
        onsets.min { abs($0.us - us) < abs($1.us - us) }
    }
}

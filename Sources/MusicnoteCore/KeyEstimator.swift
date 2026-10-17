import Foundation

/// Estimates the tonal centre from the analysed chords, independent of the audio key
/// detector: where phrases start and land, how long chords last, and cadences into the
/// candidate tonic. Used to flag a likely wrong key and to brief the LLM.
public enum KeyEstimator {
    public struct Candidate: Sendable, Hashable {
        public var key: KeySignature
        public var score: Double
        public var reasons: [String]
    }

    struct Chord { var root: Int; var third: Int?; var dominant: Bool; var weight: Double; var symbol: String
        var minor: Bool { third == 3 } }

    public static func candidates(events: [ChordEvent], limit: Int = 3) -> [Candidate] {
        let chords: [Chord] = events.compactMap { e in
            guard let s = e.symbol, let spec = ChordSymbol.parse(s) else { return nil }
            let ints = Set(spec.intervals.map { $0 % 12 })
            let third: Int? = ints.contains(3) && !ints.contains(4) ? 3 : ints.contains(4) ? 4 : nil
            return Chord(root: spec.root, third: third, dominant: ints.contains(4) && ints.contains(10),
                         weight: max(0.25, Double(e.durationUs) / 1_000_000), symbol: s)
        }
        guard !chords.isEmpty else { return [] }
        let total = chords.reduce(0) { $0 + $1.weight }
        var out: [Candidate] = []
        for tonic in 0..<12 {
            for mode in [Mode.major, Mode.minor] {
                let scale = mode == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
                var score = 0.0
                var reasons: [String] = []
                // 1. How much of the time the roots sit in the scale.
                let inScale = chords.filter { scale.contains(Pitch.pc($0.root - tonic)) }.reduce(0) { $0 + $1.weight }
                score += 2 * inScale / total
                // 2. Time spent on the tonic chord.
                let onTonic = chords.filter { $0.root == tonic }.reduce(0) { $0 + $1.weight }
                score += 2.5 * onTonic / total
                if onTonic / total > 0.25 { reasons.append("约 \(Int(onTonic / total * 100))% 的时间停在 \(name(tonic, mode)) 上") }
                // 3. Where it starts and lands.
                if chords.first!.root == tonic { score += 0.6; reasons.append("开头就是 \(name(tonic, mode))") }
                if chords.last!.root == tonic { score += 1.2; reasons.append("最后落在 \(name(tonic, mode))") }
                // 4. Cadences into the tonic.
                var cadences: [String] = []
                for (a, b) in zip(chords, chords.dropFirst()) where b.root == tonic {
                    let d = Pitch.pc(a.root - tonic)
                    if d == 7, a.dominant || a.third == 4 { score += 0.6; cadences.append("\(a.symbol)→\(b.symbol)（V→I）") }
                    else if d == 1 { score += 0.5; cadences.append("\(a.symbol)→\(b.symbol)（从上方半音落回主和弦，♭II→i）") }
                    else if d == 5 { score += 0.3; cadences.append("\(a.symbol)→\(b.symbol)（IV→I）") }
                }
                if let c = cadences.first { reasons.append(c) }
                // 5. Tonic quality must match the mode.
                // Sus chords (no third) say nothing about major vs minor.
                let tonicChords = chords.filter { $0.root == tonic && $0.third != nil }
                if !tonicChords.isEmpty {
                    let minorShare = tonicChords.filter(\.minor).reduce(0) { $0 + $1.weight } / tonicChords.reduce(0) { $0 + $1.weight }
                    score += mode == .minor ? 0.4 * minorShare : 0.4 * (1 - minorShare)
                }
                out.append(Candidate(key: KeySignature(tonic: tonic, tonicName: name(tonic, mode).replacingOccurrences(of: mode == .major ? " 大调" : " 小调", with: ""),
                                                       mode: mode), score: score, reasons: reasons))
            }
        }
        out.sort { $0.score > $1.score }
        // Relative keys share notes; keep both but don't let duplicates crowd the list.
        return Array(out.prefix(limit))
    }

    static func name(_ tonic: Int, _ mode: Mode) -> String {
        let flats = Pitch.prefersFlats(KeySignature(tonic: tonic, tonicName: "", mode: mode))
        return Pitch.name(pc: tonic, flats: flats) + (mode == .major ? " 大调" : " 小调")
    }
}

public extension Degrees {
    /// Numbered-notation degrees (简谱级数) as used for "4536"-style names: 1 = the major tonic;
    /// a minor key is counted from its relative major (A minor's Am is 6).
    static func numberPattern(_ symbols: [String], key: KeySignature) -> String {
        let doh = key.mode == .major ? key.tonic : Pitch.pc(key.tonic + 3)
        let ref = KeySignature(tonic: doh, tonicName: "", mode: .major)
        return symbols.compactMap { tagStep(symbol: $0, key: ref) }.joined(separator: "-")
    }
}

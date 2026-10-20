import Foundation

/// Names an exact set of pitches (a voicing someone built on the keyboard), best first. Unlike
/// the grouping templates, which fit a blurry profile of a whole stretch, every pitch class
/// here is meant: a name must account for all of them.
///
/// A quality fits when its tones are exactly the pitch classes, or exactly them with the fifth
/// left out (and the ninth too, for 11ths and 13ths, as hands usually do). The lowest note is
/// the bass: a root in the bass is preferred, another chord tone makes a slash chord, and a
/// bass outside a plain triad or seventh makes it a slash chord over that note (C/D).
public enum ChordNaming {
    public static func names(pitches: [Int], key: KeySignature?, limit: Int = 4) -> [String] {
        let pcs = Set(pitches.map(Pitch.pc))
        guard pcs.count >= 2, let bass = pitches.min().map(Pitch.pc) else { return [] }
        var scored: [(name: String, score: Double)] = []
        for (order, q) in ChordCatalog.qualities.enumerated() where q.intervals.count >= 3 {
            for root in 0..<12 {
                let tones = q.intervals.map { Pitch.pc(root + $0) }
                let full = Set(tones)
                let complexity = 3.0 * Double(max(0, full.count - 3)) + Double(order) * 0.01
                for (variant, penalty) in variants(q, root: root) {
                    if variant == pcs {
                        var s = 100 - penalty - complexity
                        if root == bass { s += 8 }
                        scored.append((ChordSymbol.make(root: root, suffix: q.suffix, bass: bass, key: key), s))
                    } else if !variant.contains(bass), variant == pcs.subtracting([bass]), full.count <= 4 {
                        // A triad or seventh over a foreign bass reads as a slash chord.
                        scored.append((ChordSymbol.make(root: root, suffix: q.suffix, bass: bass, key: key), 99 - penalty - complexity - (full.count == 4 ? 4 : 0)))
                    }
                }
            }
        }
        var seen = Set<String>()
        return scored.sorted { $0.score > $1.score }.map(\.name).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    /// The quality's pitch classes as played: complete, without the fifth, and for 11ths and
    /// 13ths without the ninth as well; each with a small penalty for what is left out.
    static func variants(_ q: ChordQuality, root: Int) -> [(Set<Int>, Double)] {
        let all = Set(q.intervals.map { Pitch.pc(root + $0) })
        var out: [(Set<Int>, Double)] = [(all, 0)]
        let fifth = Pitch.pc(root + 7)
        if q.intervals.contains(7), q.intervals.count >= 4 { out.append((all.subtracting([fifth]), 10)) }
        if q.intervals.count >= 6, q.intervals.contains(14) {
            let ninth = Pitch.pc(root + 2)
            out.append((all.subtracting([ninth]), 12))
            if q.intervals.contains(7) { out.append((all.subtracting([ninth, fifth]), 18)) }
        }
        return out.filter { $0.0.count >= 2 }
    }
}

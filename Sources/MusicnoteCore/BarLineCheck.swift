import Foundation

/// Checks the bar lines against the harmony itself. Chords mostly change on beat 1, and so does
/// the bass, so if the evidence keeps landing on beat 3 (or between beats) the bar line or the
/// beat phase is off; the chord times are right, only the grid they are read in is wrong.
/// Uses Logic's chord boundaries and the notes (bass changes, chord strikes), not the grouped
/// harmony, which was built on the current bar lines and would agree with them by construction.
public enum BarLineCheck {
    public struct Result: Sendable {
        /// Share of evidence on each candidate downbeat, in half beats from the current one.
        public var shares: [(shiftBeats: Double, share: Double)]
        public var currentShare: Double
        public var best: (shiftBeats: Double, share: Double)
        public var evidence: Double
        /// Suggested shift in beats when the evidence clearly prefers another downbeat.
        public var suggestion: Double?
        /// Repetition of the chord pattern: lag in beats and how well it matches.
        public var repeatBeats: Int?
        public var repeatMatch: Double?
    }

    public struct Note: Sendable { public var pitch: Int; public var startUs: Int64; public init(pitch: Int, startUs: Int64) { self.pitch = pitch; self.startUs = startUs } }

    public static func check(grid g: BeatGrid, durationUs: Int64, logic: [LogicChordEvent], notes: [Note]) -> Result {
        let perBar = g.meter.quarterBeatsPerBar
        var events: [(q: Double, w: Double)] = []
        func pos(_ us: Int64) -> Double {
            let q = (g.q(atUs: us) - g.barAnchorQ).truncatingRemainder(dividingBy: perBar)
            return q < 0 ? q + perBar : q
        }
        // Logic boundaries (not the first event, which starts at the clip start by definition).
        for (a, b) in zip(logic, logic.dropFirst()) where a.symbol != b.symbol || a.label != b.label {
            events.append((pos(b.startUs), 1.0))
        }
        // Onset clusters: bass changes weigh more than plain strikes.
        let sorted = notes.sorted { $0.startUs < $1.startUs }
        var clusters: [[Note]] = []
        for n in sorted {
            if let last = clusters.last?.first, n.startUs - last.startUs <= 60_000 { clusters[clusters.count - 1].append(n) } else { clusters.append([n]) }
        }
        var prevBass: Int?
        for c in clusters {
            guard let low = c.min(by: { $0.pitch < $1.pitch }) else { continue }
            let changed = prevBass.map { $0 % 12 != low.pitch % 12 } ?? false
            // Bass lines in dance and pop move on many beats, so they count for less than a chord change.
            if changed { events.append((pos(low.startUs), 0.4)) } else if c.count >= 3 { events.append((pos(low.startUs), 0.1)) }
            prevBass = low.pitch
        }
        let total = events.reduce(0) { $0 + $1.w }
        func at(_ k: Double) -> Double {
            events.filter { e in let d = abs(e.q - k); return min(d, perBar - d) <= 0.2 }.reduce(0) { $0 + $1.w }
        }
        // Raw share at every half beat (for the report).
        var shares: [(Double, Double)] = []
        var k = 0.0
        while k < perBar - 0.01 { shares.append((k, total > 0 ? at(k) / total : 0)); k += 0.5 }
        // Downbeat score: changes on the beat, plus half credit for changes pushed half a beat early
        // (anticipations, common in dance music) — whole-beat candidates only.
        func score(_ k: Double) -> Double { total > 0 ? (at(k) + 0.5 * at((k - 0.5 + perBar).truncatingRemainder(dividingBy: perBar))) / total : 0 }
        let whole = (0..<Int(perBar.rounded())).map { (Double($0), score(Double($0))) }
        let current = whole.first?.1 ?? 0
        var best = whole.max { $0.1 < $1.1 } ?? (0, 0)
        var suggestion: Double?
        if best.0 != 0, total >= 4, best.1 >= 0.22, best.1 >= current * 1.6 {
            // Shifting by more than half a bar is the same as shifting the other way.
            suggestion = best.0 > perBar / 2 ? best.0 - perBar : best.0
        }
        // Changes mostly between beats: the beat phase itself is half a beat off.
        let onBeats = (0..<Int(perBar.rounded())).reduce(0.0) { $0 + at(Double($1)) }
        let offBeats = (0..<Int(perBar.rounded())).reduce(0.0) { $0 + at(Double($1) + 0.5) }
        if total >= 4, offBeats > onBeats * 1.5, let h = shares.filter({ $0.0 != $0.0.rounded() }).max(by: { $0.1 < $1.1 }) {
            best = h
            suggestion = h.0 > perBar / 2 ? h.0 - perBar : h.0
        }
        let rep = repetition(logic: logic, grid: g, durationUs: durationUs)
        return Result(shares: shares, currentShare: current, best: best, evidence: total, suggestion: suggestion,
                      repeatBeats: rep?.lag, repeatMatch: rep?.match)
    }

    /// Lag (in beats) at which the chord sequence repeats best, sampled per beat from Logic.
    static func repetition(logic: [LogicChordEvent], grid g: BeatGrid, durationUs: Int64) -> (lag: Int, match: Double)? {
        guard logic.count >= 4 else { return nil }
        var seq: [String] = []
        var q = g.q(atUs: 0).rounded(.up)
        while true {
            let t = g.us(atQ: q)
            if t >= durationUs { break }
            seq.append(logic.last { $0.startUs <= t + 30_000 }?.symbol ?? logic.last { $0.startUs <= t + 30_000 }?.label ?? "")
            q += 1
        }
        guard seq.count >= 16 else { return nil }
        var best: (Int, Double)?
        for lag in 8...(seq.count / 2) {
            let pairs = seq.count - lag
            guard pairs >= 8 else { break }
            let same = (0..<pairs).filter { seq[$0] == seq[$0 + lag] && !seq[$0].isEmpty }.count
            let m = Double(same) / Double(pairs)
            if m > (best?.1 ?? 0) + 0.02 { best = (lag, m) }
        }
        // A whole number of bars is the musical answer when it matches nearly as well (anticipations
        // in one pass blur the beat-level comparison).
        let perBar = Int(g.meter.quarterBeatsPerBar.rounded())
        if let b = best, b.0 % perBar != 0 {
            for lag in [b.0 - b.0 % perBar, b.0 - b.0 % perBar + perBar] where lag >= 8 && lag <= seq.count / 2 {
                let pairs = seq.count - lag
                let m = Double((0..<pairs).filter { seq[$0] == seq[$0 + lag] && !seq[$0].isEmpty }.count) / Double(pairs)
                if m >= b.1 - 0.12 { best = (lag, m); break }
            }
        }
        return best.flatMap { $0.1 >= 0.55 ? $0 : nil }
    }

    /// Plain-language report for the model and the notes page.
    public static func describe(_ r: Result, grid g: BeatGrid) -> String {
        func label(_ k: Double) -> String { k == k.rounded() ? "第 \(Int(k) + 1) 拍" : "第 \(Int(k) + 1) 拍后半" }
        var lines = [String(format: "换和弦点和低音换音落在小节里的位置（共 %.1f 份证据）：", r.evidence)
            + r.shares.filter { $0.share >= 0.05 }.map { String(format: "%@ %.0f%%", label($0.shiftBeats), $0.share * 100) }.joined(separator: "，")]
        lines.append(String(format: "现在的第 1 拍上有 %.0f%%。", r.currentShare * 100))
        if let s = r.suggestion {
            lines.append(String(format: "证据更集中在%@（%.0f%%）：小节线可能要整体%@ %@ 拍。", label(r.best.shiftBeats), r.best.share * 100,
                                s > 0 ? "后移" : "前移", BarEvidence.beatText(abs(s))))
            if s != s.rounded() { lines.append("挪动的是半拍：说明拍点本身偏了半拍（换和弦都在反拍上），不只是小节线。") }
        } else {
            lines.append("现在的小节线和证据一致，或者证据不够集中，不建议改。")
        }
        if let lag = r.repeatBeats, let m = r.repeatMatch {
            let perBar = Int(g.meter.quarterBeatsPerBar.rounded())
            let bars = lag % perBar == 0 ? "（= \(lag / perBar) 小节）" : "（不是整小节：多半是某一遍里和弦提前半拍、一拍进入，也可能是速度有偏差）"
            lines.append(String(format: "和弦走向每 %d 拍%@重复一次，吻合 %.0f%%：前后两遍可以互相对照，一遍里看清楚的地方可以用来核对另一遍。", lag, bars, m * 100))
        }
        return lines.joined(separator: "\n")
    }
}

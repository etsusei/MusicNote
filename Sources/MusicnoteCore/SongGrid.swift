import Foundation

/// Beats and bar lines of the whole song (unseparated original), detected once so the
/// selection can snap to bar lines. Then bar 1 of the clip starts exactly at the clip start and
/// later analysis doesn't drift by a beat or half a bar. Times are seconds in the source file.
public struct SongGrid: Codable, Hashable, Sendable {
    /// Beats as detected (often double-time for slow songs).
    public var ticks: [Double]
    public var detectedBpm: Double
    /// Read every other detected beat as one beat (a 66 BPM song detected at 132).
    public var halfTime: Bool
    public var beatsPerBar: Int
    /// Index into `ticks` of a downbeat (any one; bars repeat from it).
    public var phase: Int
    /// Detector's best downbeat phase for the half-time reading, used when switching.
    public var halfTimePhase: Int?
    /// How clearly the detector preferred its phase (small = check by ear).
    public var margin: Double
    public var fingerprint: String
    public var detectedAt: Date

    public init(ticks: [Double], detectedBpm: Double, halfTime: Bool, beatsPerBar: Int, phase: Int, halfTimePhase: Int?,
                margin: Double, fingerprint: String) {
        self.ticks = ticks; self.detectedBpm = detectedBpm; self.halfTime = halfTime; self.beatsPerBar = beatsPerBar
        self.phase = phase; self.halfTimePhase = halfTimePhase; self.margin = margin; self.fingerprint = fingerprint
        detectedAt = Date()
    }

    var step: Int { halfTime ? 2 : 1 }
    public var bpm: Double { detectedBpm / Double(step) }
    var ticksPerBar: Int { beatsPerBar * step }

    /// Median spacing of detected beats, for extrapolating past the first/last tick.
    var tickPeriod: Double {
        guard ticks.count > 2 else { return 60 / max(detectedBpm, 1) }
        let d = zip(ticks.dropFirst(), ticks).map { $0 - $1 }.sorted()
        return d[d.count / 2]
    }

    /// Time of tick index `i`, extrapolated beyond the detected range.
    func tick(_ i: Int) -> Double {
        if ticks.isEmpty { return Double(i) * tickPeriod }
        if i < 0 { return ticks[0] + Double(i) * tickPeriod }
        if i >= ticks.count { return ticks[ticks.count - 1] + Double(i - ticks.count + 1) * tickPeriod }
        return ticks[i]
    }

    /// Tick index at or just before `t` (binary search inside the detected range, linear outside).
    func index(near t: Double) -> Int {
        guard let first = ticks.first, let last = ticks.last else { return Int(floor(t / tickPeriod)) }
        if t < first { return -Int(ceil((first - t) / tickPeriod)) }
        if t >= last { return ticks.count - 1 + Int(floor((t - last) / tickPeriod)) }
        var lo = 0, hi = ticks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ticks[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Beat times (one per beat at the chosen reading) within [from, to].
    public func beats(from: Double, to: Double) -> [Double] { lines(every: step, offset: phase, from: from, to: to) }

    /// Bar-line times within [from, to].
    public func downbeats(from: Double, to: Double) -> [Double] { lines(every: ticksPerBar, offset: phase, from: from, to: to) }

    private func lines(every n: Int, offset: Int, from: Double, to: Double) -> [Double] {
        guard n > 0, to > from else { return [] }
        let lo = index(near: from) - n - 1
        let hi = index(near: to) + n + 1
        let start = offset + Int(floor(Double(lo - offset) / Double(n))) * n
        var out: [Double] = []
        var i = start
        while i <= hi {
            let t = tick(i)
            if t >= from && t <= to { out.append(t) }
            i += n
        }
        return out
    }

    /// Nearest line to `t` (bars or beats).
    public func snap(_ t: Double, toBars: Bool) -> Double {
        let span = 2 * Double(ticksPerBar) * tickPeriod
        let cands = toBars ? downbeats(from: t - span, to: t + span) : beats(from: t - span, to: t + span)
        return cands.min { abs($0 - t) < abs($1 - t) } ?? t
    }

    /// Moves bar lines by whole beats (the detector often lands a beat or half a bar off).
    public mutating func shift(beats: Int) {
        let n = ticksPerBar
        phase = ((phase + beats * step) % n + n) % n
    }

    public mutating func setHalfTime(_ on: Bool) {
        guard on != halfTime else { return }
        halfTime = on
        if on, let h = halfTimePhase { phase = h }
        phase = ((phase % ticksPerBar) + ticksPerBar) % ticksPerBar
    }

    public mutating func setBeatsPerBar(_ n: Int) {
        beatsPerBar = max(2, min(7, n))
        phase = ((phase % ticksPerBar) + ticksPerBar) % ticksPerBar
    }

    /// Lines the grid up with a tempo and bar line the user already confirmed on another clip of
    /// the same song: half-time if they counted half as fast, and the downbeat on their bar line.
    public mutating func calibrate(confirmedBpm: Double, beatsPerBar n: Int, barLineAt t: Double?) {
        setHalfTime(abs(confirmedBpm * 2 - detectedBpm) < abs(confirmedBpm - detectedBpm))
        setBeatsPerBar(n)
        guard let t else { return }
        // Every detected-beat offset: in half-time the right downbeat can be on either parity.
        var best = phase, bestDist = Double.infinity
        for k in 0..<ticksPerBar {
            var g = self; g.phase = k
            let d = abs(g.snap(t, toBars: true) - t)
            if d < bestDist { bestDist = d; best = k }
        }
        phase = best
    }

    /// Whether the detected beats inside [from, to] keep the song's tempo. Beat trackers lock onto
    /// syncopations in intros and breaks (dotted eighths at 3/4 of the beat, say); there the bar
    /// lines are guesses and shouldn't be carried into the clip.
    public func steady(from: Double, to: Double) -> Bool {
        let inside = ticks.filter { $0 >= from && $0 <= to }
        guard inside.count >= 6 else { return false }
        let d = zip(inside.dropFirst(), inside).map { $0 - $1 }.sorted()
        let median = d[d.count / 2]
        return abs(median / (60 / detectedBpm) - 1) < 0.08
    }

    /// Bar line at or just after a clip start (within 60 ms before counts as on it), relative to it.
    public func barAnchor(clipStart: Double, clipEnd: Double) -> Double? {
        downbeats(from: clipStart - 0.06, to: clipEnd).first.map { max(0, $0 - clipStart) }
    }

    /// Beat phase relative to a clip start: the first beat at or after it.
    public func beatOrigin(clipStart: Double, clipEnd: Double) -> Double? {
        beats(from: clipStart - 0.06, to: clipEnd).first.map { max(0, $0 - clipStart) }
    }
}

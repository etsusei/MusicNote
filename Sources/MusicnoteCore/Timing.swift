import Foundation

public enum Tempo {
    /// Rounds to the nearest 0.5 BPM with halves rounding up (not banker's rounding):
    /// 93.24 → 93.0, 93.25 → 93.5.
    public static func roundToHalf(_ raw: Double) -> Double? {
        guard raw.isFinite, raw > 0 else { return nil }
        return floor(raw * 2 + 0.5) / 2
    }

    /// Accepts typed input; returns the value that would be confirmed, or nil if invalid.
    public static func parseUserBpm(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return roundToHalf(v)
    }

    /// Standard MIDI tempo: integer microseconds per quarter note.
    public static func microsecondsPerQuarter(_ bpm: Double) -> Int { Int((60_000_000 / bpm).rounded()) }
}

/// Tempo and beat phase from tapping along to the playing clip. Each tap carries the wall
/// clock (for the tempo, which survives the loop wrapping) and the clip position it landed on
/// (for the phase). A pause longer than `resetGapSec` starts a new run.
public struct TapTempo: Sendable {
    public struct Tap: Sendable, Hashable {
        public var wallSec: Double
        public var clipUs: Int64
    }

    public static let resetGapSec = 2.0
    public static let minimumTaps = 4

    public private(set) var taps: [Tap] = []

    public init() {}

    public mutating func add(wallSec: Double, clipUs: Int64) {
        if let last = taps.last, wallSec - last.wallSec > Self.resetGapSec || wallSec <= last.wallSec { taps = [] }
        taps.append(Tap(wallSec: wallSec, clipUs: clipUs))
    }

    /// Least-squares beat period over all taps of the run, so one early or late tap moves the
    /// result far less than it would in an average of intervals.
    public var rawBpm: Double? {
        let n = taps.count
        guard n >= Self.minimumTaps else { return nil }
        let meanI = Double(n - 1) / 2
        let meanT = taps.reduce(0) { $0 + $1.wallSec } / Double(n)
        var num = 0.0, den = 0.0
        for (i, t) in taps.enumerated() {
            num += (Double(i) - meanI) * (t.wallSec - meanT)
            den += (Double(i) - meanI) * (Double(i) - meanI)
        }
        guard den > 0, num > 0 else { return nil }
        let bpm = 60 / (num / den)
        return (20...400).contains(bpm) ? bpm : nil
    }

    public var bpm: Double? { rawBpm.flatMap(Tempo.roundToHalf) }

    /// Where the beat sits in the clip: the circular mean of the tapped positions modulo the
    /// beat. Only the taps since the loop last wrapped count (the loop need not be a whole
    /// number of beats); nil when playback was stopped or fewer than three of them remain.
    public func beatOriginUs(bpm: Double) -> Int64? {
        guard bpm > 0, taps.count >= Self.minimumTaps else { return nil }
        var run: [Int64] = []
        for t in taps.reversed() {
            if let earliest = run.last, t.clipUs >= earliest { break }
            run.append(t.clipUs)
        }
        guard run.count >= 3 else { return nil }
        let beat = 60_000_000 / bpm
        var sx = 0.0, sy = 0.0
        for p in run {
            let a = 2 * Double.pi * Double(p).truncatingRemainder(dividingBy: beat) / beat
            sx += cos(a); sy += sin(a)
        }
        var phase = atan2(sy, sx) / (2 * .pi) * beat
        if phase < 0 { phase += beat }
        return Int64(phase.rounded())
    }
}

/// Clip-local beat grid derived from the confirmed BPM and beat origin.
/// BPM is always quarter-note based.
public struct BeatGrid: Hashable, Sendable {
    public var bpm: Double
    public var beatOriginUs: Int64
    public var meter: Meter
    public var barAnchorUs: Int64?

    public init(bpm: Double, beatOriginUs: Int64, meter: Meter = .fourFour, barAnchorUs: Int64? = nil) {
        self.bpm = bpm; self.beatOriginUs = beatOriginUs; self.meter = meter; self.barAnchorUs = barAnchorUs
    }

    public var beatUs: Double { 60_000_000 / bpm }

    /// Q = (t − beatOrigin) × BPM / 60, may be negative for pickups.
    public func q(atUs t: Int64) -> Double { Double(t - beatOriginUs) / beatUs }
    public func us(atQ q: Double) -> Int64 { beatOriginUs + Int64((q * beatUs).rounded()) }

    /// Beat times (µs) inside [0, durationUs].
    public func beatTimes(durationUs: Int64) -> [Int64] {
        guard bpm > 0 else { return [] }
        var k = Int(floor(Double(-beatOriginUs) / beatUs))
        var out: [Int64] = []
        while true {
            let t = beatOriginUs + Int64((Double(k) * beatUs).rounded())
            if t > durationUs { break }
            if t >= 0 { out.append(t) }
            k += 1
        }
        return out
    }

    /// Q position of bar 1 beat 1; defaults to the beat origin until the user sets an anchor.
    public var barAnchorQ: Double { barAnchorUs.map { q(atUs: $0) } ?? 0 }

    /// Whether the beat at Q is a downbeat. Only meaningful once a bar anchor is set.
    public func isDownbeat(q: Double) -> Bool {
        guard barAnchorUs != nil else { return false }
        let perBar = meter.quarterBeatsPerBar
        let r = (q - barAnchorQ).truncatingRemainder(dividingBy: perBar)
        let m = r < 0 ? r + perBar : r
        return m < 1e-6 || perBar - m < 1e-6
    }

    /// Closest grid position for a time, in beats subdivided by `division` (1 = quarter, 2 = eighth…).
    public func snap(us t: Int64, division: Int) -> Int64 {
        let step = 1.0 / Double(max(division, 1))
        return us(atQ: (q(atUs: t) / step).rounded() * step)
    }

    /// Short label like "约二分音符" when a span is close to a common note value.
    public static func durationLabel(quarterBeats q: Double) -> String? {
        let values: [(Double, String)] = [(4, "全音符"), (3, "附点二分音符"), (2, "二分音符"), (1.5, "附点四分音符"),
                                          (1, "四分音符"), (0.75, "附点八分音符"), (0.5, "八分音符"), (0.25, "十六分音符"),
                                          (8, "两个全音符"), (6, "一个半全音符")]
        for (v, name) in values where abs(q - v) <= v * 0.08 { return "约" + name }
        return nil
    }
}

public enum MidiTicks {
    public static let ppq = 960
    public static func ticks(q: Double) -> Int { Int((q * Double(ppq)).rounded()) }
}

public extension Int64 {
    var seconds: Double { Double(self) / 1_000_000 }
}

public func formatTime(us: Int64, millis: Bool = true) -> String {
    let neg = us < 0
    let total = abs(Double(us)) / 1_000_000
    let m = Int(total / 60)
    let s = total - Double(m * 60)
    let body = millis ? String(format: "%d:%06.3f", m, s) : String(format: "%d:%02d", m, Int(s))
    return (neg ? "-" : "") + body
}

extension BeatGrid {
    /// Bar lines sit on beats. An anchor off the beat grid (say the beat offset was nudged after
    /// bar 1 was set to the clip start) snaps to the nearest beat; one at the clip start takes the
    /// first beat at or just before it, so bar 1 stays at the start rather than moving into a pickup.
    public func beatAlignedAnchor(_ a: Int64) -> Int64 {
        let q = self.q(atUs: a)
        if abs(q - q.rounded()) < 1e-3 { return a }
        if a == 0 {
            let first = us(atQ: q.rounded(.up))
            return first - Int64(beatUs) >= -40_000 ? first - Int64(beatUs) : first
        }
        return us(atQ: q.rounded())
    }

    public var anchoredOnBeat: BeatGrid {
        var g = self
        if let a = barAnchorUs { g.barAnchorUs = beatAlignedAnchor(a) }
        return g
    }
}

extension TimingConfirmation {
    public var anchoredOnBeat: TimingConfirmation {
        var t = self
        if let a = t.barAnchorUs { t.barAnchorUs = t.grid.beatAlignedAnchor(a) }
        return t
    }
}

import Foundation
import MusicnoteCore

/// What is played under the practising hands.
public enum PracticeBacking: String, Codable, CaseIterable, Sendable {
    /// The clip as it is.
    case original
    /// Only the selected stem (the part being learnt).
    case stem
    /// Everything but the selected stem.
    case backing
    case off
}

/// How a clip was last practised: speed, backing, loop. One per clip (its id is the clip's).
public struct PracticeSettings: Record {
    public static let kind = "practice.settings"
    public var id: UUID
    /// 1 is the original tempo.
    public var rate: Double = 1
    public var backing: PracticeBacking = .original
    public var backingGain: Float = 0.8
    /// The MIDI played aloud on the built-in instrument.
    public var midiOn = false
    public var midiGain: Float = 0.7
    public var loopOn = false
    /// The loop, A to B, clip-local and on bar lines.
    public var loopStartUs: Int64?
    public var loopEndUs: Int64?
    /// Each round starts one bar before A.
    public var preroll = true
    /// Wait mode: the music stops at each note until it is played. Optional so that settings
    /// saved before it existed still read.
    public var wait: Bool?
    public var waitOn: Bool { wait ?? false }
    /// The metronome on the confirmed beat grid, and how loud. Optional for the same reason.
    public var metronome: Bool?
    public var metronomeGain: Float?
    public var metronomeOn: Bool { metronome ?? false }
    public var metronomeVolume: Float { metronomeGain ?? 0.6 }

    public init(analysisId: UUID) { id = analysisId }

    public var ownerId: UUID? { id }
    public var sortKey: Double { 0 }

    public static let rateRange = 0.5...1.0
    public static let rateStep = 0.05

    /// A speed on the 5% steps the keys move by, inside the range.
    public static func steppedRate(_ rate: Double, by steps: Int) -> Double {
        let r = (((rate / rateStep).rounded() + Double(steps)) * rateStep * 100).rounded() / 100
        return min(max(r, rateRange.lowerBound), rateRange.upperBound)
    }
}

/// The clip's bar lines, for the loop to snap to and the stage to draw.
public struct PracticeBars: Sendable {
    public struct Line: Hashable, Sendable {
        public var us: Int64
        /// 1 for the bar that starts at bar 1's anchor; 0 and below for a pickup before it.
        public var number: Int

        public init(us: Int64, number: Int) { self.us = us; self.number = number }
    }

    public let durationUs: Int64
    public let barUs: Double
    /// A quarter-note beat.
    public let beatUs: Double
    /// Start of bar 1 (the beat origin when no bar 1 is set).
    public let anchorUs: Int64
    public let lines: [Line]

    public init(timing: TimingConfirmation, durationUs: Int64) {
        let grid = timing.anchoredOnBeat.grid
        self.durationUs = durationUs
        beatUs = max(1, grid.beatUs)
        barUs = max(1, grid.beatUs * grid.meter.quarterBeatsPerBar)
        anchorUs = grid.barAnchorUs ?? grid.beatOriginUs
        var out: [Line] = []
        var k = Int(floor(Double(-anchorUs) / barUs))
        while true {
            let t = anchorUs + Int64((Double(k) * barUs).rounded())
            if t > durationUs { break }
            if t >= 0 { out.append(Line(us: t, number: k + 1)) }
            k += 1
        }
        lines = out
    }

    public var beatsPerBar: Double { barUs / beatUs }

    /// Every `stepUs` from bar 1's anchor (a beat when it is `beatUs`) inside the clip.
    public func ticks(every stepUs: Double) -> [Int64] {
        guard stepUs >= 1_000 else { return [] }
        var out: [Int64] = []
        var k = Int(floor(Double(-anchorUs) / stepUs))
        while true {
            let t = anchorUs + Int64((Double(k) * stepUs).rounded())
            if t > durationUs { break }
            if t >= 0 { out.append(t) }
            k += 1
        }
        return out
    }

    /// The bar a time falls in (the pickup before bar 1 counts as bar 0, −1, …).
    public func barNumber(at us: Int64) -> Int { Int(floor(Double(us - anchorUs) / barUs)) + 1 }

    /// Where bar `number` starts, which may lie outside the clip.
    public func start(ofBar number: Int) -> Int64 { anchorUs + Int64((Double(number - 1) * barUs).rounded()) }

    /// The nearest bar line inside the clip; the clip's own start and end count as lines too,
    /// so a loop can begin at the very start of a clip that opens mid-bar.
    public func snap(_ us: Int64) -> Int64 {
        let candidates = [0] + lines.map(\.us) + [durationUs]
        return candidates.min { abs($0 - us) < abs($1 - us) } ?? 0
    }

    /// A valid loop from two times in either order: snapped, at least one bar long (or the
    /// whole clip when it is shorter than a bar).
    public func loop(_ a: Int64, _ b: Int64) -> Range<Int64> {
        var s = snap(min(a, b)), e = snap(max(a, b))
        if e - s < Int64(barUs * 0.5) {
            e = snap(s + Int64(barUs))
            if e <= s { s = snap(e - Int64(barUs)) }
            if e <= s { s = 0; e = durationUs }
        }
        return s..<e
    }

    /// The loop offered when none is set: four bars from the bar line at or before a time.
    public func defaultLoop(at us: Int64) -> Range<Int64> {
        let start = ([0] + lines.map(\.us)).last { $0 <= us } ?? 0
        return loop(start, start + Int64(barUs * 4))
    }

    /// What is actually played for a loop: with the lead-in, from one bar before A.
    public func playRange(_ loop: Range<Int64>, preroll: Bool) -> Range<Int64> {
        preroll ? max(0, loop.lowerBound - Int64(barUs.rounded()))..<loop.upperBound : loop
    }

    /// "17–20" for a loop: the bars it covers. A loop from the clip start that opens with a
    /// short pickup is named from the first whole bar.
    public func label(_ loop: Range<Int64>) -> String {
        let half = Int64(barUs / 2)
        let first = barNumber(at: min(loop.lowerBound + half, loop.upperBound - 1_000))
        let last = max(first, barNumber(at: max(loop.upperBound - half, loop.lowerBound + 1_000)))
        return first == last ? "\(first)" : "\(first)–\(last)"
    }
}

/// The 88 keys, A0 to C8, laid out across a width of 1.
public enum PianoKeys {
    public static let lowest = 21, highest = 108
    public static let whiteCount = 52
    public static let whiteWidth = 1.0 / Double(whiteCount)
    /// A black key's width as a share of a white key's.
    public static let blackShare = 0.6

    public static func isBlack(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(((pitch % 12) + 12) % 12) }

    /// Number of white keys below a pitch, from A0.
    static func whitesBelow(_ pitch: Int) -> Int {
        var n = 0
        var p = lowest
        while p < pitch { if !isBlack(p) { n += 1 }; p += 1 }
        return n
    }

    /// Left edge and width of a key, as fractions of the keyboard's width; nil off the keyboard.
    /// A black key straddles the line between its neighbours.
    public static func frame(_ pitch: Int) -> (x: Double, width: Double)? {
        guard (lowest...highest).contains(pitch) else { return nil }
        let below = Double(whitesBelow(pitch))
        if isBlack(pitch) { return (below * whiteWidth - whiteWidth * blackShare / 2, whiteWidth * blackShare) }
        return (below * whiteWidth, whiteWidth)
    }

    /// "C4" for the C keys, which are the ones labelled.
    public static func cLabel(_ pitch: Int) -> String? { pitch % 12 == 0 ? "C\(pitch / 12 - 1)" : nil }
}

/// The notes to draw: sorted by start, with a quick way to the ones on screen.
public struct NoteTimeline: Sendable {
    public let notes: [MidiNote]
    private let longestUs: Int64

    public init(_ notes: [MidiNote]) {
        self.notes = notes.sorted { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
        longestUs = notes.map { $0.endUs - $0.startUs }.max() ?? 0
    }

    /// Indices of the notes that overlap [fromUs, toUs).
    public func visible(fromUs: Int64, toUs: Int64) -> [Int] {
        var lo = 0, hi = notes.count
        let earliest = fromUs - longestUs
        while lo < hi { let mid = (lo + hi) / 2; if notes[mid].startUs < earliest { lo = mid + 1 } else { hi = mid } }
        var out: [Int] = []
        var i = lo
        while i < notes.count, notes[i].startUs < toUs {
            if notes[i].endUs > fromUs { out.append(i) }
            i += 1
        }
        return out
    }

    /// Index of the first note that starts at or after a time (the count when none does).
    public func firstIndex(startingAtOrAfter us: Int64) -> Int {
        var lo = 0, hi = notes.count
        while lo < hi { let mid = (lo + hi) / 2; if notes[mid].startUs < us { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// Pitches sounding at a time.
    public func sounding(atUs us: Int64) -> Set<Int> {
        Set(visible(fromUs: us, toUs: us + 1).map { notes[$0].pitch })
    }
}

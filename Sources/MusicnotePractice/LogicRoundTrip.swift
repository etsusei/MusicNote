import Foundation
import MusicnoteCore

/// The sustain pedal held from one time to another, clip-local.
public struct PedalSpan: Codable, Hashable, Sendable {
    public var startUs: Int64
    public var endUs: Int64

    public init(startUs: Int64, endUs: Int64) { self.startUs = startUs; self.endUs = endUs }
}

/// The MIDI to practise from: the take corrected by hand in Logic and brought back. It is kept
/// apart from the transcription and its revisions, which harmony analysis reads. Every import
/// is a new revision; the newest is the one in use and the older ones stay.
public struct PracticeMidi: Record {
    public static let kind = "practice.midi"
    public var id: UUID
    public var analysisId: UUID
    public var revision: Int
    public var notes: [MidiNote]
    public var pedals: [PedalSpan]
    /// Name of the imported file, to recognise the take by.
    public var fileName: String
    public var importedAt: Date

    public init(analysisId: UUID, revision: Int, notes: [MidiNote], pedals: [PedalSpan], fileName: String) {
        id = UUID(); self.analysisId = analysisId; self.revision = revision
        self.notes = notes; self.pedals = pedals; self.fileName = fileName
        importedAt = Date()
    }

    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { Double(revision) }
}

/// A clip on its way to Logic and back. The clip's audio, the stem and the MIDI all start at
/// the same moment, `startUs`: the bar line at or just before the clip start (a beat line when
/// bar 1 is not set). Dropped together at bar 1 of a Logic project at the MIDI file's tempo,
/// they line up with each other and Logic's bar lines fall on the music's.
///
/// The files are for checking the MIDI against the audio by ear and eye, so they play at
/// `speed`, half the music's: the audio is stretched to twice its length at the same pitch and
/// the MIDI file carries half the tempo, its notes on the same beats. Times read back from the
/// project are scaled to the music's speed again.
public enum LogicRoundTrip {
    /// How fast the exported files play, as a fraction of the music's speed.
    public static let speed = 0.5

    /// Clip time of the files' first sample and of tick 0: zero or negative (silence in front).
    public static func startUs(_ timing: TimingConfirmation) -> Int64 {
        let grid = timing.anchoredOnBeat.grid
        let anchor = Double(grid.barAnchorUs ?? grid.beatOriginUs)
        let period = grid.barAnchorUs != nil ? grid.beatUs * grid.meter.quarterBeatsPerBar : grid.beatUs
        guard period > 0 else { return 0 }
        let start = anchor - ceil(anchor / period - 1e-9) * period
        return min(0, Int64(start.rounded()))
    }

    /// One key cannot sound twice at once, and a MIDI file cannot say which note-off belongs to
    /// which of two overlapping notes of a pitch. Where a pitch is struck again while it still
    /// sounds, the earlier note ends at the new strike and the new one lasts as long as either
    /// did, so the key is down for the same time in all.
    public static func withoutOverlaps(_ notes: [MidiNote]) -> [MidiNote] {
        var out = notes.sorted { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
        var last: [Int: Int] = [:] // pitch → index in `out` of its latest note
        var drop = Set<Int>()
        for i in out.indices {
            let p = out[i].pitch
            if let j = last[p], out[j].endUs > out[i].startUs {
                out[i].endUs = max(out[i].endUs, out[j].endUs)
                if out[j].startUs == out[i].startUs { drop.insert(j) } else { out[j].endUs = out[i].startUs }
            }
            last[p] = i
        }
        return out.indices.filter { !drop.contains($0) }.map { out[$0] }
    }

    /// The MIDI file for Logic: tick 0 is `startUs`, the tempo is the confirmed one times
    /// `speed` throughout. The notes sit on the beats they are on in the music.
    public static func midiData(notes: [MidiNote], timing: TimingConfirmation, speed: Double = LogicRoundTrip.speed,
                                trackName: String = "Musicnote") -> Data {
        let notes = withoutOverlaps(notes)
        let start = startUs(timing)
        let beatUs = timing.grid.beatUs
        func tick(_ us: Int64) -> Int { max(0, MidiTicks.ticks(q: Double(us - start) / beatUs)) }
        let out = notes.map { n -> MidiFileWriter.Note in
            let s = tick(n.startUs)
            return .init(pitch: n.pitch, velocity: n.velocity, startTick: s, durationTicks: max(1, tick(n.endUs) - s))
        }
        var writer = MidiFileWriter(bpm: timing.bpm * speed, meter: timing.meter, key: timing.key)
        writer.trackName = trackName
        return writer.data(notes: out)
    }

    public struct Imported: Sendable {
        public var notes: [MidiNote]
        public var pedals: [PedalSpan]

        public init(notes: [MidiNote], pedals: [PedalSpan]) { self.notes = notes; self.pedals = pedals }
    }

    /// The notes of a file exported from that Logic project, in clip time and not yet cut to
    /// the clip (see `fit`). Times come from the file's own tempo map, so the project may run
    /// at another tempo than the exported one as long as the audio still sits at bar 1. `speed`
    /// is how fast that audio plays (see `read` when it is not known). Drum-channel notes are
    /// left out.
    public static func notes(from file: MidiFileContents, timing: TimingConfirmation, speed: Double = LogicRoundTrip.speed) -> Imported {
        let start = startUs(timing)
        func us(_ tick: Int) -> Int64 { Int64((file.seconds(atTick: tick) * speed * 1_000_000).rounded()) + start }
        var notes: [MidiNote] = []
        var pedals: [PedalSpan] = []
        for track in file.tracks {
            for n in track.notes where n.channel != 9 {
                notes.append(MidiNote(pitch: n.pitch, velocity: n.velocity, velocitySource: .edited,
                                      startUs: us(n.startTick), endUs: us(n.endTick), instrument: "piano"))
            }
            var down: Int64?
            var last = 0
            for p in track.pedals {
                last = max(last, p.tick)
                if p.down { down = down ?? us(p.tick) } else if let d = down {
                    pedals.append(PedalSpan(startUs: d, endUs: us(p.tick)))
                    down = nil
                }
            }
            // A pedal never lifted holds to the last note of the track.
            if let d = down {
                pedals.append(PedalSpan(startUs: d, endUs: us(max(last, track.notes.map(\.endTick).max() ?? last))))
            }
        }
        notes.sort { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
        pedals.sort { $0.startUs < $1.startUs }
        return Imported(notes: notes, pedals: pedals)
    }

    public struct Read: Sendable {
        public var take: Imported
        public var report: AlignmentCheck.Report
        /// The speed the take was read at: `speed`, or 1 for a project made from full-speed files.
        public var speed: Double
    }

    /// A file from the clip's Logic project, read at the speed that puts its notes on the
    /// transcription's. Files exported before the half-speed ones were made at full speed, and
    /// a project may have been brought back to full speed by hand; read at the wrong speed the
    /// notes drift ever further from the transcription and nothing matches. Where neither
    /// speed can be told from the notes, the exported files' speed is taken.
    public static func read(_ file: MidiFileContents, timing: TimingConfirmation, reference: [MidiNote]) -> Read {
        let reads = [speed, 1].map { s -> Read in
            let take = notes(from: file, timing: timing, speed: s)
            return Read(take: take, report: AlignmentCheck.compare(take: take.notes, reference: reference), speed: s)
        }
        if reads[1].report.verdict != .unknown,
           reads[0].report.verdict == .unknown || reads[1].report.matched > reads[0].report.matched { return reads[1] }
        return reads[0]
    }

    /// A take moved earlier by `shiftUs` (0 keeps it in place) and cut to the clip. `dropped`
    /// counts the notes that lay wholly outside it.
    public static func fit(_ take: Imported, shiftUs: Int64 = 0, durationUs: Int64) -> (notes: [MidiNote], pedals: [PedalSpan], dropped: Int) {
        var dropped = 0
        let notes = take.notes.compactMap { note -> MidiNote? in
            var m = note
            m.startUs = max(0, note.startUs - shiftUs); m.endUs = min(durationUs, note.endUs - shiftUs)
            if m.endUs <= m.startUs { dropped += 1; return nil }
            return m
        }
        let pedals = take.pedals.compactMap { span -> PedalSpan? in
            let s = max(0, span.startUs - shiftUs), e = min(durationUs, span.endUs - shiftUs)
            return e > s ? PedalSpan(startUs: s, endUs: e) : nil
        }
        return (notes, pedals, dropped)
    }
}

/// Whether a take brought back from Logic still sits where the audio is. The transcription
/// was made from the stem, so its notes mark where the audio's notes are; a take whose notes
/// are all the same distance from theirs was exported from the wrong place (a region not at
/// bar 1, the audio moved in the project).
public enum AlignmentCheck {
    public enum Verdict: Equatable, Sendable {
        /// The take's notes sit on the transcription's.
        case aligned
        /// The whole take is this much late (positive) or early.
        case shifted(us: Int64)
        /// Too few notes in common to tell.
        case unknown
    }

    public struct Report: Equatable, Sendable {
        public var verdict: Verdict
        /// Notes of the take that have a transcribed note of the same pitch at the found offset.
        public var matched: Int
        public var total: Int
    }

    /// Offsets within this are the hand corrections the take was made for, not a misplacement.
    public static let toleranceUs: Int64 = 60_000

    public static func compare(take: [MidiNote], reference: [MidiNote], windowUs: Int64 = 12_000_000) -> Report {
        guard take.count >= 4, reference.count >= 4 else { return Report(verdict: .unknown, matched: 0, total: take.count) }
        var byPitch: [Int: [Int64]] = [:]
        for n in reference { byPitch[n.pitch, default: []].append(n.startUs) }
        // Every same-pitch pair votes for the distance between the two notes; the true offset
        // collects a vote from almost every note, any other distance only from coincidences.
        let bin: Int64 = 20_000
        var votes: [Int64: Int] = [:]
        for n in take {
            for r in byPitch[n.pitch] ?? [] {
                let d = n.startUs - r
                if abs(d) <= windowUs { votes[Int64((Double(d) / Double(bin)).rounded()), default: 0] += 1 }
            }
        }
        func score(_ k: Int64) -> Int { (votes[k - 1] ?? 0) + (votes[k] ?? 0) + (votes[k + 1] ?? 0) }
        // The strongest offset; of equally strong ones (music that repeats), the smallest.
        guard let best = votes.keys.max(by: { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa < sb : abs(a) > abs(b)
        }) else { return Report(verdict: .unknown, matched: 0, total: take.count) }
        // Refine to the median distance of the pairs around the winning bin.
        var near: [Int64] = []
        var matched = 0
        for n in take {
            var hit = false
            for r in byPitch[n.pitch] ?? [] {
                let d = n.startUs - r
                if abs(d - best * bin) <= bin * 3 / 2 { near.append(d); hit = true }
            }
            if hit { matched += 1 }
        }
        guard matched * 10 >= take.count * 3, !near.isEmpty else {
            return Report(verdict: .unknown, matched: matched, total: take.count)
        }
        near.sort()
        let offset = near[near.count / 2]
        return Report(verdict: abs(offset) <= toleranceUs ? .aligned : .shifted(us: offset), matched: matched, total: take.count)
    }
}

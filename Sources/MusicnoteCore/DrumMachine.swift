import Foundation

// MARK: - Model

/// The six kit pieces Logic 13's drum splitter separates, in the model's output order.
public enum DrumPiece: String, Codable, CaseIterable, Sendable {
    case kick, snare, hihat, toms, cymbals, other

    public var displayName: String {
        switch self {
        case .kick: "底鼓"
        case .snare: "军鼓"
        case .hihat: "踩镲"
        case .toms: "嗵鼓"
        case .cymbals: "镲片"
        case .other: "其他打击乐"
        }
    }
}

/// General MIDI percussion sounds (channel 10) offered for a lane.
public enum GMDrum {
    public static let sounds: [(note: Int, name: String)] = [
        (35, "底鼓 2"), (36, "底鼓"), (37, "边击"), (38, "军鼓"), (39, "拍手"), (40, "电军鼓"),
        (41, "低落地嗵"), (42, "闭镲"), (43, "高落地嗵"), (44, "踏板镲"), (45, "低嗵"), (46, "开镲"),
        (47, "中低嗵"), (48, "中高嗵"), (49, "吊镲"), (50, "高嗵"), (51, "叮叮镲"), (52, "中国镲"),
        (53, "叮叮镲帽"), (54, "铃鼓"), (55, "水镲"), (56, "牛铃"), (57, "吊镲 2"), (59, "叮叮镲 2"),
        (60, "高邦戈"), (61, "低邦戈"), (62, "康加闷音"), (63, "高康加"), (64, "低康加"), (69, "沙锤卡巴萨"),
        (70, "沙锤"), (75, "响棒"), (76, "高木鱼"), (77, "低木鱼"), (81, "三角铁开"),
    ]

    public static func name(_ note: Int) -> String { sounds.first { $0.note == note }?.name ?? "音符 \(note)" }
}

/// One programmed step. `nudge` moves it off the grid by a fraction of a step (−0.5…0.5),
/// `chance` is the percentage it plays on a given pass, `repeats` re-triggers it evenly
/// inside the step (a ratchet).
public struct DrumStep: Codable, Hashable, Sendable {
    public var index: Int
    public var velocity: Int
    public var nudge: Double
    public var chance: Int
    public var repeats: Int

    public init(index: Int, velocity: Int = 100, nudge: Double = 0, chance: Int = 100, repeats: Int = 1) {
        self.index = index; self.velocity = velocity; self.nudge = nudge; self.chance = chance; self.repeats = repeats
    }
}

public struct DrumLane: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var note: Int
    /// Which separated kit piece the lane came from, for auditioning the original.
    public var piece: DrumPiece?
    public var volume: Double
    public var muted: Bool
    public var solo: Bool
    /// Sparse and sorted by index.
    public var steps: [DrumStep]

    public init(id: UUID = UUID(), name: String, note: Int, piece: DrumPiece? = nil, volume: Double = 1,
                muted: Bool = false, solo: Bool = false, steps: [DrumStep] = []) {
        self.id = id; self.name = name; self.note = note; self.piece = piece; self.volume = volume
        self.muted = muted; self.solo = solo; self.steps = steps
    }

    public func step(at index: Int) -> DrumStep? { steps.first { $0.index == index } }
}

/// The musical content of a beat: lanes of steps on a grid. A pattern owns one; a
/// Playground section holds a snapshot of one.
public struct DrumGroove: Codable, Hashable, Sendable {
    public var meter: Meter
    /// Steps per quarter beat: 4 = sixteenths, 3 = eighth-note triplets, 6 = sixteenth triplets, 8 = 32nds.
    public var stepsPerBeat: Int
    public var bars: Int
    /// MPC-style swing on every second step: 50 = straight, 66 ≈ triplet feel, up to 75.
    public var swing: Double
    /// How much of each step's nudge is played (0 = on the grid, 1 = as extracted).
    public var feel: Double
    public var lanes: [DrumLane]

    public init(meter: Meter = .fourFour, stepsPerBeat: Int = 4, bars: Int = 1, swing: Double = 50, feel: Double = 1, lanes: [DrumLane]) {
        self.meter = meter; self.stepsPerBeat = stepsPerBeat; self.bars = bars; self.swing = swing; self.feel = feel; self.lanes = lanes
    }

    public var stepsPerBar: Int { max(1, Int((meter.quarterBeatsPerBar * Double(stepsPerBeat)).rounded())) }
    public var totalSteps: Int { stepsPerBar * bars }
    public var lengthQ: Double { Double(bars) * meter.quarterBeatsPerBar }

    public static let resolutions: [(steps: Int, name: String)] = [(4, "十六分"), (3, "八分三连"), (6, "十六分三连"), (8, "三十二分")]

    /// The kit a new pattern starts with.
    public static func blank(meter: Meter = .fourFour, bars: Int = 1) -> DrumGroove {
        let kit: [(String, Int, DrumPiece)] = [("底鼓", 36, .kick), ("军鼓", 38, .snare), ("拍手", 39, .snare), ("闭镲", 42, .hihat),
                                               ("开镲", 46, .hihat), ("低嗵", 45, .toms), ("高嗵", 50, .toms), ("吊镲", 49, .cymbals),
                                               ("叮叮镲", 51, .cymbals), ("打击乐", 63, .other)]
        return DrumGroove(meter: meter, bars: bars, lanes: kit.map { DrumLane(name: $0.0, note: $0.1, piece: $0.2) })
    }
}

/// Where an extracted pattern came from, with its kit-piece audio for comparison.
public struct DrumSource: Codable, Hashable, Sendable {
    public var analysisId: UUID
    public var songTitle: String
    public var clipTitle: String
    public var bpm: Double
    public var trimRevision: Int
    public var timingRevision: Int
    /// Clip time of the pattern's first step (bar line on or before the clip start).
    public var startUs: Int64
    /// Relative asset paths: "mix" (the clip), "drums", and one per kit piece.
    public var audio: [String: String]
    public var logicVersion: String?
    /// Bars cut off the front since extraction, so the audio still lines up.
    public var cropBars: Int

    public init(analysisId: UUID, songTitle: String, clipTitle: String, bpm: Double, trimRevision: Int, timingRevision: Int,
                startUs: Int64, audio: [String: String], logicVersion: String?, cropBars: Int = 0) {
        self.analysisId = analysisId; self.songTitle = songTitle; self.clipTitle = clipTitle; self.bpm = bpm
        self.trimRevision = trimRevision; self.timingRevision = timingRevision; self.startUs = startUs
        self.audio = audio; self.logicVersion = logicVersion; self.cropBars = cropBars
    }
}

public struct DrumPattern: Record, Hashable {
    public static let kind = "drumpattern"
    public var id: UUID
    public var title: String
    public var bpm: Double
    public var groove: DrumGroove
    public var source: DrumSource?
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, bpm: Double, groove: DrumGroove, source: DrumSource? = nil) {
        self.id = id; self.title = title; self.bpm = bpm; self.groove = groove; self.source = source
        tags = []; createdAt = Date(); updatedAt = Date()
    }

    public var ownerId: UUID? { nil }
    public var sortKey: Double { updatedAt.timeIntervalSince1970 }
}

/// A pattern placed in a Playground section; it loops for the section's length.
public struct SectionDrums: Codable, Hashable, Sendable {
    public var patternId: UUID?
    public var title: String
    public var groove: DrumGroove
    public var volume: Double

    public init(patternId: UUID?, title: String, groove: DrumGroove, volume: Double = 1) {
        self.patternId = patternId; self.title = title; self.groove = groove; self.volume = volume
    }
}

// MARK: - Editing and playback

public enum DrumOps {
    public struct Hit: Hashable, Sendable {
        public var note: Int
        public var velocity: Int
        public var q: Double
        public var laneId: UUID
    }

    /// Start of a step in quarter beats from the groove start: swing puts every second step
    /// at `swing` % of its pair (66 % ≈ triplet), then the step's own nudge (scaled by `feel`).
    public static func stepQ(_ g: DrumGroove, index: Int, nudge: Double = 0) -> Double {
        let len = 1 / Double(g.stepsPerBeat)
        var q = Double(index) * len
        if index % 2 == 1 { q += (max(50, min(75, g.swing)) - 50) / 50 * len }
        return q + nudge * g.feel * len
    }

    /// Hits for `passes` consecutive passes of the groove. Chance is decided per pass by
    /// a seeded generator, so the same seed always plays the same way.
    public static func hits(_ g: DrumGroove, passes: Int = 1, seed: UInt64 = 1, volume: Double = 1) -> [Hit] {
        var rng = SplitMix(seed: seed)
        let anySolo = g.lanes.contains { $0.solo }
        let stepLen = 1 / Double(g.stepsPerBeat)
        var out: [Hit] = []
        for pass in 0..<max(0, passes) {
            let base = Double(pass) * g.lengthQ
            for lane in g.lanes where !lane.muted && (!anySolo || lane.solo) {
                for s in lane.steps where s.index >= 0 && s.index < g.totalSteps {
                    if s.chance < 100, Int(rng.next() % 100) >= s.chance { continue }
                    let v = max(1, min(127, Int((Double(s.velocity) * lane.volume * volume).rounded())))
                    let q0 = base + stepQ(g, index: s.index, nudge: s.nudge)
                    let n = max(1, min(8, s.repeats))
                    for r in 0..<n {
                        // Ratchet hits after the first fall off a little, like a drummer's.
                        let rv = r == 0 ? v : max(1, v - 12 * r / n)
                        out.append(Hit(note: lane.note, velocity: rv, q: q0 + Double(r) * stepLen / Double(n), laneId: lane.id))
                    }
                }
            }
        }
        return out.sorted { $0.q < $1.q }
    }

    /// Hits covering `lengthQ` by looping the groove (the last pass cut at the end).
    public static func tiled(_ g: DrumGroove, lengthQ: Double, seed: UInt64 = 1, volume: Double = 1) -> [Hit] {
        guard g.lengthQ > 0 else { return [] }
        let passes = Int(ceil(lengthQ / g.lengthQ - 1e-9))
        return hits(g, passes: passes, seed: seed, volume: volume).filter { $0.q >= -1e-9 && $0.q < lengthQ - 1e-9 }
    }

    public static func setStep(_ g: inout DrumGroove, lane: UUID, _ step: DrumStep) {
        guard let li = g.lanes.firstIndex(where: { $0.id == lane }) else { return }
        g.lanes[li].steps.removeAll { $0.index == step.index }
        g.lanes[li].steps.append(step)
        g.lanes[li].steps.sort { $0.index < $1.index }
    }

    public static func removeStep(_ g: inout DrumGroove, lane: UUID, index: Int) {
        guard let li = g.lanes.firstIndex(where: { $0.id == lane }) else { return }
        g.lanes[li].steps.removeAll { $0.index == index }
    }

    /// Turns a step on (with `velocity`) or off.
    public static func toggle(_ g: inout DrumGroove, lane: UUID, index: Int, velocity: Int = 100) {
        guard let li = g.lanes.firstIndex(where: { $0.id == lane }) else { return }
        if g.lanes[li].step(at: index) != nil { removeStep(&g, lane: lane, index: index) }
        else { setStep(&g, lane: lane, DrumStep(index: index, velocity: velocity)) }
    }

    /// Changes the grid, keeping every step at its nearest new position (nudge carries the
    /// remainder). Two steps landing on one keep the louder.
    public static func setResolution(_ g: inout DrumGroove, _ stepsPerBeat: Int) {
        guard stepsPerBeat > 0, stepsPerBeat != g.stepsPerBeat else { return }
        let old = g
        g.stepsPerBeat = stepsPerBeat
        for li in g.lanes.indices {
            var byIndex: [Int: DrumStep] = [:]
            for s in old.lanes[li].steps {
                let q = Double(s.index) / Double(old.stepsPerBeat) + s.nudge / Double(old.stepsPerBeat)
                let exact = q * Double(stepsPerBeat)
                let idx = Int(exact.rounded())
                guard idx >= 0, idx < g.totalSteps else { continue }
                var n = s; n.index = idx; n.nudge = max(-0.5, min(0.5, exact - Double(idx)))
                if let have = byIndex[idx], have.velocity >= n.velocity { continue }
                byIndex[idx] = n
            }
            g.lanes[li].steps = byIndex.values.sorted { $0.index < $1.index }
        }
    }

    /// Bar count change: steps past the new end are dropped; growing repeats nothing.
    public static func setBars(_ g: inout DrumGroove, _ bars: Int) {
        g.bars = max(1, min(64, bars))
        let total = g.totalSteps
        for li in g.lanes.indices { g.lanes[li].steps.removeAll { $0.index >= total } }
    }

    /// Keeps bars `range` (0-based) only.
    public static func crop(_ g: inout DrumGroove, bars range: Range<Int>) {
        let lo = max(0, range.lowerBound), hi = min(g.bars, range.upperBound)
        guard hi > lo else { return }
        let first = lo * g.stepsPerBar, last = hi * g.stepsPerBar
        for li in g.lanes.indices {
            g.lanes[li].steps = g.lanes[li].steps.filter { $0.index >= first && $0.index < last }.map { var s = $0; s.index -= first; return s }
        }
        g.bars = hi - lo
    }

    /// Copies bar `from` onto bar `to` for the given lanes (all when nil), replacing what was there.
    public static func copyBar(_ g: inout DrumGroove, from: Int, to: Int, lanes: Set<UUID>? = nil) {
        guard from != to, (0..<g.bars).contains(from), (0..<g.bars).contains(to) else { return }
        let n = g.stepsPerBar
        for li in g.lanes.indices where lanes?.contains(g.lanes[li].id) ?? true {
            let src = g.lanes[li].steps.filter { $0.index / n == from }
            g.lanes[li].steps.removeAll { $0.index / n == to }
            g.lanes[li].steps += src.map { var s = $0; s.index = s.index - from * n + to * n; return s }
            g.lanes[li].steps.sort { $0.index < $1.index }
        }
    }

    public static func clearBar(_ g: inout DrumGroove, _ bar: Int, lanes: Set<UUID>? = nil) {
        let n = g.stepsPerBar
        for li in g.lanes.indices where lanes?.contains(g.lanes[li].id) ?? true { g.lanes[li].steps.removeAll { $0.index / n == bar } }
    }

    /// Appends a copy of the whole groove after itself.
    public static func duplicate(_ g: inout DrumGroove) {
        guard g.bars * 2 <= 64 else { return }
        let t = g.totalSteps
        g.bars *= 2
        for li in g.lanes.indices { g.lanes[li].steps += g.lanes[li].steps.map { var s = $0; s.index += t; return s } }
    }

    /// Rotates one lane by `by` steps, wrapping around the pattern.
    public static func shift(_ g: inout DrumGroove, lane: UUID, by: Int) {
        guard let li = g.lanes.firstIndex(where: { $0.id == lane }) else { return }
        let t = g.totalSteps
        g.lanes[li].steps = g.lanes[li].steps.map { var s = $0; s.index = ((s.index + by) % t + t) % t; return s }.sorted { $0.index < $1.index }
    }

    /// Fills a lane with a hit every `every` steps from `offset` (e.g. eighth-note hats).
    public static func fill(_ g: inout DrumGroove, lane: UUID, every: Int, offset: Int = 0, velocity: Int = 100) {
        guard every > 0, let li = g.lanes.firstIndex(where: { $0.id == lane }) else { return }
        g.lanes[li].steps = stride(from: offset, to: g.totalSteps, by: every).map { DrumStep(index: $0, velocity: velocity) }
    }

    /// The most typical `bars`-bar loop: the window whose steps agree most with the other
    /// windows of the same length (ties go to the earliest). Returns its first bar.
    public static func representativeLoop(_ g: DrumGroove, bars: Int) -> Int? {
        guard bars > 0, g.bars >= bars else { return nil }
        let n = g.stepsPerBar
        func window(_ start: Int) -> Set<String> {
            var s = Set<String>()
            for lane in g.lanes { for st in lane.steps where st.index / n >= start && st.index / n < start + bars {
                s.insert("\(lane.note):\(st.index - start * n)")
            } }
            return s
        }
        let starts = Array(stride(from: 0, through: g.bars - bars, by: bars))
        let windows = starts.map(window)
        guard windows.count > 1 else { return starts.first }
        var best = (score: -1.0, start: 0)
        for (i, w) in windows.enumerated() where !w.isEmpty {
            var score = 0.0
            for (j, o) in windows.enumerated() where j != i {
                let u = w.union(o).count
                score += u == 0 ? 0 : Double(w.intersection(o).count) / Double(u)
            }
            if score > best.score { best = (score, starts[i]) }
        }
        return best.score < 0 ? starts.first : best.start
    }

    /// A standalone MIDI file: one drum track on channel 10.
    public static func exportMidi(_ p: DrumPattern, passes: Int = 1) -> Data {
        var w = MidiFileWriter(bpm: p.bpm, meter: p.groove.meter, key: nil)
        w.trackName = p.title
        return w.data(notes: [], drumNotes: midiNotes(hits(p.groove, passes: passes)))
    }

    public static func midiNotes(_ hits: [Hit], offsetQ: Double = 0) -> [MidiFileWriter.Note] {
        hits.map { h in
            let t = MidiTicks.ticks(q: max(0, h.q + offsetQ))
            return MidiFileWriter.Note(pitch: h.note, velocity: h.velocity, startTick: t, durationTicks: max(1, MidiTicks.ppq / 8))
        }
    }
}

/// Small deterministic generator for step chance.
public struct SplitMix: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

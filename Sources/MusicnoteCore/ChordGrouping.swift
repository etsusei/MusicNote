import Foundation

/// Groups a confirmed MIDI take into chord events the way a musician reads a chart:
///
/// - Chords sit on the meter. Starting from the bar line, every eighth note is a
///   detection point; a new chord can only begin where notes are struck (two or more
///   notes, or a new bass note), so melody notes never become chords.
/// - Changing chord costs least on a downbeat, then the half bar, then other beats, and
///   most on an off-beat eighth. Without clear evidence a chord lasts to the next strong
///   beat — usually a whole bar — and passing chords take quarters or eighths only when
///   the notes really change.
/// - Re-striking the same chord (comping rhythm) stays one chord.
/// - A chord struck on the "and" before a beat that ties over it (R&B/Funk anticipation)
///   counts as starting on that beat; the event keeps its real onset time.
/// - When the passage repeats, every repeat is segmented jointly so all repeats share
///   the same boundaries; each repeat is still named from its own notes.
///
/// Parameters are a baseline to tune against labelled clips (待定 P0-05).
public struct ChordGrouper: Sendable {
    /// Bump when grouping changes so existing analyses can offer a re-run.
    public static let algorithm = "meter-slots-v4"

    public struct Params: Sendable {
        public var maxSegmentBars = 4.0
        public var clusterUs: Int64 = 45_000
        public var bassWeight = 1.6
        public var onsetWeight = 1.25
        public var shortNoteBeats = 0.3
        public var shortOffbeatWeight = 0.45
        public var minToneWeight = 0.06
        public var attackWeight = 1.0
        public var sustainWeight = 0.35
        public var singleNoteEvidence = 0.6
        public var sustainEvidence = 0.3
        public var penaltyDownbeat = 0.1
        public var penaltyHalfBar = 0.25
        public var penaltyBeat = 0.4
        public var penaltyOffbeat = 0.6
        public var penaltyNoAttack = 1.0
        public var restBreakBars = 1.0
        public init() {}

        public var dictionary: [String: String] {
            ["algorithm": ChordGrouper.algorithm, "grid": "eighth",
             "penalties": "\(penaltyDownbeat)/\(penaltyHalfBar)/\(penaltyBeat)/\(penaltyOffbeat)",
             "sustainWeight": "\(sustainWeight)", "maxSegmentBars": "\(maxSegmentBars)"]
        }
    }

    public struct Group: Sendable {
        public var startUs: Int64
        public var endUs: Int64
        public var noteIds: [UUID]
        public var roles: [UUID: NoteRole]
        public var texture: Texture
        public var namingPitches: [Int]
        public var bassPitch: Int?
        public var candidates: [ChordCandidate]
    }

    /// A passage that repeats every `periodBeats`, `count` times from `startUs`.
    public struct Repetition: Sendable, Hashable {
        public var periodBeats: Double
        public var periodUs: Int64
        public var startUs: Int64
        public var count: Int
        public var similarity: Double
    }

    public struct Result: Sendable {
        public var groups: [Group]
        public var repetition: Repetition?
        public var barAnchorUs: Int64
        public var barAnchorEstimated: Bool
    }

    public var params: Params
    public init(params: Params = Params()) { self.params = params }

    public func group(notes allNotes: [MidiNote], grid: BeatGrid, durationUs: Int64, key: KeySignature?,
                      excludeInstruments: Set<String> = ["drums", "voice"]) -> [Group] {
        run(notes: allNotes, grid: grid, durationUs: durationUs, key: key, excludeInstruments: excludeInstruments).groups
    }

    public func analyze(notes allNotes: [MidiNote], grid: BeatGrid, durationUs: Int64, key: KeySignature?,
                        excludeInstruments: Set<String> = ["drums", "voice"]) -> (groups: [Group], repetition: Repetition?) {
        let r = run(notes: allNotes, grid: grid, durationUs: durationUs, key: key, excludeInstruments: excludeInstruments)
        return (r.groups, r.repetition)
    }

    public func run(notes allNotes: [MidiNote], grid gridIn: BeatGrid, durationUs: Int64, key: KeySignature?,
                    excludeInstruments: Set<String> = ["drums", "voice"]) -> Result {
        let notes = allNotes.filter { !excludeInstruments.contains($0.instrument) && $0.endUs > $0.startUs }
            .sorted { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
        guard !notes.isEmpty, gridIn.bpm > 0 else { return Result(groups: [], repetition: nil, barAnchorUs: 0, barAnchorEstimated: true) }
        var grid = gridIn
        let estimated = grid.barAnchorUs == nil
        if estimated { grid.barAnchorUs = estimateBarAnchor(notes: notes, grid: grid) }
        let slots = buildSlots(notes: notes, grid: grid, durationUs: durationUs)
        guard !slots.isEmpty else { return Result(groups: [], repetition: nil, barAnchorUs: grid.barAnchorUs!, barAnchorEstimated: estimated) }
        let misfit = misfitTable(slots)
        let spb = slotsPerBar(grid)
        let rep = detectRepetition(slots: slots, grid: grid, spb: spb)

        var ranges: [(Int, Int)] = []
        if let rep {
            let first = rep.startSlot, period = rep.periodSlots
            ranges += segmentRegions(slots: slots, misfit: misfit, range: 0..<first, spb: spb)
            let occ = (0..<rep.count).map { k in Array((first + k * period)..<min(slots.count, first + (k + 1) * period)) }
            for (a, b) in jointSegment(slots: slots, misfit: misfit, occurrences: occ, spb: spb) {
                for o in occ where a < o.count {
                    var i = o[a], j = b <= o.count ? (b == o.count ? o[o.count - 1] + 1 : o[b]) : o[o.count - 1] + 1
                    while i < j, slots[i].isRest { i += 1 }
                    while j > i, slots[j - 1].isRest { j -= 1 }
                    if i < j { ranges.append((i, j)) }
                }
            }
            let tail = first + rep.count * period
            if tail < slots.count { ranges += segmentRegions(slots: slots, misfit: misfit, range: tail..<slots.count, spb: spb) }
            ranges.sort { $0.0 < $1.0 }
        } else {
            ranges = segmentRegions(slots: slots, misfit: misfit, range: 0..<slots.count, spb: spb)
        }

        var groups: [Group] = []
        for (n, (i, j)) in ranges.enumerated() {
            let start = slots[i].attacks.map(\.startUs).min() ?? slots[i].time
            // Lasts until the next chord, unless the music actually stops earlier (rests keep gaps).
            let nextStart = n + 1 < ranges.count ? (slots[ranges[n + 1].0].attacks.map(\.startUs).min() ?? slots[ranges[n + 1].0].time) : durationUs
            let lastEnd = (i..<j).flatMap { slots[$0].attacks }.map(\.endUs).max() ?? slots[j - 1].time
            let gap = Int64(grid.beatUs / 2)
            let end = min(durationUs, lastEnd + gap < nextStart ? lastEnd : nextStart)
            guard end > start else { continue }
            var profile = CellProfile(weights: [Double](repeating: 0, count: 12), bassPc: nil, bassPitch: nil)
            for s in slots[i..<j] { for k in 0..<12 { profile.weights[k] += s.weights[k] * s.evidence } }
            // Bass: the lowest note struck in the chord's span (sustained bass if nothing was struck).
            let struck = (i..<j).flatMap { slots[$0].attacks }
            if let b = struck.map(\.pitch).min() ?? slots[i].bassPitch { profile.bassPitch = b; profile.bassPc = Pitch.pc(b) }
            groups.append(makeGroup(notes: notes, start: start, end: end, profile: profile, grid: grid, key: key))
        }
        let repetition = rep.map { r in
            Repetition(periodBeats: Double(r.periodSlots) / 2, periodUs: Int64(Double(r.periodSlots) * grid.beatUs / 2),
                       startUs: slots[r.startSlot].time, count: r.count, similarity: r.similarity)
        }
        return Result(groups: groups, repetition: repetition, barAnchorUs: grid.barAnchorUs!, barAnchorEstimated: estimated)
    }

    // MARK: Slots

    enum Metric { case downbeat, halfBar, beat, offbeat }

    struct Slot {
        var time: Int64
        var index: Int // eighths from the bar anchor (may be negative for pickups)
        var attacks: [MidiNote]
        var weights: [Double]
        var bassPitch: Int?
        var evidence: Double
        var canStart: Bool // struck chord or new bass
        var metric: Metric
        var anticipates: Bool // off-beat strike tied over the following beat
        var isRest: Bool { evidence == 0 }
    }

    struct CellProfile {
        var weights: [Double]
        var bassPc: Int?
        var bassPitch: Int?
    }

    func slotsPerBar(_ grid: BeatGrid) -> Int { max(2, Int((grid.meter.quarterBeatsPerBar * 2).rounded())) }

    func metric(_ k: Int, grid: BeatGrid) -> Metric {
        let spb = slotsPerBar(grid)
        let pos = ((k % spb) + spb) % spb
        if pos == 0 { return .downbeat }
        if grid.meter.denominator == 8 { return pos % 3 == 0 ? .beat : .offbeat } // compound: dotted-quarter beats
        if spb % 4 == 0 && pos == spb / 2 { return .halfBar }
        return pos % 2 == 0 ? .beat : .offbeat
    }

    func buildSlots(notes: [MidiNote], grid: BeatGrid, durationUs: Int64) -> [Slot] {
        let eighth = grid.beatUs / 2
        let anchor = grid.barAnchorUs ?? grid.beatOriginUs
        func k(_ t: Int64) -> Int { Int((Double(t - anchor) / eighth).rounded()) }
        let k0 = min(k(notes.first!.startUs), 0 > k(0) ? 0 : k(0))
        let k1 = Int((Double(durationUs - anchor) / eighth).rounded(.up))
        guard k1 > k0 else { return [] }
        var attacks = [[MidiNote]](repeating: [], count: k1 - k0 + 1)
        for n in notes { let i = k(n.startUs) - k0; if i >= 0 && i < attacks.count { attacks[i].append(n) } }
        var out: [Slot] = []
        var prevBass: Int?
        for i in 0..<(k1 - k0) {
            let kk = k0 + i
            let t = anchor + Int64(Double(kk) * eighth)
            guard t < durationUs else { break }
            let probe = t + Int64(eighth * 0.25)
            let struck = attacks[i]
            let struckIds = Set(struck.map(\.id))
            let sustained = notes.filter { !struckIds.contains($0.id) && $0.startUs < probe && $0.endUs > probe + Int64(eighth * 0.25) }
            var w = [Double](repeating: 0, count: 12)
            let lowest = (struck + sustained).min { $0.pitch < $1.pitch }
            for n in struck {
                var x = params.attackWeight
                if struck.count == 1, Double(n.durationUs) < eighth { x *= 0.5 } // short lone note: likely melody
                if n.id == lowest?.id { x *= params.bassWeight }
                w[Pitch.pc(n.pitch)] += x
            }
            for n in sustained { w[Pitch.pc(n.pitch)] += params.sustainWeight * (n.id == lowest?.id ? params.bassWeight : 1) }
            let evidence: Double = struck.count >= 2 ? 1 : struck.count == 1 ? params.singleNoteEvidence : (sustained.isEmpty ? 0 : params.sustainEvidence)
            let bass = lowest?.pitch
            let newBass = struck.contains { $0.id == lowest?.id } && bass != prevBass
            let canStart = struck.count >= 2 || newBass
            // Anticipation: struck off the beat, nothing new on the next eighth, and it rings through it.
            let nextStruck = i + 1 < attacks.count ? attacks[i + 1] : []
            let ties = struck.contains { $0.endUs > t + Int64(eighth * 1.5) }
            out.append(Slot(time: t, index: kk, attacks: struck, weights: w, bassPitch: bass, evidence: evidence,
                            canStart: canStart, metric: metric(kk, grid: grid), anticipates: nextStruck.isEmpty && ties && struck.count >= 2))
            if let b = bass { prevBass = b }
        }
        return out
    }

    /// Where the bar line most likely is: the beat phase on which struck chords land (or are
    /// anticipated by an eighth) most, weighted by how long they ring. Ties favour the first chord.
    func estimateBarAnchor(notes: [MidiNote], grid: BeatGrid) -> Int64 {
        let clusters = onsetClusters(notes).filter { $0.count >= 2 }
        guard let first = clusters.first ?? notes.first.map({ Cluster(time: $0.startUs, count: 1, sustainEnd: $0.endUs) }) else { return grid.beatOriginUs }
        let bpb = max(1, Int(grid.meter.quarterBeatsPerBar.rounded()))
        let firstBeat = grid.q(atUs: first.time).rounded()
        var best: (score: Double, anchorQ: Double)?
        for phase in 0..<bpb {
            let anchorQ = firstBeat + Double(phase)
            var score = 0.0
            for c in clusters {
                let q = grid.q(atUs: c.time)
                let ring = min(Double(bpb), max(0.5, Double(c.sustainEnd - c.time) / grid.beatUs))
                var pos = (q - anchorQ).truncatingRemainder(dividingBy: Double(bpb))
                if pos < 0 { pos += Double(bpb) }
                if pos < 0.15 || pos > Double(bpb) - 0.15 { score += 2 * ring }
                else if abs(pos - (Double(bpb) - 0.5)) < 0.15, Double(c.sustainEnd - c.time) / grid.beatUs > 0.75 { score += 1.5 * ring }
                else if bpb % 2 == 0, abs(pos - Double(bpb) / 2) < 0.15 { score += 0.5 * ring }
            }
            if best == nil || score > best!.score + 1e-9 { best = (score, anchorQ) }
        }
        // Put the anchor at or before the first chord so the passage starts in bar 1.
        var q = best!.anchorQ
        while grid.us(atQ: q) > first.time + Int64(grid.beatUs * 0.6) { q -= Double(bpb) }
        return grid.us(atQ: q)
    }

    // MARK: Segmentation

    func misfitTable(_ slots: [Slot]) -> [[Double]] {
        let templates = TemplateMatcher.templates
        return slots.map { s in
            let total = s.weights.reduce(0, +)
            guard s.evidence > 0, total > 0 else { return [Double](repeating: 0, count: templates.count) }
            let p = s.weights.map { $0 / total }
            let bassPc = s.bassPitch.map(Pitch.pc)
            return templates.map { max(0, 1 - TemplateMatcher.score(p: p, bassPc: bassPc, root: $0.root, quality: $0.quality)) * s.evidence }
        }
    }

    /// Cost of starting a chord at slot i.
    func startPenalty(_ s: Slot, slots: [Slot], at i: Int) -> Double {
        var m = s.metric
        if s.anticipates, i + 1 < slots.count { m = slots[i + 1].metric }
        var p: Double
        switch m {
        case .downbeat: p = params.penaltyDownbeat
        case .halfBar: p = params.penaltyHalfBar
        case .beat: p = params.penaltyBeat
        case .offbeat: p = params.penaltyOffbeat
        }
        if !s.canStart { p += params.penaltyNoAttack }
        return p
    }

    /// Splits at long rests (≥ restBreakBars of silence), then segments each region.
    func segmentRegions(slots: [Slot], misfit: [[Double]], range: Range<Int>, spb: Int) -> [(Int, Int)] {
        guard !range.isEmpty else { return [] }
        let breakLen = Int(params.restBreakBars * Double(spb))
        var regions: [Range<Int>] = []
        var start: Int?
        var restRun = 0
        for i in range {
            if slots[i].isRest {
                restRun += 1
                if restRun >= breakLen, let s = start { regions.append(s..<(i - restRun + 1)); start = nil }
            } else {
                if start == nil { start = i }
                restRun = 0
            }
        }
        if let s = start { regions.append(s..<range.upperBound) }
        var out: [(Int, Int)] = []
        for r in regions {
            for (a, b) in jointSegment(slots: slots, misfit: misfit, occurrences: [Array(r)], spb: spb) {
                var i = r.lowerBound + a, j = r.lowerBound + b
                while i < j, slots[i].isRest { i += 1 }
                while j > i, slots[j - 1].isRest { j -= 1 }
                if i < j { out.append((i, j)) }
            }
        }
        return out
    }

    /// DP with boundaries shared by all occurrences (one occurrence = plain segmentation).
    /// Each occurrence picks its own best chord per segment; costs and start penalties add up.
    func jointSegment(slots: [Slot], misfit: [[Double]], occurrences occ: [[Int]], spb: Int) -> [(Int, Int)] {
        let T = TemplateMatcher.templates.count
        let m = occ.map(\.count).max() ?? 0
        guard m > 0 else { return [] }
        let maxLen = max(spb, Int(params.maxSegmentBars * Double(spb)))
        var prefixes: [[[Double]]] = []
        for o in occ {
            var p = [[Double]](repeating: [Double](repeating: 0, count: T), count: m + 1)
            for c in 0..<m { for t in 0..<T { p[c + 1][t] = p[c][t] + (c < o.count ? misfit[o[c]][t] : 0) } }
            prefixes.append(p)
        }
        let penalties: [Double] = (0..<m).map { c in
            let ps = occ.compactMap { c < $0.count ? startPenalty(slots[$0[c]], slots: slots, at: $0[c]) : nil }
            return ps.isEmpty ? 0 : ps.reduce(0, +) / Double(ps.count) * Double(occ.count)
        }
        var best = [Double](repeating: .infinity, count: m + 1)
        var back = [Int](repeating: -1, count: m + 1)
        best[0] = 0
        for j in 1...m {
            var i = j - 1
            while i >= 0, j - i <= maxLen {
                var cost = i == 0 ? 0 : penalties[i]
                for p in prefixes {
                    var seg = Double.infinity
                    for t in 0..<T { seg = min(seg, p[j][t] - p[i][t]) }
                    cost += seg
                }
                if best[i] + cost < best[j] { best[j] = best[i] + cost; back[j] = i }
                i -= 1
            }
        }
        var out: [(Int, Int)] = []
        var j = m
        while j > 0 { out.append((back[j], j)); j = back[j] }
        return out.reversed()
    }

    // MARK: Repetition

    struct SlotRepetition { var startSlot: Int; var periodSlots: Int; var count: Int; var similarity: Double }

    /// Whole-bar period (2 bars or more) at which the passage repeats, from the slot
    /// pitch-class content. Starts at the first bar line at or before the first chord.
    func detectRepetition(slots: [Slot], grid: BeatGrid, spb: Int) -> SlotRepetition? {
        guard let firstSound = slots.firstIndex(where: { !$0.isRest }) else { return nil }
        // First bar line at or before the first sound (anticipations land just before it).
        var start = firstSound
        while start > 0, slots[start].metric != .downbeat { start -= 1 }
        if slots[start].metric != .downbeat { start = firstSound }
        let n = slots.count - start
        func feat(_ s: Slot) -> [Double] { s.weights.map { $0 * s.evidence } }
        func norm(_ v: [Double]) -> Double { sqrt(v.reduce(0) { $0 + $1 * $1 }) }
        var best: SlotRepetition?
        var lag = spb * 2
        while lag * 2 <= n + spb / 2 {
            var sum = 0.0, count = 0
            for i in start..<(slots.count - lag) {
                let a = feat(slots[i]), b = feat(slots[i + lag])
                let na = norm(a), nb = norm(b)
                if na == 0 && nb == 0 { continue }
                count += 1
                if na > 0 && nb > 0 { sum += zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / (na * nb) }
            }
            if count >= lag / 2 {
                let sim = sum / Double(count)
                let reps = Int(Double(n) / Double(lag) + 0.15)
                if sim >= 0.72, reps >= 2, best == nil || sim > best!.similarity + 0.03 {
                    best = SlotRepetition(startSlot: start, periodSlots: lag, count: reps, similarity: sim)
                }
            }
            lag += spb
        }
        return best
    }

    // MARK: Events

    struct Cluster { var time: Int64; var count: Int; var sustainEnd: Int64 }

    func onsetClusters(_ notes: [MidiNote]) -> [Cluster] {
        var out: [Cluster] = []
        var i = 0
        while i < notes.count {
            var j = i + 1
            while j < notes.count, notes[j].startUs - notes[i].startUs <= params.clusterUs { j += 1 }
            let end = notes[i..<j].map(\.endUs).sorted()[(j - i) / 2]
            out.append(Cluster(time: notes[i].startUs, count: j - i, sustainEnd: end))
            i = j
        }
        return out
    }

    func makeGroup(notes: [MidiNote], start: Int64, end: Int64, profile: CellProfile, grid: BeatGrid, key: KeySignature?) -> Group {
        let members = notes.filter { $0.startUs < end && $0.endUs > start }
        let ranked = TemplateMatcher.best(profile: profile.weights, bassPc: profile.bassPc, limit: 4)
        let total = max(profile.weights.reduce(0, +), 1e-9)
        let norm = profile.weights.map { $0 / total }
        let top = ranked.first
        let chordPcs: Set<Int> = top.map { fit in Set(fit.quality.intervals.map { Pitch.pc(fit.root + $0) }) } ?? []

        // Roles by pitch class and note shape.
        var roles: [UUID: NoteRole] = [:]
        let highest = members.map(\.pitch).max() ?? 0
        for n in members {
            let pc = Pitch.pc(n.pitch)
            let beats = Double(n.durationUs) / grid.beatUs
            if chordPcs.contains(pc) && norm[pc] >= params.minToneWeight {
                roles[n.id] = .chordTone
            } else if let top, [1, 2, 3, 5, 6, 8, 9].contains(Pitch.pc(pc - top.root)), norm[pc] >= params.minToneWeight {
                roles[n.id] = .possibleTension
            } else if n.pitch >= highest - 4 && beats < 1 && members.count > 3 {
                roles[n.id] = .possibleMelody
            } else {
                roles[n.id] = .possiblePassing
            }
        }

        // Naming input: lowest instance of each kept pitch class, plus the sustained bass.
        var lowestByPc: [Int: Int] = [:]
        for n in members where roles[n.id] == .chordTone || roles[n.id] == .possibleTension {
            let pc = Pitch.pc(n.pitch)
            lowestByPc[pc] = min(lowestByPc[pc] ?? n.pitch, n.pitch)
        }
        var naming = Array(lowestByPc.values)
        if let b = profile.bassPitch, !naming.contains(b) { naming.append(b) }
        naming.sort()

        // Texture: share of notes that start inside a cluster of 3+ simultaneous onsets.
        let sorted = members.filter { $0.startUs >= start }.sorted { $0.startUs < $1.startUs }
        var clustered = 0
        var i = 0
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count, sorted[j].startUs - sorted[i].startUs <= params.clusterUs { j += 1 }
            if j - i >= 3 { clustered += j - i }
            i = j
        }
        let share = sorted.isEmpty ? 1 : Double(clustered) / Double(sorted.count)
        let texture: Texture = share >= 0.75 ? .block : share <= 0.25 ? .broken : .mixed

        let candidates = ranked.map {
            ChordCandidate(symbol: ChordSymbol.make(root: $0.root, suffix: $0.quality.suffix, bass: profile.bassPc, key: key),
                           source: .template, score: ($0.score * 100).rounded() / 100, raw: nil)
        }
        return Group(startUs: start, endUs: end, noteIds: members.map(\.id), roles: roles, texture: texture,
                     namingPitches: naming, bassPitch: profile.bassPitch, candidates: candidates)
    }
}

/// Scores (root, quality) templates against a weighted pitch-class profile.
public enum TemplateMatcher {
    public struct Fit: Sendable { public var root: Int; public var quality: ChordQuality; public var score: Double }

    // Common qualities only; exotic names come from Musicpy or the user.
    static let pool: [ChordQuality] = ChordCatalog.qualities.filter {
        ["", "m", "dim", "aug", "sus4", "sus2", "6", "m6", "7", "maj7", "m7", "m7♭5", "dim7", "7sus4",
         "9", "maj9", "m9", "add9", "7♭9", "7♯9", "13", "m11", "6/9"].contains($0.suffix)
    }

    public static let templates: [(root: Int, quality: ChordQuality)] = (0..<12).flatMap { r in pool.map { (root: r, quality: $0) } }

    /// Fit of one (root, quality) to a normalized profile: coverage minus missing
    /// essential tones minus a small complexity cost, plus a bonus when the bass is the root.
    public static func score(p: [Double], bassPc: Int?, root: Int, quality q: ChordQuality) -> Double {
        let pcs = q.intervals.map { Pitch.pc(root + $0) }
        let set = Set(pcs)
        let covered = set.reduce(0.0) { $0 + p[$1] }
        var missing = 0.0
        for (k, i) in q.intervals.enumerated() where p[pcs[k]] < 0.04 {
            switch i {
            case 0: missing += 0.12
            case 3, 4, 10, 11: missing += 0.16
            case 7: missing += 0.04
            default: missing += 0.12
            }
        }
        var s = covered - missing - 0.03 * Double(max(0, set.count - 3))
        if let bassPc, bassPc == root { s += 0.08 }
        return s
    }

    public static func best(profile: [Double], bassPc: Int?, limit: Int = 1) -> [Fit] {
        let total = profile.reduce(0, +)
        guard total > 0 else { return [] }
        let p = profile.map { $0 / total }
        var fits = templates.map { Fit(root: $0.root, quality: $0.quality, score: score(p: p, bassPc: bassPc, root: $0.root, quality: $0.quality)) }
        fits.sort { $0.score > $1.score }
        // Keep distinct symbols only.
        var seen = Set<String>()
        return Array(fits.filter { seen.insert("\($0.root)\($0.quality.suffix)").inserted }.prefix(limit))
    }
}

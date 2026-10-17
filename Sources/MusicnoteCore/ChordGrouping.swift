import Foundation

/// Groups a confirmed MIDI take into chord events by accumulating pitch classes
/// over time windows, so broken chords, Alberti figures, arpeggios and comping
/// recover their full harmony instead of being cut at every note-on.
///
/// 1. Candidate boundaries come from the beat grid, moved earlier to an actual
///    onset cluster when a chord is anticipated (common in Funk/R&B).
/// 2. Each cell accumulates overlap-weighted pitch classes; sustained bass and
///    cell-initial onsets count more, short off-beat notes less.
/// 3. Dynamic programming merges adjacent cells explainable by one chord and
///    splits where the pitch content changes, with a per-change penalty.
/// 4. Low-weight notes are kept and labelled with a role, never dropped.
///
/// Parameters are a starting baseline to be tuned against labelled clips.
public struct ChordGrouper: Sendable {
    /// Bump when grouping changes so existing analyses can offer a re-run.
    public static let algorithm = "window-dp-v2"

    public struct Params: Sendable {
        public var cellBeats = 1.0
        public var maxSegmentCells = 8
        public var changePenalty = 0.35
        public var anticipationBeats = 0.5
        public var clusterUs: Int64 = 45_000
        public var bassWeight = 1.6
        public var onsetWeight = 1.25
        public var shortNoteBeats = 0.3
        public var shortOffbeatWeight = 0.45
        public var restThreshold = 0.05
        public var minToneWeight = 0.06
        public var attackMinNotes = 3
        public var attackSnapBeats = 0.15
        public init() {}

        public var dictionary: [String: String] {
            ["cellBeats": "\(cellBeats)", "maxSegmentCells": "\(maxSegmentCells)", "changePenalty": "\(changePenalty)",
             "anticipationBeats": "\(anticipationBeats)", "bassWeight": "\(bassWeight)", "onsetWeight": "\(onsetWeight)",
             "shortNoteBeats": "\(shortNoteBeats)", "shortOffbeatWeight": "\(shortOffbeatWeight)", "algorithm": ChordGrouper.algorithm, "attackMinNotes": "\(attackMinNotes)"]
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

    public var params: Params
    public init(params: Params = Params()) { self.params = params }

    public func group(notes allNotes: [MidiNote], grid: BeatGrid, durationUs: Int64, key: KeySignature?,
                      excludeInstruments: Set<String> = ["drums", "voice"]) -> [Group] {
        let notes = allNotes.filter { !excludeInstruments.contains($0.instrument) && $0.endUs > $0.startUs }
            .sorted { $0.startUs < $1.startUs }
        guard !notes.isEmpty, grid.bpm > 0 else { return [] }
        let boundaries = cellBoundaries(notes: notes, grid: grid, durationUs: durationUs)
        guard boundaries.count >= 2 else { return [] }
        let cells = (0..<(boundaries.count - 1)).map { cellProfile(notes: notes, start: boundaries[$0], end: boundaries[$0 + 1], grid: grid) }

        // DP over cells; rests break segments. A segment costs the best single chord's
        // misfit summed cell by cell, so a rich chord can't swallow two neighbours.
        let n = cells.count
        let templates = TemplateMatcher.templates
        // prefix[c][t] = Σ misfit of template t over cells 0..<c
        var prefix = [[Double]](repeating: [Double](repeating: 0, count: templates.count), count: n + 1)
        for c in 0..<n {
            let total = cells[c].weights.reduce(0, +)
            for t in 0..<templates.count {
                let misfit: Double
                if cells[c].isRest || total <= 0 { misfit = 0 } else {
                    let p = cells[c].weights.map { $0 / total }
                    let s = TemplateMatcher.score(p: p, bassPc: cells[c].bassPc, root: templates[t].root, quality: templates[t].quality)
                    // Weighted by length in beats; a bass bonus can't make a fit better than perfect.
                    misfit = max(0, 1 - s) * cells[c].beats
                }
                prefix[c + 1][t] = prefix[c][t] + misfit
            }
        }
        var best = [Double](repeating: .infinity, count: n + 1)
        var back = [Int](repeating: -1, count: n + 1)
        best[0] = 0
        for j in 1...n {
            if cells[j - 1].isRest {
                best[j] = best[j - 1]; back[j] = -(j - 1) - 2 // marker: rest cell
                continue
            }
            var i = j - 1
            while i >= 0, j - i <= params.maxSegmentCells, !cells[i].isRest {
                var segment = Double.infinity
                for t in 0..<templates.count { segment = min(segment, prefix[j][t] - prefix[i][t]) }
                let cost = segment + params.changePenalty
                if best[i] + cost < best[j] { best[j] = best[i] + cost; back[j] = i }
                i -= 1
            }
        }
        var ranges: [(Int, Int)] = []
        var j = n
        while j > 0 {
            let b = back[j]
            if b <= -2 { j = -(b + 2); continue } // skip rest cell
            ranges.append((b, j)); j = b
        }
        ranges.reverse()

        return ranges.map { (i, j) in
            makeGroup(notes: notes, start: boundaries[i], end: boundaries[j], profile: mergedProfile(cells[i..<j]), grid: grid, key: key)
        }
    }

    // MARK: Cells

    struct CellProfile {
        var weights: [Double] // 12 pitch classes
        var bassPc: Int?
        var bassPitch: Int?
        var isRest: Bool
        var beats: Double = 1
    }

    func cellBoundaries(notes: [MidiNote], grid: BeatGrid, durationUs: Int64) -> [Int64] {
        let step = grid.beatUs * params.cellBeats
        var raw: [Int64] = [0]
        var k = 1.0
        let firstBeat = grid.beatTimes(durationUs: durationUs).first ?? 0
        if firstBeat > 0 { raw.append(firstBeat) }
        while true {
            let t = firstBeat + Int64((k * step).rounded())
            if t >= durationUs { break }
            raw.append(t); k += 1
        }
        raw.append(durationUs)
        raw = Array(Set(raw)).sorted()
        // Onset clusters (≥2 notes within clusterUs) that land shortly before a boundary
        // and sustain across it move that boundary to the actual onset.
        let clusters = onsetClusters(notes)
        let window = Int64(grid.beatUs * params.anticipationBeats)
        var out = raw
        for idx in 1..<(out.count - 1) {
            let b = out[idx]
            if let c = clusters.last(where: { $0.time < b && $0.time >= b - window && $0.time > out[idx - 1] }),
               c.sustainEnd > b + Int64(grid.beatUs * 0.25) {
                // Only if nothing else starts between the cluster and the beat.
                out[idx] = c.time
            }
        }
        // Block attacks (≥3 notes struck together) are boundaries wherever they fall, so
        // fast passing chords between beats (e.g. chromatic A → A♭ → G planing on eighths)
        // get their own cells. One near a beat replaces that beat instead of adding a sliver.
        let snap = Int64(grid.beatUs * params.attackSnapBeats)
        for c in clusters where c.count >= params.attackMinNotes && c.time > 0 && c.time < durationUs {
            if let j = out.firstIndex(where: { abs($0 - c.time) <= snap }) {
                if j > 0 && j < out.count - 1 { out[j] = c.time }
            } else {
                out.append(c.time)
            }
        }
        out = Array(Set(out)).sorted()
        // Drop slivers shorter than the cluster window.
        var cleaned: [Int64] = []
        for t in out { if let last = cleaned.last, t - last < params.clusterUs, t != out.last { continue }; cleaned.append(t) }
        if cleaned.last != durationUs { cleaned[cleaned.count - 1] = durationUs }
        return cleaned
    }

    struct Cluster { var time: Int64; var count: Int; var sustainEnd: Int64 }

    func onsetClusters(_ notes: [MidiNote]) -> [Cluster] {
        var out: [Cluster] = []
        var i = 0
        while i < notes.count {
            var j = i + 1
            while j < notes.count, notes[j].startUs - notes[i].startUs <= params.clusterUs { j += 1 }
            if j - i >= 2 {
                let end = notes[i..<j].map(\.endUs).sorted()[ (j - i) / 2 ]
                out.append(Cluster(time: notes[i].startUs, count: j - i, sustainEnd: end))
            }
            i = j
        }
        return out
    }

    func cellProfile(notes: [MidiNote], start: Int64, end: Int64, grid: BeatGrid) -> CellProfile {
        var w = [Double](repeating: 0, count: 12)
        let len = Double(max(end - start, 1))
        let overlapping = notes.filter { $0.startUs < end && $0.endUs > start }
        // Sustained bass: lowest pitch that covers at least 30% of the cell.
        let bass = overlapping.filter { Double(min($0.endUs, end) - max($0.startUs, start)) >= 0.3 * len }
            .min { $0.pitch < $1.pitch }
        for n in overlapping {
            var weight = Double(min(n.endUs, end) - max(n.startUs, start)) / len
            if n.startUs >= start, n.startUs - start <= params.clusterUs { weight *= params.onsetWeight }
            let beats = Double(n.durationUs) / grid.beatUs
            let qPos = grid.q(atUs: n.startUs)
            let offbeat = abs(qPos - qPos.rounded()) > 0.1
            if beats < params.shortNoteBeats, offbeat { weight *= params.shortOffbeatWeight }
            if let bass, n.id == bass.id { weight *= params.bassWeight }
            w[Pitch.pc(n.pitch)] += weight
        }
        let total = w.reduce(0, +)
        return CellProfile(weights: w, bassPc: bass.map { Pitch.pc($0.pitch) }, bassPitch: bass?.pitch,
                           isRest: total < params.restThreshold, beats: len / grid.beatUs)
    }

    func mergedProfile(_ cells: ArraySlice<CellProfile>) -> CellProfile {
        var w = [Double](repeating: 0, count: 12)
        var bassVotes: [Int: Double] = [:]
        var lowest: Int?
        for c in cells {
            for i in 0..<12 { w[i] += c.weights[i] }
            if let b = c.bassPc { bassVotes[b, default: 0] += 1 }
            if let p = c.bassPitch { lowest = min(lowest ?? p, p) }
        }
        let bass = bassVotes.max { $0.value < $1.value }?.key
        return CellProfile(weights: w, bassPc: bass, bassPitch: lowest, isRest: false)
    }

    // MARK: Events

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

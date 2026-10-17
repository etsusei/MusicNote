import Foundation

/// Material sources and editing rules for the Playground. Every insert is a
/// snapshot: editing blocks never touches notes, MIDI or other blocks.
public enum PlaygroundOps {
    public struct SourceContext: Sendable {
        public var analysisId: UUID
        public var harmonyRevision: Int
        public var timing: TimingConfirmation
        public var notes: [MidiNote]
        public var segmentDurationUs: Int64
        public init(analysisId: UUID, harmonyRevision: Int, timing: TimingConfirmation, notes: [MidiNote], segmentDurationUs: Int64) {
            self.analysisId = analysisId; self.harmonyRevision = harmonyRevision; self.timing = timing
            self.notes = notes; self.segmentDurationUs = segmentDurationUs
        }
    }

    public enum ImportError: Error, LocalizedError {
        case outOfRange(lowest: Int, highest: Int)
        public var errorDescription: String? {
            switch self {
            case .outOfRange(let lo, let hi): "移调后音高超出 MIDI 0–127（\(lo)…\(hi)），请整体移八度或取消"
            }
        }
    }

    /// Semitone shift from the source tonic to the target tonic, nearest direction.
    public static func transposition(from: KeySignature, to: KeySignature) -> Int {
        var d = Pitch.pc(to.tonic - from.tonic)
        if d > 6 { d -= 12 }
        return d
    }

    /// One block per event, positioned relative to the first event, keeping gaps.
    /// Notes sustained across events appear once (in the first block that contains them).
    public static func blocks(events: [ChordEvent], context: SourceContext, kind: String, voicing: VoicingMode,
                              target: KeySignature, octaveShift: Int = 0) throws -> [ChordBlock] {
        guard let first = events.first else { return [] }
        let grid = context.timing.grid
        let semis = transposition(from: context.timing.key, to: target) + octaveShift * 12
        let byId = Dictionary(uniqueKeysWithValues: context.notes.map { ($0.id, $0) })
        var used = Set<UUID>()
        let originQ = grid.q(atUs: first.startUs)
        var out: [ChordBlock] = []
        for e in events {
            let q0 = grid.q(atUs: e.startUs), q1 = grid.q(atUs: e.endUs)
            var notes: [BlockNote] = []
            for id in e.noteIds where !used.contains(id) {
                guard let n = byId[id], !e.excludedNoteIds.contains(id) || true else { continue }
                used.insert(id)
                let ns = grid.q(atUs: n.startUs) - q0
                notes.append(BlockNote(pitch: n.pitch + semis, velocity: n.velocity, startQ: ns,
                                       durationQ: Double(n.durationUs) / grid.beatUs, sourceNoteId: n.id))
            }
            let symbol = e.symbol.map { ChordSymbol.transpose($0, by: semis, key: target) } ?? "?"
            var block = ChordBlock(startQ: q0 - originQ, durationQ: max(0.25, q1 - q0), symbol: symbol, voicingMode: voicing,
                                   originalNotes: notes, originalDurationQ: max(0.25, q1 - q0), transposeSemitones: semis,
                                   source: BlockSource(kind: kind, analysisId: context.analysisId, eventId: e.id,
                                                       harmonyRevision: context.harmonyRevision, sourceKey: context.timing.key,
                                                       sourceBpm: context.timing.bpm, label: e.symbol ?? "?"))
            block.octaveShift = octaveShift
            out.append(block)
        }
        try checkRange(out)
        return out
    }

    /// Skeleton: each backbone block runs to the next backbone start; the first keeps
    /// the original gap, the last runs to the end of the original segment. Marked simplified.
    public static func skeletonBlocks(backbone: [String], events: [ChordEvent], context: SourceContext, voicing: VoicingMode,
                                      target: KeySignature, octaveShift: Int = 0) throws -> [ChordBlock] {
        let byId = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let chosen = backbone.compactMap { byId[$0] }
        guard let firstEvent = events.first, !chosen.isEmpty else { return [] }
        var blocks = try Self.blocks(events: chosen, context: context, kind: "skeleton", voicing: voicing, target: target, octaveShift: octaveShift)
        let grid = context.timing.grid
        let originQ = grid.q(atUs: firstEvent.startUs)
        let endQ = grid.q(atUs: max(events.last!.endUs, min(context.segmentDurationUs, events.last!.endUs)))
        for i in blocks.indices {
            blocks[i].startQ = grid.q(atUs: chosen[i].startUs) - originQ
            let nextQ = i + 1 < blocks.count ? grid.q(atUs: chosen[i + 1].startUs) - originQ : endQ - originQ
            let newDur = max(0.25, nextQ - blocks[i].startQ)
            // Sustained notes that reached the original event end extend to the new end.
            let oldDur = blocks[i].originalDurationQ
            blocks[i].originalNotes = blocks[i].originalNotes.map { n in
                var n = n
                if n.startQ + n.durationQ >= oldDur - 0.05 { n.durationQ = max(n.durationQ, newDur - n.startQ) }
                return n
            }
            blocks[i].durationQ = newDur
            blocks[i].originalDurationQ = newDur
            blocks[i].simplified = true
        }
        return blocks
    }

    public static func manualBlock(rootPc: Int, suffix: String, target: KeySignature, durationQ: Double) -> ChordBlock? {
        let symbol = ChordSymbol.make(root: rootPc, suffix: suffix, bass: nil, key: target)
        guard let pitches = StandardVoicing.pitches(symbol: symbol) else { return nil }
        let notes = pitches.map { BlockNote(pitch: $0, velocity: 90, startQ: 0, durationQ: durationQ, sourceNoteId: nil) }
        return ChordBlock(startQ: 0, durationQ: durationQ, symbol: symbol, voicingMode: .standard, originalNotes: notes,
                          originalDurationQ: durationQ, source: BlockSource(kind: "manual", label: symbol))
    }

    public static func collectionBlocks(_ items: [CollectionItem], target: KeySignature, sourceKeys: [UUID: KeySignature]) throws -> [ChordBlock] {
        var q = 0.0
        var out: [ChordBlock] = []
        for it in items {
            let semis = sourceKeys[it.analysisId].map { transposition(from: $0, to: target) } ?? 0
            let dur = max(0.25, it.notes.map { $0.startQ + $0.durationQ }.max() ?? 1)
            let notes = it.notes.map { var n = $0; n.pitch += semis; return n }
            out.append(ChordBlock(startQ: q, durationQ: dur, symbol: ChordSymbol.transpose(it.symbol, by: semis, key: target),
                                  voicingMode: .original, originalNotes: notes, originalDurationQ: dur, transposeSemitones: semis,
                                  source: BlockSource(kind: "collection", analysisId: it.analysisId, eventId: it.eventId,
                                                      harmonyRevision: it.harmonyRevision, sourceKey: sourceKeys[it.analysisId], label: it.symbol)))
            q += dur
        }
        try checkRange(out)
        return out
    }

    static func checkRange(_ blocks: [ChordBlock]) throws {
        let pitches = blocks.flatMap { $0.originalNotes.map(\.pitch) }
        if let lo = pitches.min(), let hi = pitches.max(), lo < 0 || hi > 127 { throw ImportError.outOfRange(lowest: lo, highest: hi) }
    }

    /// Notes a block sounds, at its current length. Dragging an edge scales inner timing.
    public static func sounding(_ b: ChordBlock) -> [BlockNote] {
        if b.voicingMode == .standard, let pitches = StandardVoicing.pitches(symbol: b.symbol) {
            return pitches.map { BlockNote(pitch: $0 + b.octaveShift * 12, velocity: 90, startQ: 0, durationQ: b.durationQ, sourceNoteId: nil) }
        }
        let factor = b.originalDurationQ > 0 ? b.durationQ / b.originalDurationQ : 1
        return b.originalNotes.map { n in
            BlockNote(pitch: n.pitch, velocity: n.velocity, startQ: n.startQ * factor, durationQ: max(0.01, n.durationQ * factor), sourceNoteId: n.sourceNoteId)
        }
    }

    public static func sectionStartQ(_ project: PlaygroundProject, index: Int) -> Double {
        project.sections.prefix(index).reduce(0) { $0 + Double($1.barCount) * project.meter.quarterBeatsPerBar }
    }

    public static func sectionLengthQ(_ project: PlaygroundProject, _ s: PlaygroundSection) -> Double {
        Double(s.barCount) * project.meter.quarterBeatsPerBar
    }

    /// Overlapping blocks on the single chord lane.
    public static func conflicts(in section: PlaygroundSection) -> [(UUID, UUID)] {
        let b = section.blocks.sorted { $0.startQ < $1.startQ }
        var out: [(UUID, UUID)] = []
        for i in b.indices { for j in (i + 1)..<b.count where b[j].startQ < b[i].endQ - 1e-6 { out.append((b[i].id, b[j].id)) } }
        return out
    }

    public struct Problem: Hashable, Sendable { public var message: String }

    public static func problems(_ project: PlaygroundProject) -> [Problem] {
        var out: [Problem] = []
        for (i, s) in project.sections.enumerated() {
            let len = sectionLengthQ(project, s)
            if !conflicts(in: s).isEmpty { out.append(Problem(message: "「\(s.name)」有重叠的和弦块")) }
            for b in s.blocks {
                if b.endQ > len + 1e-6 { out.append(Problem(message: "「\(s.name)」的 \(b.symbol) 超出乐段末尾")) }
                for n in sounding(b) {
                    if n.pitch < 0 || n.pitch > 127 { out.append(Problem(message: "「\(s.name)」的 \(b.symbol) 有超出 MIDI 音域的音")) ; break }
                    if n.durationQ <= 0 { out.append(Problem(message: "「\(s.name)」的 \(b.symbol) 有零时长音符")); break }
                }
            }
            _ = i
        }
        return out
    }

    /// Absolute notes (in Q) for the given range of sections.
    public static func flatten(_ project: PlaygroundProject, sections: Range<Int>? = nil) -> [(pitch: Int, velocity: Int, startQ: Double, durationQ: Double)] {
        var out: [(Int, Int, Double, Double)] = []
        let range = sections ?? 0..<project.sections.count
        let base = sectionStartQ(project, index: range.lowerBound)
        for i in range {
            let s0 = sectionStartQ(project, index: i) - base
            for b in project.sections[i].blocks {
                for n in sounding(b) where (0...127).contains(n.pitch) {
                    out.append((n.pitch, n.velocity, s0 + b.startQ + n.startQ, n.durationQ))
                }
            }
        }
        return out.sorted { $0.2 < $1.2 }.map { (pitch: $0.0, velocity: $0.1, startQ: $0.2, durationQ: $0.3) }
    }

    public static func exportMidi(_ project: PlaygroundProject) -> Data {
        var w = MidiFileWriter(bpm: project.bpm, meter: project.meter, key: project.key)
        w.trackName = project.title
        w.markers = project.sections.enumerated().map { (MidiTicks.ticks(q: sectionStartQ(project, index: $0.offset)), $0.element.name) }
        let notes = flatten(project).map {
            MidiFileWriter.Note(pitch: $0.pitch, velocity: $0.velocity, startTick: MidiTicks.ticks(q: $0.startQ),
                                durationTicks: max(1, MidiTicks.ticks(q: $0.startQ + $0.durationQ) - MidiTicks.ticks(q: $0.startQ)))
        }
        return w.data(notes: notes)
    }

    /// First free start in a section at or after `from`, or nil if the material doesn't fit.
    public static func freeStart(in section: PlaygroundSection, length: Double, sectionLength: Double, from: Double = 0) -> Double? {
        let end = section.blocks.map(\.endQ).max() ?? 0
        let start = max(from, end)
        return start + length <= sectionLength + 1e-6 ? start : nil
    }
}

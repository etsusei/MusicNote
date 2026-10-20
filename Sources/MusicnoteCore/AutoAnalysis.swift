import Foundation

// Evidence and run records for model-driven ("自主") analysis. Every source is kept side by
// side with its provenance; nothing here overwrites the user's MIDI, notes or tags.

public struct EvidenceNote: Codable, Hashable, Sendable {
    public var pitch: Int
    public var startUs: Int64
    public var endUs: Int64
    public var velocity: Int
    public var instrument: String
    public init(pitch: Int, startUs: Int64, endUs: Int64, velocity: Int, instrument: String) {
        self.pitch = pitch; self.startUs = startUs; self.endUs = endUs; self.velocity = velocity; self.instrument = instrument
    }
}

/// One transcription run (MuScriptor or MT3) of one source: all pitched instruments of the selected stem, or the original minus drums and voice.
public struct TranscriptionEvidence: Record {
    public static let kind = "evidence.transcription"
    public var id: UUID
    public var analysisId: UUID
    public var trimRevision: Int
    public var engine: String // muscriptor / mt3
    public var source: String // stem (selected stem; "piano" in older records) / original
    public var params: [String: String]
    public var notes: [EvidenceNote]
    public var dropped: [String: Int]
    public var seconds: Double
    public var createdAt: Date
    public init(analysisId: UUID, trimRevision: Int, engine: String, source: String, params: [String: String],
                notes: [EvidenceNote], dropped: [String: Int], seconds: Double) {
        id = UUID(); self.analysisId = analysisId; self.trimRevision = trimRevision; self.engine = engine
        self.source = source; self.params = params; self.notes = notes; self.dropped = dropped
        self.seconds = seconds; createdAt = Date()
    }
    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { createdAt.timeIntervalSince1970 }
}

public struct LogicChordEvent: Codable, Hashable, Sendable {
    public var label: String // native, e.g. "Fm(7)"
    public var symbol: String? // converted, e.g. "Fm7"
    public var startUs: Int64
    public var endUs: Int64 // derived from the next event
    public init(label: String, symbol: String?, startUs: Int64, endUs: Int64) {
        self.label = label; self.symbol = symbol; self.startUs = startUs; self.endUs = endUs
    }
}

/// Logic Chord ID candidates for one source and beat grid.
public struct ChordEvidence: Record {
    public static let kind = "evidence.logic"
    public var id: UUID
    public var analysisId: UUID
    public var trimRevision: Int
    public var timingRevision: Int
    public var source: String
    public var grid: String // quarter / eighth
    public var events: [LogicChordEvent]
    public var logicVersion: String
    public var seconds: Double
    public var createdAt: Date
    public init(analysisId: UUID, trimRevision: Int, timingRevision: Int, source: String, grid: String,
                events: [LogicChordEvent], logicVersion: String, seconds: Double) {
        id = UUID(); self.analysisId = analysisId; self.trimRevision = trimRevision; self.timingRevision = timingRevision
        self.source = source; self.grid = grid; self.events = events; self.logicVersion = logicVersion
        self.seconds = seconds; createdAt = Date()
    }
    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { createdAt.timeIntervalSince1970 }
}

public struct AutoStep: Codable, Hashable, Sendable {
    public var time: Date
    public var tool: String
    public var arguments: String
    public var summary: String
    public var ok: Bool
    public var seconds: Double
    public init(tool: String, arguments: String, summary: String, ok: Bool, seconds: Double) {
        time = Date(); self.tool = tool; self.arguments = arguments; self.summary = summary; self.ok = ok; self.seconds = seconds
    }
}

/// Audit record of one targeted review (question → evidence → decision), not private reasoning.
public struct ReviewRecord: Codable, Hashable, Sendable {
    public var question: String
    public var expectedEvidence: String
    public var operation: String
    public var observedEvidence: String
    public var decision: String
    public var stopReason: String
    public init(question: String, expectedEvidence: String, operation: String, observedEvidence: String, decision: String, stopReason: String) {
        self.question = question; self.expectedEvidence = expectedEvidence; self.operation = operation
        self.observedEvidence = observedEvidence; self.decision = decision; self.stopReason = stopReason
    }
}

public struct AutoRun: Record {
    public static let kind = "autorun"
    public var id: UUID
    public var analysisId: UUID
    public var trimRevision: Int
    public var status: JobStatus
    public var provider: String
    public var model: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var steps: [AutoStep]
    public var reviews: [ReviewRecord]
    public var toolCalls: Int
    public var maxToolCalls: Int
    public var maxSeconds: Double
    /// Older runs saved straight into the harmony list; this is that revision number.
    public var harmonyRevision: Int?
    /// The submitted result, waiting for the user to adopt it. Adopting copies it into a new
    /// current harmony revision; until then the chords below stay as they were.
    public var proposal: HarmonyRevision?
    /// Hand edits to the proposal not yet saved. When a rename rewrote notes with the standard
    /// voicing, the edited notes wait here and become a MIDI revision only on save.
    public var draftNotes: [MidiNote]?
    public var edited: Bool?
    public var finalMessage: String
    public var error: String?
    public init(analysisId: UUID, trimRevision: Int, provider: String, model: String, maxToolCalls: Int, maxSeconds: Double) {
        id = UUID(); self.analysisId = analysisId; self.trimRevision = trimRevision; status = .running
        self.provider = provider; self.model = model; startedAt = Date(); steps = []; reviews = []
        toolCalls = 0; self.maxToolCalls = maxToolCalls; self.maxSeconds = maxSeconds; finalMessage = ""
    }
    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { startedAt.timeIntervalSince1970 }

    public var submitted: Bool { proposal != nil || harmonyRevision != nil }

    /// The result to show and adopt: the stored proposal, or (older runs) the revision it saved.
    public func result(in store: Store) -> HarmonyRevision? {
        if let proposal { return proposal }
        guard let n = harmonyRevision else { return nil }
        return store.all(HarmonyRevision.self, owner: analysisId).first { $0.revision == n && $0.auto?.runId == id }
    }
}

public enum AutoAdoption {
    /// Whether the current harmony is this run's result (possibly edited since adopting).
    public static func isAdopted(_ run: AutoRun, current: HarmonyRevision?) -> Bool { current?.auto?.runId == run.id }

    /// Saved and not edited since.
    public static func isSaved(_ run: AutoRun, current: HarmonyRevision?) -> Bool { isAdopted(run, current: current) && run.edited != true }

    /// Copies the run's result into a new current harmony revision; nothing else is touched.
    /// Degrees follow the key set now, in case it changed since the run.
    @discardableResult
    public static func adopt(_ run: AutoRun, store: Store) throws -> HarmonyRevision {
        guard var rev = run.result(in: store), var item = store.fetch(AnalysisItem.self, id: run.analysisId) else {
            throw WorkerError(code: "SOURCE_MISSING", message: "找不到这次分析的结果")
        }
        guard item.trimRevision == run.trimRevision else {
            throw WorkerError(code: "REVISION_CONFLICT", message: "选区在分析之后改过，这个结果不再对应当前选区", retryable: false)
        }
        let latest = store.all(HarmonyRevision.self, owner: run.analysisId).map(\.revision).max() ?? 0
        rev.id = UUID()
        rev.revision = latest + 1
        rev.createdAt = Date()
        if let key = item.timing?.key {
            rev.key = key
            for i in rev.events.indices { rev.events[i].degree = rev.events[i].symbol.flatMap { Degrees.label(symbol: $0, key: key) } }
        }
        rev.params["adoptedFrom"] = run.id.uuidString
        try store.save(rev)
        item.harmonyRevision = rev.revision
        item.updatedAt = Date()
        try store.save(item)
        return rev
    }
}

public struct AutoChordInfo: Codable, Hashable, Sendable {
    public var role: String // backbone / passing / connecting / substitute / color
    public var reason: String
    public var confidence: String // high / medium / low
    public init(role: String, reason: String, confidence: String) { self.role = role; self.reason = reason; self.confidence = confidence }
    public var roleDisplay: String {
        switch role {
        case "backbone": "主干"
        case "passing": "经过"
        case "connecting": "连接"
        case "substitute": "替代"
        case "color": "色彩"
        default: role
        }
    }
}

public struct ConfirmPoint: Codable, Hashable, Sendable {
    public var startUs: Int64
    public var eventId: String?
    public var question: String
    public init(startUs: Int64, eventId: String?, question: String) { self.startUs = startUs; self.eventId = eventId; self.question = question }
}

/// What the agent concluded for a harmony revision it produced.
public struct AutoHarmony: Codable, Hashable, Sendable {
    public var runId: UUID
    public var summary: String
    public var chordInfo: [String: AutoChordInfo]
    public var toConfirm: [ConfirmPoint]
    public var key: KeySuggestion?
    public var sources: [String]
    /// The model's view that the bar lines are off: move them by this many beats (halves allowed).
    public var barShiftBeats: Double?
    public var barReason: String?
    public init(runId: UUID, summary: String, chordInfo: [String: AutoChordInfo], toConfirm: [ConfirmPoint], key: KeySuggestion?, sources: [String]) {
        self.runId = runId; self.summary = summary; self.chordInfo = chordInfo; self.toConfirm = toConfirm; self.key = key; self.sources = sources
    }
}

// MARK: - Logic labels

public enum LogicChordLabel {
    /// "Fm(7)" → "Fm7", "Csus4(7)" → "C7sus4", "G(7)/B" → "G7/B", "Ab(maj7)" → "A♭maj7",
    /// "Bdim(7)" → "Bdim7". Unknown shapes return nil (the native label is still kept).
    public static func symbol(_ label: String) -> String? {
        var s = label.trimmingCharacters(in: .whitespaces)
        guard s != "nochord", let first = s.first, "ABCDEFG".contains(first) else { return nil }
        var bass = ""
        if let slash = s.lastIndex(of: "/") { bass = String(s[slash...]); s = String(s[..<slash]) }
        var idx = s.index(after: s.startIndex)
        if idx < s.endIndex, "#b".contains(s[idx]) { idx = s.index(after: idx) }
        let root = String(s[..<idx])
        var rest = String(s[idx...])
        var ext = ""
        if let open = rest.lastIndex(of: "("), rest.hasSuffix(")"), !rest.hasPrefix("(b5)") || rest.count > 4 {
            ext = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            rest = String(rest[..<open])
        }
        let quality: String
        switch (rest, ext) {
        case ("", ""): quality = ""
        case ("", "7"): quality = "7"
        case ("", "maj7"): quality = "maj7"
        case ("", "6"): quality = "6"
        case ("m", ""): quality = "m"
        case ("m", "7"): quality = "m7"
        case ("m", "maj7"): quality = "mMaj7"
        case ("m", "6"): quality = "m6"
        case ("aug", ""): quality = "aug"
        case ("aug", "7"): quality = "aug7"
        case ("dim", ""): quality = "dim"
        case ("dim", "7"): quality = "dim7"
        case ("m7b5", ""): quality = "m7♭5"
        case ("sus2", ""): quality = "sus2"
        case ("sus2", "7"): quality = "7(sus2)"
        case ("sus2", "maj7"): quality = "maj7(sus2)"
        case ("sus4", ""): quality = "sus4"
        case ("sus4", "7"): quality = "7sus4"
        case ("5", ""): quality = "5"
        case ("5", "7"): quality = "7(omit3)"
        case ("5", "maj7"): quality = "maj7(omit3)"
        case ("(b5)", ""): quality = "(b5)"
        case ("(b5)", "7"): quality = "7(b5)"
        default: return nil
        }
        let out = Pitch.normalizeName(root) + quality + (bass.isEmpty ? "" : "/" + Pitch.normalizeName(String(bass.dropFirst())))
        return ChordSymbol.parse(out) != nil ? out : nil
    }
}

// MARK: - Aligning two transcriptions

public enum TranscriptionAligner {
    public struct MergedNote: Codable, Hashable, Sendable {
        public var pitch: Int
        public var startUs: Int64
        public var endUs: Int64
        public var support: String // both / muscriptor / mt3
    }

    public struct Result: Sendable {
        public var offsetUs: Int64 // add to B to line it up with A
        public var matched: Int
        public var onlyA: Int
        public var onlyB: Int
        public var merged: [MergedNote]
        /// Matched notes / all distinct notes.
        public var agreement: Double { let t = matched + onlyA + onlyB; return t == 0 ? 0 : Double(matched) / Double(t) }
    }

    /// Same pitch, onsets within `toleranceUs` after removing the global offset (estimated from
    /// same-pitch onset differences). A is the timing reference.
    public static func align(_ a: [EvidenceNote], _ b: [EvidenceNote], labels: (String, String), toleranceUs: Int64 = 70_000) -> Result {
        var deltas: [Int64: Int] = [:]
        let bByPitch = Dictionary(grouping: b.indices, by: { b[$0].pitch })
        for n in a {
            for j in bByPitch[n.pitch] ?? [] {
                let d = b[j].startUs - n.startUs
                if abs(d) <= 200_000 { deltas[(d / 10_000), default: 0] += 1 }
            }
        }
        let bin = deltas.max { $0.value < $1.value }?.key ?? 0
        let offset = -bin * 10_000
        var usedB = Set<Int>()
        var merged: [MergedNote] = []
        var matched = 0
        for n in a.sorted(by: { $0.startUs < $1.startUs }) {
            let cands = (bByPitch[n.pitch] ?? []).filter { !usedB.contains($0) && abs(b[$0].startUs + offset - n.startUs) <= toleranceUs }
            if let j = cands.min(by: { abs(b[$0].startUs + offset - n.startUs) < abs(b[$1].startUs + offset - n.startUs) }) {
                usedB.insert(j)
                matched += 1
                merged.append(MergedNote(pitch: n.pitch, startUs: n.startUs, endUs: max(n.endUs, b[j].endUs + offset), support: "both"))
            } else {
                merged.append(MergedNote(pitch: n.pitch, startUs: n.startUs, endUs: n.endUs, support: labels.0))
            }
        }
        for j in b.indices where !usedB.contains(j) {
            merged.append(MergedNote(pitch: b[j].pitch, startUs: max(0, b[j].startUs + offset), endUs: max(0, b[j].endUs + offset), support: labels.1))
        }
        merged.sort { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
        return Result(offsetUs: offset, matched: matched, onlyA: a.count - matched, onlyB: b.count - usedB.count, merged: merged)
    }
}

// MARK: - Bar-by-bar evidence for the model

public enum BarEvidence {
    public struct Sources {
        public var userMidi: [MidiNote]
        public var merged: [TranscriptionAligner.MergedNote]
        public var logic: [LogicChordEvent]
        public var current: [ChordEvent]
        public init(userMidi: [MidiNote], merged: [TranscriptionAligner.MergedNote], logic: [LogicChordEvent], current: [ChordEvent]) {
            self.userMidi = userMidi; self.merged = merged; self.logic = logic; self.current = current
        }
    }

    public static func barCount(grid: BeatGrid, durationUs: Int64) -> Int {
        let perBar = grid.meter.quarterBeatsPerBar
        return max(1, Int(ceil((grid.q(atUs: durationUs) - grid.barAnchorQ) / perBar)))
    }

    public static func barStartUs(_ bar: Int, grid: BeatGrid) -> Int64 {
        grid.us(atQ: grid.barAnchorQ + Double(bar - 1) * grid.meter.quarterBeatsPerBar)
    }

    /// Bar (1-based) and beat (1-based, halves) of a time.
    public static func position(_ us: Int64, grid: BeatGrid) -> (bar: Int, beat: Double) {
        let perBar = grid.meter.quarterBeatsPerBar
        let q = ((grid.q(atUs: us) - grid.barAnchorQ) * 2).rounded() / 2
        // floor keeps beat in [1, perBar + 1): the last half beat is "4.5", not the next bar's "0.5".
        let bar = Int(floor(q / perBar))
        let beat = q - Double(bar) * perBar + 1
        return (bar + 1, beat)
    }

    /// Where a chord reads in the bar: one struck up to an eighth before a beat and held through
    /// it is an anticipation of that beat (pushed comping, common in dance and pop), so it is
    /// shown on the beat. The stored time is unchanged; this is only how it is read.
    public static func readingStart(_ startUs: Int64, endUs: Int64, grid g: BeatGrid) -> (us: Int64, pushed: Bool) {
        let q = g.q(atUs: startUs)
        let next = q.rounded(.up)
        let early = next - q
        guard early > 0.1, early <= 0.55 else { return (startUs, false) }
        let beatUs = g.us(atQ: next)
        // Held at least a beat past the beat it anticipates.
        guard Double(endUs - beatUs) >= g.beatUs * 0.9 else { return (startUs, false) }
        return (beatUs, true)
    }

    /// Chords as read in the bars, in time order: anticipations start on the beat they
    /// anticipate (when `foldPushes`), and a chord touching the next runs to that one's reading
    /// start. The bars draw these spans and play-along sounds them, so what plays is what shows.
    public static func readingSpans(_ events: [ChordEvent], grid g: BeatGrid, foldPushes: Bool = true)
        -> [(ev: ChordEvent, s: Int64, e: Int64, pushed: Bool)] {
        let evs = events.sorted { $0.startUs < $1.startUs }
        let starts = evs.map { foldPushes ? readingStart($0, grid: g) : (us: $0.startUs, pushed: false) }
        return evs.indices.map { i in
            let touching = i + 1 < evs.count && abs(evs[i].endUs - evs[i + 1].startUs) <= 2_000
            return (evs[i], starts[i].us, touching ? starts[i + 1].us : evs[i].endUs, starts[i].pushed)
        }
    }

    /// A chord's reading start; one whose timing was set by hand reads where it was put.
    public static func readingStart(_ ev: ChordEvent, grid g: BeatGrid) -> (us: Int64, pushed: Bool) {
        ev.timingSetByHand == true ? (ev.startUs, false) : readingStart(ev.startUs, endUs: ev.endUs, grid: g)
    }

    public static func usAt(bar: Int, beat: Double, grid: BeatGrid) -> Int64 {
        grid.us(atQ: grid.barAnchorQ + Double(bar - 1) * grid.meter.quarterBeatsPerBar + (beat - 1))
    }

    public static func beatText(_ b: Double) -> String { b == b.rounded() ? String(Int(b)) : String(format: "%.1f", b) }

    /// Compact text: per bar, the Logic candidates, then struck notes per eighth position for the
    /// user's corrected MIDI and for the two transcriptions (with which engine heard each note).
    public static func describe(bars: ClosedRange<Int>, grid: BeatGrid, durationUs: Int64, key: KeySignature?, sources: Sources) -> String {
        let flats = Pitch.prefersFlats(key)
        func name(_ p: Int) -> String { Pitch.noteName(p, flats: flats) }
        var lines: [String] = []
        for bar in bars {
            let s = barStartUs(bar, grid: grid), e = min(durationUs, barStartUs(bar + 1, grid: grid))
            guard e > 0, s < durationUs else { continue }
            lines.append(String(format: "第%d小节（%.2f–%.2fs）", bar, Double(max(0, s)) / 1e6, Double(e) / 1e6))
            let logic = sources.logic.filter { $0.startUs < e && $0.endUs > s }
                .map { "\(beatText(position($0.startUs, grid: grid).bar == bar ? position($0.startUs, grid: grid).beat : 1))拍 \($0.label)" }
            if !logic.isEmpty { lines.append("  Logic：" + logic.joined(separator: " | ")) }
            let cur = sources.current.filter { $0.startUs < e && $0.endUs > s }
                .map { "\(beatText(position($0.startUs, grid: grid).bar == bar ? position($0.startUs, grid: grid).beat : 1))拍 \($0.symbol ?? "?")\($0.manualOverride ? "（人工命名）" : "")" }
            if !cur.isEmpty { lines.append("  当前已保存和声：" + cur.joined(separator: " | ")) }
            func slots<T>(_ notes: [T], start: (T) -> Int64, label: (T) -> String) -> String {
                var bySlot: [Double: [String]] = [:]
                for n in notes where start(n) >= s - 30_000 && start(n) < e - 30_000 {
                    let p = position(start(n), grid: grid)
                    let beat = p.bar == bar ? p.beat : (p.bar < bar ? 1 : grid.meter.quarterBeatsPerBar + 0.5)
                    bySlot[beat, default: []].append(label(n))
                }
                return bySlot.keys.sorted().map { "\(beatText($0)): " + bySlot[$0]!.joined(separator: " ") }.joined(separator: " | ")
            }
            if !sources.userMidi.isEmpty {
                let t = slots(sources.userMidi.sorted { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }, start: \.startUs) { name($0.pitch) }
                if !t.isEmpty { lines.append("  人工校对MIDI：" + t) }
            }
            if !sources.merged.isEmpty {
                let t = slots(sources.merged, start: \.startUs) { n in
                    name(n.pitch) + (n.support == "both" ? "" : n.support == "mt3" ? "(仅MT3)" : "(仅MuS)")
                }
                if !t.isEmpty { lines.append("  双转录：" + t) }
                // Sustained notes entering the bar.
                let held = sources.merged.filter { $0.startUs < s - 30_000 && $0.endUs > s + Int64(grid.beatUs) }.map { name($0.pitch) }
                if !held.isEmpty { lines.append("  从上一小节延续：" + held.joined(separator: " ")) }
            }
        }
        return lines.joined(separator: "\n")
    }
}

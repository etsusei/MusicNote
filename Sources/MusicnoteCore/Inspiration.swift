import Foundation

/// A progression put together by dragging chords heard while studying (灵感进行). Each chord keeps
/// exactly the notes that sounded when it was clicked. Positions are in quarter beats (Q) from
/// bar 1, 4/4.
public struct InspirationChord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var symbol: String
    public var startQ: Double
    public var lengthQ: Double
    public var pitches: [Int]
    /// Where it was taken from ("Endlessly 第 3 小节"), for going back to listen.
    public var sourceLabel: String?
    public var sourceAnalysisId: UUID?

    public init(id: String = "c-" + UUID().uuidString.prefix(8).lowercased(), symbol: String, startQ: Double, lengthQ: Double, pitches: [Int],
                sourceLabel: String? = nil, sourceAnalysisId: UUID? = nil) {
        self.id = id; self.symbol = symbol; self.startQ = startQ; self.lengthQ = lengthQ; self.pitches = pitches
        self.sourceLabel = sourceLabel; self.sourceAnalysisId = sourceAnalysisId
    }

    public var endQ: Double { startQ + lengthQ }
}

public struct InspirationProgression: Record, Hashable {
    public static let kind = "inspiration"
    public var id: UUID
    public var title: String
    public var bars: Int
    public var bpm: Double
    public var chords: [InspirationChord]
    /// In 灵感集合 (the working draft in the floating window is not, until saved).
    public var inCollection: Bool
    /// Playback key: nil plays as captured.
    public var targetKey: KeySignature?
    public var smartTranspose: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(title: String = "", bars: Int = 4, bpm: Double = 90) {
        id = UUID(); self.title = title; self.bars = bars; self.bpm = bpm; chords = []; inCollection = false
        targetKey = nil; smartTranspose = true; createdAt = Date(); updatedAt = Date()
    }

    public var ownerId: UUID? { nil }
    public var sortKey: Double { updatedAt.timeIntervalSince1970 }
    public var lengthQ: Double { Double(bars) * 4 }

    /// "Cmaj9 – Am7 – Dm9 – G13" when untitled.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        let names = chords.sorted { $0.startQ < $1.startQ }.map(\.symbol)
        return names.isEmpty ? "空的灵感进行" : names.prefix(4).joined(separator: " – ") + (names.count > 4 ? " …" : "")
    }

    public var sourceLabels: [String] { Array(NSOrderedSet(array: chords.compactMap(\.sourceLabel)).array as? [String] ?? []) }
}

// MARK: - Editing (same rules as hand-editing a harmony)

public enum InspirationEdit {
    static let minLen = 0.5 // an eighth

    public static func snap(_ q: Double) -> Double { max(0, (q * 2).rounded() / 2) }
    public static func snapBar(_ q: Double) -> Double { max(0, (q / 4).rounded(.down) * 4) }

    /// Puts chord `id` at [start, end): others give up that time — covered ones vanish, one it
    /// lands inside is split, leftovers under an eighth are dropped. Clipped to the progression.
    public static func place(_ p: inout InspirationProgression, id: String, start: Double, end: Double) {
        guard let i = p.chords.firstIndex(where: { $0.id == id }) else { return }
        let a = min(snap(start), p.lengthQ - minLen), b = min(max(snap(end), a + minLen), p.lengthQ)
        var moved = p.chords[i]
        moved.startQ = a; moved.lengthQ = b - a
        var out: [InspirationChord] = []
        for (k, c) in p.chords.enumerated() where k != i {
            if c.endQ <= a || c.startQ >= b { out.append(c); continue }
            if c.startQ < a { var head = c; head.lengthQ = a - c.startQ; if head.lengthQ >= minLen - 1e-6 { out.append(head) } }
            if c.endQ > b {
                var tail = c; tail.startQ = b; tail.lengthQ = c.endQ - b
                if c.startQ < a { tail.id = c.id + "-" + UUID().uuidString.prefix(4).lowercased() }
                if tail.lengthQ >= minLen - 1e-6 { out.append(tail) }
            }
        }
        out.append(moved)
        p.chords = out.sorted { $0.startQ < $1.startQ }
    }

    /// Drops dragged chords (offsets relative to the drop point).
    public static func drop(_ p: inout InspirationProgression, _ chords: [InspirationChord], at q: Double) {
        for var c in chords {
            c.id = "c-" + UUID().uuidString.prefix(8).lowercased()
            let start = q + c.startQ
            guard start < p.lengthQ - 1e-6 else { continue }
            p.chords.append(c)
            place(&p, id: c.id, start: start, end: start + c.lengthQ)
        }
    }

    public static func move(_ p: inout InspirationProgression, id: String, toStart q: Double) {
        guard let c = p.chords.first(where: { $0.id == id }) else { return }
        let a = min(snap(q), p.lengthQ - c.lengthQ)
        place(&p, id: id, start: a, end: a + c.lengthQ)
    }

    /// Drags one edge; a neighbour touching it follows when this one shrinks.
    public static func resize(_ p: inout InspirationProgression, id: String, leftEdge: Bool, to q: Double) {
        guard let c = p.chords.first(where: { $0.id == id }) else { return }
        let x = snap(q)
        let neighbour = (leftEdge ? p.chords.first { $0.id != id && abs($0.endQ - c.startQ) < 1e-6 }
                                  : p.chords.first { $0.id != id && abs($0.startQ - c.endQ) < 1e-6 })?.id
        let shrinking = leftEdge ? x > c.startQ : x < c.endQ
        place(&p, id: id, start: leftEdge ? x : c.startQ, end: leftEdge ? c.endQ : x)
        if shrinking, let nid = neighbour, let k = p.chords.firstIndex(where: { $0.id == nid }), let me = p.chords.first(where: { $0.id == id }) {
            if leftEdge { p.chords[k].lengthQ = me.startQ - p.chords[k].startQ } else {
                let end = p.chords[k].endQ; p.chords[k].startQ = me.endQ; p.chords[k].lengthQ = end - me.endQ
            }
        }
    }

    public static func delete(_ p: inout InspirationProgression, id: String) { p.chords.removeAll { $0.id == id } }

    /// A typed chord sounds as its standard voicing.
    @discardableResult
    public static func add(_ p: inout InspirationProgression, symbol: String, start: Double, end: Double) -> String? {
        guard let pitches = StandardVoicing.pitches(symbol: symbol) else { return nil }
        let c = InspirationChord(symbol: symbol, startQ: start, lengthQ: end - start, pitches: pitches)
        p.chords.append(c)
        place(&p, id: c.id, start: start, end: end)
        return c.id
    }

    public static func rename(_ p: inout InspirationProgression, id: String, symbol: String) {
        guard let i = p.chords.firstIndex(where: { $0.id == id }), let pitches = StandardVoicing.pitches(symbol: symbol) else { return }
        p.chords[i].symbol = symbol
        p.chords[i].pitches = pitches
    }

    /// Changing the length keeps what fits.
    public static func setBars(_ p: inout InspirationProgression, _ n: Int) {
        p.bars = n
        p.chords = p.chords.compactMap { c in
            guard c.startQ < p.lengthQ - 1e-6 else { return nil }
            var c = c; c.lengthQ = min(c.lengthQ, p.lengthQ - c.startQ); return c
        }
    }
}

// MARK: - Transposition

public enum InspirationTranspose {
    /// The key the chords imply (as captured).
    public static func detectedKey(_ p: InspirationProgression) -> KeySignature? {
        let events = p.chords.sorted { $0.startQ < $1.startQ }.map { c in
            ChordEvent(id: c.id, order: 0, startUs: Int64(c.startQ * 500_000), endUs: Int64(c.endQ * 500_000), noteIds: [], noteRoles: [:],
                       texture: .block, excludedNoteIds: [], namingPitches: [], candidates: [], symbol: c.symbol,
                       namingSource: .user, manualOverride: true, degree: nil, bassPitch: nil)
        }
        return KeyEstimator.candidates(events: events, limit: 1).first?.key
    }

    /// Semitones from the detected key to the target. Smart: the shorter way round (≤ 6), so the
    /// sound stays near where it was; otherwise always upwards.
    public static func semitones(_ p: InspirationProgression) -> Int {
        guard let to = p.targetKey, let from = detectedKey(p) else { return 0 }
        return semitones(from: from, to: to, smart: p.smartTranspose)
    }

    public static func semitones(from: KeySignature, to: KeySignature, smart: Bool) -> Int {
        let up = ((to.tonic - from.tonic) % 12 + 12) % 12
        return smart && up > 6 ? up - 12 : up
    }

    /// One chord's notes moved by `n`; smart keeps the voicing intact but shifts whole octaves so
    /// the lowest note sits around C2–C3 and the top stays at or below C6.
    public static func pitches(_ c: InspirationChord, by n: Int, smart: Bool) -> [Int] {
        var ps = c.pitches.map { $0 + n }
        guard smart, let lo = ps.min(), let hi = ps.max() else { return ps }
        var shift = 0
        while lo + shift < 36 { shift += 12 }
        while hi + shift > 84 && lo + shift - 12 >= 36 { shift -= 12 }
        while lo + shift > 48 && hi + shift - 12 >= 48 { shift -= 12 }
        ps = ps.map { $0 + shift }
        return ps
    }

    /// Name in the target key's spelling.
    public static func symbol(_ c: InspirationChord, by n: Int, key: KeySignature?) -> String {
        n == 0 ? c.symbol : ChordSymbol.transpose(c.symbol, by: n, key: key)
    }
}

// MARK: - Drag payload

/// What a drag from the analysis carries: the chords as heard, with offsets and lengths in
/// quarter beats; `wholeBar` snaps the drop to a bar line.
public struct ChordDragPayload: Codable, Sendable {
    public var chords: [InspirationChord]
    public var wholeBar: Bool
    public var bpm: Double?

    public init(chords: [InspirationChord], wholeBar: Bool, bpm: Double?) { self.chords = chords; self.wholeBar = wholeBar; self.bpm = bpm }

    static let prefix = "musicnote-chords:"
    public var encoded: String { Self.prefix + (String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "") }
    public static func decode(_ s: String) -> ChordDragPayload? {
        guard s.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(ChordDragPayload.self, from: Data(s.dropFirst(prefix.count).utf8))
    }
    /// What lands in the progression: a single chord as one quarter note; a whole bar as it was.
    public var placed: [InspirationChord] {
        wholeBar ? chords : chords.map { var c = $0; c.startQ = 0; c.lengthQ = 1; return c }
    }

    public var lengthQ: Double { placed.map(\.endQ).max() ?? 1 }
}

// MARK: - For the chat (# 灵感进行)

public enum InspirationSnapshot {
    /// What the teacher gets for a # reference: the progression as it plays in its chosen key
    /// (names, degrees, voicings, positions), its speed, and where the chords came from.
    public static func object(_ p: InspirationProgression) -> [String: Any] {
        let detected = InspirationTranspose.detectedKey(p)
        let n = InspirationTranspose.semitones(p)
        let key = p.targetKey ?? detected
        let smart = p.targetKey != nil && p.smartTranspose
        let chords: [[String: Any]] = p.chords.sorted { $0.startQ < $1.startQ }.map { c in
            let sym = InspirationTranspose.symbol(c, by: n, key: p.targetKey)
            let bar = Int(c.startQ / 4) + 1
            let beat = c.startQ - Double(bar - 1) * 4 + 1
            var o: [String: Any] = [
                "position": "第 \(bar) 小节第 \(beat == beat.rounded() ? String(Int(beat)) : String(format: "%.1f", beat)) 拍",
                "lengthBeats": c.lengthQ, "symbol": sym,
                "voicing": InspirationTranspose.pitches(c, by: n, smart: smart).map { Pitch.noteName($0) }.joined(separator: " "),
            ]
            if let k = key, let d = Degrees.label(symbol: sym, key: k) { o["degree"] = d.display }
            if let src = c.sourceLabel { o["from"] = src }
            return o
        }
        var out: [String: Any] = ["title": p.displayTitle, "bars": p.bars, "bpm": p.bpm, "meter": "4/4", "chords": chords,
                                  "note": "用户从分析里拖出来拼的进行；每个和弦的 voicing 就是用户当时听到的。"]
        if let d = detected { out["detectedKey"] = d.display }
        if let t = p.targetKey { out["playKey"] = t.display + (n != 0 ? "（从原调移了 \(n > 0 ? "+" : "")\(n) 半音\(smart ? "，智能移调" : "")）" : "") }
        return out
    }
}

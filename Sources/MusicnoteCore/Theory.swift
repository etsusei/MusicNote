import Foundation

// MARK: - Pitch spelling

public enum Pitch {
    static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    public static func pc(_ pitch: Int) -> Int { ((pitch % 12) + 12) % 12 }

    /// Keys that conventionally use flats (major tonic or relative-major tonic).
    public static func prefersFlats(_ key: KeySignature?) -> Bool {
        guard let key else { return false }
        let majorTonic = key.mode == .major ? key.tonic : pc(key.tonic + 3)
        // F, B♭, E♭, A♭, D♭, G♭ majors.
        if [5, 10, 3, 8, 1, 6].contains(majorTonic) {
            // G♭ vs F♯: follow the user's spelling when it has a sharp.
            if majorTonic == 6, key.tonicName.contains("♯") || key.tonicName.contains("#") { return false }
            return true
        }
        return key.tonicName.contains("♭") || (key.tonicName.count == 2 && key.tonicName.hasSuffix("b"))
    }

    public static func name(pc: Int, flats: Bool) -> String { (flats ? flatNames : sharpNames)[self.pc(pc)] }
    public static func name(pc: Int, key: KeySignature?) -> String { name(pc: pc, flats: prefersFlats(key)) }

    public static func noteName(_ pitch: Int, flats: Bool = false) -> String {
        name(pc: pitch, flats: flats) + String(pitch / 12 - 1)
    }

    /// Parses "C", "E♭", "Eb", "F#", "f♯" into a pitch class.
    public static func parsePitchClass(_ s: String) -> Int? {
        var chars = Array(s.trimmingCharacters(in: .whitespaces))
        guard let first = chars.first?.uppercased(), let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][first] else { return nil }
        chars.removeFirst()
        var v = base
        for c in chars {
            switch c {
            case "#", "♯": v += 1
            case "b", "♭": v -= 1
            default: return nil
            }
        }
        return pc(v)
    }

    public static func normalizeName(_ s: String) -> String {
        s.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭", options: [], range: s.count > 1 ? s.index(after: s.startIndex)..<s.endIndex : nil)
    }
}

// MARK: - Chord qualities

public struct ChordQuality: Sendable {
    public let suffix: String // canonical display suffix
    public let intervals: [Int] // semitones from root, including root
    public let minorThird: Bool
    public let aliases: [String]
}

public enum ChordCatalog {
    public static let qualities: [ChordQuality] = [
        q("", [0, 4, 7], false, ["maj", "M", "major"]),
        q("m", [0, 3, 7], true, ["min", "mi", "-", "minor"]),
        q("dim", [0, 3, 6], true, ["°", "o"]),
        q("aug", [0, 4, 8], false, ["+", "#5", "♯5"]),
        q("sus2", [0, 2, 7], false, []),
        q("sus4", [0, 5, 7], false, ["sus"]),
        q("5", [0, 7], false, []),
        q("6", [0, 4, 7, 9], false, []),
        q("m6", [0, 3, 7, 9], true, ["-6", "min6"]),
        q("7", [0, 4, 7, 10], false, ["dom7"]),
        q("maj7", [0, 4, 7, 11], false, ["M7", "Δ", "△", "Δ7", "△7", "Maj7", "ma7"]),
        q("m7", [0, 3, 7, 10], true, ["-7", "min7", "mi7"]),
        q("mMaj7", [0, 3, 7, 11], true, ["mM7", "m(maj7)", "-Δ7", "minmaj7", "m△7"]),
        q("m7♭5", [0, 3, 6, 10], true, ["ø", "ø7", "m7b5", "-7b5", "half-diminished"]),
        q("dim7", [0, 3, 6, 9], true, ["°7", "o7"]),
        q("7sus4", [0, 5, 7, 10], false, ["7sus"]),
        q("aug7", [0, 4, 8, 10], false, ["7#5", "7♯5", "+7"]),
        q("maj7♯5", [0, 4, 8, 11], false, ["maj7#5", "+maj7"]),
        q("add9", [0, 4, 7, 14], false, ["add2"]),
        q("madd9", [0, 3, 7, 14], true, ["m(add9)", "-add9"]),
        q("6/9", [0, 4, 7, 9, 14], false, ["69"]),
        q("9", [0, 4, 7, 10, 14], false, []),
        q("maj9", [0, 4, 7, 11, 14], false, ["M9", "Δ9", "△9"]),
        q("m9", [0, 3, 7, 10, 14], true, ["-9", "min9"]),
        q("9sus4", [0, 5, 7, 10, 14], false, ["9sus"]),
        q("7♭9", [0, 4, 7, 10, 13], false, ["7b9"]),
        q("7♯9", [0, 4, 7, 10, 15], false, ["7#9"]),
        q("7♯11", [0, 4, 7, 10, 18], false, ["7#11"]),
        q("7♭13", [0, 4, 7, 10, 20], false, ["7b13"]),
        q("maj7♯11", [0, 4, 7, 11, 18], false, ["maj7#11", "Δ#11"]),
        q("11", [0, 4, 7, 10, 14, 17], false, []),
        q("m11", [0, 3, 7, 10, 14, 17], true, ["-11", "min11"]),
        q("13", [0, 4, 7, 10, 14, 21], false, []),
        q("maj13", [0, 4, 7, 11, 14, 21], false, ["M13", "Δ13"]),
        q("m13", [0, 3, 7, 10, 14, 21], true, ["-13", "min13"]),
        q("7alt", [0, 4, 10, 13, 15, 20], false, ["alt"]),
    ]

    private static func q(_ s: String, _ i: [Int], _ m: Bool, _ a: [String]) -> ChordQuality {
        ChordQuality(suffix: s, intervals: i, minorThird: m, aliases: a)
    }

    static let bySuffix: [String: ChordQuality] = {
        var d: [String: ChordQuality] = [:]
        for q in qualities {
            d[q.suffix] = q
            for a in q.aliases { d[a] = q }
            d[q.suffix.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")] = q
        }
        return d
    }()

    /// Musicpy chord_type names → our suffixes.
    public static let musicpyTypes: [String: String] = [
        "major": "", "minor": "m", "maj7": "maj7", "m7": "m7", "7": "7", "dim": "dim", "aug": "aug",
        "dim7": "dim7", "m7b5": "m7♭5", "half-diminished7": "m7♭5", "sus": "sus4", "sus2": "sus2", "sus4": "sus4",
        "6": "6", "m6": "m6", "9": "9", "maj9": "maj9", "m9": "m9", "11": "11", "m11": "m11", "13": "13",
        "maj13": "maj13", "m13": "m13", "add9": "add9", "madd9": "madd9", "mmaj7": "mMaj7", "minor-major7": "mMaj7",
        "7sus4": "7sus4", "7sus": "7sus4", "aug7": "aug7", "7#5": "aug7", "maj7#5": "maj7♯5", "7b9": "7♭9", "7#9": "7♯9",
        "7#11": "7♯11", "7b13": "7♭13", "maj7#11": "maj7♯11", "6/9": "6/9", "69": "6/9", "9sus4": "9sus4",
        "5": "5", "power chord": "5", "maj": "", "M7": "maj7", "maj7+": "maj7♯5",
    ]
}

// MARK: - Chord symbols

public struct ChordSpec: Hashable, Sendable {
    public var root: Int
    public var rootName: String
    public var suffix: String
    public var intervals: [Int] // sorted semitones from root, root included
    public var minorThird: Bool
    public var bass: Int?
    public var bassName: String?

    public var symbol: String { rootName + suffix + (bassName.map { "/" + $0 } ?? "") }
    public var pitchClasses: Set<Int> {
        var s = Set(intervals.map { Pitch.pc(root + $0) })
        if let bass { s.insert(bass) }
        return s
    }
}

public enum ChordSymbol {
    /// Typed input to a chord symbol, case-insensitively: "am7" → "Am7", "f#m7/c#" → "F♯m7/C♯",
    /// "ebmaj7" → "E♭maj7", "CMAJ7" → "Cmaj7". Root and bass letters are capitalised and their
    /// accidentals written ♯/♭; the quality is tried as typed (so "CM7" stays a major seventh),
    /// then lower-cased. Nil when it still isn't a chord.
    public static func normalizeInput(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let f = t.first, "abcdefgABCDEFG".contains(f) else { return nil }
        func note(_ s: Substring) -> (String, Substring) {
            var out = s.prefix(1).uppercased()
            var rest = s.dropFirst()
            if let a = rest.first, "#♯".contains(a) { out += "♯"; rest = rest.dropFirst() }
            else if let a = rest.first, "b♭".contains(a) { out += "♭"; rest = rest.dropFirst() }
            return (out, rest)
        }
        let parts = t.split(separator: "/", maxSplits: 1)
        let (root, quality) = note(parts[0])
        var bass = ""
        if parts.count > 1 {
            guard let b = parts[1].first, "abcdefgABCDEFG".contains(b) else { return nil }
            let (bn, extra) = note(parts[1])
            guard extra.isEmpty else { return nil }
            bass = "/" + bn
        }
        for q in [String(quality), quality.lowercased()] {
            let candidate = root + q + bass
            if parse(candidate) != nil { return candidate }
        }
        return nil
    }

    /// Parses chord symbols like "Dm7", "G7♯9", "C/E", "B♭maj7(♯11)", "F♯ø", "E♭7(b9,#11)".
    /// Returns nil for anything that isn't confidently a chord (plain words stay text).
    public static func parse(_ raw: String) -> ChordSpec? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 24 else { return nil }
        var bassName: String?
        var bass: Int?
        if let slash = s.lastIndex(of: "/"), s[s.index(after: slash)...].first.map({ "ABCDEFG".contains($0) }) == true {
            let b = String(s[s.index(after: slash)...])
            guard let bp = Pitch.parsePitchClass(b) else { return nil }
            bass = bp; bassName = Pitch.normalizeName(b)
            s = String(s[..<slash])
        }
        guard let first = s.first, "ABCDEFG".contains(first) else { return nil }
        var idx = s.index(after: s.startIndex)
        if idx < s.endIndex, "#♯b♭".contains(s[idx]) {
            // "Bb" is B-flat; but "Bbmaj7"/"Bb7" too. Accept one accidental.
            idx = s.index(after: idx)
        }
        let rootText = String(s[..<idx])
        guard let root = Pitch.parsePitchClass(rootText) else { return nil }
        var rest = String(s[idx...])
        // Pull modifiers out of parentheses: 7(b9,#11) → 7 + [b9, #11]
        var mods: [String] = []
        if let open = rest.firstIndex(of: "("), rest.hasSuffix(")") {
            let inner = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
            mods = inner.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            rest = String(rest[..<open])
        }
        // Longest base-suffix match, then trailing modifiers.
        var quality: ChordQuality?
        var remainder = rest
        if rest.isEmpty {
            quality = ChordCatalog.bySuffix[""]
        } else {
            for len in stride(from: rest.count, through: 0, by: -1) {
                let head = String(rest.prefix(len))
                if let q = ChordCatalog.bySuffix[head] { quality = q; remainder = String(rest.dropFirst(len)); break }
            }
        }
        guard var q = quality, let extra = splitModifiers(remainder) else { return nil }
        mods += extra
        var intervals = Set(q.intervals)
        var suffix = q.suffix
        for m in mods {
            let norm = m.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#").lowercased()
            switch norm {
            case "b9": intervals.insert(13); intervals.remove(14)
            case "9": intervals.insert(14)
            case "#9": intervals.insert(15)
            case "11": intervals.insert(17)
            case "#11": intervals.insert(18)
            case "b13": intervals.insert(20)
            case "13": intervals.insert(21)
            case "b5": intervals.remove(7); intervals.insert(6)
            case "#5": intervals.remove(7); intervals.insert(8)
            case "add9", "add2": intervals.insert(14)
            case "add11", "add4": intervals.insert(17)
            case "add13", "add6": intervals.insert(21)
            case "omit3", "no3": intervals.remove(3); intervals.remove(4)
            case "omit5", "no5": intervals.remove(7)
            case "omit1", "no1", "omitroot": intervals.remove(0)
            case "sus4": intervals.remove(3); intervals.remove(4); intervals.insert(5)
            case "sus2": intervals.remove(3); intervals.remove(4); intervals.insert(2)
            default: return nil
            }
            suffix += display(modifier: m)
        }
        q = ChordQuality(suffix: suffix, intervals: intervals.sorted(), minorThird: q.minorThird, aliases: [])
        return ChordSpec(root: root, rootName: Pitch.normalizeName(rootText), suffix: suffix,
                         intervals: q.intervals, minorThird: q.minorThird, bass: bass, bassName: bassName)
    }

    private static func splitModifiers(_ s: String) -> [String]? {
        if s.isEmpty { return [] }
        let pattern = try! NSRegularExpression(pattern: "^((?:add|omit|no)\\d+|sus[24]|[#♯b♭]?\\d+)")
        var out: [String] = []
        var rest = s
        while !rest.isEmpty {
            let ns = rest as NSString
            guard let m = pattern.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) else { return nil }
            out.append(ns.substring(with: m.range))
            rest = ns.substring(from: m.range.length)
        }
        return out
    }

    private static func display(modifier m: String) -> String {
        let t = m.replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "#", with: "♯")
        if t.hasPrefix("add") || t.hasPrefix("omit") || t.hasPrefix("no") || t.hasPrefix("sus") { return "(\(m))" }
        return t
    }

    /// Builds the canonical symbol for a root + quality suffix + optional bass, spelled for a key.
    public static func make(root: Int, suffix: String, bass: Int?, key: KeySignature?) -> String {
        let flats = Pitch.prefersFlats(key)
        var s = Pitch.name(pc: root, flats: flats) + suffix
        if let bass, Pitch.pc(bass) != Pitch.pc(root) { s += "/" + Pitch.name(pc: bass, flats: flats) }
        return s
    }

    /// Converts a Musicpy naming result to our symbol, or nil if it doesn't map.
    public static func fromMusicpy(root: String?, type: String?, bassPitchClass: Int?, omit: [String], key: KeySignature?) -> String? {
        guard let root, let type, let rpc = Pitch.parsePitchClass(root) else { return nil }
        guard let suffix = ChordCatalog.musicpyTypes[type] ?? (ChordCatalog.bySuffix[type]?.suffix) else { return nil }
        var s = make(root: rpc, suffix: suffix, bass: bassPitchClass, key: key)
        if !omit.isEmpty {
            let parts = omit.map { "omit" + $0 }
            if let slash = s.firstIndex(of: "/") {
                s.insert(contentsOf: "(" + parts.joined(separator: ",") + ")", at: slash)
            } else { s += "(" + parts.joined(separator: ",") + ")" }
        }
        return s
    }

    /// Transposes a symbol by semitones, re-spelling for the target key.
    public static func transpose(_ symbol: String, by semitones: Int, key: KeySignature?) -> String {
        guard let spec = parse(symbol) else { return symbol }
        let flats = Pitch.prefersFlats(key)
        var s = Pitch.name(pc: spec.root + semitones, flats: flats) + spec.suffix
        if let b = spec.bass { s += "/" + Pitch.name(pc: b + semitones, flats: flats) }
        return s
    }
}

// MARK: - Degrees

public enum Degrees {
    // Semitone above tonic → (degree, accidental) using the tonic's major scale as reference.
    static let table: [(Int, Int)] = [(1, 0), (2, -1), (2, 0), (3, -1), (3, 0), (4, 0), (5, -1), (5, 0), (6, -1), (6, 0), (7, -1), (7, 0)]
    static let romans = ["I", "II", "III", "IV", "V", "VI", "VII"]

    /// Basic degree of a chord in a key. Minor-key chords are still measured against
    /// the tonic's major scale: in C minor, E♭ is ♭III and A♭ is ♭VI; the tonic triad is i.
    public static func label(for spec: ChordSpec, in key: KeySignature) -> DegreeLabel {
        let semis = Pitch.pc(spec.root - key.tonic)
        var (deg, acc) = table[semis]
        // The tritone reads as ♯IV for diminished-type chords (♯iv°), ♭V otherwise.
        if semis == 6, spec.suffix.hasPrefix("dim") || spec.suffix.hasPrefix("m7♭5") { (deg, acc) = (4, 1) }
        var roman = romans[deg - 1]
        let lower = spec.minorThird
        if lower { roman = roman.lowercased() }
        var quality = spec.suffix
        if lower, quality.hasPrefix("m"), !quality.hasPrefix("maj") { quality.removeFirst() }
        if quality.hasPrefix("dim7") { quality = "°7" + quality.dropFirst(4) }
        else if quality.hasPrefix("dim") { quality = "°" + quality.dropFirst(3) }
        else if quality.hasPrefix("7♭5"), lower { quality = "ø7" + quality.dropFirst(3) }
        else if quality.hasPrefix("aug") { quality = "+" + quality.dropFirst(3) }
        let accText = acc < 0 ? "♭" : acc > 0 ? "♯" : ""
        var display = accText + roman + quality
        var bassDegree: String?
        if let bass = spec.bass, bass != spec.root {
            let (bd, ba) = table[Pitch.pc(bass - key.tonic)]
            bassDegree = (ba < 0 ? "♭" : ba > 0 ? "♯" : "") + String(bd)
            display += "/" + bassDegree!
        }
        return DegreeLabel(degreeIndex: deg, accidental: acc, quality: spec.suffix, minorThird: lower,
                           bassDegree: bassDegree, display: display)
    }

    public static func label(symbol: String, key: KeySignature) -> DegreeLabel? {
        ChordSymbol.parse(symbol).map { label(for: $0, in: key) }
    }

    /// Arabic scale-step of a chord root for skeleton tags (e.g. "4" for IV, "♭7" for ♭VII).
    public static func tagStep(symbol: String, key: KeySignature) -> String? {
        guard let spec = ChordSymbol.parse(symbol) else { return nil }
        let (d, a) = table[Pitch.pc(spec.root - key.tonic)]
        return (a < 0 ? "♭" : a > 0 ? "♯" : "") + String(d)
    }
}

// MARK: - Standard voicing

/// The chord as it was actually played: only notes that belong to the chord name, taken from where
/// the chord is struck (widened to the whole event for broken textures). Melody and passing notes
/// drop out. Nil when the notes don't cover the chord; callers then use the standard voicing.
public enum PlayedVoicing {
    public typealias Note = (pitch: Int, start: Double, duration: Double)

    /// `notes` are relative to the chord start, in seconds.
    public static func chordTones(symbol: String?, notes: [Note]) -> [Note]? {
        guard let spec = symbol.flatMap(ChordSymbol.parse(_:)) else { return nil }
        var pcs = Set(spec.intervals.map { (spec.root + $0) % 12 })
        if let b = spec.bass { pcs.insert(b) }
        return notes.filter { pcs.contains($0.pitch % 12) && $0.duration > 0.03 }
    }

    public static func pitches(symbol: String?, notes: [Note], onsetWindow: Double = 0.6) -> [Int]? {
        guard let spec = symbol.flatMap(ChordSymbol.parse(_:)), let tones = chordTones(symbol: symbol, notes: notes) else { return nil }
        var pcs = Set(spec.intervals.map { (spec.root + $0) % 12 })
        if let b = spec.bass { pcs.insert(b) }
        let need = min(3, pcs.count)
        func distinct(_ ns: [Note]) -> [Int] { Array(Set(ns.map(\.pitch))).sorted() }
        let struck = distinct(tones.filter { $0.start <= onsetWindow })
        if Set(struck.map { $0 % 12 }).count >= need { return struck }
        let all = distinct(tones)
        return Set(all.map { $0 % 12 }).count >= need ? all : nil
    }
}

public enum StandardVoicing {
    /// Centered close voicing that keeps every tone the symbol requires, plus the slash bass.
    /// Root sits in C3–B3; upper tones stack above; extensions go above the seventh.
    public static func pitches(for spec: ChordSpec) -> [Int] {
        let rootPitch = 48 + spec.root
        var out: [Int] = []
        if let bass = spec.bass, bass != spec.root {
            out.append(36 + bass)
        }
        let core = spec.intervals.filter { $0 < 12 }
        let ext = spec.intervals.filter { $0 >= 12 }
        var last = rootPitch - 1
        let hasRoot = spec.intervals.contains(0)
        for i in core.sorted() {
            if i == 0 && !hasRoot { continue }
            var p = rootPitch + i
            while p <= last { p += 12 }
            out.append(p); last = p
        }
        for i in ext.sorted() {
            var p = rootPitch + i
            while p <= last { p += 12 }
            out.append(p); last = p
        }
        return Array(Set(out)).sorted()
    }

    public static func pitches(symbol: String) -> [Int]? { ChordSymbol.parse(symbol).map(pitches(for:)) }
}

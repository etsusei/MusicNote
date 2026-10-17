// Core logic checks. Run with: swift run MusicnoteChecks
import Foundation
import MusicnoteCore

enum TagTextCheck {
    static func normalize(_ s: String) -> String {
        var t = s
        for d in ["–", "—", "−", " "] { t = t.replacingOccurrences(of: d, with: "-") }
        return t
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "autoanalyze" {
    exit(await runAutoAnalyze(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "skeleton" {
    exit(await runSkeleton(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "voicings" {
    exit(runVoicings(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "regroup" {
    exit(runRegroup(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "seed" {
    exit(runSeed(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "e2e" {
    let code = await runEndToEnd(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}

var failures = 0
var passes = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if condition() { passes += 1 } else { failures += 1; print("FAIL \(file):\(line) \(message)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
    check(a == b, "\(message) expected \(b), got \(a)", file: file, line: line)
}

// A04: 0.5 BPM rounding, halves round up.
eq(Tempo.roundToHalf(93.24), 93.0, "93.24")
eq(Tempo.roundToHalf(93.25), 93.5, "93.25")
eq(Tempo.roundToHalf(93.75), 94.0, "93.75")
eq(Tempo.roundToHalf(120.0), 120.0, "120")
check(Tempo.roundToHalf(0) == nil && Tempo.roundToHalf(-3) == nil, "non-positive rejected")
eq(Tempo.parseUserBpm("94.3"), 94.5, "typed 94.3")
check(Tempo.parseUserBpm("abc") == nil, "non-numeric rejected")

// Q and tempo conversions.
let grid = BeatGrid(bpm: 94.5, beatOriginUs: 0)
eq(grid.us(atQ: 2), 1_269_841, "2 beats at 94.5")
eq(grid.q(atUs: 1_269_841).rounded(), 2, "q back")
eq(Tempo.microsecondsPerQuarter(120), 500_000, "mpq")
let pickup = BeatGrid(bpm: 120, beatOriginUs: 250_000)
check(pickup.q(atUs: 0) < 0, "pickup Q negative")
eq(pickup.beatTimes(durationUs: 2_000_000), [250_000, 750_000, 1_250_000, 1_750_000], "beat times")
eq(MidiTicks.ticks(q: 1.5), 1440, "ticks")
eq(Meter(6, 8).quarterBeatsPerBar, 3, "6/8 Q per bar")

// Chord parsing.
func syms(_ s: String) -> [Int]? { ChordSymbol.parse(s).map { $0.intervals } }
eq(syms("Dm7"), [0, 3, 7, 10], "Dm7")
eq(syms("Cmaj7"), [0, 4, 7, 11], "Cmaj7")
eq(syms("C△7"), [0, 4, 7, 11], "C△7")
eq(syms("C7♯9"), [0, 4, 7, 10, 15], "C7#9")
eq(syms("C7#9"), [0, 4, 7, 10, 15], "C7#9 ascii")
eq(syms("G7(b9,#11)"), [0, 4, 7, 10, 13, 18], "G7(b9,#11)")
eq(syms("F♯ø"), [0, 3, 6, 10], "half dim")
eq(syms("Bbmaj9"), [0, 4, 7, 11, 14], "Bbmaj9")
eq(ChordSymbol.parse("Bbmaj9")?.root, 10, "Bb root")
eq(ChordSymbol.parse("C/E")?.bass, 4, "slash bass")
eq(ChordSymbol.parse("C/E")?.root, 0, "slash root stays C")
check(ChordSymbol.parse("Hello") == nil, "plain word not a chord")
check(ChordSymbol.parse("Cxyz") == nil, "garbage suffix rejected")
eq(syms("C7b9#11"), [0, 4, 7, 10, 13, 18], "stacked mods")

// Degrees (major-scale reference).
let cMajor = KeySignature(tonic: 0, tonicName: "C", mode: .major)
let cMinor = KeySignature(tonic: 0, tonicName: "C", mode: .minor)
eq(Degrees.label(symbol: "Dm7", key: cMajor)?.display, "ii7", "ii7")
eq(Degrees.label(symbol: "G7", key: cMajor)?.display, "V7", "V7")
eq(Degrees.label(symbol: "Cmaj7", key: cMajor)?.display, "Imaj7", "Imaj7")
eq(Degrees.label(symbol: "Cm", key: cMinor)?.display, "i", "minor tonic")
eq(Degrees.label(symbol: "E♭", key: cMinor)?.display, "♭III", "bIII in minor")
eq(Degrees.label(symbol: "A♭maj7", key: cMinor)?.display, "♭VImaj7", "bVI")
eq(Degrees.label(symbol: "C/E", key: cMajor)?.display, "I/3", "slash bass degree, root stays I")
eq(Degrees.label(symbol: "Bm7♭5", key: cMajor)?.display, "viiø7", "half-dim")
eq(Degrees.label(symbol: "F♯dim7", key: cMajor)?.display, "♯iv°7", "#iv°7")
eq(Degrees.tagStep(symbol: "F", key: cMajor), "4", "tag step")

// Standard voicing keeps required tones (A18).
let maj7 = StandardVoicing.pitches(symbol: "Cmaj7")!
check(Set(maj7.map { $0 % 12 }) == [0, 4, 7, 11], "maj7 keeps the seventh: \(maj7)")
let slash = StandardVoicing.pitches(symbol: "C/E")!
eq(slash.first.map { $0 % 12 }, 4, "slash bass lowest")
let c79 = StandardVoicing.pitches(symbol: "C7♯9")!
check(Set(c79.map { $0 % 12 }).isSuperset(of: [0, 4, 10, 3]), "C7#9 has #9 and 3: \(c79)")

// Transposition keeps quality and slash bass.
let ebKey = KeySignature(tonic: 3, tonicName: "E♭", mode: .major)
eq(ChordSymbol.transpose("Dm7/G", by: 3, key: ebKey), "Fm7/B♭", "transpose")

// Musicpy mapping.
eq(ChordSymbol.fromMusicpy(root: "D", type: "m7", bassPitchClass: 2, omit: [], key: cMajor), "Dm7", "musicpy m7")
eq(ChordSymbol.fromMusicpy(root: "C", type: "major", bassPitchClass: 4, omit: [], key: cMajor), "C/E", "musicpy slash")

// Context budget (A22).
eq(ContextBudget(actualWindow: 1_000_000, reserve: 32_000).trigger, 950_000, "1M trigger")
eq(ContextBudget(actualWindow: 200_000, reserve: 32_000).trigger, 168_000, "smaller window earlier")

// Grouping: an arpeggiated C major figure over 2 beats then G7 block chords.
func n(_ p: Int, _ s: Double, _ e: Double) -> MidiNote {
    MidiNote(pitch: p, startUs: Int64(s * 1_000_000), endUs: Int64(e * 1_000_000), instrument: "acoustic_piano")
}
// 120 BPM: beat = 0.5 s. Bar 1: C E G C arpeggio (eighths), bar 2: G7 block on each beat.
var notes: [MidiNote] = []
let arp = [48, 52, 55, 60, 64, 60, 55, 52]
for (i, p) in arp.enumerated() { notes.append(n(p, Double(i) * 0.25, Double(i) * 0.25 + 0.24)) }
for b in 0..<4 { for p in [43, 53, 59, 62] { notes.append(n(p, 2.0 + Double(b) * 0.5, 2.0 + Double(b) * 0.5 + 0.45)) } }
let groups = ChordGrouper().group(notes: notes, grid: BeatGrid(bpm: 120, beatOriginUs: 0), durationUs: 4_000_000, key: cMajor)
eq(groups.count, 2, "arpeggio + block → two events")
eq(groups.first?.candidates.first?.symbol, "C", "arpeggio recovers C")
eq(groups.first?.texture, .broken, "arpeggio texture")
eq(groups.last?.candidates.first?.symbol, "G7", "block G7")
eq(groups.last?.texture, .block, "block texture")

// Anticipated change: F chord pushed an eighth before beat 3 of bar 1.
var push: [MidiNote] = []
for p in [48, 52, 55] { push.append(n(p, 0, 0.74)) } // C on beats 1-2 (0 – 0.75 s)
for p in [53, 57, 60] { push.append(n(p, 0.75, 2.0)) } // F lands on the "and" of 2
let pg = ChordGrouper().group(notes: push, grid: BeatGrid(bpm: 120, beatOriginUs: 0), durationUs: 2_000_000, key: cMajor)
eq(pg.count, 2, "anticipation two events")
eq(pg.last?.startUs, 750_000, "boundary moved to the anticipated onset")

// Rests keep gaps.
let rest = [n(48, 0, 0.9), n(52, 0, 0.9), n(55, 0, 0.9), n(55, 2.0, 2.9), n(59, 2.0, 2.9), n(62, 2.0, 2.9)]
let rg = ChordGrouper().group(notes: rest, grid: BeatGrid(bpm: 120, beatOriginUs: 0), durationUs: 3_000_000, key: cMajor)
eq(rg.count, 2, "rest separates")
check((rg.last?.startUs ?? 0) >= 2_000_000 - 1, "second event starts after rest")

// MIDI writer emits a valid header and end-of-track.
let midi = MidiFileWriter(bpm: 94.5, meter: .fourFour, key: cMajor)
    .data(notes: [.init(pitch: 60, velocity: 100, startTick: 0, durationTicks: 960)])
check(midi.prefix(4) == Data("MThd".utf8), "MThd")
check(midi.suffix(4) == Data([0x00, 0xFF, 0x2F, 0x00]), "end of track")


// Playground (A23–A26): transposition keeps quality and slash bass; sustained notes aren't duplicated.
let srcTiming = TimingConfirmation(trimRevision: 1, bpm: 120, beatOriginUs: 0, meter: .fourFour, meterConfirmed: true, barAnchorUs: 0, key: cMajor)
let sustain = MidiNote(pitch: 36, startUs: 0, endUs: 2_000_000)
let e1n = [sustain, n(52, 0, 0.9), n(55, 0, 0.9)]
let e2n = [n(53, 1.0, 1.9), n(57, 1.0, 1.9)]
let allN = e1n + e2n
let ev1 = ChordEvent(id: "chord-01", order: 0, startUs: 0, endUs: 1_000_000, noteIds: e1n.map(\.id), noteRoles: [:], texture: .block, excludedNoteIds: [], namingPitches: [], candidates: [], symbol: "C/E", namingSource: .user, manualOverride: true, degree: nil, bassPitch: nil)
let ev2 = ChordEvent(id: "chord-02", order: 1, startUs: 1_000_000, endUs: 2_000_000, noteIds: [sustain.id] + e2n.map(\.id), noteRoles: [:], texture: .block, excludedNoteIds: [], namingPitches: [], candidates: [], symbol: "Fmaj7", namingSource: .user, manualOverride: true, degree: nil, bassPitch: nil)
let ctx = PlaygroundOps.SourceContext(analysisId: UUID(), harmonyRevision: 1, timing: srcTiming, notes: allN, segmentDurationUs: 2_000_000)
let dKey = KeySignature(tonic: 2, tonicName: "D", mode: .major)
let blocks = try! PlaygroundOps.blocks(events: [ev1, ev2], context: ctx, kind: "progression", voicing: .original, target: dKey)
eq(blocks.map(\.symbol), ["D/F♯", "Gmaj7"], "transposed symbols")
eq(blocks[1].startQ, 2, "second block at beat 2")
eq(blocks.flatMap { $0.originalNotes }.filter { $0.sourceNoteId == sustain.id }.count, 1, "sustain once")
eq(blocks[0].originalNotes.first { $0.sourceNoteId == sustain.id }?.pitch, 38, "transposed by +2")
check((try? PlaygroundOps.blocks(events: [ev1], context: ctx, kind: "chord", voicing: .original, target: dKey, octaveShift: -4)) == nil, "out of range rejected")
var resized = blocks[1]; resized.durationQ = 4
eq(PlaygroundOps.sounding(resized).first?.durationQ, 3.6, "edge drag scales inner timing (2→4 beats doubles 1.8)")
let sk = try! PlaygroundOps.skeletonBlocks(backbone: ["chord-02"], events: [ev1, ev2], context: ctx, voicing: .original, target: cMajor)
eq(sk.first?.startQ, 2, "skeleton keeps original gap")
check(sk.first?.simplified == true, "skeleton marked simplified")
var proj = PlaygroundProject(title: "t", key: cMajor, bpm: 100, meter: .fourFour)
proj.sections[0].blocks = blocks
let mid = PlaygroundOps.exportMidi(proj)
check(mid.count > 40, "playground midi")
eq(PlaygroundOps.problems(proj).count, 0, "no problems")
proj.sections[0].blocks.append(blocks[0])
check(!PlaygroundOps.problems(proj).isEmpty, "overlap reported")
eq(TagTextCheck.normalize("4–5–3–6"), TagTextCheck.normalize("4-5-3-6"), "tag normalize")

// Fast chromatic planing between beats: A → A♭ → G on eighths at 140 BPM, then G held.
let bm = KeySignature(tonic: 11, tonicName: "B", mode: .minor)
let b140 = 60.0 / 140
var plan: [MidiNote] = []
func at(_ q: Double, _ len: Double, _ ps: [Int]) { for p in ps { plan.append(n(p, q * b140, (q + len) * b140 - 0.01)) } }
at(0, 3, [54, 58, 61, 66])          // F♯ for three beats
at(3.5, 0.5, [57, 61, 64, 73])      // A on the "and" of 4
at(4, 0.5, [56, 60, 63, 72])        // A♭ (G♯) on beat 1
at(4.5, 4.5, [55, 59, 62, 71])      // G from the "and" of 1
let pl = ChordGrouper().group(notes: plan, grid: BeatGrid(bpm: 140, beatOriginUs: 0), durationUs: Int64(9 * b140 * 1e6), key: bm)
eq(pl.map { $0.candidates.first?.symbol ?? "?" }, ["F♯", "A", "G♯", "G"], "chromatic planing keeps each half-beat chord")

// A repeat whose second ending changes chords keeps its own changes (no forced alignment).
var rp: [MidiNote] = []
func put(_ q: Double, _ len: Double, _ ps: [Int]) { for p in ps { rp.append(n(p, q * b140, (q + len) * b140 - 0.01)) } }
for k in 0..<2 {
    let o = Double(k) * 16
    put(o + 0, 4, [54, 59, 61, 64])            // F♯sus
    put(o + 4, 8, [55, 59, 62])                // G
    if k == 0 { put(o + 12, 4, [54, 57, 61]) } // F♯m
    else { put(o + 12, 2, [52, 55, 59]); put(o + 14, 2, [54, 58, 61]) } // Em → F♯ the second time
}
let rg2 = ChordGrouper().group(notes: rp, grid: BeatGrid(bpm: 140, beatOriginUs: 0, barAnchorUs: 0), durationUs: Int64(32 * b140 * 1e6), key: bm)
eq(rg2.map { $0.candidates.first?.symbol ?? "?" }, ["F♯7sus4", "G", "F♯m", "F♯7sus4", "G", "Em", "F♯"], "second ending changes are kept")

// Comping: Cmaj7 re-struck on eighths (staccato with gaps) under a single-note melody = one chord per bar.
var comp: [MidiNote] = []
let b120 = 0.5
for e in [0.0, 1.5, 2.0, 3.5] { for p in [48, 52, 55, 59] { comp.append(n(p, e * b120, e * b120 + 0.2)) } }
for (i, p) in [72, 74, 76, 79, 77, 76, 74, 72].enumerated() { comp.append(n(p, Double(i) * 0.25, Double(i) * 0.25 + 0.2)) }
for e in [4.0, 5.5, 6.0, 7.5] { for p in [53, 57, 60, 64] { comp.append(n(p, e * b120, e * b120 + 0.2)) } }
let cg = ChordGrouper().group(notes: comp, grid: BeatGrid(bpm: 120, beatOriginUs: 0, barAnchorUs: 0), durationUs: 4_000_000, key: cMajor)
eq(cg.map { $0.candidates.first?.symbol ?? "?" }, ["Cmaj7", "Fmaj7"], "comping rhythm + melody = one chord per bar")

// Bar line estimate: chords land every 4 beats starting on grid beat 2 (beat origin is a pickup).
var shifted: [MidiNote] = []
for (bar, ps) in [[48, 52, 55], [53, 57, 60], [55, 59, 62], [48, 52, 55]].enumerated() {
    for p in ps { shifted.append(n(p, (1 + Double(bar) * 4) * b120, (1 + Double(bar) * 4 + 4) * b120 - 0.02)) }
}
let sr = ChordGrouper().run(notes: shifted, grid: BeatGrid(bpm: 120, beatOriginUs: 0), durationUs: 9_000_000, key: cMajor)
eq(sr.barAnchorUs, 500_000, "bar line estimated at the first chord, not the first detected beat")
check(sr.barAnchorEstimated, "anchor marked as estimated")
eq(sr.groups.map { $0.candidates.first?.symbol ?? "?" }, ["C", "F", "G", "C"], "one chord per bar")

// A new voicing struck on a downbeat is a new chord, even when the basic chord is the same
// (Gmaj7 for a bar, then G B D E F♯ A next bar); re-striking the same voicing stays one chord.
var vc: [MidiNote] = []
func vput(_ q: Double, _ len: Double, _ ps: [Int]) { for p in ps { vc.append(n(p, q * b140, (q + len) * b140 - 0.01)) } }
vput(0, 2, [55, 59, 62, 66, 71]); vput(2.5, 1.5, [55, 59, 62, 66])     // Gmaj7, re-struck
vput(4, 3.5, [55, 59, 62, 64, 66, 69])                               // next bar: add E and A
let vg = ChordGrouper().group(notes: vc, grid: BeatGrid(bpm: 140, beatOriginUs: 0, barAnchorUs: 0), durationUs: Int64(8 * b140 * 1e6), key: bm)
eq(vg.count, 2, "new voicing on the downbeat splits; the re-strike in bar 1 doesn't")

// Membership: the legato tail of the previous chord (14 ms overlap) is not part of the next chord;
// a bass held through the chord is.
let tail = MidiNote(pitch: 56, startUs: 0, endUs: 1_014_000)
let held = MidiNote(pitch: 43, startUs: 0, endUs: 3_000_000)
let struckIn = MidiNote(pitch: 59, startUs: 1_000_000, endUs: 2_000_000)
let mem = ChordGrouper.members([tail, held, struckIn], start: 1_000_000, end: 3_000_000, beatUs: 428_571)
eq(Set(mem.map(\.id)), Set([held.id, struckIn.id]), "legato tails excluded, held bass included")

// Key estimate from chords: the user's clip circles F♯ with G as ♭II → F♯ minor, not A major.
func ev(_ id: String, _ sym: String, _ s: Double, _ e: Double) -> ChordEvent {
    ChordEvent(id: id, order: 0, startUs: Int64(s * 1e6), endUs: Int64(e * 1e6), noteIds: [], noteRoles: [:], texture: .block,
               excludedNoteIds: [], namingPitches: [], candidates: [], symbol: sym, namingSource: .user, manualOverride: true, degree: nil, bassPitch: nil)
}
let clip = [ev("1", "F♯7sus4", 0.74, 1.79), ev("2", "A", 1.79, 2.02), ev("3", "G♯", 2.02, 2.22), ev("4", "G", 2.22, 4.17),
            ev("5", "Gmaj9", 4.17, 5.67), ev("6", "F♯m7", 5.67, 7.6), ev("7", "F♯7sus4", 7.6, 8.68), ev("8", "A", 8.68, 8.9),
            ev("9", "G♯", 8.9, 9.1), ev("10", "G", 9.1, 11.02), ev("11", "Gmaj13", 11.02, 12.31), ev("12", "F♯", 12.52, 13.4)]
let kc = KeyEstimator.candidates(events: clip)
eq(kc.first.map { "\($0.key.tonic)\($0.key.mode)" }, "6minor", "F♯ minor from where phrases start and land")
let twoFiveOne = [ev("1", "Dm7", 0, 2), ev("2", "G7", 2, 4), ev("3", "Cmaj7", 4, 8)]
eq(KeyEstimator.candidates(events: twoFiveOne).first.map { "\($0.key.tonic)\($0.key.mode)" }, "0major", "ii-V-I in C")
eq(Degrees.numberPattern(["F", "G", "Em", "Am"], key: cMajor), "4-5-3-6", "4536 numbering")
eq(Degrees.numberPattern(["F♯m7", "G", "F♯"], key: KeySignature(tonic: 6, tonicName: "F♯", mode: .minor)), "6-♭7-6", "minor counted from relative major")

// Logic Chord ID labels → app chord symbols (the vocabulary writes the seventh in parentheses).
eq(["Fm(7)", "Csus4(7)", "G(7)/B", "Ab(maj7)", "Bdim(7)", "C", "Ebm"].map { LogicChordLabel.symbol($0) ?? "nil" },
   ["Fm7", "C7sus4", "G7/B", "A♭maj7", "Bdim7", "C", "E♭m"], "Logic labels converted")
check(LogicChordLabel.symbol("N") == nil, "no-chord label rejected")

// Two transcriptions: B runs 30 ms late overall; offset removed, same pitches matched, extras kept as single-sided.
func en(_ p: Int, _ s: Int64) -> EvidenceNote { EvidenceNote(pitch: p, startUs: s, endUs: s + 400_000, velocity: 80, instrument: "acoustic_piano") }
let ta = [en(48, 0), en(55, 0), en(60, 500_000), en(64, 1_000_000)]
let tb = [en(48, 30_000), en(55, 30_000), en(60, 530_000), en(67, 1_030_000)]
let al = TranscriptionAligner.align(ta, tb, labels: ("muscriptor", "mt3"))
eq(al.offsetUs, -30_000, "global offset estimated")
eq([al.matched, al.onlyA, al.onlyB], [3, 1, 1], "matched / single-sided counts")
eq(al.merged.filter { $0.support == "mt3" }.map(\.startUs), [1_000_000], "single-sided note shifted onto A's timing")

// Bar/beat positions with a pickup: bar line at 0.5 s, 120 BPM 4/4.
let pkg = BeatGrid(bpm: 120, beatOriginUs: 0, barAnchorUs: 500_000)
eq([BarEvidence.position(500_000, grid: pkg).bar, BarEvidence.position(2_500_000, grid: pkg).bar], [1, 2], "bars counted from the anchor")
eq(BarEvidence.position(1_750_000, grid: pkg).beat, 3.5, "off-beat half")
eq(BarEvidence.usAt(bar: 2, beat: 3.5, grid: pkg), 3_750_000, "bar.beat back to time")
eq(BarEvidence.barCount(grid: pkg, durationUs: 8_400_000), 4, "partial last bar counted")

// Played voicing: Cm9 struck on the beat with a melody F and a passing A♭ later; only chord tones, as struck.
let cm9Bar: [PlayedVoicing.Note] = [(48, 0, 2), (55, 0, 2), (58, 0, 2), (62, 0, 2), (63, 0.02, 2),   // C G B♭ D E♭
                                    (77, 0.4, 0.3), (68, 1.0, 0.2), (72, 1.2, 0.3)]                  // F (melody), A♭ (passing), C later
eq(PlayedVoicing.pitches(symbol: "Cm9", notes: cm9Bar), [48, 55, 58, 62, 63], "melody/passing notes and later notes left out")
// Broken chord: tones arrive one by one, so the whole event is used.
eq(PlayedVoicing.pitches(symbol: "F", notes: [(53, 0, 0.3), (57, 0.7, 0.3), (60, 1.4, 0.3), (62, 1.6, 0.2)]), [53, 57, 60], "arpeggio gathered, D dropped")
check(PlayedVoicing.pitches(symbol: "G7", notes: [(67, 0, 1), (74, 0, 1)]) == nil, "too few chord tones → standard voicing")

// MCP bridge: initialize, list and call go through workers/mcp_bridge.py to the app-side socket;
// a wrong token is refused.
do {
    let sock = AgentToolSocket(tools: [["name": "echo", "description": "d", "inputSchema": ["type": "object"]]]) { name, args in
        ("\(name):\(args["x"] as? Int ?? -1)", true)
    }
    try sock.start()
    let reqs = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"x":7}}}"#]
    func bridge(token: String) async -> [[String: Any]] {
        let w = WorkerProcess("/usr/bin/python3", ["-I", FileManager.default.currentDirectoryPath + "/workers/mcp_bridge.py"])
        w.environment = ["MUSICNOTE_MCP_SOCKET": sock.path, "MUSICNOTE_MCP_TOKEN": token]
        w.stdinData = Data((reqs.joined(separator: "\n") + "\n").utf8)
        nonisolated(unsafe) var out: [[String: Any]] = []
        _ = try? await w.run { if let m = decodeJSONLine($0) { out.append(m) } }
        return out
    }
    let ok = await bridge(token: sock.token)
    eq(ok.compactMap { $0["id"] as? Int }, [1, 2, 3], "bridge answers requests, skips notifications")
    let listed = ((ok.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    eq(listed ?? [], ["echo"], "tools listed from the app")
    let called = (ok.first { $0["id"] as? Int == 3 }?["result"] as? [String: Any])
    eq(((called?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", "echo:7", "call forwarded with arguments")
    let bad = await bridge(token: "wrong")
    let badCall = bad.first { $0["id"] as? Int == 3 }?["result"] as? [String: Any]
    check(bad.first { $0["id"] as? Int == 2 }.flatMap { (($0["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty } ?? true, "wrong token gets no tools")
    check(badCall?["isError"] as? Bool == true, "wrong token cannot call tools")
    sock.stop()
} catch { check(false, "socket: \(error)") }

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

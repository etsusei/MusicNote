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

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

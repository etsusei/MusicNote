// Core logic checks. Run with: swift run MusicnoteChecks
import Foundation
import MusicnoteCore

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

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

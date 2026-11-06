import Foundation
import MusicnoteCore

/// Step sequencer and drum transcription checks (part of the default run).
func runDrumChecks() {
    func lane(_ g: DrumGroove, _ note: Int) -> DrumLane? { g.lanes.first { $0.note == note } }
    func idx(_ g: DrumGroove, _ note: Int) -> [Int] { lane(g, note)?.steps.map(\.index) ?? [] }

    // Swing delays every second step; nudge scales with feel.
    var g = DrumGroove(bars: 1, swing: 66, lanes: [DrumLane(name: "闭镲", note: 42)])
    eq(DrumOps.stepQ(g, index: 0), 0, "step 0 on the beat")
    check(abs(DrumOps.stepQ(g, index: 1) - 0.33) < 1e-9, "66% swing puts the odd sixteenth at 66% of its pair (~1/3 beat)")
    eq(DrumOps.stepQ(g, index: 2), 0.5, "even steps stay put")
    g.swing = 50; g.feel = 0.5
    eq(DrumOps.stepQ(g, index: 4, nudge: 0.2), 1.0 + 0.1 * 0.25, "feel halves the nudge")

    // Toggle, chance, ratchet, mute/solo, volume.
    var k = DrumGroove.blank()
    let kick = k.lanes[0].id, snare = k.lanes[1].id, hat = k.lanes[3].id
    for i in [0, 8] { DrumOps.toggle(&k, lane: kick, index: i) }
    for i in [4, 12] { DrumOps.toggle(&k, lane: snare, index: i, velocity: 90) }
    DrumOps.fill(&k, lane: hat, every: 2, velocity: 70)
    eq(idx(k, 36), [0, 8], "kick on 1 and 3")
    DrumOps.toggle(&k, lane: kick, index: 8)
    eq(idx(k, 36), [0], "toggle again turns it off")
    DrumOps.toggle(&k, lane: kick, index: 8)
    eq(DrumOps.hits(k).count, 2 + 2 + 8, "all hits of one pass")
    eq(DrumOps.hits(k, passes: 3).count, 36, "three passes")
    var chancy = k
    chancy.lanes[3].steps = chancy.lanes[3].steps.map { var s = $0; s.chance = 50; return s }
    let a = DrumOps.hits(chancy, passes: 8, seed: 7), b = DrumOps.hits(chancy, passes: 8, seed: 7)
    eq(a, b, "same seed, same chance outcome")
    let hatHits = a.filter { $0.note == 42 }.count
    check(hatHits > 12 && hatHits < 52, "50% chance plays about half the hats (\(hatHits)/64)")
    var rat = k
    rat.lanes[1].steps[0].repeats = 3
    let snareHits = DrumOps.hits(rat).filter { $0.note == 38 }
    eq(snareHits.map { ($0.q * 1000).rounded() / 1000 }, [1.0, 1.083, 1.167, 3.0], "ratchet splits the step evenly")
    check(snareHits[1].velocity < snareHits[0].velocity, "ratchet repeats fall off")
    var solo = k
    solo.lanes[1].solo = true
    check(DrumOps.hits(solo).allSatisfy { $0.note == 38 }, "solo plays only that lane")
    solo.lanes[1].muted = true
    check(DrumOps.hits(solo).isEmpty, "muted solo lane plays nothing; others stay silent under solo")
    var quiet = k
    quiet.lanes[0].volume = 0.5
    eq(DrumOps.hits(quiet).first { $0.note == 36 }?.velocity, 50, "lane volume scales velocity")

    // Grid edits.
    var r = k
    DrumOps.setResolution(&r, 8)
    eq(idx(r, 38), [8, 24], "32nds keep the backbeat")
    DrumOps.setResolution(&r, 3)
    eq(idx(r, 38), [3, 9], "triplets keep the backbeat")
    var bars = k
    DrumOps.setBars(&bars, 2)
    DrumOps.copyBar(&bars, from: 0, to: 1)
    eq(idx(bars, 36), [0, 8, 16, 24], "bar copied")
    DrumOps.clearBar(&bars, 1, lanes: [kick])
    eq(idx(bars, 36), [0, 8], "bar cleared for one lane")
    eq(idx(bars, 38), [4, 12, 20, 28], "other lanes untouched")
    DrumOps.crop(&bars, bars: 1..<2)
    eq(bars.bars, 1, "crop to one bar")
    eq(idx(bars, 38), [4, 12], "crop moves steps to the front")
    var waltz = k
    DrumOps.setBars(&waltz, 2)
    DrumOps.copyBar(&waltz, from: 0, to: 1)
    DrumOps.setMeter(&waltz, Meter(3, 4))
    eq(idx(waltz, 38), [4, 16], "3/4 keeps beat 2 of each bar, drops beat 4")
    var dup = k
    DrumOps.duplicate(&dup)
    eq(dup.bars, 2, "duplicate doubles")
    eq(idx(dup, 38), [4, 12, 20, 28], "duplicate copies steps")
    DrumOps.shift(&dup, lane: snare, by: -5)
    eq(idx(dup, 38), [7, 15, 23, 31], "shift wraps around")
    eq(DrumOps.tiled(k, lengthQ: 6).count, 12 + 6, "tiling cuts the last pass")

    // Representative loop: bars 0, 1 and 3 share a beat; bar 2 is a fill.
    var song = DrumGroove(bars: 4, lanes: [DrumLane(name: "底鼓", note: 36), DrumLane(name: "军鼓", note: 38)])
    for bar in [0, 1, 3] { for i in [0, 8] { DrumOps.toggle(&song, lane: song.lanes[0].id, index: bar * 16 + i) }
        for i in [4, 12] { DrumOps.toggle(&song, lane: song.lanes[1].id, index: bar * 16 + i) } }
    for i in 0..<16 { DrumOps.toggle(&song, lane: song.lanes[1].id, index: 32 + i) }
    eq(DrumOps.representativeLoop(song, bars: 1), 0, "the fill bar is not the loop")
    eq(DrumOps.representativeLoop(song, bars: 2), 0, "two-bar loop")

    // Transcription on a 120 BPM grid (bar line at 0.5 s, clip starts at 0).
    let grid = BeatGrid(bpm: 120, beatOriginUs: 500_000, meter: .fourFour, barAnchorUs: 500_000)
    func on(_ beats: [Double], _ level: Double = -12, decay: Double = 0.05, pitch: Double? = nil) -> [DrumOnset] {
        beats.map { DrumOnset(time: 0.5 + $0 * 0.5, level: level, decay: decay, pitch: pitch) }
    }
    let straight: [DrumPiece: [DrumOnset]] = [
        .kick: on([0, 2, 4, 6]),
        .snare: on([1, 3, 5, 7]) + on([3.75], -30),
        .hihat: on(stride(from: 0.0, to: 8, by: 0.5).map { $0 + 0.025 }, -18),
    ]
    let t = DrumTranscriber.groove(onsets: straight, grid: grid, durationUs: 4_500_000)
    eq(t.startUs, 500_000, "the empty bar before the first bar line is dropped")
    eq(t.groove.bars, 2, "covers the hits")
    eq(t.groove.stepsPerBeat, 4, "straight sixteenths")
    eq(t.groove.swing, 50, "no swing")
    eq(idx(t.groove, 36), [0, 8, 16, 24], "kick on 1 and 3")
    eq(idx(t.groove, 38), [4, 12, 15, 20, 28], "backbeat plus a ghost note")
    check((lane(t.groove, 38)?.step(at: 15)?.velocity ?? 127) < 70, "ghost note is quiet")
    check((lane(t.groove, 42)?.steps.first?.nudge ?? 0) > 0.05, "late hats keep their nudge")
    eq(t.groove.lanes.map(\.note), [36, 38, 42], "lanes in kit order")

    let shuffled: [DrumPiece: [DrumOnset]] = [.hihat: (0..<16).map { i in
        // Pairs of sixteenths a half beat (0.25 s) long, the second at 62 % of the pair.
        DrumOnset(time: 0.5 + Double(i / 2) * 0.25 + Double(i % 2) * 0.25 * 0.62, level: -15, decay: 0.04)
    }]
    let s = DrumTranscriber.groove(onsets: shuffled, grid: grid, durationUs: 2_500_000)
    eq(s.groove.stepsPerBeat, 4, "swung sixteenths stay on a sixteenth grid")
    check(abs(s.groove.swing - 62) <= 1, "swing found (\(s.groove.swing))")
    check((lane(s.groove, 42)?.steps.map { abs($0.nudge) }.max() ?? 1) < 0.05, "swing takes up the offset")

    let triplets: [DrumPiece: [DrumOnset]] = [.hihat: on(Array(stride(from: 0.0, to: 4, by: 1.0 / 3))), .kick: on([0, 2])]
    eq(DrumTranscriber.groove(onsets: triplets, grid: grid, durationUs: 2_500_000).groove.stepsPerBeat, 3, "triplets")

    let kit: [DrumPiece: [DrumOnset]] = [
        .hihat: on([0], -15, decay: 0.4) + on([1, 1.25], -15, decay: 0.05),
        .toms: on([2], -12, pitch: 180) + on([2.5], -12, pitch: 120) + on([3], -12, pitch: 82),
        .cymbals: on([0], -10, decay: 1.2) + on([4, 5, 6, 7], -20, decay: 0.5),
        .snare: on([3.5]) + [DrumOnset(time: 0.5 + 3.5 * 0.5 + 0.06, level: -12, decay: 0.05)],
    ]
    let k2 = DrumTranscriber.groove(onsets: kit, grid: grid, durationUs: 4_500_000).groove
    eq(idx(k2, 46).count, 1, "long hat is open")
    eq(idx(k2, 42).count, 2, "short hats are closed")
    eq([50, 47, 43].map { idx(k2, $0).count }, [1, 1, 1], "three toms by pitch")
    eq(idx(k2, 49).count, 1, "isolated cymbal is a crash")
    eq(idx(k2, 51).count, 4, "time-keeping cymbal is a ride")
    eq(lane(k2, 38)?.steps.first?.repeats, 2, "two snare hits in one step make a ratchet")

    // A crash's ring carries hi-hat strokes into the cymbal track.
    let leak: [DrumPiece: [DrumOnset]] = [.cymbals: on([0], -10, decay: 1.5) + on([1, 1.5], -20, decay: 0.3) + on([3], -35, decay: 0.3),
                                          .hihat: on([0.5, 1, 1.5, 2], -25)]
    let lk = DrumTranscriber.groove(onsets: leak, grid: grid, durationUs: 2_500_000).groove
    eq(idx(lk, 49) + idx(lk, 51), [0], "hat strokes and a faint tail in the cymbal track are dropped")
    eq(idx(lk, 42), [2, 4, 6, 8], "the hats stay")

    // MIDI: drum track on channel 10.
    let p = DrumPattern(title: "t", bpm: 100, groove: k)
    let mid = DrumOps.exportMidi(p)
    check(mid.prefix(4) == Data("MThd".utf8), "MIDI header")
    eq(mid[10...11].map { $0 }, [0, 3], "three tracks with drums")
    check(mid.contains(0x99), "notes on channel 10")
}

/// `swift run MusicnoteChecks drums <analysisId> <outRoot>`: extracts the drums of a clip in the
/// app's library into a scratch data root (the library is only read).
func runDrumExtract(_ args: [String]) async -> Int32 {
    guard args.count >= 3, let id = UUID(uuidString: args[1]) else { print("usage: drums ANALYSIS_ID OUT_ROOT"); return 2 }
    do {
        let lib = AppPaths(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Musicnote"))
        let libStore = try Store(url: lib.database)
        guard let item = libStore.fetch(AnalysisItem.self, id: id) else { print("no such clip"); return 2 }
        let paths = AppPaths(root: URL(fileURLWithPath: args[2]))
        try paths.ensure()
        let store = try Store(url: paths.database)
        try store.save(item)
        for h in libStore.all(HarmonyRevision.self, owner: id) { try store.save(h) }
        for m in libStore.all(MidiRevision.self, owner: id) { try store.save(m) }
        let root = FileManager.default.currentDirectoryPath
        let tools = ToolSettings.defaults(projectRoot: root, separatorBinary: root + "/.build/release/musicnote-separate")
        let pipeline = Pipeline(store: store, paths: paths, tools: tools)
        guard let grid = pipeline.drumGrid(item) else { print("clip has no confirmed grid"); return 2 }
        let song = libStore.fetch(Song.self, id: item.songId)?.title ?? "?"
        let t0 = Date()
        let (pattern, notes) = try await pipeline.extractDrums(item, grid: grid, songTitle: song, patternId: UUID(),
                                                               jobDir: paths.jobs.appendingPathComponent("drums")) { p in
            print("  ·", p.stage, p.completed, p.total.map(String.init) ?? "-")
        }
        print(pattern.title, String(format: "%.1fs", Date().timeIntervalSince(t0)), "bpm", pattern.bpm, "bars", pattern.groove.bars,
              "start", formatTime(us: pattern.source!.startUs))
        notes.forEach { print("  ", $0) }
        let g = pattern.groove
        for l in g.lanes {
            var row = ""
            for i in 0..<min(g.totalSteps, g.stepsPerBar * 4) {
                if i % g.stepsPerBar == 0 { row += "|" }
                let s = l.step(at: i)
                row += s.map { $0.repeats > 1 ? "r" : $0.velocity >= 90 ? "X" : $0.velocity >= 55 ? "x" : "." } ?? "-"
            }
            print(l.name.padding(toLength: 5, withPad: "　", startingAt: 0), row)
        }
        try DrumOps.exportMidi(pattern).write(to: paths.root.appendingPathComponent("pattern.mid"))
        try store.save(pattern)
        return 0
    } catch {
        print("error:", error.localizedDescription); return 1
    }
}

/// `swift run MusicnoteChecks drumwav <drums.wav> <bpm> <barOneSec> <outDir>`: kit split, onsets
/// and grid on a drum track directly (no six-stem split), for checking against a known groove.
func runDrumWav(_ args: [String]) async -> Int32 {
    guard args.count >= 5, let bpm = Double(args[2]), let bar = Double(args[3]) else { print("usage: drumwav WAV BPM BAR1_SEC OUT_DIR"); return 2 }
    let out = URL(fileURLWithPath: args[4])
    let sep = FileManager.default.currentDirectoryPath + "/.build/release/musicnote-separate"
    let w = WorkerProcess(sep, ["--drums", "--input", args[1], "--output-dir", out.path])
    guard let r = try? await w.run(), r.status == 0 else { print("split failed"); return 1 }
    var onsets: [DrumPiece: [DrumOnset]] = [:]
    var duration = 0.0
    for piece in DrumPiece.allCases {
        guard let x = try? Pipeline.monoSamples(out.appendingPathComponent("\(piece.rawValue).wav")) else { continue }
        duration = Double(x.count) / 44100
        onsets[piece] = DrumOnsetDetector.detect(x, pitched: piece == .toms)
        print(piece.rawValue, onsets[piece]!.count, "hits")
        if ProcessInfo.processInfo.environment["ONSETS"] != nil {
            print("   ", onsets[piece]!.map { String(format: "%.3f/%.0f/%.2f", ($0.time - bar) / (60 / bpm) * 4, $0.level, $0.decay) }.joined(separator: " "))
        }
    }
    let us = Int64(bar * 1e6)
    let res = DrumTranscriber.groove(onsets: onsets, grid: BeatGrid(bpm: bpm, beatOriginUs: us, meter: .fourFour, barAnchorUs: us),
                                     durationUs: Int64(duration * 1e6))
    res.notes.forEach { print("  ", $0) }
    let g = res.groove
    for l in g.lanes {
        var row = ""
        for i in 0..<g.totalSteps { if i % g.stepsPerBar == 0 { row += "|" }
            row += l.step(at: i).map { $0.repeats > 1 ? "r" : $0.velocity >= 90 ? "X" : $0.velocity >= 55 ? "x" : "." } ?? "-" }
        print(String(l.note).padding(toLength: 4, withPad: " ", startingAt: 0), row)
    }
    return 0
}

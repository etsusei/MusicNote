import Foundation
import MusicnoteCore
import MusicnotePractice

/// Practice mode: the trip to Logic and back, and the check that a returned take is in place.
func runPracticeChecks() {
    let key = KeySignature(tonic: 6, tonicName: "F♯", mode: .minor)
    func timing(bpm: Double = 120, origin: Int64 = 0, anchor: Int64? = 0) -> TimingConfirmation {
        TimingConfirmation(trimRevision: 1, bpm: bpm, beatOriginUs: origin, meter: .fourFour, meterConfirmed: true,
                           barAnchorUs: anchor, key: key)
    }

    // Where the exported files start: the bar line at or before the clip start.
    eq(LogicRoundTrip.startUs(timing()), 0, "clip starting on bar 1 needs no silence in front")
    eq(LogicRoundTrip.startUs(timing(origin: 300_000, anchor: 300_000)), -1_700_000, "bar 1 at 0.3 s: a bar minus 0.3 s in front")
    eq(LogicRoundTrip.startUs(timing(origin: 0, anchor: 2_000_000)), 0, "bar 1 a whole bar in: the clip start is a bar line")
    eq(LogicRoundTrip.startUs(timing(origin: 130_000, anchor: nil)), -370_000, "no bar 1: the beat line before the start")

    // Out to a MIDI file and back gives the same notes, whatever silence is in front.
    let notes = [
        MidiNote(pitch: 47, startUs: 300_000, endUs: 1_050_000),
        MidiNote(pitch: 62, velocity: 80, startUs: 300_000, endUs: 1_000_000),
        MidiNote(pitch: 66, startUs: 1_300_000, endUs: 1_800_000),
        MidiNote(pitch: 62, startUs: 1_800_000, endUs: 2_300_000),
        MidiNote(pitch: 73, startUs: 7_250_000, endUs: 7_900_000),
    ]
    for t in [timing(), timing(origin: 300_000, anchor: 300_000), timing(bpm: 93.5, origin: 130_000, anchor: nil)] {
        guard let file = try? MidiFileReader.read(LogicRoundTrip.midiData(notes: notes, timing: t)) else {
            check(false, "exported MIDI reads back"); continue
        }
        eq(file.ppq, 960, "ppq")
        check(abs(file.initialBpm - t.bpm) < 0.01, "tempo in the file, got \(file.initialBpm)")
        let back = LogicRoundTrip.fit(LogicRoundTrip.notes(from: file, timing: t), durationUs: 8_000_000)
        eq(back.notes.count, notes.count, "note count after the round trip")
        eq(back.dropped, 0, "nothing dropped")
        for (a, b) in zip(notes, back.notes) {
            check(a.pitch == b.pitch && a.velocity == b.velocity && abs(a.startUs - b.startUs) < 1_000 && abs(a.endUs - b.endUs) < 1_000,
                  "round trip \(a.pitch) \(a.startUs)–\(a.endUs) → \(b.pitch) \(b.startUs)–\(b.endUs)")
        }
    }

    // A pitch struck again while it still sounds: the first note ends at the second strike,
    // which lasts as long as either did; two notes on one key at one moment become one.
    let doubled = LogicRoundTrip.withoutOverlaps([
        MidiNote(pitch: 59, startUs: 1_000_000, endUs: 4_000_000),
        MidiNote(pitch: 59, startUs: 2_900_000, endUs: 3_100_000),
        MidiNote(pitch: 64, startUs: 1_000_000, endUs: 2_000_000),
        MidiNote(pitch: 64, startUs: 1_000_000, endUs: 2_500_000),
        MidiNote(pitch: 64, startUs: 2_500_000, endUs: 3_000_000),
    ])
    eq(doubled.map { [$0.pitch, Int($0.startUs), Int($0.endUs)] },
       [[59, 1_000_000, 2_900_000], [64, 1_000_000, 2_500_000], [64, 2_500_000, 3_000_000], [59, 2_900_000, 4_000_000]], "restruck notes")

    // A file as a DAW writes it: running status, note-on with velocity 0 as note-off, a tempo
    // change, the sustain pedal, a drum-channel note, and a project at another tempo.
    func vlq(_ v: Int) -> [UInt8] {
        var out = [UInt8(v & 0x7F)], x = v >> 7
        while x > 0 { out.insert(UInt8(x & 0x7F) | 0x80, at: 0); x >>= 7 }
        return out
    }
    func chunk(_ tag: String, _ body: [UInt8]) -> [UInt8] {
        Array(tag.utf8) + [UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    }
    // 480 ticks per quarter; 100 BPM (600 000 µs) for two beats, then 50 BPM.
    let conductor: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0]
        + vlq(960) + [0xFF, 0x51, 0x03, 0x12, 0x4F, 0x80]
        + [0x00, 0xFF, 0x2F, 0x00]
    let piano: [UInt8] = [0x00, 0xFF, 0x03, 0x05] + Array("Piano".utf8)
        + [0x00, 0xB0, 64, 127]             // pedal down at 0
        + [0x00, 0x90, 60, 100]             // C4 on at 0
        + vlq(480) + [64, 90]               // running status: E4 on at one beat
        + vlq(480) + [60, 0]                // running status, velocity 0: C4 off at two beats
        + [0x00, 0xB0, 64, 0]               // pedal up at two beats
        + vlq(480) + [0x80, 64, 0]          // E4 off at three beats
        + [0x00, 0x99, 36, 100] + vlq(240) + [0x89, 36, 0] // a kick on the drum channel
        + [0x00, 0xFF, 0x2F, 0x00]
    let raw = Data(chunk("MThd", [0, 1, 0, 2, 0x01, 0xE0]) + chunk("MTrk", conductor) + chunk("MTrk", piano))
    if let file = try? MidiFileReader.read(raw) {
        eq(file.tracks.count, 2, "two tracks")
        eq(file.tracks[1].name, "Piano", "track name")
        eq(file.tracks[1].notes.count, 3, "three notes read")
        check(abs(file.seconds(atTick: 960) - 1.2) < 1e-9, "two beats at 100 BPM")
        check(abs(file.seconds(atTick: 1440) - 2.4) < 1e-9, "the third beat runs at 50 BPM")
        let take = LogicRoundTrip.fit(LogicRoundTrip.notes(from: file, timing: timing()), durationUs: 10_000_000)
        eq(take.notes.map(\.pitch), [60, 64], "the drum-channel note is left out")
        eq(take.notes.first?.endUs, 1_200_000, "C4 ends where the tempo changes")
        eq(take.notes.last?.startUs, 600_000, "E4 starts on the second beat")
        eq(take.notes.last?.endUs, 2_400_000, "E4 ends after a slow beat")
        eq(take.pedals, [PedalSpan(startUs: 0, endUs: 1_200_000)], "pedal span")
        // Cut to a shorter clip: E4 is shortened, nothing is lost.
        let cut = LogicRoundTrip.fit(LogicRoundTrip.notes(from: file, timing: timing()), durationUs: 1_000_000)
        eq(cut.notes.last?.endUs, 1_000_000, "note cut at the clip end")
        eq(cut.pedals.first?.endUs, 1_000_000, "pedal cut at the clip end")
    } else { check(false, "hand-written MIDI file reads") }
    check((try? MidiFileReader.read(Data("RIFFxxxxWAVE".utf8))) == nil, "a WAV is not a MIDI file")
    check((try? MidiFileReader.read(Data(chunk("MThd", [0, 1, 0, 1, 0xE7, 0x28])))) == nil, "SMPTE division is refused")

    // Is a returned take still where the audio is?
    var reference: [MidiNote] = []
    let chord = [[47, 62, 66, 69], [40, 67, 71, 74], [45, 67, 71, 76], [38, 66, 69, 73]]
    for bar in 0..<8 {
        for (beat, len) in [(0.0, 1.4), (2.5, 1.0)] {
            for p in chord[bar % 4] {
                let s = Int64((Double(bar) * 4 + beat) * 500_000)
                reference.append(MidiNote(pitch: p, startUs: s, endUs: s + Int64(len * 500_000)))
            }
        }
    }
    // Hand corrections: every onset nudged by up to 30 ms, a few notes removed, one added.
    var take = reference.enumerated().compactMap { i, n -> MidiNote? in
        if i % 9 == 4 { return nil }
        var m = n
        let nudge = Int64((i * 37) % 61 - 30) * 1_000
        m.startUs = max(0, n.startUs + nudge); m.endUs = n.endUs + nudge
        return m
    }
    take.append(MidiNote(pitch: 81, startUs: 5_250_000, endUs: 5_500_000))
    let inPlace = AlignmentCheck.compare(take: take, reference: reference)
    eq(inPlace.verdict, .aligned, "a corrected take is in place")
    check(inPlace.matched >= take.count - 1, "nearly every note matched, got \(inPlace.matched) of \(inPlace.total)")
    // The same take exported one bar late.
    let late = take.map { n -> MidiNote in var m = n; m.startUs += 2_000_000; m.endUs += 2_000_000; return m }
    if case .shifted(let us) = AlignmentCheck.compare(take: late, reference: reference).verdict {
        check(abs(us - 2_000_000) < 20_000, "a bar late is found, got \(us)")
        let fixed = LogicRoundTrip.fit(.init(notes: late, pedals: []), shiftUs: us, durationUs: 16_000_000)
        eq(AlignmentCheck.compare(take: fixed.notes, reference: reference).verdict, .aligned, "moved back, it is in place")
    } else { check(false, "a take one bar late is reported as shifted") }
    // 150 ms early.
    let early = take.map { n -> MidiNote in var m = n; m.startUs -= 150_000; m.endUs -= 150_000; return m }
    if case .shifted(let us) = AlignmentCheck.compare(take: early, reference: reference).verdict {
        check(abs(us + 150_000) < 20_000, "150 ms early is found, got \(us)")
    } else { check(false, "a take 150 ms early is reported as shifted") }
    // Other music altogether: no verdict.
    let other = (0..<20).map { MidiNote(pitch: 90 + $0 % 5, startUs: Int64($0) * 333_000, endUs: Int64($0) * 333_000 + 200_000) }
    eq(AlignmentCheck.compare(take: other, reference: reference).verdict, .unknown, "nothing in common gives no verdict")
}

/// `swift run MusicnoteChecks practice <dataRoot> <analysisId> <outDir>` runs the Logic export
/// of a real, finished clip into a folder and reads its MIDI back: the audio files must be as
/// long as the clip plus the silence in front, and the notes must return where they were.
func runPracticeFiles(_ args: [String]) async -> Int32 {
    guard args.count >= 4, let id = UUID(uuidString: args[2]) else { print("usage: practice DATA_ROOT ANALYSIS_ID OUT_DIR"); return 2 }
    let paths = AppPaths(root: URL(fileURLWithPath: args[1]))
    let out = URL(fileURLWithPath: args[3], isDirectory: true)
    do {
        let store = try Store(url: paths.database)
        let root = FileManager.default.currentDirectoryPath
        let tools = ToolSettings.defaults(projectRoot: root, separatorBinary: root + "/.build/debug/musicnote-separate")
        let pipeline = Pipeline(store: store, paths: paths, tools: tools)
        guard let item = store.all(AnalysisItem.self).first(where: { $0.id == id }), let timing = item.timing,
              let midi = store.all(MidiRevision.self, owner: id).last(where: { $0.status == .confirmed }),
              let source = Pipeline.resolve(item.source) else { print("FAIL clip, timing, MIDI or source missing"); return 1 }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let padUs = -LogicRoundTrip.startUs(timing)
        let want = Double(item.durationUs + padUs) / 1e6
        print("clip \(item.title) \(Double(item.durationUs) / 1e6) s, \(timing.bpm) BPM, bar 1 at \(timing.barAnchorUs.map { String($0) } ?? "-") µs, pad \(Double(padUs) / 1e6) s, \(midi.notes.count) notes")

        func seconds(_ url: URL) async -> Double {
            nonisolated(unsafe) var text = ""
            _ = try? await WorkerProcess(tools.ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]).run { text += $0 }
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
        var ok = true
        let original = out.appendingPathComponent("1 原曲.wav")
        try await pipeline.exportWav(source, clipOf: item, padUs: padUs, to: original)
        let a = await seconds(original)
        print("original \(a) s, want \(want)"); ok = ok && abs(a - want) < 0.002

        if let stem = item.separation.flatMap({ $0.mix ?? item.selectedStem.flatMap($0.stem) }) {
            let file = out.appendingPathComponent("2 分轨.wav")
            try await pipeline.exportWav(paths.url(relative: stem.relativePath), padUs: padUs, to: file)
            let b = await seconds(file)
            // An MP3 stem may decode a few padding frames long, never short.
            print("stem \(b) s, want \(want)"); ok = ok && b - want > -0.002 && b - want < 0.06
            if let backing = try await pipeline.mixBacking([stem, stem], frames: item.separation?.frames ?? 0, into: out) {
                _ = backing
                let c = await seconds(out.appendingPathComponent("backing.mp3"))
                print("backing (the stem summed with itself) \(c) s, want \(Double(item.durationUs) / 1e6)")
                ok = ok && abs(c - Double(item.durationUs) / 1e6) < 0.08
            } else { print("FAIL no backing written"); ok = false }
        } else { print("no stem kept for this clip") }

        let mid = out.appendingPathComponent("3 MIDI.mid")
        try LogicRoundTrip.midiData(notes: midi.notes, timing: timing).write(to: mid)
        let back = LogicRoundTrip.fit(LogicRoundTrip.notes(from: try MidiFileReader.read(Data(contentsOf: mid)), timing: timing), durationUs: item.durationUs)
        // Each note against the returned note of its pitch that starts nearest.
        var worst: Int64 = 0
        let sent = LogicRoundTrip.withoutOverlaps(midi.notes)
        for n in sent {
            guard let m = back.notes.filter({ $0.pitch == n.pitch }).min(by: { abs($0.startUs - n.startUs) < abs($1.startUs - n.startUs) }) else { worst = .max; continue }
            let d = max(abs(m.startUs - max(0, n.startUs)), abs(m.endUs - min(item.durationUs, n.endUs)))
            if d > worst { worst = d; if d > 1_500 { print("  off: pitch \(n.pitch) \(n.startUs)–\(n.endUs) came back \(m.startUs)–\(m.endUs)") } }
        }
        let report = AlignmentCheck.compare(take: back.notes, reference: midi.notes)
        print("MIDI back: \(back.notes.count) notes, worst difference \(worst) µs, \(report.verdict), matched \(report.matched)/\(report.total)")
        if sent.count != midi.notes.count { print("  \(midi.notes.count - sent.count) notes doubled on the same key at the same moment were merged") }
        ok = ok && back.notes.count == sent.count && worst < 1_500 && report.verdict == .aligned
        print(ok ? "OK" : "FAIL")
        return ok ? 0 : 1
    } catch {
        print("FAIL", error.localizedDescription); return 1
    }
}

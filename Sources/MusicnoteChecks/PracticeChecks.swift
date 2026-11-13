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

/// Time-stretched playback: the clock must say where the audio really is. A click every half
/// second is played at several speeds, through speed changes and around a loop; each click's
/// place in the output is compared with where the clock says that source moment is heard.
func runStretchChecks() {
    let sr = 44_100.0
    let clickEvery = Int(sr / 2), clickLength = 220
    // The source: 5 ms bursts of a 2 kHz tone, silence between.
    let source: StretchPlayer.Source = { start, count, l, r in
        for i in 0..<count {
            let f = Int(start) + i
            let k = f % clickEvery
            var v: Float = 0
            if f >= 0, k < clickLength {
                let env = sin(Double.pi * Double(k) / Double(clickLength))
                v = Float(0.8 * env * sin(2 * Double.pi * 2000 * Double(k) / sr))
            }
            l[i] = v; r[i] = v
        }
    }

    /// Plays `seconds` of output in 512-frame buffers; `speed` gives the speed asked for at
    /// each output time. Returns the output and, for every buffer, what the clock said.
    func play(_ player: StretchPlayer, seconds: Double, speed: (Double) -> Double) -> (out: [Float], map: [StretchPlayer.Rendered]) {
        let n = 512, buffers = Int(seconds * sr) / n
        var out = [Float](repeating: 0, count: buffers * n), right = [Float](repeating: 0, count: n)
        var map: [StretchPlayer.Rendered] = []
        for b in 0..<buffers {
            player.rate = speed(Double(b * n) / sr)
            out.withUnsafeMutableBufferPointer { o in
                right.withUnsafeMutableBufferPointer { rr in
                    map.append(player.render(frames: n, left: o.baseAddress! + b * n, right: rr.baseAddress!, source: source))
                }
            }
        }
        return (out, map)
    }

    /// Output frame at which the clock says source frame `f` is heard (first time after `from`).
    func outputFrame(of f: Double, in map: [StretchPlayer.Rendered], from: Int = 0) -> Double? {
        for (b, r) in map.enumerated() {
            for s in r.wrapped ? [r.first, r.second] : [r.first] where s.outCount > 0 && b * 512 + s.outOffset >= from {
                if f >= s.sourceStart, f < s.sourceEnd {
                    return Double(b * 512 + s.outOffset) + (f - s.sourceStart) / (s.sourceEnd - s.sourceStart) * Double(s.outCount)
                }
            }
        }
        return nil
    }

    /// Centre of the click nearest an expected output frame: the energy centroid around it.
    func clickCentre(_ out: [Float], near: Double, width: Int) -> Double? {
        let a = max(0, Int(near) - width), b = min(out.count, Int(near) + width)
        guard b > a else { return nil }
        var e = 0.0, m = 0.0
        for i in a..<b { let p = Double(out[i] * out[i]); e += p; m += p * Double(i) }
        return e > 1e-4 ? m / e : nil
    }

    /// Worst distance (ms of output time) between where clicks are heard and where the clock
    /// puts them, over the clicks whose centres lie in `sourceRange`.
    func worstError(_ out: [Float], _ map: [StretchPlayer.Rendered], clicks: [Int], label: String) -> Double {
        var worst = 0.0, found = 0
        for c in clicks {
            let centre = Double(c * clickEvery + clickLength / 2)
            guard let expected = outputFrame(of: centre, in: map) else { continue }
            guard let heard = clickCentre(out, near: expected, width: Int(sr * 0.12)) else {
                check(false, "\(label): click \(c) is missing from the output"); continue
            }
            found += 1
            worst = max(worst, abs(heard - expected) / sr * 1000)
            if ProcessInfo.processInfo.environment["STRETCH_VERBOSE"] != nil {
                print(String(format: "    %@ click %d: %+.1f ms", label, c, (heard - expected) / sr * 1000))
            }
        }
        check(found >= clicks.count - 1, "\(label): \(found) of \(clicks.count) clicks found")
        return worst
    }

    // Steady speeds.
    for speed in [1.0, 0.75, 0.5] {
        let player = StretchPlayer(sampleRate: sr)
        player.rate = speed
        player.seek(to: 0)
        let began = Date()
        let (out, map) = play(player, seconds: 6, speed: { _ in speed })
        let cost = Date().timeIntervalSince(began) / 6 * 100
        let clicks = Array(1...Int(6 * speed * 2 - 1))
        let worst = worstError(out, map, clicks: clicks, label: "speed \(speed)")
        print(String(format: "  stretch: speed %.2f, clock off by at most %.1f ms over %d clicks, %.1f%% of one core", speed, worst, clicks.count, cost))
        check(cost < 50, "speed \(speed): rendering takes \(cost)% of real time")
        check(worst < 12, "speed \(speed): clicks within 12 ms of the clock, worst \(worst)")
    }

    // The speed dragged around while playing: 1 → 0.6 → 0.85 → 0.5 → 1, a change every 2 s.
    do {
        let player = StretchPlayer(sampleRate: sr)
        let steps = [1.0, 0.6, 0.85, 0.5, 1.0, 0.7]
        let (out, map) = play(player, seconds: 12, speed: { steps[min(steps.count - 1, Int($0 / 2))] })
        let heardSeconds = map.last.map { $0.first.sourceEnd / sr } ?? 0
        let clicks = Array(1...Int(heardSeconds * 2 - 1))
        let worst = worstError(out, map, clicks: clicks, label: "changing speed")
        print(String(format: "  stretch: speed changed five times, clock off by at most %.1f ms over %d clicks", worst, clicks.count))
        check(worst < 15, "changing speed: clicks within 15 ms of the clock, worst \(worst)")
        // The glide: one buffer after a change the speed has moved, but not all the way.
        let p2 = StretchPlayer(sampleRate: sr)
        _ = play(p2, seconds: 0.5, speed: { _ in 1 })
        p2.rate = 0.5
        _ = play(p2, seconds: 512 / sr, speed: { _ in 0.5 })
        check(p2.currentRate < 1 && p2.currentRate > 0.5, "the speed glides, got \(p2.currentRate) one buffer after the change")
        _ = play(p2, seconds: 0.5, speed: { _ in 0.5 })
        eq(p2.currentRate, 0.5, "and arrives")
    }

    // A loop from 1.0 s to 3.0 s at 0.75 speed: the clock stays inside it and the clicks at
    // 1.0, 1.5, 2.0 and 2.5 s come round again where the clock says.
    do {
        let player = StretchPlayer(sampleRate: sr)
        player.rate = 0.75
        player.setLoop(Int64(sr)..<Int64(3 * sr))
        let (out, map) = play(player, seconds: 9, speed: { _ in 0.75 })
        check(map.allSatisfy { $0.first.sourceStart >= sr - 1 && $0.first.sourceEnd <= 3 * sr + 1 }, "the clock stays inside the loop")
        let wraps = map.enumerated().filter { $0.element.wrapped }.map { $0.offset * 512 + $0.element.second.outOffset }
        check(wraps.count == 3, "three times round in 9 s, got \(wraps.count)")
        var worst = 0.0, found = 0
        for pass in [0] + wraps {
            for c in [3, 4, 5] {
                let centre = Double(c * clickEvery + clickLength / 2)
                guard let expected = outputFrame(of: centre, in: map, from: pass), expected < Double(out.count) - sr * 0.2,
                      let heard = clickCentre(out, near: expected, width: Int(sr * 0.12)) else { continue }
                found += 1
                worst = max(worst, abs(heard - expected) / sr * 1000)
            }
        }
        print(String(format: "  stretch: looping, clock off by at most %.1f ms over %d clicks", worst, found))
        check(found >= 9 && worst < 12, "loop: \(found) clicks within 12 ms of the clock, worst \(worst)")
    }
}

/// The practice page's own logic: bar lines and the loop, the keyboard layout, the notes on screen.
func runPracticePageChecks() {
    let key = KeySignature(tonic: 0, tonicName: "C", mode: .major)
    // 120 BPM in 4/4: a bar is 2 s. Bar 1 starts 0.5 s into a 21 s clip.
    let timing = TimingConfirmation(trimRevision: 1, bpm: 120, beatOriginUs: 500_000, meter: .fourFour, meterConfirmed: true,
                                    barAnchorUs: 500_000, key: key)
    let bars = PracticeBars(timing: timing, durationUs: 21_000_000)
    eq(bars.lines.first, PracticeBars.Line(us: 500_000, number: 1), "first bar line")
    eq(bars.lines.count, 11, "bar lines at 0.5, 2.5 … 20.5 s")
    eq(bars.barNumber(at: 0), 0, "the pickup is bar 0")
    eq(bars.barNumber(at: 2_500_000), 2, "bar 2 starts at 2.5 s")
    eq(bars.start(ofBar: 3), 4_500_000, "bar 3")
    eq(bars.snap(3_300_000), 2_500_000, "snaps to the nearest bar line")
    eq(bars.snap(100_000), 0, "the clip start is a place to snap to")
    eq(bars.snap(20_900_000), 21_000_000, "so is its end")
    eq(bars.loop(8_400_000, 2_600_000), 2_500_000..<8_500_000, "a loop from two points in either order")
    eq(bars.loop(4_400_000, 4_600_000), 4_500_000..<6_500_000, "never shorter than a bar")
    eq(bars.loop(20_900_000, 20_950_000), 18_500_000..<21_000_000, "at the end it reaches back to the bar line a bar before")
    eq(bars.defaultLoop(at: 5_000_000), 4_500_000..<12_500_000, "four bars from the bar being played")
    eq(bars.playRange(4_500_000..<8_500_000, preroll: true), 2_500_000..<8_500_000, "the lead-in starts a bar early")
    eq(bars.playRange(500_000..<4_500_000, preroll: true), 0..<4_500_000, "but not before the clip")
    eq(bars.playRange(4_500_000..<8_500_000, preroll: false), 4_500_000..<8_500_000, "no lead-in")
    eq(bars.label(4_500_000..<12_500_000), "3–6", "loop label")
    eq(bars.label(4_500_000..<6_500_000), "3", "one-bar loop label")
    eq(bars.label(0..<4_500_000), "1–2", "a loop from the clip start is named from bar 1, not the half-second pickup")
    // No bar 1 set: bars count from the beat origin.
    let loose = PracticeBars(timing: TimingConfirmation(trimRevision: 1, bpm: 120, beatOriginUs: 130_000, meter: .fourFour,
                                                        meterConfirmed: false, barAnchorUs: nil, key: key), durationUs: 5_000_000)
    eq(loose.lines.map(\.us), [130_000, 2_130_000, 4_130_000], "bars from the beat origin")

    // Speed steps.
    eq(PracticeSettings.steppedRate(0.75, by: -1), 0.7, "one step slower")
    eq(PracticeSettings.steppedRate(0.73, by: 1), 0.8, "an odd speed steps from its nearest 5%")
    eq(PracticeSettings.steppedRate(1.0, by: 1), 1.0, "not past original speed")
    eq(PracticeSettings.steppedRate(0.5, by: -1), 0.5, "not below half speed")

    // The keyboard: 52 white keys; A0 first, C8 last; black keys straddle their neighbours.
    eq((PianoKeys.lowest...PianoKeys.highest).filter { !PianoKeys.isBlack($0) }.count, 52, "52 white keys")
    check(PianoKeys.frame(21).map { $0.x == 0 } ?? false, "A0 at the left edge")
    check(PianoKeys.frame(108).map { abs($0.x + $0.width - 1) < 1e-9 } ?? false, "C8 ends at the right edge")
    if let c4 = PianoKeys.frame(60), let cs4 = PianoKeys.frame(61), let d4 = PianoKeys.frame(62) {
        check(abs(c4.x - 23 * PianoKeys.whiteWidth) < 1e-9, "middle C is the 24th white key")
        check(abs(cs4.x + cs4.width / 2 - d4.x) < 1e-9, "C♯4 is centred on the line between C4 and D4")
    } else { check(false, "middle C has a place") }
    check(PianoKeys.frame(20) == nil && PianoKeys.frame(109) == nil, "nothing off the keyboard")
    eq(PianoKeys.cLabel(60), "C4", "middle C label")
    check(PianoKeys.cLabel(62) == nil, "only C keys are labelled")

    // The notes on screen.
    let line = NoteTimeline([
        MidiNote(pitch: 60, startUs: 0, endUs: 9_000_000),          // a long held note
        MidiNote(pitch: 64, startUs: 1_000_000, endUs: 1_500_000),
        MidiNote(pitch: 67, startUs: 4_000_000, endUs: 4_500_000),
        MidiNote(pitch: 72, startUs: 8_000_000, endUs: 8_200_000),
    ])
    eq(line.visible(fromUs: 3_000_000, toUs: 6_000_000).map { line.notes[$0].pitch }, [60, 67], "the held note and the one in the window")
    eq(line.visible(fromUs: 9_000_000, toUs: 12_000_000), [], "nothing after the last note")
    eq(line.sounding(atUs: 1_200_000), [60, 64], "sounding together")
    eq(line.sounding(atUs: 1_500_000), [60], "a note is over at its end")
}

/// Keys pressed on the connected keyboard: right or wrong.
func runPracticeJudgeChecks() {
    let line = NoteTimeline([
        MidiNote(pitch: 60, startUs: 1_000_000, endUs: 3_000_000),
        MidiNote(pitch: 64, startUs: 1_000_000, endUs: 1_200_000),
        MidiNote(pitch: 67, startUs: 5_000_000, endUs: 5_100_000),
    ])
    var judge = PracticeJudge()
    check(judge.keyDown(60, atUs: 1_050_000, rate: 1, in: line) == .hit, "on time")
    check(judge.keyDown(64, atUs: 880_000, rate: 1, in: line) == .hit, "120 ms early still counts")
    check(judge.keyDown(62, atUs: 1_000_000, rate: 1, in: line) == .wrong, "a pitch the music does not have")
    eq(judge.held.count, 3, "three keys held")
    judge.keyUp(62)
    check(judge.held[62] == nil && judge.held[60] == .hit, "a released key is forgotten, the others keep their verdict")
    check(judge.keyDown(60, atUs: 2_500_000, rate: 1, in: line) == .hit, "late into a held note still counts")
    check(judge.keyDown(64, atUs: 1_500_000, rate: 1, in: line) == .wrong, "but not after a short note is over")
    check(judge.keyDown(67, atUs: 4_700_000, rate: 1, in: line) == .wrong, "300 ms early is too early")
    check(judge.keyDown(67, atUs: 5_150_000, rate: 1, in: line) == .hit, "150 ms after a short note's start still counts")
    // At half speed 180 ms of real time reaches only 90 ms of the music.
    check(judge.keyDown(67, atUs: 4_880_000, rate: 0.5, in: line) == .wrong, "120 ms of music early is 240 ms real at half speed")
    check(judge.keyDown(67, atUs: 4_930_000, rate: 0.5, in: line) == .hit, "70 ms of music early is 140 ms real at half speed")
    eq(judge.hits, 5, "hits counted")
    eq(judge.wrongs, 4, "wrong presses counted")
    judge.releaseAll()
    check(judge.held.isEmpty, "all released")
}

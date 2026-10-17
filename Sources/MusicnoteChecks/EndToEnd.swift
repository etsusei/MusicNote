import Foundation
import MusicnoteCore

/// `swift run MusicnoteChecks e2e <audio> <startSec> <endSec> <dataRoot>` drives the
/// whole backend on a real file: detect → confirm → separate → transcribe → harmony.
func runEndToEnd(_ args: [String]) async -> Int32 {
    guard args.count >= 5, let start = Double(args[2]), let end = Double(args[3]) else {
        print("usage: e2e AUDIO START END DATA_ROOT"); return 2
    }
    let audio = URL(fileURLWithPath: args[1])
    let paths = AppPaths(root: URL(fileURLWithPath: args[4]))
    do {
        try paths.ensure()
        let store = try Store(url: paths.database)
        let root = FileManager.default.currentDirectoryPath
        let tools = ToolSettings.defaults(projectRoot: root, separatorBinary: root + "/.build/debug/musicnote-separate")
        print("missing tools:", tools.missing())
        let pipeline = Pipeline(store: store, paths: paths, tools: tools)
        let source = try Pipeline.inspectSource(url: audio)
        print("source", source.fileName, source.durationSec, source.sampleRate)
        let song = Song(title: audio.deletingPathExtension().lastPathComponent)
        var item = AnalysisItem(songId: song.id, title: "e2e", source: source,
                                trimStartUs: Int64(start * 1e6), trimEndUs: Int64(end * 1e6))
        try store.save(song); try store.save(item)
        let progress: ProgressHandler = { p in print("  ·", p.stage, p.completed, p.total.map(String.init) ?? "-") }

        var t = Date()
        let det = try await pipeline.detect(item, jobDir: paths.jobs.appendingPathComponent("detect"), progress: progress)
        print("detect", det.rawBpm ?? -1, "→", det.roundedBpm ?? -1, det.rawKey ?? "?", det.rawScale ?? "?", "ticks", det.ticksSec.count, String(format: "%.1fs", Date().timeIntervalSince(t)))
        item.detection = det
        let tonic = Pitch.parsePitchClass(det.rawKey ?? "C") ?? 0
        let key = KeySignature(tonic: tonic, tonicName: Pitch.normalizeName(det.rawKey ?? "C"), mode: det.rawScale == "minor" ? .minor : .major)
        let origin = Int64(((det.ticksSec.first ?? 0) * 1e6).rounded())
        item.timing = TimingConfirmation(trimRevision: item.trimRevision, bpm: det.roundedBpm ?? 120, beatOriginUs: origin,
                                         meter: .fourFour, meterConfirmed: false, barAnchorUs: nil, key: key)
        item.timingRevision = 1

        t = Date()
        let sep = try await pipeline.separate(item, jobDir: paths.jobs.appendingPathComponent("separate"), progress: progress)
        print("separate", sep.stems.map { "\($0.kind.rawValue):\($0.level.rawValue)" }, "gain", sep.sharedGainDb, String(format: "%.1fs", Date().timeIntervalSince(t)))
        item.separation = sep

        t = Date()
        let midi = try await pipeline.transcribe(item, stem: .piano, revision: 1, parent: nil, progress: progress)
        print("transcribe notes", midi.notes.count, String(format: "%.1fs", Date().timeIntervalSince(t)))

        t = Date()
        let harmony = await pipeline.analyzeHarmony(item, midi: midi, timing: item.timing!, revision: 1, previous: nil)
        print("harmony", harmony.namerVersion, "events", harmony.events.count, String(format: "%.1fs", Date().timeIntervalSince(t)))
        for e in harmony.events {
            print(String(format: "  %@–%@", formatTime(us: e.startUs), formatTime(us: e.endUs)),
                  e.symbol ?? "未确定", e.degree?.display ?? "", e.texture.rawValue,
                  "cands:", e.candidates.prefix(3).map(\.symbol).joined(separator: " "))
        }
        if args.count >= 6 {
            var midiC = midi; midiC.status = .confirmed
            item.confirmedMidiRevision = 1; item.selectedStem = .piano; item.harmonyRevision = 1; item.state = .ready
            try store.save(midiC); try store.save(harmony); try store.save(item)
            let snap = SnapshotBuilder(store: store).analysisSnapshot(item)
            let text = TeacherPrompt.skeletonTask + "\n\n数据：\n" + SnapshotBuilder.json(snap)
            let provider: ChatProvider = args[5] == "claude"
                ? ClaudeProvider(binary: tools.claudeBinary, sandboxDir: paths.chatSandbox)
                : CodexProvider(binary: tools.codexBinary, sandboxDir: paths.chatSandbox)
            print("status", await provider.status())
            t = Date()
            let r = try await provider.send(ProviderTurn(sessionId: nil, systemPrompt: TeacherPrompt.system, text: text,
                                                         model: nil, effort: "low", outputSchema: TeacherPrompt.skeletonSchema)) { _ in }
            print("skeleton raw chars", r.text.count, "tokens", r.contextTokens ?? -1, "window", r.contextWindow ?? -1, String(format: "%.1fs", Date().timeIntervalSince(t)))
            if let parsed = SkeletonParser.parse(r.text, events: harmony.events) {
                print("backbone", parsed.backbone, "tags", parsed.suggestedTags)
                print(parsed.explanation.prefix(400))
            } else { print("UNPARSED:", r.text.prefix(600)) }
        }
        return 0
    } catch {
        print("E2E FAILED:", error.localizedDescription)
        return 1
    }
}

/// `swift run MusicnoteChecks seed <dataRoot>`: copies the first ready item into one item per
/// earlier state, plus a Playground project, so every page can be snapshot-checked.
func runSeed(_ args: [String]) -> Int32 {
    guard args.count >= 2 else { print("usage: seed DATA_ROOT"); return 2 }
    let paths = AppPaths(root: URL(fileURLWithPath: args[1]))
    guard let store = try? Store(url: paths.database), let base = store.all(AnalysisItem.self).first(where: { $0.state == .ready }) else {
        print("no ready item"); return 1
    }
    func copy(_ title: String, _ f: (inout AnalysisItem) -> Void) -> UUID {
        var i = base
        i.id = UUID(); i.title = title
        i.confirmedMidiRevision = nil; i.harmonyRevision = nil
        f(&i)
        try? store.save(i)
        return i.id
    }
    let draft = copy("选区阶段") { $0.state = .draft; $0.detection = nil; $0.timing = nil; $0.separation = nil; $0.selectedStem = nil }
    let confirm = copy("确认阶段") { $0.state = .awaitingConfirmation; $0.timing = nil; $0.separation = nil; $0.selectedStem = nil }
    let stems = copy("选轨阶段") { $0.state = .awaitingStem; $0.selectedStem = nil }
    // Playground with the base item's progression.
    var ids: [String] = ["draft:\(draft)", "confirm:\(confirm)", "stems:\(stems)", "ready:\(base.id)"]
    if let h = store.all(HarmonyRevision.self, owner: base.id).last, let t = base.timing,
       let midi = store.all(MidiRevision.self, owner: base.id).last {
        let ctx = PlaygroundOps.SourceContext(analysisId: base.id, harmonyRevision: h.revision, timing: t, notes: midi.notes, segmentDurationUs: base.durationUs)
        var p = PlaygroundProject(title: "练习作品", key: KeySignature(tonic: 2, tonicName: "D", mode: .minor), bpm: 96, meter: .fourFour)
        p.sections = [PlaygroundSection(name: "Verse", barCount: 8), PlaygroundSection(name: "Chorus", barCount: 4)]
        p.sections[0].blocks = (try? PlaygroundOps.blocks(events: h.events, context: ctx, kind: "progression", voicing: .original, target: p.key)) ?? []
        if let m = PlaygroundOps.manualBlock(rootPc: 7, suffix: "m7", target: p.key, durationQ: 4) { p.sections[1].blocks = [m] }
        try? store.save(p)
        ids.append("playground:\(p.id)")
    }
    print(ids.joined(separator: "\n"))
    return 0
}

/// `swift run MusicnoteChecks regroup <dataRoot>`: prints current vs. new grouping for every
/// harmonic item, without saving anything.
func runRegroup(_ args: [String]) -> Int32 {
    guard args.count >= 2, let store = try? Store(url: AppPaths(root: URL(fileURLWithPath: args[1])).database) else { return 2 }
    if args.count >= 3, args[2] == "--save" {
        // Only for scratch copies: writes a new harmony revision per item.
        let root = FileManager.default.currentDirectoryPath
        let pipeline = Pipeline(store: store, paths: AppPaths(root: URL(fileURLWithPath: args[1])),
                                tools: ToolSettings.defaults(projectRoot: root, separatorBinary: ""))
        let sem = DispatchSemaphore(value: 0)
        Task {
            for var item in store.all(AnalysisItem.self) where item.isHarmonic {
                guard let t = item.timing, let r = item.confirmedMidiRevision,
                      let midi = store.all(MidiRevision.self, owner: item.id).first(where: { $0.revision == r }) else { continue }
                let prev = store.all(HarmonyRevision.self, owner: item.id).max { $0.revision < $1.revision }
                let h = await pipeline.analyzeHarmony(item, midi: midi, timing: t, revision: (prev?.revision ?? 0) + 1, previous: prev)
                try? store.save(h); item.harmonyRevision = h.revision; try? store.save(item)
                print("saved r\(h.revision):", h.events.map { $0.symbol ?? "?" }.joined(separator: " "))
            }
            sem.signal()
        }
        sem.wait()
        return 0
    }
    for item in store.all(AnalysisItem.self) where item.isHarmonic {
        guard let t = item.timing, let r = item.confirmedMidiRevision,
              let midi = store.all(MidiRevision.self, owner: item.id).first(where: { $0.revision == r }) else { continue }
        let groups = ChordGrouper().group(notes: midi.notes, grid: t.grid, durationUs: item.durationUs, key: t.key)
        print("== \(item.title) (\(t.bpm) BPM, \(t.key.display))")
        for g in groups {
            print(String(format: "  %7.3f–%7.3f  %5.2f拍  ", g.startUs.seconds, g.endUs.seconds, Double(g.endUs - g.startUs) / t.grid.beatUs),
                  g.candidates.prefix(3).map(\.symbol).joined(separator: " / "))
        }
    }
    return 0
}

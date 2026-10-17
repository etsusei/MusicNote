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
        print("transcribe notes", midi.notes.count, String(format: "%.1fs", Date().timeIntervalSince(t)), "lead-in", sep.leadInUs.map { String(format: "%.2fs", Double($0) / 1e6) } ?? "none")
        print("first onsets", midi.notes.sorted { $0.startUs < $1.startUs }.prefix(12).map { String(format: "%.2f", Double($0.startUs) / 1e6) }.joined(separator: " "))

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

/// `swift run MusicnoteChecks skeleton <dataRoot> [codex|claude]`: runs the skeleton prompt on the
/// first harmonic item and prints what the learner would read. Doesn't save.
func runSkeleton(_ args: [String]) async -> Int32 {
    guard args.count >= 2, let store = try? Store(url: AppPaths(root: URL(fileURLWithPath: args[1])).database),
          let item = store.all(AnalysisItem.self).first(where: { $0.isHarmonic && $0.confirmedMidiRevision != nil }) else { return 2 }
    let paths = AppPaths(root: URL(fileURLWithPath: args[1]))
    let tools = ToolSettings.defaults(projectRoot: FileManager.default.currentDirectoryPath, separatorBinary: "")
    let builder = SnapshotBuilder(store: store)
    guard let h = builder.latestHarmony(item.id) else { return 1 }
    let text = TeacherPrompt.skeletonTask + "\n\n数据：\n" + SnapshotBuilder.json(builder.analysisSnapshot(item))
    let provider: ChatProvider = args.count > 2 && args[2] == "claude"
        ? ClaudeProvider(binary: tools.claudeBinary, sandboxDir: paths.chatSandbox)
        : CodexProvider(binary: tools.codexBinary, sandboxDir: paths.chatSandbox)
    do {
        let r = try await provider.send(ProviderTurn(sessionId: nil, systemPrompt: TeacherPrompt.system, text: text, model: nil,
                                                     effort: "medium", outputSchema: TeacherPrompt.skeletonSchema)) { _ in }
        guard let p = SkeletonParser.parse(r.text, events: h.events) else { print("UNPARSED:\n" + r.text); return 1 }
        let byId = Dictionary(uniqueKeysWithValues: h.events.map { ($0.id, $0) })
        if let k = p.keySuggestion { print("调性：", k.modeName, k.agreesWithCurrent ? "（与当前一致）" : "（与当前不同）", "—", k.reason) }
        print("数字型：", p.numberPattern)
        print("一句话：", p.summary)
        for v in p.voicings { print("  voicing", byId[v.eventId]?.symbol ?? "?", v.description) }
        print("骨架：", p.backbone.map { byId[$0]?.symbol ?? "?" }.joined(separator: " → "))
        for rel in p.relations { print("  ·", byId[rel.eventId]?.symbol ?? "?", rel.kind, rel.reason) }
        for a in p.alternatives { print("  另一种：", a.backboneEventIds.map { byId[$0]?.symbol ?? "?" }.joined(separator: " → "), a.reason) }
        print("—— explanation（\(p.explanation.count) 字）——\n" + p.explanation)
        print("标签：", p.suggestedTags)
        if args.contains("--save") {
            var sk = Skeleton(analysisId: item.id, harmonyRevision: h.revision, provider: provider.id, model: "默认")
            sk.backboneEventIds = p.backbone; sk.relations = p.relations; sk.alternatives = p.alternatives
            sk.explanation = p.explanation; sk.summary = p.summary; sk.numberPattern = p.numberPattern
            sk.keySuggestion = p.keySuggestion; sk.voicings = p.voicings; sk.keyUsed = item.timing?.key.display; sk.status = .succeeded
            try? store.save(sk)
        }
        return 0
    } catch { print("FAILED:", error.localizedDescription); return 1 }
}

/// `swift run MusicnoteChecks autoanalyze <dataRoot> <analysisId> [model] [effort]`: runs the
/// model-driven analysis on a library (use a copy) and prints the trail and the result.
func runAutoAnalyze(_ rawArgs: [String]) async -> Int32 {
    let useClaude = rawArgs.contains("--claude")
    let args = rawArgs.filter { $0 != "--claude" }
    guard args.count >= 3, let id = UUID(uuidString: args[2]) else { print("usage: autoanalyze DATA_ROOT ANALYSIS_ID [model] [effort] [--claude]"); return 2 }
    let paths = AppPaths(root: URL(fileURLWithPath: args[1]))
    guard let store = try? Store(url: paths.database), let item = store.fetch(AnalysisItem.self, id: id) else { print("no item"); return 2 }
    let root = FileManager.default.currentDirectoryPath
    let tools = ToolSettings.defaults(projectRoot: root, separatorBinary: root + "/.build/debug/musicnote-separate")
    let model = args.count > 3 ? args[3] : nil
    let effort = args.count > 4 ? args[4] : "medium"
    let run = AutoRun(analysisId: id, trimRevision: item.trimRevision, provider: useClaude ? "claude" : "codex", model: model ?? "默认",
                      maxToolCalls: AutoAgent.defaultMaxToolCalls, maxSeconds: AutoAgent.defaultMaxSeconds)
    let box = AutoToolbox(store: store, paths: paths, tools: tools, item: item, run: run)
    nonisolated(unsafe) var shown = 0
    box.onUpdate = { r in
        while shown < r.steps.count {
            let s = r.steps[shown]; shown += 1
            print(String(format: "[%5.1fs] %@ %@ → %@", s.seconds, s.ok ? "✓" : "✗", s.tool, s.arguments))
            print("        " + s.summary.replacingOccurrences(of: "\n", with: "\n        ").prefix(500))
        }
    }
    let provider: any AgentProvider = useClaude
        ? ClaudeAgentProvider(binary: tools.claudeBinary, sandboxDir: paths.chatSandbox, python: tools.systemPython, bridgeScript: tools.workers + "/mcp_bridge.py")
        : CodexProvider(binary: tools.codexBinary, sandboxDir: paths.chatSandbox, enableCodeMode: true)
    let t0 = Date()
    let song = store.fetch(Song.self, id: item.songId)?.title ?? ""
    await AutoAgent.run(toolbox: box, provider: provider, songTitle: song, model: model, effort: effort)
    let r = box.run
    print("== status", r.status.rawValue, "tool calls", r.toolCalls, String(format: "%.0fs", Date().timeIntervalSince(t0)), r.error ?? "")
    for rv in r.reviews { print("复核：", rv.question, "|", rv.observedEvidence, "|", rv.decision, "|", rv.stopReason) }
    if let h = r.result(in: store), let t = item.timing {
        var g = t.grid; if g.barAnchorUs == nil { g.barAnchorUs = h.barAnchorUs }
        print("summary:", h.auto?.summary ?? "")
        if let k = h.auto?.key { print("key:", k.tonic, k.mode, k.modeName, k.reason) }
        for e in h.events {
            let p = BarEvidence.position(e.startUs, grid: g)
            print(String(format: "  %d.%@  %-10@ %@ %@", p.bar, p.beat == p.beat.rounded() ? String(Int(p.beat)) : String(format: "%.1f", p.beat),
                         e.symbol ?? "?", h.auto?.chordInfo[e.id]?.roleDisplay ?? "", h.auto?.chordInfo[e.id]?.reason ?? ""))
        }
        for c in h.auto?.toConfirm ?? [] { let p = BarEvidence.position(c.startUs, grid: g); print("  待确认 \(p.bar).\(p.beat):", c.question) }
    }
    print("final:", r.finalMessage)
    return r.status == .succeeded ? 0 : 1
}

/// Read-only: what "片段" plays for each chord of the current harmony, next to everything the chord covers.
func runVoicings(_ args: [String]) -> Int32 {
    guard args.count >= 3, let store = try? Store(url: AppPaths(root: URL(fileURLWithPath: args[1])).database),
          let id = UUID(uuidString: args[2]), let item = store.fetch(AnalysisItem.self, id: id),
          let h = store.all(HarmonyRevision.self, owner: id).first(where: { $0.revision == item.harmonyRevision }),
          let r = item.confirmedMidiRevision, let midi = store.all(MidiRevision.self, owner: id).first(where: { $0.revision == r }) else { return 2 }
    let window = min(0.6, (item.timing?.grid.beatUs ?? 600_000) / 1e6)
    var fallback = 0
    for ev in h.events {
        let rel: [PlayedVoicing.Note] = midi.notes.filter { ev.noteIds.contains($0.id) }.map { n in
            let s = max(n.startUs, ev.startUs)
            return (pitch: n.pitch, start: Double(s - ev.startUs) / 1e6, duration: Double(min(n.endUs, ev.endUs) - s) / 1e6)
        }
        let played = PlayedVoicing.pitches(symbol: ev.symbol, notes: rel, onsetWindow: window)
        if played == nil { fallback += 1 }
        let all = Array(Set(rel.map(\.pitch))).sorted()
        print((ev.symbol ?? "?").padding(toLength: 12, withPad: " ", startingAt: 0),
              "片段:", played.map { $0.map { Pitch.noteName($0) }.joined(separator: " ") } ?? "→ 标准",
              " | 原来全部:", all.map { Pitch.noteName($0) }.joined(separator: " "))
    }
    print("\(h.events.count) chords, \(fallback) fall back to standard")
    return 0
}

/// Adopts the latest model result as the current harmony (same as the app's "采用这个结果").
func runAdopt(_ args: [String]) -> Int32 {
    guard args.count >= 3, let store = try? Store(url: AppPaths(root: URL(fileURLWithPath: args[1])).database),
          let id = UUID(uuidString: args[2]),
          let run = store.all(AutoRun.self, owner: id).filter(\.submitted).max(by: { $0.startedAt < $1.startedAt }) else { return 2 }
    do {
        let h = try AutoAdoption.adopt(run, store: store)
        print("adopted run \(run.id) as r\(h.revision):", h.events.compactMap(\.symbol).joined(separator: " "))
        return 0
    } catch { print(error.localizedDescription); return 1 }
}

/// Calls one autonomous-analysis tool directly (no model): `tool DATA_ROOT ANALYSIS_ID NAME [JSON_ARGS]`.
/// Reads go through the same scope checks; nothing is submitted unless NAME is submit_analysis.
func runTool(_ args: [String]) async -> Int32 {
    guard args.count >= 4, let id = UUID(uuidString: args[2]) else { print("usage: tool DATA_ROOT ANALYSIS_ID NAME [JSON]"); return 2 }
    let paths = AppPaths(root: URL(fileURLWithPath: args[1]))
    guard let store = try? Store(url: paths.database), let item = store.fetch(AnalysisItem.self, id: id) else { print("no item"); return 2 }
    let root = FileManager.default.currentDirectoryPath
    let tools = ToolSettings.defaults(projectRoot: root, separatorBinary: root + "/.build/debug/musicnote-separate")
    let run = AutoRun(analysisId: id, trimRevision: item.trimRevision, provider: "cli", model: "-", maxToolCalls: 99, maxSeconds: 9999)
    let box = AutoToolbox(store: store, paths: paths, tools: tools, item: item, run: run)
    let json = args.count > 4 ? ((try? JSONSerialization.jsonObject(with: Data(args[4].utf8))) as? [String: Any] ?? [:]) : [:]
    let (text, ok) = await box.call(args[3], json)
    print(ok ? "OK" : "FAILED"); print(text)
    paths.removeOwned(paths.jobs.appendingPathComponent("auto-\(run.id.uuidString)", isDirectory: true))
    return ok ? 0 : 1
}

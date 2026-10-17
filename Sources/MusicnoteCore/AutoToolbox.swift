import Foundation

/// The tools a model can call during autonomous analysis. Every tool is bound to one
/// immutable scope (analysis item + selection revision) and enforces it here, not in the prompt.
/// Results are compact text the model reads; heavy data stays in the store.
public final class AutoToolbox: @unchecked Sendable {
    public let store: Store
    public let paths: AppPaths
    public let tools: ToolSettings
    public let pipeline: Pipeline
    public let analysisId: UUID
    public private(set) var run: AutoRun
    public var onUpdate: (@Sendable (AutoRun) -> Void)?
    let trimRevision: Int
    let durationUs: Int64

    public init(store: Store, paths: AppPaths, tools: ToolSettings, item: AnalysisItem, run: AutoRun) {
        self.store = store; self.paths = paths; self.tools = tools; analysisId = item.id; self.run = run
        pipeline = Pipeline(store: store, paths: paths, tools: tools)
        trimRevision = item.trimRevision
        durationUs = item.durationUs
    }

    // MARK: Scope

    func item() throws -> AnalysisItem {
        guard let i = store.fetch(AnalysisItem.self, id: analysisId) else { throw WorkerError(code: "SOURCE_MISSING", message: "分析子项不存在") }
        guard i.trimRevision == trimRevision else {
            throw WorkerError(code: "REVISION_CONFLICT", message: "选区在分析过程中被修改，本次结果作废", retryable: false)
        }
        return i
    }

    func grid(_ i: AnalysisItem) throws -> BeatGrid {
        guard var g = i.timing?.grid else { throw WorkerError(code: "TEMPO_KEY_UNCONFIRMED", message: "还没有确认速度网格") }
        if g.barAnchorUs == nil {
            let notes = confirmedMidi(i)?.notes ?? []
            g.barAnchorUs = latestHarmony()?.barAnchorUs ?? ChordGrouper().estimatedBarAnchor(notes: notes, grid: g)
        }
        return g
    }

    func confirmedMidi(_ i: AnalysisItem) -> MidiRevision? {
        guard let r = i.confirmedMidiRevision else { return nil }
        return store.all(MidiRevision.self, owner: analysisId).first { $0.revision == r }
    }

    func latestHarmony() -> HarmonyRevision? { store.all(HarmonyRevision.self, owner: analysisId).max { $0.revision < $1.revision } }

    func bars(_ i: AnalysisItem) throws -> Int { BarEvidence.barCount(grid: try grid(i), durationUs: durationUs) }

    func checkBars(_ from: Int, _ to: Int, _ i: AnalysisItem) throws -> ClosedRange<Int> {
        let n = try bars(i)
        guard from >= 1, to >= from, to <= n else { throw WorkerError(code: "INVALID_RANGE", message: "小节超出选区：本次只有第 1–\(n) 小节", retryable: false) }
        return from...to
    }

    /// Audio for a source, with the clip offset inside that file. Only the user's selection is reachable.
    func audio(_ source: String, _ i: AnalysisItem) throws -> (path: String, offset: Double) {
        switch source {
        case "original":
            guard let url = Pipeline.resolve(i.source) else { throw WorkerError(code: "SOURCE_MISSING", message: "原曲文件找不到了") }
            return (url.path, i.trimStartUs.seconds)
        default:
            guard let stem = i.selectedStem, let a = i.separation?.stem(stem) else {
                throw WorkerError(code: "SOURCE_MISSING", message: "没有可用的分轨（只保留了选中的分轨）")
            }
            return (paths.url(relative: a.relativePath).path, 0)
        }
    }

    // MARK: Dispatch

    public static let budgetFree: Set<String> = ["note_review", "submit_analysis", "inspect_analysis"]

    public func call(_ name: String, _ args: [String: Any]) async -> (text: String, ok: Bool) {
        let started = Date()
        let argText = SnapshotBuilder.json(args)
        if !Self.budgetFree.contains(name) {
            run.toolCalls += 1
            let elapsed = Date().timeIntervalSince(run.startedAt)
            if run.toolCalls > run.maxToolCalls || elapsed > run.maxSeconds {
                let msg = "BUDGET_EXCEEDED：预算已用完（\(run.toolCalls - 1)/\(run.maxToolCalls) 次工具，\(Int(elapsed)) 秒）。请立即用 submit_analysis 提交当前最好的结果，把没查清的位置放进 toConfirm。"
                record(name, argText, msg, ok: false, started)
                return (msg, false)
            }
        }
        do {
            let text: String
            switch name {
            case "inspect_analysis": text = try inspect()
            case "run_logic_chords": text = try await logicChords(source: args["source"] as? String ?? "original",
                                                                  gridMode: args["grid"] as? String ?? "quarter",
                                                                  refresh: args["refresh"] as? Bool ?? false)
            case "run_transcription": text = try await transcribe(engine: args["engine"] as? String ?? "mt3",
                                                                  source: args["source"] as? String ?? "piano",
                                                                  refresh: args["refresh"] as? Bool ?? false)
            case "align_transcriptions": text = try alignText(source: args["source"] as? String ?? "piano")
            case "bar_evidence": text = try barEvidence(from: intArg(args["fromBar"]) ?? 1, to: intArg(args["toBar"]) ?? 4)
            case "local_audio_check": text = try await localCheck(args)
            case "harmony_draft": text = try await harmonyDraft(useUserMidi: args["useUserMidi"] as? Bool ?? true)
            case "key_check": text = try await keyCheck(chords: args["chords"] as? [String])
            case "note_review": text = noteReview(args)
            case "submit_analysis": text = try await submit(args)
            default: throw WorkerError(code: "UNKNOWN_TOOL", message: "没有这个工具：\(name)", retryable: false)
            }
            record(name, argText, String(text.prefix(400)), ok: true, started)
            return (text, true)
        } catch {
            let msg = "ERROR \((error as? WorkerError)?.code ?? "TOOL_FAILED")：\(error.localizedDescription)"
            record(name, argText, msg, ok: false, started)
            return (msg, false)
        }
    }

    func intArg(_ v: Any?) -> Int? { (v as? Int) ?? (v as? Double).map { Int($0) } ?? (v as? NSNumber)?.intValue }
    func doubleArg(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) ?? (v as? NSNumber)?.doubleValue }

    func record(_ tool: String, _ args: String, _ summary: String, ok: Bool, _ started: Date) {
        run.steps.append(AutoStep(tool: tool, arguments: args, summary: summary, ok: ok, seconds: Date().timeIntervalSince(started)))
        save()
    }

    public func save() {
        try? store.save(run)
        onUpdate?(run)
    }

    public func finish(status: JobStatus, message: String, error: String? = nil) {
        run.status = status
        run.finalMessage = message
        run.error = error
        run.finishedAt = Date()
        save()
        // Scratch files (decoded clips, grid files); evidence lives in the database.
        paths.removeOwned(paths.jobs.appendingPathComponent("auto-\(run.id.uuidString)", isDirectory: true))
    }

    // MARK: Tools

    func inspect() throws -> String {
        let i = try item()
        let g = try grid(i)
        let midi = confirmedMidi(i)
        let h = latestHarmony()
        let tr = store.all(TranscriptionEvidence.self, owner: analysisId).filter { $0.trimRevision == trimRevision }
        let lg = store.all(ChordEvidence.self, owner: analysisId).filter { $0.trimRevision == trimRevision }
        var o: [String: Any] = [
            "selection": String(format: "原曲 %.3f–%.3fs，共 %.3fs（工具只能在这个区间内工作）", i.trimStartUs.seconds, i.trimEndUs.seconds, i.durationUs.seconds),
            "tempo": "\(g.bpm) BPM（四分音符）", "meter": g.meter.display,
            "barLine": String(format: "第 1 小节从片段内 %.3fs 开始%@", Double(g.barAnchorUs ?? 0) / 1e6, i.timing?.barAnchorUs == nil ? "（自动估计）" : "（用户设定）"),
            "bars": try bars(i), "keySetByUser": i.timing?.key.display ?? "未设",
            "selectedStem": i.selectedStem?.displayName ?? "无",
            "sourcesAvailable": ["original（原曲选区）"] + (i.selectedStem.map { ["piano（已选分轨：\($0.displayName)）"] } ?? []),
            "userCorrectedMidi": midi.map { "有：r\($0.revision)，\($0.notes.count) 个音（人工校对过，最可靠的音符证据）" } ?? "无",
            "savedHarmony": h.map { hr in
                "r\(hr.revision)：" + hr.events.map { e in
                    let p = BarEvidence.position(e.startUs, grid: g)
                    return "\(p.bar).\(BarEvidence.beatText(p.beat)) \(e.symbol ?? "?")\(e.manualOverride ? "（人工命名）" : "")"
                }.joined(separator: " → ")
            } ?? "无",
            "evidence": tr.map { "\($0.engine)/\($0.source)：\($0.notes.count) 个钢琴音" } + lg.map { "logic/\($0.source)/\($0.grid)：\($0.events.count) 个和弦" },
            "budget": "已用 \(run.toolCalls)/\(run.maxToolCalls) 次工具调用，\(Int(Date().timeIntervalSince(run.startedAt)))/\(Int(run.maxSeconds)) 秒",
        ]
        if let d = i.detection, let k = d.rawKey { o["audioKeyDetection"] = "\(k) \(d.rawScale ?? "")" }
        return SnapshotBuilder.json(o)
    }

    func logicChords(source: String, gridMode: String, refresh: Bool) async throws -> String {
        let i = try item()
        let g = try grid(i)
        if !refresh, let hit = store.all(ChordEvidence.self, owner: analysisId)
            .last(where: { $0.trimRevision == trimRevision && $0.timingRevision == i.timingRevision && $0.source == source && $0.grid == gridMode }) {
            return "（复用已有结果）\n" + logicText(hit, g)
        }
        let (path, offset) = try audio(source, i)
        let div = gridMode == "eighth" ? 2.0 : 1.0
        var beats: [Double] = [], downbeats: [Double] = []
        var q = ceil(g.q(atUs: 0) * div) / div
        while true {
            let t = g.us(atQ: q)
            if t >= durationUs { break }
            if t >= 0 {
                beats.append(Double(t) / 1e6)
                if g.isDownbeat(q: q) { downbeats.append(Double(t) / 1e6) }
            }
            q += 1 / div
        }
        let dir = paths.jobs.appendingPathComponent("auto-\(run.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gridFile = dir.appendingPathComponent("grid-\(source)-\(gridMode).json")
        try JSONSerialization.data(withJSONObject: ["beats": beats, "downbeats": downbeats]).write(to: gridFile)
        nonisolated(unsafe) var result: [String: Any]?
        let w = WorkerProcess(tools.systemPython, [tools.workers + "/logic_chords_worker.py", "--audio", path,
                                                   "--offset", String(offset), "--duration", String(durationUs.seconds),
                                                   "--grid-json", gridFile.path,
                                                   "--cache-dir", paths.root.appendingPathComponent("cache/logic").path,
                                                   "--ffmpeg", tools.ffmpeg])
        _ = try await w.run { line in if let o = decodeJSONLine(line) { result = o } }
        guard let result else { throw WorkerError(code: "ANALYSIS_FAILED", message: "Logic worker 没有输出") }
        if let e = result["error"] as? [String: Any] { throw WorkerError(code: e["code"] as? String ?? "ANALYSIS_FAILED", message: e["message"] as? String ?? "") }
        let events = (result["events"] as? [[String: Any]] ?? []).compactMap { e -> LogicChordEvent? in
            guard let l = e["label"] as? String, let s = e["startSec"] as? Double, let en = e["endSec"] as? Double else { return nil }
            return LogicChordEvent(label: l, symbol: LogicChordLabel.symbol(l), startUs: Int64(s * 1e6), endUs: Int64(en * 1e6))
        }
        let ev = ChordEvidence(analysisId: analysisId, trimRevision: trimRevision, timingRevision: i.timingRevision, source: source,
                               grid: gridMode, events: events, logicVersion: result["logicVersion"] as? String ?? "",
                               seconds: result["seconds"] as? Double ?? 0)
        try store.save(ev)
        return logicText(ev, g)
    }

    func logicText(_ ev: ChordEvidence, _ g: BeatGrid) -> String {
        "Logic Chord ID（\(ev.source)，\(ev.grid == "eighth" ? "八分" : "四分")拍点，Logic \(ev.logicVersion)；只是候选，词表没有 9/11/13；结束时间由下一个起点推出）：\n" +
            ev.events.map { e in
                let p = BarEvidence.position(e.startUs, grid: g)
                return "\(p.bar).\(BarEvidence.beatText(p.beat)) \(e.label)\(e.symbol.map { " = \($0)" } ?? "")"
            }.joined(separator: "\n")
    }

    func transcribe(engine: String, source: String, refresh: Bool) async throws -> String {
        let i = try item()
        if !refresh, let hit = store.all(TranscriptionEvidence.self, owner: analysisId)
            .last(where: { $0.trimRevision == trimRevision && $0.engine == engine && $0.source == source }) {
            return "（复用已有结果）" + transcriptionSummary(hit, try grid(i))
        }
        var (path, offset) = try audio(source, i)
        var tmpClip: URL?
        if source == "original" {
            // Decode just the selection; tools never see audio outside it.
            let dir = paths.jobs.appendingPathComponent("auto-\(run.id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let clip = dir.appendingPathComponent("original-clip.wav")
            if !FileManager.default.fileExists(atPath: clip.path) { try await pipeline.extractClip(i, to: clip) }
            path = clip.path; offset = 0; tmpClip = clip
        }
        _ = tmpClip
        nonisolated(unsafe) var notes: [EvidenceNote] = []
        nonisolated(unsafe) var dropped: [String: Int] = [:]
        nonisolated(unsafe) var failure: WorkerError?
        nonisolated(unsafe) var secs = 0.0
        let w: WorkerProcess
        var params: [String: String] = ["source": source]
        if engine == "mt3" {
            w = WorkerProcess(tools.mt3Python, [tools.workers + "/mt3_worker.py", path, "--mt3-dir", tools.mt3Dir,
                                                "--offset", String(offset), "--duration", String(durationUs.seconds),
                                                "--programs", "0-5", "--device", "mps"])
            params["model"] = "mt3"; params["device"] = "mps (jax-mps)"; params["programs"] = "0-5 原声钢琴+电钢琴"
        } else {
            w = WorkerProcess(tools.muscriptorPython, [tools.workers + "/muscriptor_worker.py", path, "--stem", "piano",
                                                       "--model", tools.muscriptorModel, "--device", tools.muscriptorDevice])
            w.environment = ProcessInfo.processInfo.environment.merging(["PYTORCH_ENABLE_MPS_FALLBACK": "1"]) { $1 }
            params["model"] = tools.muscriptorModel; params["instruments"] = "acoustic_piano, electric_piano"
        }
        let r = try await w.run { line in
            guard let o = decodeJSONLine(line), let ev = o["event"] as? String else { return }
            switch ev {
            case "note":
                guard let p = o["pitch"] as? Int, let s = (o["startUs"] as? NSNumber)?.int64Value, let e = (o["endUs"] as? NSNumber)?.int64Value else { return }
                let inst = o["instrument"] as? String ?? ""
                guard inst == "acoustic_piano" || inst == "electric_piano" else { dropped[inst, default: 0] += 1; return }
                notes.append(EvidenceNote(pitch: p, startUs: s, endUs: e, velocity: o["velocity"] as? Int ?? 100, instrument: inst))
            case "done":
                secs = o["seconds"] as? Double ?? 0
                for (k, v) in o["dropped"] as? [String: Int] ?? [:] { dropped[k, default: 0] += v }
            case "error": failure = WorkerError(code: o["code"] as? String ?? "TRANSCRIPTION_FAILED", message: o["message"] as? String ?? "")
            default: break
            }
        }
        if let failure { throw failure }
        guard r.status == 0 else { throw WorkerError(code: "TRANSCRIPTION_FAILED", message: String(r.stderr.suffix(300))) }
        // Keep the notes inside the selection only.
        notes = notes.filter { $0.startUs >= 0 && $0.startUs < durationUs }
        let ev = TranscriptionEvidence(analysisId: analysisId, trimRevision: trimRevision, engine: engine, source: source,
                                       params: params, notes: notes, dropped: dropped, seconds: secs)
        try store.save(ev)
        return transcriptionSummary(ev, try grid(i))
    }

    func transcriptionSummary(_ ev: TranscriptionEvidence, _ g: BeatGrid) -> String {
        var perBar: [Int: Int] = [:]
        for n in ev.notes { perBar[BarEvidence.position(n.startUs, grid: g).bar, default: 0] += 1 }
        let inst = Dictionary(grouping: ev.notes, by: \.instrument).mapValues(\.count)
        return "\(ev.engine)/\(ev.source)：保留 \(ev.notes.count) 个钢琴音（\(inst.map { "\($0.key) \($0.value)" }.sorted().joined(separator: "，"))）"
            + (ev.dropped.isEmpty ? "" : "；已排除非钢琴：\(ev.dropped.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: "，"))")
            + String(format: "；用时 %.1fs\n每小节音数：", ev.seconds)
            + perBar.keys.sorted().map { "\($0):\(perBar[$0]!)" }.joined(separator: " ")
    }

    func latestTranscription(_ engine: String, _ source: String) -> TranscriptionEvidence? {
        store.all(TranscriptionEvidence.self, owner: analysisId).last { $0.trimRevision == trimRevision && $0.engine == engine && $0.source == source }
    }

    func aligned(source: String) -> TranscriptionAligner.Result? {
        guard let a = latestTranscription("muscriptor", source), let b = latestTranscription("mt3", source) else { return nil }
        return TranscriptionAligner.align(a.notes, b.notes, labels: ("muscriptor", "mt3"))
    }

    func alignText(source: String) throws -> String {
        let i = try item()
        let g = try grid(i)
        guard let r = aligned(source: source) else {
            throw WorkerError(code: "MISSING_EVIDENCE", message: "\(source) 还缺少 MuScriptor 或 MT3 的转录结果，先调用 run_transcription", retryable: false)
        }
        var perBar: [Int: (both: Int, total: Int)] = [:]
        for n in r.merged {
            let b = BarEvidence.position(n.startUs, grid: g).bar
            var x = perBar[b] ?? (0, 0); x.total += 1; if n.support == "both" { x.both += 1 }; perBar[b] = x
        }
        return String(format: "对齐 MuScriptor 与 MT3（%@）：整体偏移 %+.0f ms，共同 %d，仅 MuScriptor %d，仅 MT3 %d，一致率 %.0f%%\n",
                      source, Double(r.offsetUs) / 1000, r.matched, r.onlyA, r.onlyB, r.agreement * 100)
            + "每小节一致：" + perBar.keys.sorted().map { b in String(format: "%d:%.0f%%", b, Double(perBar[b]!.both) / Double(max(1, perBar[b]!.total)) * 100) }.joined(separator: " ")
            + "\n两者一致只说明音存在，不说明它属于和弦；单边的音可能是漏转，也可能是误转。"
    }

    func barEvidence(from: Int, to: Int) throws -> String {
        let i = try item()
        let g = try grid(i)
        let range = try checkBars(from, min(to, from + 7), i)
        let logic = store.all(ChordEvidence.self, owner: analysisId)
            .filter { $0.trimRevision == trimRevision && $0.timingRevision == i.timingRevision }
        let preferred = logic.last { $0.source == "original" && $0.grid == "quarter" } ?? logic.last
        let srcs = BarEvidence.Sources(userMidi: confirmedMidi(i)?.notes ?? [], merged: aligned(source: "piano")?.merged ?? [],
                                       logic: preferred?.events ?? [], current: latestHarmony()?.events ?? [])
        var text = BarEvidence.describe(bars: range, grid: g, durationUs: durationUs, key: i.timing?.key, sources: srcs)
        if to > range.upperBound { text += "\n（一次最多 8 小节，后面请再调用）" }
        return "位置写法：小节.拍（1.5 = 第 1 拍后半拍）。\n" + text
    }

    /// Tonal-centre evidence side by side: the key the user set, whole-selection audio pitch
    /// classes (with major/minor profile fits), where the bass sits, and how the chords score
    /// as a progression. Relative keys share a scale, so the chords and the bass decide.
    func keyCheck(chords: [String]?) async throws -> String {
        let i = try item()
        let flats = Pitch.prefersFlats(i.timing?.key)
        func name(_ pc: Int, _ minor: Bool) -> String { Pitch.noteName(60 + pc, flats: flats).filter { !$0.isNumber } + (minor ? " 小调" : " 大调") }
        var lines = ["用户设定：\(i.timing?.key.display ?? "未设")"]
        if let d = i.detection, d.trimRevision == trimRevision, let k = d.rawKey {
            lines.append("Essentia 整段检测：\(k) \(d.rawScale ?? "")" + (d.keyStrength.map { String(format: "（强度 %.2f）", $0) } ?? ""))
        }
        // Whole selection, original mix.
        let (path, offset) = try audio("original", i)
        nonisolated(unsafe) var res: [String: Any]?
        let w = WorkerProcess(tools.essentiaPython, [tools.workers + "/essentia_worker.py", "chroma", path,
                                                     "--start", String(offset), "--end", String(offset + Double(durationUs) / 1e6)])
        _ = try await w.run { line in if let o = decodeJSONLine(line) { res = o } }
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        if let c = res?["chroma"] as? [String: Double] {
            let v = names.map { c[$0] ?? 0 }
            lines.append("整段音频音级能量（原曲混音）：" + (0..<12).sorted { v[$0] > v[$1] }.prefix(8)
                .map { String(format: "%@ %.2f", Pitch.noteName(60 + $0, flats: flats).filter { !$0.isNumber }, v[$0]) }.joined(separator: "，"))
            let fits = KeyProfile.fits(v).prefix(4)
            lines.append("音级与大/小调模板的吻合度（Krumhansl，越接近 1 越像）：" + fits.map { String(format: "%@ %.2f", name($0.tonic, $0.minor), $0.r) }.joined(separator: "，"))
        }
        // Bass: the lowest sounding note per eighth, weighted by time.
        let notes = confirmedMidi(i)?.notes.map { (p: $0.pitch, s: $0.startUs, e: $0.endUs) }
            ?? (latestTranscription("muscriptor", "piano")?.notes.map { (p: $0.pitch, s: $0.startUs, e: $0.endUs) } ?? [])
        if !notes.isEmpty {
            let g = try grid(i)
            var bass = [Double](repeating: 0, count: 12)
            var t = Int64(0)
            let step = Int64(g.beatUs / 2)
            while t < durationUs {
                if let low = notes.filter({ $0.s <= t && $0.e > t }).min(by: { $0.p < $1.p }) { bass[low.p % 12] += 1 }
                t += step
            }
            let total = max(1, bass.reduce(0, +))
            lines.append("低音停留（按八分点计）：" + (0..<12).filter { bass[$0] > 0 }.sorted { bass[$0] > bass[$1] }.prefix(6)
                .map { "\(Pitch.noteName(60 + $0, flats: flats).filter { !$0.isNumber }) \(Int(bass[$0] / total * 100))%" }.joined(separator: "，"))
        }
        // Chords: the model's own sequence if given, otherwise the saved harmony.
        let evs: [ChordEvent]
        if let chords, !chords.isEmpty {
            evs = chords.enumerated().compactMap { n, sym in
                ChordSymbol.parse(sym) == nil ? nil : ChordEvent(id: "k\(n)", order: n, startUs: Int64(n) * 1_000_000, endUs: Int64(n + 1) * 1_000_000, noteIds: [], noteRoles: [:],
                                                               texture: .block, excludedNoteIds: [], namingPitches: [], candidates: [], symbol: sym,
                                                               namingSource: .agent, manualOverride: false, degree: nil, bassPitch: nil)
            }
            lines.append("和弦序列（你给的，按等长计）：" + chords.joined(separator: " "))
        } else {
            evs = latestHarmony()?.events ?? []
            lines.append("和弦序列（已保存的和声）：" + evs.compactMap(\.symbol).joined(separator: " "))
        }
        for c in KeyEstimator.candidates(events: evs, limit: 3) {
            lines.append(String(format: "和弦调性评分 %@ %.2f：", c.key.display, c.score) + c.reasons.joined(separator: "；"))
        }
        lines.append("提示：关系大小调（如 E♭ 大调 / C 小调）音阶相同，音级能量分不开；看主和弦停在哪、终止式落在哪、低音围绕谁，以及是否出现导音（小调的还原 7 级）。"
                     + "结论写进 submit_analysis 的 key，理由要说出你依据的是哪几条。")
        return lines.joined(separator: "\n")
    }

    func localCheck(_ args: [String: Any]) async throws -> String {
        let i = try item()
        let g = try grid(i)
        guard let bar = intArg(args["bar"]), let beat = doubleArg(args["beat"]) else {
            throw WorkerError(code: "INVALID_ARGUMENTS", message: "需要 bar 和 beat", retryable: false)
        }
        let endBar = intArg(args["endBar"]) ?? bar
        let endBeat = doubleArg(args["endBeat"]) ?? (beat + 1)
        let s = BarEvidence.usAt(bar: bar, beat: beat, grid: g), e = BarEvidence.usAt(bar: endBar, beat: endBeat, grid: g)
        guard s >= 0, e <= durationUs + 1000, e - s >= 100_000 else {
            throw WorkerError(code: "INVALID_RANGE", message: "窗口必须在选区内且至少 0.1 秒", retryable: false)
        }
        let source = args["source"] as? String ?? "piano"
        let (path, offset) = try audio(source, i)
        nonisolated(unsafe) var res: [String: Any]?
        let w = WorkerProcess(tools.essentiaPython, [tools.workers + "/essentia_worker.py", "chroma", path,
                                                     "--start", String(offset + Double(s) / 1e6), "--end", String(offset + Double(e) / 1e6)])
        _ = try await w.run { line in if let o = decodeJSONLine(line) { res = o } }
        var lines = [String(format: "窗口 %d.%@–%d.%@（%.2f–%.2fs），音频：%@", bar, BarEvidence.beatText(beat), endBar, BarEvidence.beatText(endBeat),
                            Double(s) / 1e6, Double(e) / 1e6, source == "original" ? "原曲混音" : "钢琴分轨")]
        if let c = res?["chroma"] as? [String: Double] {
            let ranked = c.sorted { $0.value > $1.value }
            lines.append("音频音级能量（HPCP，最强=1；谐波也会贡献能量，不能直接当作实际音）：" + ranked.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: "，"))
        } else if let err = res?["error"] as? [String: Any] {
            lines.append("音频音级：失败（\(err["message"] as? String ?? "")）")
        }
        let flats = Pitch.prefersFlats(i.timing?.key)
        func fmt(_ p: Int, _ st: Int64, _ en: Int64) -> String {
            let pos = BarEvidence.position(st, grid: g)
            return "\(Pitch.noteName(p, flats: flats))@\(pos.bar).\(BarEvidence.beatText(pos.beat))(\(String(format: "%.2f", Double(en - st) / g.beatUs))拍)"
        }
        if let m = confirmedMidi(i) {
            let ns = m.notes.filter { $0.startUs < e && $0.endUs > s }.sorted { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
            lines.append("人工校对MIDI：" + ns.map { fmt($0.pitch, $0.startUs, $0.endUs) }.joined(separator: " "))
        }
        for engine in ["muscriptor", "mt3"] {
            if let t = latestTranscription(engine, "piano") {
                let ns = t.notes.filter { $0.startUs < e && $0.endUs > s }
                lines.append("\(engine)：" + ns.map { fmt($0.pitch, $0.startUs, $0.endUs) }.joined(separator: " "))
            }
        }
        if let lg = store.all(ChordEvidence.self, owner: analysisId).last(where: { $0.trimRevision == trimRevision }) {
            lines.append("Logic：" + lg.events.filter { $0.startUs < e && $0.endUs > s }.map { $0.label }.joined(separator: " → "))
        }
        return lines.joined(separator: "\n")
    }

    func harmonyDraft(useUserMidi: Bool) async throws -> String {
        let i = try item()
        let g = try grid(i)
        var notes: [MidiNote]
        var basis: String
        if useUserMidi, let m = confirmedMidi(i) {
            notes = m.notes; basis = "人工校对 MIDI"
        } else if let r = aligned(source: "piano") {
            notes = r.merged.map { MidiNote(pitch: $0.pitch, startUs: $0.startUs, endUs: $0.endUs, instrument: "acoustic_piano") }
            basis = "双转录合并（含单边音）"
        } else if let t = latestTranscription("muscriptor", "piano") ?? latestTranscription("mt3", "piano") {
            notes = t.notes.map { MidiNote(pitch: $0.pitch, startUs: $0.startUs, endUs: $0.endUs, instrument: $0.instrument) }
            basis = t.engine
        } else {
            throw WorkerError(code: "MISSING_EVIDENCE", message: "没有音符证据，先转录或使用人工 MIDI", retryable: false)
        }
        let groups = ChordGrouper().group(notes: notes, grid: g, durationUs: durationUs, key: i.timing?.key)
        return "程序分组草稿（依据：\(basis)；按拍子分组 + 模板命名，只是参考，可整体推翻）：\n" + groups.map { gr in
            let p = BarEvidence.position(gr.startUs, grid: g)
            return "\(p.bar).\(BarEvidence.beatText(p.beat)) " + gr.candidates.prefix(3).map(\.symbol).joined(separator: " / ")
                + String(format: "（%.1f拍）", Double(gr.endUs - gr.startUs) / g.beatUs)
        }.joined(separator: "\n")
    }

    func noteReview(_ a: [String: Any]) -> String {
        run.reviews.append(ReviewRecord(question: a["question"] as? String ?? "", expectedEvidence: a["expectedEvidence"] as? String ?? "",
                                        operation: a["operation"] as? String ?? "", observedEvidence: a["observedEvidence"] as? String ?? "",
                                        decision: a["decision"] as? String ?? "", stopReason: a["stopReason"] as? String ?? ""))
        save()
        return "已记录"
    }

    /// Validates the model's harmony and saves it as a new harmony revision (older revisions,
    /// the user's MIDI, notes and tags are untouched).
    func submit(_ a: [String: Any]) async throws -> String {
        let i = try item()
        let g = try grid(i)
        let key = i.timing?.key
        var errors: [String] = []
        let barsN = try bars(i)
        struct C { var start: Int64; var symbol: String; var info: AutoChordInfo; var where_: String }
        var chords: [C] = []
        for (n, c) in (a["chords"] as? [[String: Any]] ?? []).enumerated() {
            guard let bar = intArg(c["bar"]), let beat = doubleArg(c["beat"]), let sym = c["symbol"] as? String else {
                errors.append("第 \(n + 1) 个和弦缺少 bar/beat/symbol"); continue
            }
            let w = "第 \(n + 1) 个（\(bar).\(BarEvidence.beatText(beat)) \(sym)）"
            guard bar >= 1, bar <= barsN, beat >= 1, beat < g.meter.quarterBeatsPerBar + 1 else { errors.append(w + "位置超出选区或小节范围"); continue }
            let t = BarEvidence.usAt(bar: bar, beat: beat, grid: g)
            guard t < durationUs, t >= -Int64(g.beatUs) else { errors.append(w + "在选区之外"); continue }
            guard ChordSymbol.parse(sym) != nil else { errors.append(w + "和弦名无法解析，请用 Fm7、G7/B、C7sus4、A♭maj7、Cm(add9) 这类写法"); continue }
            let role = c["role"] as? String ?? "backbone"
            chords.append(C(start: max(0, t), symbol: sym, info: AutoChordInfo(role: role, reason: c["reason"] as? String ?? "",
                                                                               confidence: c["confidence"] as? String ?? "medium"), where_: w))
        }
        if chords.isEmpty { errors.append("chords 为空") }
        if !run.steps.contains(where: { $0.tool == "key_check" && $0.ok }) { errors.append("提交前要先调用一次 key_check 做调性检查") }
        if (a["key"] as? [String: Any])?["tonic"] == nil { errors.append("缺少 key：写出你判断的调（tonic、mode）和理由") }
        let sorted = chords.sorted { $0.start < $1.start }
        for (x, y) in zip(sorted, sorted.dropFirst()) where y.start - x.start < 50_000 { errors.append("\(x.where_) 和 \(y.where_) 起点重叠") }
        guard errors.isEmpty else { return "NOT_SAVED，请修正后重新提交：\n" + errors.joined(separator: "\n") }

        let midi = confirmedMidi(i)
        let pitched = (midi?.notes ?? []).filter { $0.instrument != "drums" && $0.instrument != "voice" }
        let revNo = 0 // assigned when the user adopts it
        var events: [ChordEvent] = []
        var infos: [String: AutoChordInfo] = [:]
        for (n, c) in sorted.enumerated() {
            let end = n + 1 < sorted.count ? sorted[n + 1].start : durationUs
            let members = ChordGrouper.members(pitched, start: c.start, end: end, beatUs: g.beatUs)
            let id = String(format: "chord-%02d", n + 1)
            var ev = ChordEvent(id: id, order: n, startUs: c.start, endUs: end, noteIds: members.map(\.id), noteRoles: [:], texture: .block,
                                excludedNoteIds: [], namingPitches: Array(Set(members.map(\.pitch))).sorted(),
                                candidates: [ChordCandidate(symbol: c.symbol, source: .agent, score: nil, raw: nil)],
                                symbol: c.symbol, namingSource: .agent, manualOverride: false, degree: nil,
                                bassPitch: members.map(\.pitch).min())
            if let key { ev.degree = Degrees.label(symbol: c.symbol, key: key) }
            events.append(ev)
            infos[id] = c.info
        }
        var confirms: [ConfirmPoint] = []
        for q in a["toConfirm"] as? [[String: Any]] ?? [] {
            guard let bar = intArg(q["bar"]), let beat = doubleArg(q["beat"]) else { continue }
            let t = max(0, min(durationUs - 1, BarEvidence.usAt(bar: bar, beat: beat, grid: g)))
            confirms.append(ConfirmPoint(startUs: t, eventId: events.last { $0.startUs <= t + 30_000 }?.id, question: q["question"] as? String ?? ""))
        }
        var keyS: KeySuggestion?
        if let k = a["key"] as? [String: Any], let tonic = k["tonic"] as? String, Pitch.parsePitchClass(tonic) != nil {
            let mode = k["mode"] as? String == "minor" ? "minor" : "major"
            let agrees = key.map { $0.tonic == Pitch.parsePitchClass(tonic) && $0.mode.rawValue == mode } ?? false
            keyS = KeySuggestion(tonic: tonic, mode: mode, modeName: k["name"] as? String ?? "", agreesWithCurrent: agrees, reason: k["reason"] as? String ?? "")
        }
        let sources = Set(store.all(TranscriptionEvidence.self, owner: analysisId).filter { $0.trimRevision == trimRevision }.map { "\($0.engine)/\($0.source)" }
            + store.all(ChordEvidence.self, owner: analysisId).filter { $0.trimRevision == trimRevision }.map { "logic/\($0.source)" }
            + (midi != nil ? ["人工MIDI r\(midi!.revision)"] : []))
        var rev = HarmonyRevision(analysisId: analysisId, revision: revNo, midiRevision: midi?.revision ?? 0, timingRevision: i.timingRevision,
                                  key: key ?? KeySignature(tonic: 0, tonicName: "C", mode: .major), events: events,
                                  params: ["algorithm": "agent", "source": "auto", "runId": run.id.uuidString,
                                           "barAnchorUs": String(g.barAnchorUs ?? 0), "barAnchorEstimated": i.timing?.barAnchorUs == nil ? "1" : "0"],
                                  namerVersion: "model \(run.provider) \(run.model)")
        rev.auto = AutoHarmony(runId: run.id, summary: a["summary"] as? String ?? "", chordInfo: infos, toConfirm: confirms, key: keyS, sources: sources.sorted())
        // Kept with the run; the current harmony changes only when the user adopts it.
        run.proposal = rev
        save()
        let lines = events.map { e -> String in
            let p = BarEvidence.position(e.startUs, grid: g)
            return "\(p.bar).\(BarEvidence.beatText(p.beat)) \(e.symbol ?? "?")（\(infos[e.id]?.roleDisplay ?? "")）"
        }
        return "SAVED（待用户采用）：\(events.count) 个和弦，\(confirms.count) 处待确认。用户点“采用”后才会替换当前和声。\n" + lines.joined(separator: "\n")
            + "\n如果还要修改，可以再次调用 submit_analysis 覆盖本次结果；否则用一两句话结束。"
    }
}

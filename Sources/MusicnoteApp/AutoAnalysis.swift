import Foundation
import MusicnoteCore

// MARK: - Autonomous analysis

extension AppModel {
    func latestAutoRun(_ itemId: UUID) -> AutoRun? {
        if let live = autoRuns[itemId] { return live }
        return store.all(AutoRun.self, owner: itemId).max { $0.startedAt < $1.startedAt }
    }

    var autoAnalysisProvider: CodexProvider {
        if let p = _autoProvider { return p }
        let p = CodexProvider(binary: settings.tools.codexBinary, sandboxDir: paths.chatSandbox, enableCodeMode: true)
        _autoProvider = p
        return p
    }

    /// Claude Code reaches the same toolbox through `workers/mcp_bridge.py`.
    var autoClaudeProvider: ClaudeAgentProvider {
        if let p = _autoClaude { return p }
        let t = settings.tools
        let p = ClaudeAgentProvider(binary: t.claudeBinary, sandboxDir: paths.chatSandbox, python: t.systemPython, bridgeScript: t.workers + "/mcp_bridge.py")
        _autoClaude = p
        return p
    }

    /// Lets the model analyse the selection with Musicnote's tools. Older harmony revisions,
    /// the user's MIDI, notes and tags are never modified.
    func startAutoAnalysis(_ itemId: UUID, provider pid: String = "codex") {
        guard autoTasks[itemId] == nil, let item = item(itemId) else { return }
        guard item.timing != nil else {
            alert = AppAlert(title: "还不能自主分析", message: "先确认速度与调性，这样才能按小节分析。"); return
        }
        let model = settings.providerModels[pid]
        let effort = validEffort(pid, model: model, effort: settings.providerEfforts[pid]) ?? "medium"
        let run = AutoRun(analysisId: itemId, trimRevision: item.trimRevision, provider: pid, model: model ?? "默认",
                          maxToolCalls: AutoAgent.defaultMaxToolCalls, maxSeconds: AutoAgent.defaultMaxSeconds)
        let box = AutoToolbox(store: store, paths: paths, tools: settings.tools, item: item, run: run)
        box.onUpdate = { [weak self] r in Task { @MainActor in self?.autoRuns[itemId] = r } }
        autoRuns[itemId] = run
        try? store.save(run)
        let provider: any AgentProvider = pid == "claude" ? autoClaudeProvider : autoAnalysisProvider
        let title = song(item.songId)?.title ?? ""
        autoTasks[itemId] = Task { [weak self] in
            await AutoAgent.run(toolbox: box, provider: provider, songTitle: title, model: model, effort: effort)
            guard let self else { return }
            self.autoRuns[itemId] = nil
            self.autoTasks[itemId] = nil
            self.reload()
            // A finished result goes straight into checking.
            if box.run.status == .succeeded { self.reviewRun(itemId, run: box.run) }
            if box.run.status == .failed { self.alert = AppAlert(title: "自主分析没有完成", message: box.run.error ?? box.run.finalMessage) }
        }
    }

    func cancelAutoAnalysis(_ itemId: UUID) { autoTasks[itemId]?.cancel() }

    /// Bar 1 and the beat phase start at a note the user picked; the tempo stays.
    func setBarOne(_ itemId: UUID, atUs us: Int64) {
        guard var item = item(itemId), var t = item.timing else { return }
        t.barAnchorUs = us
        t.beatOriginUs = us
        item.timing = t
        item.timingRevision += 1
        save(item)
    }

    /// After transcription: bar 1 picked (or kept), then harmony.
    func confirmBarOne(_ itemId: UUID, atUs us: Int64?) {
        if let us { setBarOne(itemId, atUs: us) }
        confirmMidi(itemId)
    }

    /// Later, from the notes page: a model harmony is re-read in the new grid, a program one regrouped.
    func changeBarOne(_ itemId: UUID, atUs us: Int64) {
        setBarOne(itemId, atUs: us)
        harmonyFollowsTiming(itemId)
    }

    private func harmonyFollowsTiming(_ itemId: UUID) {
        guard let item = item(itemId) else { return }
        if var h = latestHarmony(itemId), h.params["algorithm"] == "agent" {
            h.timingRevision = item.timingRevision
            h.params["barAnchorUs"] = String(item.timing?.barAnchorUs ?? 0)
            saveHarmony(h)
        } else if item.isHarmonic, confirmedMidi(item) != nil {
            runHarmony(itemId)
        }
    }

    /// Moves the bar lines by whole or half beats; note times stay. A half beat also moves the
    /// beat phase. An adopted model result only needs re-reading in the new grid; a program
    /// grouping depends on the bar lines, so it is redone.
    func shiftBarLine(_ itemId: UUID, beats: Double) {
        guard var item = item(itemId), var t = item.timing else { return }
        let g = t.grid
        let barUs = g.beatUs * g.meter.quarterBeatsPerBar
        let current = Double(t.barAnchorUs ?? latestHarmony(itemId)?.barAnchorUs ?? t.beatOriginUs)
        var a = current + beats * g.beatUs
        while a < 0 { a += barUs }
        while a >= barUs { a -= barUs }
        t.barAnchorUs = Int64(a.rounded())
        if beats != beats.rounded() { t.beatOriginUs = Int64(a.rounded()) }
        item.timing = t
        item.timingRevision += 1
        save(item)
        if var h = latestHarmony(itemId), h.params["algorithm"] == "agent" {
            h.timingRevision = item.timingRevision
            h.params["barAnchorUs"] = String(t.barAnchorUs ?? 0)
            saveHarmony(h)
        } else if item.isHarmonic, confirmedMidi(item) != nil {
            runHarmony(itemId)
        }
    }

    /// The bar-line check on what the clip has: Logic evidence if a model run made it, and the MIDI.
    func barLineCheck(_ item: AnalysisItem) -> (BarLineCheck.Result, BeatGrid)? {
        guard var g = item.timing?.grid, let midi = confirmedMidi(item) else { return nil }
        if g.barAnchorUs == nil { g.barAnchorUs = latestHarmony(item.id)?.barAnchorUs }
        let logic = store.all(ChordEvidence.self, owner: item.id).filter { $0.trimRevision == item.trimRevision }
        let lg = (logic.last { $0.source == "original" } ?? logic.last)?.events ?? []
        let r = BarLineCheck.check(grid: g, durationUs: item.durationUs, logic: lg,
                                   notes: midi.notes.map { BarLineCheck.Note(pitch: $0.pitch, startUs: $0.startUs) })
        return (r, g)
    }

    /// Latest run that produced a result (a later failed or cancelled run doesn't hide it).
    func latestAutoResultRun(_ itemId: UUID) -> AutoRun? {
        store.all(AutoRun.self, owner: itemId).filter(\.submitted).max { $0.startedAt < $1.startedAt }
    }
}

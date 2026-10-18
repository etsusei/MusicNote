import MusicnoteCore
import SwiftUI

enum AutoToolLabel {
    static func text(_ tool: String) -> String {
        switch tool {
        case "inspect_analysis": "查看现状"
        case "run_logic_chords": "Logic 和弦候选"
        case "run_transcription": "转录"
        case "align_transcriptions": "对齐双转录"
        case "bar_evidence": "读小节证据"
        case "local_audio_check": "定向复核"
        case "harmony_draft": "看程序草稿"
        case "note_review": "记录复核"
        case "submit_analysis": "提交结果"
        default: tool
        }
    }
}

/// Model-driven analysis on the notes page: start/cancel, live steps, and the bar-by-bar result.
struct AutoAnalysisSection: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    @AppStorage("autoProvider") private var providerId = "codex"

    private static let providers = [("codex", "Codex"), ("claude", "Claude Code")]
    private var connected: Bool { model.providerStatus[providerId]?.state == .connected }
    private var providerName: String { Self.providers.first { $0.0 == providerId }?.1 ?? providerId }

    var body: some View {
        let _ = model.dataVersion
        let running = model.autoTasks[item.id] != nil
        let run = model.latestAutoRun(item.id)
        let resultRun = model.latestAutoResultRun(item.id)
        let result = resultRun?.result(in: model.store)
        let current = model.latestHarmony(item.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SectionHeader(title: "模型自主分析",
                              subtitle: "模型自己调用 Logic 和弦候选、MT3 + MuScriptor 双转录、局部音频复核，最后交付按小节的和弦走向。你在结果上检查、修改，点“保存”后才更新下面的完整进行和骨架；旧的和声和 MIDI 版本都保留。")
                Spacer()
                if running {
                    Button("停止") { model.cancelAutoAnalysis(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                } else {
                    Picker("", selection: $providerId) {
                        ForEach(Self.providers, id: \.0) { p in
                            Text(p.1 + (model.providerStatus[p.0]?.state == .connected ? "" : "（未连接）")).tag(p.0)
                        }
                    }
                    .labelsHidden().frame(width: 150)
                    .help("模型和推理强度沿用设置里给这个客户端选的")
                    Button(result == nil ? "开始自主分析" : "重新自主分析") { model.startAutoAnalysis(item.id, provider: providerId) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!connected)
                        .help(connected ? "使用 \(providerName)（\(model.settings.providerModels[providerId] ?? "默认模型")）" : "需要先连接 \(providerName)")
                }
            }
            if let run, running || run.id != resultRun?.id {
                RunProgress(run: run, running: running)
            }
            if let resultRun, let h = result, let auto = h.auto, let timing = item.timing {
                AdoptBar(item: item, run: resultRun, result: h, current: current)
                AutoResult(item: item, harmony: h, auto: auto, timing: timing, run: resultRun)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.35)))
    }
}

/// Whether the chords below are this result, and the one-click way to make them so.
struct AdoptBar: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var run: AutoRun
    var result: HarmonyRevision
    var current: HarmonyRevision?

    var body: some View {
        let saved = AutoAdoption.isSaved(run, current: current)
        let adopted = AutoAdoption.isAdopted(run, current: current)
        let stale = item.trimRevision != run.trimRevision
        HStack(spacing: 10) {
            Image(systemName: saved ? "checkmark.seal.fill" : "square.and.pencil").foregroundStyle(saved ? Theme.success : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(saved ? "已保存：完整进行、和弦卡、播放、骨架和聊天都用这个结果"
                     : adopted ? "有未保存的修改" : "检查并修改下面的和弦走向，没问题就保存")
                    .font(.system(size: 13, weight: .semibold))
                Text(stale ? "选区在分析之后改过，这个结果不能再保存，请重新自主分析。"
                     : saved ? "还能接着在下面改，改完再保存一次。完整进行目前是\(currentText)。"
                     : "点和弦选中，双击改名，可插入、删除、按八分音符挪起止，能撤销。保存前不会动你的和声、MIDI 和骨架；保存后更新完整进行并重新生成骨架。完整进行目前是\(currentText)。")
                    .font(.caption12).foregroundStyle(stale ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !saved && !stale {
                Button(adopted ? "保存修改" : "保存") { model.adoptAutoResult(item.id, run: run) }.buttonStyle(PrimaryButtonStyle())
                    .help("存成新的和声版本（旧版本保留），更新完整进行并重新生成骨架")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(saved ? Theme.success.opacity(0.08) : Theme.accent.opacity(0.08)))
    }

    private var currentText: String {
        guard let c = current else { return "空的" }
        if c.auto?.runId == run.id { return "这次结果上次保存的版本（r\(c.revision)）" }
        if c.params["algorithm"] == "agent" { return "另一次模型分析的结果（r\(c.revision)）" }
        return "程序分组的结果（r\(c.revision)）"
    }
}

struct RunProgress: View {
    var run: AutoRun
    var running: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if running { ProgressView().controlSize(.small) }
                Text(running ? "分析中" : statusText).font(.system(size: 13, weight: .semibold))
                Text("工具 \(run.toolCalls)/\(run.maxToolCalls) 次 · \(Int((run.finishedAt ?? Date()).timeIntervalSince(run.startedAt))) 秒 · \(run.provider == "claude" ? "Claude Code" : "Codex") \(run.model)")
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
            }
            if let e = run.error, !running { Text(e).font(.caption12).foregroundStyle(Theme.warning) }
            ForEach(Array(run.steps.suffix(running ? 8 : 4).enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: s.ok ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(s.ok ? Theme.success : Theme.warning)
                    Text(AutoToolLabel.text(s.tool)).font(.system(size: 12, weight: .medium)).frame(width: 96, alignment: .leading)
                    Text(firstLine(s)).font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
    }

    private var statusText: String {
        switch run.status {
        case .succeeded: "已完成"
        case .cancelled: "已停止"
        case .failed: "没有完成"
        case .interrupted: "被中断"
        default: run.status.rawValue
        }
    }

    private func firstLine(_ s: AutoStep) -> String {
        if s.tool == "note_review" || s.tool == "local_audio_check" || s.tool == "bar_evidence" {
            return s.arguments.replacingOccurrences(of: "\"", with: "").prefix(160).description
        }
        return s.summary.split(separator: "\n").first.map(String.init) ?? ""
    }
}

struct AutoResult: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var harmony: HarmonyRevision
    var auto: AutoHarmony
    var timing: TimingConfirmation
    var run: AutoRun?

    private var grid: BeatGrid {
        var g = timing.grid
        if g.barAnchorUs == nil { g.barAnchorUs = harmony.barAnchorUs }
        return g
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !auto.summary.isEmpty { Text(auto.summary).font(.system(size: 14, weight: .medium)) }
            if let k = auto.key, let key = k.key, key != item.timing?.key {
                KeyCorrectionCard(title: "调性检查：模型判断是 \(k.modeName.isEmpty ? key.display : k.modeName)，和你设定的 \(item.timing?.key.display ?? "") 不同", reason: k.reason,
                                  apply: { model.applyKey(item.id, key) }, applyTitle: "改为 \(key.display)", dismiss: nil)
            } else if let k = auto.key {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.success)
                    Text("调性检查：\(k.modeName.isEmpty ? (k.key?.display ?? "") : k.modeName)，与设定一致").font(.system(size: 12, weight: .semibold))
                    Text(k.reason).font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
            // Only while the grid is still the one the model analysed in (moving it hides the card).
            if let sh = auto.barShiftBeats, sh != 0, harmony.params["barAnchorUs"] == String(grid.barAnchorUs ?? 0) {
                BarShiftCard(text: "模型核对小节线后认为要整体挪动：" + (auto.barReason ?? "") + "（和弦时间不变，只是换个格子读。）",
                             shift: sh, apply: { model.shiftBarLine(item.id, beats: sh) }, dismiss: nil)
            }
            Legend(itemId: item.id)
            if let run, item.trimRevision == run.trimRevision {
                BarProgressionView(item: item, harmony: harmony, auto: auto, grid: grid,
                                   edit: { f in model.editProposal(run.id, f) }, undo: { model.undoProposalEdit(run.id) },
                                   undoCount: model.proposalUndoCount(run.id), notes: model.proposalNotes(run))
            } else {
                BarProgressionView(item: item, harmony: harmony, auto: auto, grid: grid)
            }
            if !auto.toConfirm.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("待确认（\(auto.toConfirm.count)）").font(.system(size: 13, weight: .semibold))
                    ForEach(Array(auto.toConfirm.enumerated()), id: \.offset) { _, c in
                        let p = BarEvidence.position(c.startUs, grid: grid)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "questionmark.circle").foregroundStyle(Theme.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(p.bar) 小节第 \(beatText(p.beat)) 拍").font(.system(size: 12, weight: .semibold))
                                Text(c.question).font(.caption12).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button("听原曲") { model.audition(item.id, startUs: max(0, c.startUs - Int64(grid.beatUs)), endUs: c.startUs + Int64(grid.beatUs * 2), original: true) }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                            Button("听分轨") { model.audition(item.id, startUs: max(0, c.startUs - Int64(grid.beatUs)), endUs: c.startUs + Int64(grid.beatUs * 2), original: false) }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                if let run, !run.reviews.isEmpty {
                    DisclosureGroup("复核记录（\(run.reviews.count)）") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(run.reviews.enumerated()), id: \.offset) { _, r in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("问：" + r.question).font(.caption12)
                                    if !r.observedEvidence.isEmpty { Text("证据：" + r.observedEvidence).font(.caption12).foregroundStyle(Theme.textSecondary) }
                                    if !r.decision.isEmpty { Text("决定：" + r.decision).font(.caption12).foregroundStyle(Theme.accent) }
                                    if !r.stopReason.isEmpty { Text("停止：" + r.stopReason).font(.caption12).foregroundStyle(Theme.textSecondary) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption12)
                }
            }
            HStack {
                Text("证据来源：" + auto.sources.joined(separator: "、") + " · \(run?.provider == "claude" ? "Claude Code" : "Codex") \(run?.model ?? "")")
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
    }

    func beatText(_ b: Double) -> String { b == b.rounded() ? String(Int(b)) : String(format: "%.1f", b) }
}

struct Legend: View {
    var itemId: UUID? = nil
    @AppStorage("foldPushes") private var foldPushes = true
    var body: some View {
        HStack(spacing: 12) {
            chip("主干", fill: true)
            chip("经过 / 连接", fill: false)
            HStack(spacing: 4) { Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.warning); Text("待确认") }
            Toggle(isOn: $foldPushes) { HStack(spacing: 3) { Image(systemName: "arrow.uturn.backward"); Text("提前进入的按进入的拍显示") } }
                .toggleStyle(.checkbox).help("提前一个八分音符按下、延续过拍子的和弦，画在它进入的拍子上；实际时间不变")
            Text("点和弦听实际按法；点小节号听原曲").foregroundStyle(Theme.textSecondary)
            Spacer()
            if let itemId { BarNudge(itemId: itemId) }
        }
        .font(.system(size: 11))
    }
    private func chip(_ t: String, fill: Bool) -> some View {
        Text(t).padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill ? Theme.noteFill : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.noteFill, style: StrokeStyle(lineWidth: 1, dash: fill ? [] : [3, 2])))
            .foregroundStyle(fill ? Theme.onNote : Theme.textPrimary)
    }
}

/// Bars in rows of four; each chord is placed at its beat and sized by its length.
struct BarProgressionView: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var harmony: HarmonyRevision
    var auto: AutoHarmony?
    var grid: BeatGrid
    typealias Edit = (inout HarmonyEdit.State, BeatGrid, KeySignature?) throws -> Void
    /// Hand editing (of the model's result, as a draft until saved); nil = read-only.
    var edit: ((Edit) -> Void)? = nil
    var undo: (() -> Void)? = nil
    var undoCount = 0
    /// Notes to play chords from (the draft's, when edits rewrote voicings).
    var notes: [MidiNote]? = nil
    private var editable: Bool { edit != nil }
    @AppStorage("foldPushes") private var foldPushes = true
    @AppStorage("editWritesVoicing") private var writeVoicing = true
    @ViewState private var selected: String?
    @ViewState private var insertMode = false
    @ViewState private var renaming: String?
    @ViewState private var pendingInsert: Int64?
    @ViewState private var nameText = ""

    /// Chords as read in the bar: anticipations (struck up to an eighth early, held through the
    /// beat) start on the beat they anticipate; each chord runs to the next one's reading start.
    private var reading: [(ev: ChordEvent, s: Int64, e: Int64, pushed: Bool)] {
        let evs = harmony.events.sorted { $0.startUs < $1.startUs }
        let starts: [(us: Int64, pushed: Bool)] = evs.map { foldPushes ? BarEvidence.readingStart($0.startUs, endUs: $0.endUs, grid: grid) : (us: $0.startUs, pushed: false) }
        return evs.indices.map { i in
            (evs[i], starts[i].us, i + 1 < evs.count ? starts[i + 1].us : evs[i].endUs, starts[i].pushed)
        }
    }

    var body: some View {
        let bars = BarEvidence.barCount(grid: grid, durationUs: item.durationUs)
        let rows = stride(from: 1, through: bars, by: 4).map { Array($0...min(bars, $0 + 3)) }
        VStack(alignment: .leading, spacing: 6) {
            if editable { editBar }
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { bar in barCell(bar) }
                    if row.count < 4 { ForEach(0..<(4 - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) } }
                }
            }
        }
        .popover(isPresented: Binding(get: { renaming != nil || pendingInsert != nil },
                                      set: { if !$0 { renaming = nil; pendingInsert = nil } })) { namePopover }
    }

    // MARK: Editing

    private var selectedEvent: ChordEvent? { harmony.events.first { $0.id == selected } }

    private var editBar: some View {
        let ev = selectedEvent
        let idx = ev.flatMap { e in harmony.events.firstIndex { $0.id == e.id } }
        let eighth = Int64(grid.beatUs / 2)
        return HStack(spacing: 8) {
            Toggle(isOn: $insertMode) { Label("插入", systemImage: "plus") }.toggleStyle(.button)
                .help("打开后在小节里点一个位置（吸附到八分音符），插入新和弦")
            Divider().frame(height: 16)
            if let ev, let idx {
                Text("\(ev.symbol ?? "?") · \(harmony.position(of: ev.startUs, grid: grid))").font(.system(size: 12, weight: .semibold))
                Button("改名") { startRename(ev) }
                Button("删除") { let id = ev.id; selected = nil; edit? { st, g, _ in try HarmonyEdit.delete(&st, id: id, grid: g) } }
                    .disabled(harmony.events.count < 2).help("这个和弦的时值并入前一个")
                HStack(spacing: 1) {
                    Text("起点").foregroundStyle(Theme.textSecondary)
                    Button { move(ev.id, to: ev.startUs - eighth) } label: { Image(systemName: "chevron.left") }.disabled(idx == 0)
                    Button { move(ev.id, to: ev.startUs + eighth) } label: { Image(systemName: "chevron.right") }.disabled(idx == 0)
                }.help("起点前后挪一个八分音符（前一个和弦跟着变）")
                HStack(spacing: 1) {
                    Text("终点").foregroundStyle(Theme.textSecondary)
                    let next = idx + 1 < harmony.events.count ? harmony.events[idx + 1] : nil
                    Button { if let n = next { move(n.id, to: n.startUs - eighth) } } label: { Image(systemName: "chevron.left") }.disabled(next == nil)
                    Button { if let n = next { move(n.id, to: n.startUs + eighth) } } label: { Image(systemName: "chevron.right") }.disabled(next == nil)
                }.help("终点前后挪一个八分音符（后一个和弦跟着变）")
            } else {
                Text(insertMode ? "在小节里点一个位置插入和弦" : "点和弦选中；双击改名；右键更多").foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Toggle("改名时用标准按法改写 MIDI", isOn: $writeVoicing).toggleStyle(.checkbox)
                .help("改名后，这个和弦时间段里的音换成新和弦名的标准按法（会生成新的 MIDI 版本，可撤销）")
            Button { undo?() } label: { Label(undoCount > 0 ? "撤销（\(undoCount)）" : "撤销", systemImage: "arrow.uturn.backward") }
                .disabled(undoCount == 0)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }

    private func move(_ id: String, to us: Int64) {
        edit? { st, g, _ in try HarmonyEdit.moveStart(&st, id: id, toUs: us, grid: g) }
    }

    private func startRename(_ ev: ChordEvent) { nameText = ev.symbol ?? ""; renaming = ev.id; pendingInsert = nil }

    private var namePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pendingInsert != nil ? "插入和弦（\(pendingInsert.map { harmony.position(of: HarmonyEdit.snapEighth($0, grid: grid), grid: grid) } ?? "")）" : "改和弦名")
                .font(.system(size: 13, weight: .semibold))
            TextField("如 Am7、G7/B、Fmaj9", text: $nameText).textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit(commitName)
            if !nameText.isEmpty && ChordSymbol.parse(nameText) == nil {
                Text("看不懂这个和弦名").font(.caption12).foregroundStyle(Theme.warning)
            } else if let p = StandardVoicing.pitches(symbol: nameText) {
                Text("标准按法：" + p.map { Pitch.noteName($0) }.joined(separator: " ")).font(.caption12).foregroundStyle(Theme.textSecondary)
            }
            Toggle("用标准按法改写 MIDI", isOn: $writeVoicing).toggleStyle(.checkbox).font(.caption12)
            HStack {
                Spacer()
                Button("取消") { renaming = nil; pendingInsert = nil }
                Button("确定") { commitName() }.buttonStyle(PrimaryButtonStyle()).disabled(ChordSymbol.parse(nameText) == nil)
            }
        }
        .padding(14)
    }

    private func commitName() {
        guard ChordSymbol.parse(nameText) != nil else { return }
        let name = nameText, voicing = writeVoicing
        if let t = pendingInsert {
            edit? { st, g, key in
                let id = try HarmonyEdit.insert(&st, atUs: t, symbol: name, key: key, grid: g, writeVoicing: voicing)
                Task { @MainActor in selected = id }
            }
            insertMode = false
        } else if let id = renaming {
            edit? { st, _, key in try HarmonyEdit.rename(&st, id: id, symbol: name, key: key, writeVoicing: voicing) }
        }
        renaming = nil; pendingInsert = nil
    }

    // MARK: Cells

    private func barCell(_ bar: Int) -> some View {
        let s = BarEvidence.barStartUs(bar, grid: grid), e = BarEvidence.barStartUs(bar + 1, grid: grid)
        let span = Double(e - s)
        let events = reading.filter { $0.s < e && $0.e > s }
        return VStack(alignment: .leading, spacing: 3) {
            Button { model.audition(item.id, startUs: max(0, s), endUs: min(item.durationUs, e), original: true) } label: {
                HStack(spacing: 3) { Text("\(bar)").font(.system(size: 11, weight: .semibold)); Image(systemName: "speaker.wave.2").font(.system(size: 9)) }
            }.buttonStyle(.borderless).foregroundStyle(Theme.textSecondary).help("听原曲第 \(bar) 小节")
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Insert mode: a click anywhere in the bar picks the position.
                    if editable && insertMode {
                        Rectangle().fill(Theme.accent.opacity(0.06)).contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { loc in
                                let us = s + Int64(Double(loc.x / max(1, geo.size.width)) * span)
                                nameText = harmony.events.first { $0.startUs <= us && $0.endUs > us }?.symbol ?? ""
                                renaming = nil
                                pendingInsert = min(max(0, us), item.durationUs - 1)
                            }
                    }
                    // Beat ticks
                    ForEach(1..<Int(grid.meter.quarterBeatsPerBar.rounded()), id: \.self) { b in
                        Rectangle().fill(Theme.borderSubtle).frame(width: 1, height: 6)
                            .offset(x: geo.size.width * CGFloat(Double(b) / grid.meter.quarterBeatsPerBar), y: geo.size.height - 6)
                            .allowsHitTesting(false)
                    }
                    ForEach(events, id: \.ev.id) { r in
                        let x0 = max(0, Double(r.s - s) / span), x1 = min(1, Double(r.e - s) / span)
                        let w = max(14, geo.size.width * CGFloat(x1 - x0) - 2)
                        chordChip(r.ev, continued: r.s < s - 20_000, roomy: w > 70, pushed: r.pushed && r.s >= s - 20_000)
                            .frame(width: w, height: geo.size.height - 8)
                            .offset(x: geo.size.width * CGFloat(x0))
                            .allowsHitTesting(!(editable && insertMode))
                    }
                }
            }
            .frame(height: 50)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderSubtle))
    }

    @ViewBuilder private func chordChip(_ ev: ChordEvent, continued: Bool, roomy: Bool, pushed: Bool) -> some View {
        let info = auto?.chordInfo[ev.id]
        let strong = info?.role == "backbone" || info?.role == nil
        let confirm = auto?.toConfirm.contains { $0.eventId == ev.id } ?? false
        let isSelected = editable && selected == ev.id
        let label = HStack(spacing: 2) {
            Text(continued ? "↳" : Self.breakable(ev.symbol ?? "?")).font(.system(size: strong ? 13 : 11, weight: strong ? .semibold : .medium))
                .lineLimit(2).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
            if pushed && !continued { Image(systemName: "arrow.uturn.backward").font(.system(size: 8, weight: .semibold)).opacity(0.7) }
            if ev.manualOverride && editable && !continued && roomy { Image(systemName: "pencil").font(.system(size: 8)).opacity(0.7) }
            if confirm && !continued && roomy { Image(systemName: "questionmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.warning) }
        }
        .padding(.horizontal, roomy ? 4 : 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(strong ? Theme.noteFill.opacity(continued ? 0.45 : 1) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Theme.accent : (confirm ? Theme.warning : Theme.noteFill),
                                                         style: StrokeStyle(lineWidth: isSelected ? 2.5 : (confirm ? 1.5 : 1), dash: strong || isSelected ? [] : [3, 2])))
        .foregroundStyle(strong ? Theme.onNote : Theme.textPrimary)
        .help("\(ev.symbol ?? "?")（\(info?.roleDisplay ?? "")）：\(info?.reason ?? "")" + (pushed ? "\n提前一个八分音符按下（按它进入的拍子显示）" : ""))
        if editable {
            label
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { selected = ev.id; startRename(ev) }
                .onTapGesture { selected = ev.id; play(ev) }
                .contextMenu {
                    Button("改名…") { selected = ev.id; startRename(ev) }
                    Button("从中间拆分") {
                        let mid = ev.startUs + (ev.endUs - ev.startUs) / 2, name = ev.symbol ?? "C"
                        edit? { st, g, key in _ = try HarmonyEdit.insert(&st, atUs: mid, symbol: name, key: key, grid: g, writeVoicing: false) }
                    }
                    Button("删除（并入前一个）", role: .destructive) {
                        let id = ev.id; selected = nil
                        edit? { st, g, _ in try HarmonyEdit.delete(&st, id: id, grid: g) }
                    }.disabled(harmony.events.count < 2)
                }
        } else {
            Button { play(ev) } label: { label }.buttonStyle(.plain)
        }
    }

    /// Lets a narrow chip wrap a long name before its extension or bass ("Fm" / "(add9)", "A♭maj7" / "/B♭").
    static func breakable(_ symbol: String) -> String {
        symbol.replacingOccurrences(of: "(", with: "\u{200B}(").replacingOccurrences(of: "/", with: "\u{200B}/")
    }

    /// Plays the chord tones as struck in the corrected MIDI; the standard voicing if they don't cover the chord.
    private func play(_ ev: ChordEvent) {
        let rel: [PlayedVoicing.Note] = (notes ?? model.confirmedMidi(item)?.notes ?? []).filter { ev.noteIds.contains($0.id) }.map { n in
            let st = max(n.startUs, ev.startUs)
            return (pitch: n.pitch, start: Double(st - ev.startUs) / 1e6, duration: Double(min(n.endUs, ev.endUs) - st) / 1e6)
        }
        let window = min(0.6, grid.beatUs / 1e6)
        guard let p = PlayedVoicing.pitches(symbol: ev.symbol, notes: rel, onsetWindow: window) ?? ev.symbol.flatMap(StandardVoicing.pitches(symbol:)) else { return }
        AudioEngine.shared.playChord(p, duration: min(2.5, max(0.8, Double(ev.endUs - ev.startUs) / 1e6)))
    }
}

/// Manual room to move the bar lines afterwards, by an eighth or a beat; note times stay.
struct BarNudge: View {
    @Environment(AppModel.self) private var model
    var itemId: UUID
    var body: some View {
        HStack(spacing: 2) {
            Text("小节线").foregroundStyle(Theme.textSecondary)
            Button { model.shiftBarLine(itemId, beats: -1) } label: { Image(systemName: "chevron.left.2") }.help("整体提前一拍")
            Button { model.shiftBarLine(itemId, beats: -0.5) } label: { Image(systemName: "chevron.left") }.help("整体提前一个八分音符")
            Button { model.shiftBarLine(itemId, beats: 0.5) } label: { Image(systemName: "chevron.right") }.help("整体推后一个八分音符")
            Button { model.shiftBarLine(itemId, beats: 1) } label: { Image(systemName: "chevron.right.2") }.help("整体推后一拍")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }
}

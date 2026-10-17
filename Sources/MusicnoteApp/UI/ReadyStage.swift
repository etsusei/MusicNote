import MusicnoteCore
import SwiftUI
import UniformTypeIdentifiers

struct ReadyStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var transport: TransportModel
    @AppStorage("readyTab") private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(item.isHarmonic ? "笔记与和弦" : "笔记").tag(0)
                Text("MIDI 校对").tag(1)
                Text("速度网格").tag(2)
            }
            .pickerStyle(.segmented).frame(width: 340).padding(.vertical, 8)
            Divider()
            switch tab {
            case 1: MidiStage(item: item, transport: transport, embedded: true)
            case 2: TimingEditor(item: item)
            default: NotesStage(item: item)
            }
        }
        .onAppear { if tab != 1 { AudioEngine.shared.stopAll() } }
        .onChange(of: tab) { _, t in if t != 1 { AudioEngine.shared.stopAll() } }
    }
}

// MARK: - Notes & chords

struct NotesStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    @AppStorage("cardStandard") private var standardAll = false
    @ViewState private var playgroundSend: PlaygroundSendRequest?

    var body: some View {
        let _ = model.dataVersion
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summary
                let stale = model.harmonyStale(item)
                if !stale.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(stale, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption12).foregroundStyle(Theme.warning) }
                            HStack {
                                if item.isHarmonic {
                                    Button("重新分析和声") { model.runHarmony(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                                    Button("只重算级数") { model.recomputeDegrees(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                                }
                                Text("重算只替换派生结果，不会改你的笔记和手动标签。").font(.caption12).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                if item.isHarmonic {
                    if let h = model.latestHarmony(item.id), !h.events.isEmpty {
                        progression(h)
                        chordCards(h)
                        SkeletonSection(item: item, harmony: h, send: { playgroundSend = $0 })
                    } else if model.jobs[item.id] == nil {
                        Card {
                            HStack {
                                Text("还没有和弦分析结果。").foregroundStyle(Theme.textSecondary)
                                Button("分析和声") { model.runHarmony(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                            }
                        }
                    }
                } else {
                    Card { Text("\(item.selectedStem?.displayName ?? "")轨不做和弦、级数和骨架分析；可以写笔记、打标签并在聊天里引用。").foregroundStyle(Theme.textSecondary) }
                }
                tags
                NotesEditor(item: item)
                actions
            }
            .padding(24)
        }
        .defaultScrollAnchor(.top)
        .sheet(item: $playgroundSend) { req in PlaygroundSendSheet(request: req).environment(model) }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Text("\(formatTime(us: item.trimStartUs))–\(formatTime(us: item.trimEndUs))").font(.mono13)
            if let t = item.timing {
                StatusPill(text: t.key.display)
                StatusPill(text: String(format: "%.1f BPM", t.bpm))
                StatusPill(text: t.meter.display + (t.meterConfirmed ? "" : "（未确认）"))
            }
            if let s = item.selectedStem { StatusPill(text: s.displayName + "轨") }
            Spacer()
        }
    }

    private func progression(_ h: HarmonyRevision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: "完整进行", subtitle: "按时间顺序，重复和弦保留为独立实例。级数以主音大调为参照；仅基于\(item.selectedStem?.displayName ?? "所选")分轨。")
                Spacer()
                Toggle("全部显示标准按法", isOn: $standardAll).toggleStyle(.checkbox).font(.caption12)
            }
            Text(h.events.map { ($0.symbol ?? "未确定") }.joined(separator: "  →  ")).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
            Text(h.events.map { $0.degree?.display ?? "?" }.joined(separator: "  →  ")).font(.control13).foregroundStyle(Theme.textSecondary)
            if h.barAnchorEstimated, let a = h.barAnchorUs {
                HStack(spacing: 8) {
                    Label("小节线是自动估计的：第 1 小节从 \(formatTime(us: a)) 开始（和弦大多落在这里或提前半拍）", systemImage: "metronome")
                        .font(.caption12).foregroundStyle(Theme.warning)
                    Button("采用") { model.adoptBarAnchor(item.id, a) }.buttonStyle(SecondaryButtonStyle(compact: true))
                        .help("写入速度网格；之后可在「速度网格」里修改")
                }
            }
            Text("命名：\(h.namerVersion) · 分组：\(h.params["algorithm"] ?? "")（八分音符检测点，换和弦优先落在小节线和强拍）").font(.caption12).foregroundStyle(Theme.textSecondary)
        }
    }

    private func chordCards(_ h: HarmonyRevision) -> some View {
        let notes = model.confirmedMidi(item)?.notes ?? []
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 12)], spacing: 12) {
            ForEach(h.events) { ev in
                ChordEventCard(item: item, harmony: h, event: ev, notes: notes, forceStandard: standardAll,
                               send: { playgroundSend = $0 })
            }
        }
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "手动标签", subtitle: "只由你填写；跨歌检索以这里为准。")
            HStack(alignment: .top) {
                Text("片段").font(.caption12).foregroundStyle(Theme.textSecondary).frame(width: 40, alignment: .leading)
                TagEditor(tags: Binding(get: { item.tags }, set: { var i = item; i.tags = $0; model.save(i) }), placeholder: "如 Neo-Soul、律动")
            }
            if item.isHarmonic {
                HStack(alignment: .top) {
                    Text("骨架").font(.caption12).foregroundStyle(Theme.textSecondary).frame(width: 40, alignment: .leading)
                    TagEditor(tags: Binding(get: { item.skeletonTags }, set: { var i = item; i.skeletonTags = $0; model.save(i) }), placeholder: "如 4-5-3-6")
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("导出校正 MIDI…") { exportMidi() }.buttonStyle(SecondaryButtonStyle())
            if item.isHarmonic, model.latestHarmony(item.id) != nil {
                Button("完整进行送入 Playground…") { playgroundSend = PlaygroundSendRequest(itemId: item.id, kind: .progression) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
        }
    }

    private func exportMidi() {
        guard let midi = model.confirmedMidi(item), let timing = item.timing else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = "\(model.song(item.songId)?.title ?? "Musicnote") - \(item.title).mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ClipMidiExport.data(notes: midi.notes, timing: timing).write(to: url)
    }
}

// MARK: - Chord card

struct ChordEventCard: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var harmony: HarmonyRevision
    var event: ChordEvent
    var notes: [MidiNote]
    var forceStandard: Bool
    var send: (PlaygroundSendRequest) -> Void
    @ViewState private var standard = false
    @ViewState private var block = false
    @ViewState private var editingName = false
    @ViewState private var nameText = ""
    @ViewState private var showNotes = false

    private var members: [MidiNote] { notes.filter { event.noteIds.contains($0.id) }.sorted { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) } }
    private var actualPitches: [Int] { Array(Set(members.map(\.pitch))).sorted() }
    private var useStandard: Bool { standard || forceStandard }
    private var shownPitches: [Int] { useStandard ? (event.symbol.flatMap(StandardVoicing.pitches(symbol:)) ?? []) : actualPitches }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if editingName {
                    TextField("和弦名", text: $nameText).textFieldStyle(.roundedBorder).frame(width: 120)
                        .onSubmit { rename(nameText) }
                } else {
                    Text(event.symbol ?? "未确定").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(event.symbol == nil ? Theme.warning : Theme.textPrimary)
                        .onTapGesture(count: 2) { nameText = event.symbol ?? ""; editingName = true }
                }
                Text(event.degree?.display ?? "").font(.control13).foregroundStyle(Theme.textSecondary)
                Spacer()
                if event.manualOverride { Image(systemName: "pencil.circle").foregroundStyle(Theme.accent).help("人工命名") }
                Text(event.texture.display).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            KeyboardView(pitches: shownPitches, height: 58)
            HStack(spacing: 6) {
                Picker("", selection: $standard) { Text("片段").tag(false); Text("标准").tag(true) }
                    .pickerStyle(.segmented).frame(width: 100).disabled(forceStandard)
                Button { play() } label: { Image(systemName: "play.fill") }.buttonStyle(SecondaryButtonStyle(compact: true)).help("按当前音色发声")
                if !useStandard && event.texture != .block {
                    Toggle("柱式", isOn: $block).toggleStyle(.checkbox).font(.caption12).help("默认按原时序回放；勾选后合并成柱式和弦")
                }
                Spacer()
                Menu {
                    Section("候选名称") {
                        ForEach(event.candidates, id: \.symbol) { c in
                            Button("\(c.symbol)（\(c.source == .musicpy ? "Musicpy" : "模板")）") { rename(c.symbol) }
                        }
                    }
                    Button("手动改名…") { nameText = event.symbol ?? ""; editingName = true }
                    if event.manualOverride { Button("恢复自动命名") { restoreAuto() } }
                    Divider()
                    Button("查看/排除参与命名的音…") { showNotes = true }
                    Button("与下一个合并") { model.mergeEvent(item.id, eventId: event.id) }
                    Button("从中间拆分") { model.splitEvent(item.id, eventId: event.id) }
                    Divider()
                    Button("加入学习收藏") { collect() }
                    Button("送入 Playground…") { send(PlaygroundSendRequest(itemId: item.id, kind: .chord(event.id))) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 28)
            }
            Text("\(item.timing.map { harmony.position(of: event.startUs, grid: $0.grid) } ?? "") · \(String(format: "%.2f", beats)) 拍 · \(formatTime(us: event.startUs))")
                .font(.caption12).foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderSubtle))
        .popover(isPresented: $showNotes) { notesPopover }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.symbol ?? "未确定") \(event.degree?.display ?? "")，音符 \(shownPitches.map { Pitch.noteName($0) }.joined(separator: " "))")
    }

    private var beats: Double {
        guard let g = item.timing?.grid else { return 0 }
        return Double(event.durationUs) / g.beatUs
    }

    private var notesPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("参与命名的音（排除只影响命名，不删除 MIDI）").font(.caption12).foregroundStyle(Theme.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(members) { n in
                        Toggle(isOn: Binding(get: { !event.excludedNoteIds.contains(n.id) }, set: { on in toggleExclude(n.id, include: on) })) {
                            HStack {
                                Text(Pitch.noteName(n.pitch)).font(.mono13).frame(width: 44, alignment: .leading)
                                Text(formatTime(us: n.startUs)).font(.caption12)
                                if let r = event.noteRoles[n.id] { Text(r.display).font(.caption12).foregroundStyle(r == .chordTone ? Theme.textSecondary : Theme.accent) }
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
            }.frame(maxHeight: 280)
        }
        .padding(12).frame(width: 260)
    }

    private func play() {
        if useStandard { AudioEngine.shared.playChord(shownPitches); return }
        if block || event.texture == .block { AudioEngine.shared.playChord(actualPitches, duration: min(2.5, Double(event.durationUs) / 1e6)); return }
        AudioEngine.shared.playNotes(members.map { n in
            let s = max(n.startUs, event.startUs)
            return (pitch: n.pitch, start: Double(s - event.startUs) / 1e6, duration: Double(min(n.endUs, event.endUs) - s) / 1e6, velocity: n.velocity)
        })
    }

    private func rename(_ s: String) {
        editingName = false
        let t = s.trimmingCharacters(in: .whitespaces)
        model.updateEvent(item.id, eventId: event.id) { ev, key in
            ev.symbol = t.isEmpty ? nil : t
            ev.manualOverride = true
            ev.namingSource = .user
            ev.degree = ev.symbol.flatMap { Degrees.label(symbol: $0, key: key) }
        }
    }

    private func restoreAuto() {
        model.updateEvent(item.id, eventId: event.id) { ev, key in
            ev.manualOverride = false
            ev.symbol = ev.candidates.first?.symbol
            ev.namingSource = ev.candidates.first?.source
            ev.degree = ev.symbol.flatMap { Degrees.label(symbol: $0, key: key) }
        }
    }

    private func toggleExclude(_ id: UUID, include: Bool) {
        model.updateEvent(item.id, eventId: event.id, rename: true) { ev, _ in
            if include { ev.excludedNoteIds.removeAll { $0 == id } } else if !ev.excludedNoteIds.contains(id) { ev.excludedNoteIds.append(id) }
        }
    }

    private func collect() {
        guard let g = item.timing?.grid else { return }
        let q0 = g.q(atUs: event.startUs)
        let bn = members.map { BlockNote(pitch: $0.pitch, velocity: $0.velocity, startQ: g.q(atUs: max($0.startUs, event.startUs)) - q0,
                                         durationQ: Double(min($0.endUs, event.endUs) - max($0.startUs, event.startUs)) / g.beatUs, sourceNoteId: $0.id) }
        model.addToCollection(CollectionItem(analysisId: item.id, eventId: event.id, harmonyRevision: harmony.revision,
                                             symbol: event.symbol ?? "?", notes: bn), title: "我的收藏")
    }
}

// MARK: - Skeleton

struct SkeletonSection: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var harmony: HarmonyRevision
    var send: (PlaygroundSendRequest) -> Void
    @ViewState private var provider = ""

    var body: some View {
        let sk = model.latestSkeleton(item.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "LLM 骨架与解释", subtitle: "模型给的是建议与解释，不会自动成为你的标签，也不会改 MIDI。")
                Spacer()
                Picker("", selection: $provider) {
                    ForEach(Array(model.providers.keys.sorted()), id: \.self) { id in
                        Text("\(model.providers[id]!.displayName)（\(model.providerStatus[id]?.state.display ?? "…")）").tag(id)
                    }
                }.frame(width: 220)
                if model.skeletonRunning.contains(item.id) {
                    ProgressView().controlSize(.small); Text("生成中").font(.caption12)
                } else {
                    Button(sk == nil ? "生成骨架解释" : "重新生成") { model.generateSkeleton(item.id, providerId: provider) }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
            if let sk {
                if sk.status == .failed {
                    Card { Label(sk.error ?? "生成失败", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
                } else if sk.status == .succeeded {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                StatusPill(text: "\(model.providers[sk.provider]?.displayName ?? sk.provider) · \(sk.model)")
                                if sk.harmonyRevision != harmony.revision { StatusPill(text: "基于旧版和声", color: Theme.warning) }
                                if sk.unstructured { StatusPill(text: "未结构化回答", color: Theme.warning) }
                                Spacer()
                                if !sk.backboneEventIds.isEmpty {
                                    Button("骨架送入 Playground…") { send(PlaygroundSendRequest(itemId: item.id, kind: .skeleton)) }
                                        .buttonStyle(SecondaryButtonStyle(compact: true))
                                }
                            }
                            if let summary = sk.summary, !summary.isEmpty {
                                Text(summary).font(.system(size: 15, weight: .semibold))
                            }
                            if !sk.backboneEventIds.isEmpty {
                                let byId = Dictionary(uniqueKeysWithValues: harmony.events.map { ($0.id, $0) })
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("骨架").font(.caption12).foregroundStyle(Theme.textSecondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sk.backboneEventIds.map { id in (byId[id]?.symbol ?? "?") }.joined(separator: " → "))
                                            .font(.system(size: 15, weight: .medium))
                                        Text(sk.backboneEventIds.map { id in byId[id]?.degree?.display ?? "?" }.joined(separator: " → "))
                                            .font(.control13).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                if !sk.relations.isEmpty {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(sk.relations, id: \.eventId) { r in
                                            let ev = byId[r.eventId]
                                            let pos = ev.flatMap { e in item.timing.map { harmony.position(of: e.startUs, grid: $0.grid) } } ?? ""
                                            Text("· \(pos.replacingOccurrences(of: " ", with: "")) \(ev?.symbol ?? "?")\(r.targetEventId.flatMap { byId[$0]?.symbol }.map { " → \($0)" } ?? "")（\(relationName(r.kind))）：\(r.reason)")
                                                .font(.caption12).foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                }
                                if let a = sk.alternatives.first {
                                    Text("另一种看法：" + a.backboneEventIds.map { byId[$0]?.symbol ?? "?" }.joined(separator: " → ") + "。\(a.reason)")
                                        .font(.caption12)
                                }
                            }
                            RichTextView(text: sk.explanation, linkedEvents: linked)
                            if let tags = sk.error, tags.hasPrefix("建议标签：") {
                                HStack {
                                    Text("模型建议的标签（点击才会加入）：").font(.caption12).foregroundStyle(Theme.textSecondary)
                                    ForEach(tags.dropFirst(5).split(separator: "、").map(String.init), id: \.self) { t in
                                        Button(t) { var i = item; if !i.skeletonTags.contains(t) { i.skeletonTags.append(t); model.save(i) } }
                                            .buttonStyle(SecondaryButtonStyle(compact: true))
                                    }
                                }
                            }
                        }
                    }
                }
            } else if !model.skeletonRunning.contains(item.id) {
                Text("尚未生成。连接 Codex 或 Claude Code 后可生成；不连接也不影响笔记和标签。").font(.caption12).foregroundStyle(Theme.textSecondary)
            }
        }
        .onAppear { if provider.isEmpty { provider = model.settings.defaultProvider } }
    }

    private var linked: [String: String] {
        var d: [String: String] = [:]
        for e in harmony.events { if let s = e.symbol, d[s] == nil { d[s] = "\(item.id.uuidString)|\(e.id)" } }
        return d
    }

    private func relationName(_ k: String) -> String {
        switch k { case "passing": "经过"; case "connecting": "连接"; case "substitute": "替代"; default: "色彩变化" }
    }
}

// MARK: - Free notes

struct NotesEditor: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    @ViewState private var text = ""
    @ViewState private var preview = false
    @ViewState private var saveTask: Task<Void, Never>?
    @ViewState private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "自由笔记", subtitle: "和声、旋律听感、voicing、配器、编曲、混音和练习想法。和弦名会自动变成可试听的卡片。")
                Spacer()
                Picker("", selection: $preview) { Text("编辑").tag(false); Text("预览").tag(true) }.pickerStyle(.segmented).frame(width: 120)
            }
            if preview {
                Card { RichTextView(text: text.isEmpty ? "（空）" : text).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                TextEditor(text: $text).font(.body14).frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.controlBorder.opacity(0.5)))
            }
        }
        .onAppear { if !loaded { text = model.noteDocument(item.id).text; loaded = true } }
        .onChange(of: text) { _, t in
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { return }
                var d = model.noteDocument(item.id); d.text = t; model.saveNote(d)
            }
        }
        .onDisappear { saveTask?.cancel(); var d = model.noteDocument(item.id); if d.text != text { d.text = text; model.saveNote(d) } }
    }
}

// MARK: - Timing after confirmation

struct TimingEditor: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    @ViewState private var bpmText = ""
    @ViewState private var originMs = 0.0
    @ViewState private var numerator = 4
    @ViewState private var denominator = 4
    @ViewState private var anchorText = ""
    @ViewState private var tonic = 0
    @ViewState private var flats = false
    @ViewState private var mode: Mode = .major

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "速度网格与调性",
                              subtitle: "修改 BPM、拍点、拍号只改变网格、时值和级数上下文，不改变音频或 MIDI 的真实时间。")
                Card {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow { Text("BPM（四分音符）"); TextField("", text: $bpmText).frame(width: 90).textFieldStyle(.roundedBorder) }
                        GridRow { Text("节拍起点（ms）"); TextField("", value: $originMs, format: .number).frame(width: 90).textFieldStyle(.roundedBorder) }
                        GridRow {
                            Text("拍号")
                            HStack {
                                Stepper("\(numerator)", value: $numerator, in: 1...15)
                                Text("/")
                                Picker("", selection: $denominator) { ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) } }.frame(width: 64)
                            }
                        }
                        GridRow { Text("小节起点（ms，可空）"); TextField("", text: $anchorText).frame(width: 90).textFieldStyle(.roundedBorder) }
                        GridRow {
                            Text("调性")
                            HStack {
                                Picker("", selection: $tonic) { ForEach(0..<12, id: \.self) { Text(Pitch.name(pc: $0, flats: flats)).tag($0) } }.frame(width: 90)
                                Toggle("降号", isOn: $flats).toggleStyle(.checkbox)
                                Picker("", selection: $mode) { Text("大调").tag(Mode.major); Text("小调").tag(Mode.minor) }.pickerStyle(.segmented).frame(width: 120)
                            }
                        }
                    }
                }
                HStack {
                    Button("保存") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(Tempo.parseUserBpm(bpmText) == nil)
                    Text("保存后，和弦分组标为待核对、级数需重算；可在笔记页重新分析。").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(24)
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let t = item.timing else { return }
        bpmText = String(format: "%.1f", t.bpm); originMs = Double(t.beatOriginUs) / 1000
        numerator = t.meter.numerator; denominator = t.meter.denominator
        anchorText = t.barAnchorUs.map { String(Double($0) / 1000) } ?? ""
        tonic = t.key.tonic; mode = t.key.mode; flats = t.key.tonicName.contains("♭")
    }

    private func save() {
        guard var t = item.timing, let b = Tempo.parseUserBpm(bpmText) else { return }
        t.bpm = b
        t.beatOriginUs = Int64(originMs * 1000)
        t.meter = Meter(numerator, denominator)
        t.barAnchorUs = Double(anchorText).map { Int64($0 * 1000) }
        t.key = KeySignature(tonic: tonic, tonicName: Pitch.name(pc: tonic, flats: flats), mode: mode)
        t.confirmedAt = Date()
        model.updateTiming(item.id, timing: t)
    }
}

// MARK: - Harmony edits

extension AppModel {
    /// Edits one event in the latest harmony revision; `rename` re-runs naming (e.g. after exclusions).
    func updateEvent(_ itemId: UUID, eventId: String, rename: Bool = false, _ f: @escaping (inout ChordEvent, KeySignature) -> Void) {
        guard var h = latestHarmony(itemId), let idx = h.events.firstIndex(where: { $0.id == eventId }), let item = item(itemId) else { return }
        let key = item.timing?.key ?? h.key
        f(&h.events[idx], key)
        saveHarmony(h)
        if rename, let midi = confirmedMidi(item) {
            let ev = h.events[idx]
            Task {
                let renamed = await pipeline.renameEvent(ev, notes: midi.notes, key: key)
                guard var cur = latestHarmony(itemId), let j = cur.events.firstIndex(where: { $0.id == eventId }) else { return }
                cur.events[j] = renamed
                saveHarmony(cur)
            }
        }
    }

    func mergeEvent(_ itemId: UUID, eventId: String) {
        guard var h = latestHarmony(itemId), let i = h.events.firstIndex(where: { $0.id == eventId }), i + 1 < h.events.count,
              let item = item(itemId), let midi = confirmedMidi(item) else { return }
        var a = h.events[i]
        let b = h.events[i + 1]
        a.endUs = b.endUs
        a.noteIds = Array(Set(a.noteIds + b.noteIds))
        for (k, v) in b.noteRoles where a.noteRoles[k] == nil { a.noteRoles[k] = v }
        a.manualOverride = false
        h.events.remove(at: i + 1)
        h.events[i] = a
        for k in h.events.indices { h.events[k].order = k }
        saveHarmony(h)
        let key = item.timing?.key ?? h.key
        Task {
            let renamed = await pipeline.renameEvent(a, notes: midi.notes, key: key)
            guard var cur = latestHarmony(itemId), let j = cur.events.firstIndex(where: { $0.id == a.id }) else { return }
            cur.events[j] = renamed
            saveHarmony(cur)
        }
    }

    /// Moves the boundary between two adjacent chords; both are re-named from the notes they now hold.
    func moveEventBoundary(_ itemId: UUID, left: String, right: String, to t: Int64) {
        guard var h = latestHarmony(itemId), let item = item(itemId), let midi = confirmedMidi(item),
              let i = h.events.firstIndex(where: { $0.id == left }), let j = h.events.firstIndex(where: { $0.id == right }), j == i + 1,
              t > h.events[i].startUs, t < h.events[j].endUs else { return }
        h.events[i].endUs = t
        h.events[j].startUs = t
        let beatUs = item.timing?.grid.beatUs ?? 500_000
        let pitched = midi.notes.filter { $0.instrument != "drums" && $0.instrument != "voice" }
        for k in [i, j] {
            let e = h.events[k]
            h.events[k].noteIds = ChordGrouper.members(pitched, start: e.startUs, end: e.endUs, beatUs: beatUs).map(\.id)
            h.events[k].excludedNoteIds = e.excludedNoteIds.filter { h.events[k].noteIds.contains($0) }
        }
        saveHarmony(h)
        let key = item.timing?.key ?? h.key
        let touched = [h.events[i], h.events[j]]
        Task {
            for e in touched {
                let renamed = await pipeline.renameEvent(e, notes: midi.notes, key: key)
                guard var cur = latestHarmony(itemId), let k = cur.events.firstIndex(where: { $0.id == e.id }) else { continue }
                cur.events[k] = renamed
                saveHarmony(cur)
            }
        }
    }

    func splitEvent(_ itemId: UUID, eventId: String, at position: Int64? = nil) {
        guard var h = latestHarmony(itemId), let i = h.events.firstIndex(where: { $0.id == eventId }),
              let item = item(itemId), let midi = confirmedMidi(item) else { return }
        let ev = h.events[i]
        var mid = (ev.startUs + ev.endUs) / 2
        if let p = position, p > ev.startUs, p < ev.endUs { mid = p }
        else if let g = item.timing?.grid { let s = g.snap(us: mid, division: 1); if s > ev.startUs && s < ev.endUs { mid = s } }
        let inEvent = midi.notes.filter { ev.noteIds.contains($0.id) }
        let beatUs = item.timing?.grid.beatUs ?? 500_000
        var a = ev, b = ev
        a.endUs = mid; b.startUs = mid
        a.noteIds = ChordGrouper.members(inEvent, start: a.startUs, end: mid, beatUs: beatUs).map(\.id)
        b.noteIds = ChordGrouper.members(inEvent, start: mid, end: b.endUs, beatUs: beatUs).map(\.id)
        b.id = ev.id + "b"
        while h.events.contains(where: { $0.id == b.id }) { b.id += "b" }
        a.manualOverride = false; b.manualOverride = false
        h.events[i] = a
        h.events.insert(b, at: i + 1)
        for k in h.events.indices { h.events[k].order = k }
        saveHarmony(h)
        let key = item.timing?.key ?? h.key
        Task {
            for e in [a, b] {
                let renamed = await pipeline.renameEvent(e, notes: midi.notes, key: key)
                guard var cur = latestHarmony(itemId), let j = cur.events.firstIndex(where: { $0.id == e.id }) else { continue }
                cur.events[j] = renamed
                saveHarmony(cur)
            }
        }
    }

    /// Writes the estimated bar line into the confirmed timing (grouping already used it).
    func adoptBarAnchor(_ itemId: UUID, _ anchorUs: Int64) {
        guard var item = item(itemId), var t = item.timing else { return }
        t.barAnchorUs = anchorUs
        item.timing = t
        save(item)
        if var h = latestHarmony(itemId) { h.params["barAnchorEstimated"] = "0"; h.timingRevision = item.timingRevision; saveHarmony(h) }
    }

    /// Key change only re-derives degrees and spellings; groups, notes and overrides stay.
    func recomputeDegrees(_ itemId: UUID) {
        guard let item = item(itemId), let key = item.timing?.key, var h = latestHarmony(itemId) else { return }
        h.key = key
        for i in h.events.indices { h.events[i].degree = h.events[i].symbol.flatMap { Degrees.label(symbol: $0, key: key) } }
        h.needsReview.removeAll { $0.contains("调性") }
        saveHarmony(h)
    }
}

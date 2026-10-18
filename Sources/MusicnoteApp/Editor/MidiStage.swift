import AVFoundation
import MusicnoteCore
import SwiftUI

/// MIDI proofreading: selected stem audio and MIDI with independent mute/solo,
/// shared cursor and loop. Toggling never stops playback.
struct MidiStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var transport: TransportModel
    var embedded = false

    @ViewState private var editor = MidiEditorController()
    @ViewState private var peaks: WaveformPeaks?
    @ViewState private var audioMute = false
    @ViewState private var audioSolo = false
    @ViewState private var midiMute = false
    @ViewState private var midiSolo = false
    @ViewState private var loopOn = false
    @ViewState private var fitToken = 0
    @ViewState private var saveTask: Task<Void, Never>?
    @ViewState private var confirmSwitch: StemKind?
    @ViewState private var loaded = false
    @ViewState private var chords: [ChordSpan] = []
    @ViewState private var previewTask: Task<Void, Never>?

    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                MidiEditorRepresentable(controller: editor, peaks: peaks, chords: chords, playheadUs: transport.positionUs,
                                        isPlaying: transport.isPlaying, fitToken: fitToken,
                                        onSeek: { AudioEngine.shared.seek(Int64(Double($0) / 1_000_000 * 44100)) },
                                        onLoop: { r in loopOn = r != nil; applyLoop() },
                                        onChordBoundary: { l, r, t in model.moveEventBoundary(item.id, left: l, right: r, to: t) },
                                        onChordRename: { id, name in renameChord(id, name) },
                                        onChordMerge: { id in model.mergeEvent(item.id, eventId: id) },
                                        onChordSplit: { id, t in model.splitEvent(item.id, eventId: id, at: t) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let id = editor.selected.first, editor.selected.count == 1, let n = editor.notes.first(where: { $0.id == id }) {
                    NoteInspector(note: n, grid: item.timing?.grid)
                        .frame(width: 180)
                }
            }
            Divider()
            footer
        }
        .onAppear(perform: load)
        .onChange(of: editor.version) { _, _ in syncMidi(); refreshChords() }
        .onChange(of: model.dataVersion) { _, _ in refreshChords() }
        .onChange(of: audioMute) { _, _ in applyMix() }
        .onChange(of: audioSolo) { _, _ in applyMix() }
        .onChange(of: midiMute) { _, _ in applyMix() }
        .onChange(of: midiSolo) { _, _ in applyMix() }
        .onChange(of: loopOn) { _, _ in applyLoop() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in togglePlay() }
        .alert("改选分轨？", isPresented: Binding(get: { confirmSwitch != nil }, set: { if !$0 { confirmSwitch = nil } })) {
            Button("改选并重新转录", role: .destructive) { if let s = confirmSwitch { AudioEngine.shared.pause(); model.transcribe(item.id, stem: s) } }
            Button("取消", role: .cancel) {}
        } message: { Text("会放弃当前 MIDI 草稿，用另一条分轨重新转录。") }
    }

    private var toolbar: some View {
        @Bindable var editor = editor
        return HStack(spacing: 10) {
            Button { togglePlay() } label: { Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill") }
                .buttonStyle(SecondaryButtonStyle(compact: true)).help("播放 / 暂停（空格）")
            Text(formatTime(us: transport.positionUs)).font(.mono13).frame(width: 84, alignment: .leading)
            Toggle("循环", isOn: $loopOn).toggleStyle(.checkbox).help("在时间标尺上拖动设置循环范围")
            Divider().frame(height: 18)
            mixButtons("音频", mute: $audioMute, solo: $audioSolo)
            mixButtons("MIDI", mute: $midiMute, solo: $midiSolo)
            Divider().frame(height: 18)
            Picker("吸附", selection: $editor.snapDivision) {
                Text("关").tag(0); Text("1/4").tag(1); Text("1/8").tag(2); Text("1/16").tag(4); Text("1/32").tag(8)
            }.frame(width: 120)
            InstrumentPicker()
            Spacer()
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!editor.canUndo).help("撤销 ⌘Z")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!editor.canRedo).help("重做 ⇧⌘Z")
            Button { fitToken += 1 } label: { Image(systemName: "arrow.left.and.right.square") }.help("缩放到全片段")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func mixButtons(_ title: String, mute: Binding<Bool>, solo: Binding<Bool>) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.caption12)
            Toggle("M", isOn: mute).toggleStyle(.button).controlSize(.small).help("\(title) 静音")
            Toggle("S", isOn: solo).toggleStyle(.button).controlSize(.small).help("\(title) 独奏")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(editor.notes.count) 个音符 · 拖空白框选 · 双击空白新增 · Delete 删除 · ↑↓ 半音（⇧ 八度）· ←→ 移动（⌥ 微调）· ⌥滚轮缩放 · 和弦条：点选音符、拖分界、右键改名/合并/拆分")
                .font(.caption12).foregroundStyle(Theme.textSecondary)
            Text("MuScriptor 不输出力度，转录音符统一为 100。").font(.caption12).foregroundStyle(Theme.textSecondary)
            Spacer()
            if let sep = item.separation, !sep.candidatesDeleted {
                Menu("改选分轨") {
                    ForEach(sep.stems.map(\.kind).filter { $0 != item.selectedStem }, id: \.self) { k in
                        Button(k.displayName) { confirmSwitch = k }
                    }
                }.frame(width: 100)
            }
            Button("完成校对") {
                flushSave()
                AudioEngine.shared.pause()
                model.confirmMidi(item.id)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!hasDraft)
            .help(item.isHarmonic ? "发布确认版 MIDI，然后分组和弦并识别级数" : "发布确认版 MIDI（此分轨不做和声分析）")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var hasDraft: Bool {
        let _ = model.dataVersion
        return model.midiRevisions(item.id).contains { $0.status == .draft }
    }

    // MARK: Audio & data

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let midi = model.workingMidi(item.id) else { return }
        editor.load(midi.notes, grid: editorGrid(midi.notes), durationUs: item.durationUs)
        editor.onChange = { notes in scheduleSave(notes) }
        let e = AudioEngine.shared
        e.pause(); e.configure(sampleRate: 44100); e.setMetronome(MetronomeConfig()); e.setLoop(nil)
        transport.sampleRate = 44100
        if let stem = item.selectedStem, let asset = item.transcriptionStem ?? item.separation?.stem(stem),
           let buf = try? AudioLoader.load(model.paths.url(relative: asset.relativePath)) {
            peaks = WaveformPeaks(buffer: buf)
            e.setTracks([AudioTrack(id: "stem", buffer: buf)])
            e.setLength(Int64(buf.frameLength))
        } else {
            e.setTracks([])
            e.setLength(Int64(Double(item.durationUs) / 1_000_000 * 44100))
        }
        syncMidi()
        applyMix()
        e.seek(0)
        fitToken += 1
        refreshChords()
    }

    /// The confirmed grid, with the bar line the user set, or the one grouping estimated.
    private func editorGrid(_ notes: [MidiNote]) -> BeatGrid? {
        guard var g = item.timing?.grid else { return nil }
        if g.barAnchorUs == nil {
            g.barAnchorUs = model.latestHarmony(item.id)?.barAnchorUs ?? ChordGrouper().estimatedBarAnchor(notes: notes, grid: g)
        }
        return g
    }

    /// Saved chords when the notes match the analysed MIDI; otherwise a live preview of the
    /// current notes so proofreading can be checked against the harmony as you go.
    private func refreshChords() {
        let hasDraft = model.midiRevisions(item.id).contains { $0.status == .draft }
        if item.isHarmonic, !hasDraft, let h = model.latestHarmony(item.id), h.midiRevision == item.confirmedMidiRevision {
            previewTask?.cancel()
            chords = h.events.map { ChordSpan(id: $0.id, startUs: $0.startUs, endUs: $0.endUs, symbol: $0.symbol ?? "?", editable: true) }
            return
        }
        guard item.selectedStem?.isHarmonic ?? false, let g = editor.grid else { chords = []; return }
        let notes = editor.notes, dur = item.durationUs, key = item.timing?.key
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let groups = await Task.detached { ChordGrouper().group(notes: notes, grid: g, durationUs: dur, key: key) }.value
            if Task.isCancelled { return }
            chords = groups.enumerated().map { i, gr in
                ChordSpan(id: "preview-\(i)", startUs: gr.startUs, endUs: gr.endUs, symbol: gr.candidates.first?.symbol ?? "?", editable: false)
            }
        }
    }

    private func renameChord(_ id: String, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        model.updateEvent(item.id, eventId: id) { ev, key in
            ev.symbol = t.isEmpty ? nil : t
            ev.manualOverride = true
            ev.namingSource = .user
            ev.degree = ev.symbol.flatMap { Degrees.label(symbol: $0, key: key) }
        }
    }

    private func syncMidi() {
        let notes = editor.notes.map {
            ScheduledNote(startFrame: Int64(Double($0.startUs) / 1_000_000 * 44100), endFrame: Int64(Double($0.endUs) / 1_000_000 * 44100),
                          pitch: UInt8(clamping: $0.pitch), velocity: UInt8(clamping: $0.velocity))
        }
        AudioEngine.shared.setMidi(notes, enabled: true)
    }

    private func applyMix() {
        AudioEngine.shared.updateTrack("stem", muted: audioMute, solo: audioSolo)
        AudioEngine.shared.setMidiMix(muted: midiMute, solo: midiSolo)
    }

    private func applyLoop() {
        if loopOn, let l = editor.loop {
            AudioEngine.shared.setLoop(Int64(Double(l.lowerBound) / 1_000_000 * 44100)..<Int64(Double(l.upperBound) / 1_000_000 * 44100))
        } else if loopOn {
            AudioEngine.shared.setLoop(0..<Int64(Double(item.durationUs) / 1_000_000 * 44100))
        } else { AudioEngine.shared.setLoop(nil) }
    }

    private func togglePlay() {
        let e = AudioEngine.shared
        if e.isPlaying { e.pause() } else { e.play() }
    }

    private func scheduleSave(_ notes: [MidiNote]) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            model.saveDraft(item.id, notes: notes)
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        model.saveDraft(item.id, notes: editor.notes)
    }
}

struct NoteInspector: View {
    var note: MidiNote
    var grid: BeatGrid?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("所选音符").font(.system(size: 13, weight: .semibold))
            row("音高", "\(Pitch.noteName(note.pitch)) (\(note.pitch))")
            row("起点", formatTime(us: note.startUs))
            row("时长", String(format: "%.3f s", note.durationUs.seconds))
            if let g = grid {
                row("拍位置", String(format: "%.2f", g.q(atUs: note.startUs)))
                row("拍长", String(format: "%.2f", Double(note.durationUs) / g.beatUs))
            }
            row("力度", note.velocitySource == .default ? "\(note.velocity)（默认）" : "\(note.velocity)")
            row("来源", note.instrument.isEmpty ? "—" : note.instrument)
            if note.edited { Text("已人工修改").font(.caption12).foregroundStyle(Theme.accent) }
            Spacer()
        }
        .padding(12)
        .background(Theme.surface)
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.caption12).foregroundStyle(Theme.textSecondary); Spacer(); Text(v).font(.mono13) }
    }
}

struct InstrumentPicker: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Picker("音色", selection: Binding(get: { model.settings.instrument }, set: { model.settings.instrument = $0; model.saveSettings() })) {
            ForEach(Instrument.allCases, id: \.self) { Text($0.display).tag($0) }
        }.frame(width: 130)
    }
}

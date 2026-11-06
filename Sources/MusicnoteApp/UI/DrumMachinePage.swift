import AppKit
import MusicnoteCore
import SwiftUI
import UniformTypeIdentifiers

/// What plays along with the pattern: nothing, or the extracted audio it came from.
enum DrumCompare: String, CaseIterable {
    case off, mix, drums, lane
    var title: String {
        switch self {
        case .off: "不对照"
        case .mix: "原曲"
        case .drums: "原曲鼓"
        case .lane: "本轨原声"
        }
    }
}

/// The parameter shown and drawn in the strip under the grid, for the selected lane.
enum StepParam: String, CaseIterable {
    case velocity, nudge, chance, repeats
    var title: String {
        switch self {
        case .velocity: "力度"
        case .nudge: "微移"
        case .chance: "概率"
        case .repeats: "连击"
        }
    }
}

/// Undo keeps the groove and how many bars were cropped off the front (so the extracted
/// audio still lines up after undoing a crop).
private struct DrumSnapshot { var groove: DrumGroove; var cropBars: Int }

/// Step sequencer for one pattern: grid, per-step parameters, lane and bar tools, playback
/// with the extracted audio for comparison, MIDI export and sending to Playground.
struct DrumMachinePage: View {
    @Environment(AppModel.self) private var model
    @ViewState var pattern: DrumPattern
    @ViewState private var selectedLane: UUID?
    @ViewState private var selectedStep: Int?
    @ViewState private var bars: ClosedRange<Int>?
    @ViewState private var undoStack: [DrumSnapshot] = []
    @ViewState private var redoStack: [DrumSnapshot] = []
    @ViewState private var transport = TransportModel()
    @ViewState private var compare: DrumCompare = .off
    @ViewState private var compareGain = 0.8
    @ViewState private var metronome = false
    @ViewState private var param: StepParam = .velocity
    @ViewState private var cellW: CGFloat = 22
    @ViewState private var playing: PlayState?
    @ViewState private var sendOpen = false

    /// What is scheduled: which bars, how many passes (chance varies per pass).
    struct PlayState: Equatable { var firstBar: Int; var bars: Int; var passes: Int }

    private var g: DrumGroove { pattern.groove }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            Divider()
            HSplitView {
                ScrollView(.vertical) {
                    DrumGrid(groove: g, selectedLane: $selectedLane, selectedStep: $selectedStep, bars: $bars,
                             param: $param, cellW: cellW, playStep: playStep,
                             begin: beginEdit, apply: apply, preview: { AudioEngine.shared.tapDrum($0.note, velocity: 110) },
                             setLane: { id, f in edit { gr in if let i = gr.lanes.firstIndex(where: { $0.id == id }) { f(&gr.lanes[i]) } } })
                        .padding(.horizontal, 20).padding(.vertical, 14)
                }
                .frame(minWidth: 480)
                DrumInspector(pattern: $pattern, selectedLane: $selectedLane, selectedStep: $selectedStep, bars: $bars,
                              begin: beginEdit, apply: apply, editPattern: editPattern)
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            }
            Divider()
            transportBar
        }
        .onChange(of: pattern) { old, p in
            model.save(p)
            if old.bpm != p.bpm || old.groove.bars != p.groove.bars || old.groove.meter != p.groove.meter { restartIfPlaying() }
            else { reschedule() }
        }
        .onChange(of: bars) { _, _ in restartIfPlaying() }
        .onChange(of: compare) { _, _ in restartIfPlaying() }
        .onChange(of: metronome) { _, _ in restartIfPlaying() }
        .onChange(of: compareGain) { _, v in AudioEngine.shared.updateTrack("compare", gain: Float(v)) }
        .onAppear {
            AudioEngine.shared.stopAll(); transport.sampleRate = 44100
            if selectedLane == nil { selectedLane = g.lanes.first { !$0.steps.isEmpty }?.id ?? g.lanes.first?.id }
        }
        .onDisappear { AudioEngine.shared.stopAll(); transport.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in togglePlay() }
        .sheet(isPresented: $sendOpen) { DrumSendSheet(pattern: pattern, bars: bars).environment(model) }
    }

    // MARK: Header and toolbar

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("节奏名", text: $pattern.title).font(.pageTitle).textFieldStyle(.plain)
            if let src = pattern.source {
                Text("提取自 \(src.songTitle) · \(src.clipTitle) · 原曲 \(String(format: "%g", src.bpm)) BPM")
                    .font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if model.item(src.analysisId) != nil {
                    Button("回到片段") { model.route = .analysis(src.analysisId) }.buttonStyle(.borderless).font(.caption12)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("BPM")
                TextField("", value: $pattern.bpm, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 56).textFieldStyle(.roundedBorder)
                    .onSubmit { pattern.bpm = max(30, min(300, pattern.bpm)) }
                if let src = pattern.source, abs(src.bpm - pattern.bpm) >= 0.01 {
                    Button("原速") { pattern.bpm = src.bpm }.buttonStyle(.borderless).font(.caption12)
                        .help("回到原曲速度 \(String(format: "%g", src.bpm))，原声对照才对得上")
                }
            }
            HStack(spacing: 2) {
                Stepper("\(g.meter.numerator)", value: Binding(get: { g.meter.numerator }, set: { n in edit { DrumOps.setMeter(&$0, Meter(n, $0.meter.denominator)) } }), in: 1...15)
                    .fixedSize()
                Text("/")
                Picker("", selection: Binding(get: { g.meter.denominator }, set: { d in edit { DrumOps.setMeter(&$0, Meter($0.meter.numerator, d)) } })) {
                    ForEach([2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 52)
            }
            Picker("格子", selection: Binding(get: { g.stepsPerBeat }, set: { r in edit { DrumOps.setResolution(&$0, r) } })) {
                ForEach(DrumGroove.resolutions, id: \.steps) { Text($0.name).tag($0.steps) }
            }
            .frame(width: 150)
            Stepper("\(g.bars) 小节", value: Binding(get: { g.bars }, set: { n in edit { DrumOps.setBars(&$0, n) } }), in: 1...64).fixedSize()
            HStack(spacing: 4) {
                Text("摇摆")
                Slider(value: Binding(get: { g.swing }, set: { pattern.groove.swing = $0.rounded() }), in: 50...75) { began in if began { beginEdit() } }
                    .frame(width: 90).disabled(g.stepsPerBeat % 2 == 1)
                Text("\(Int(g.swing))%").font(.mono13).frame(width: 34, alignment: .leading)
            }
            .help(g.stepsPerBeat % 2 == 1 ? "三连音格子不用摇摆" : "每两步里第二步的位置：50% 平直，66% 接近三连音")
            HStack(spacing: 4) {
                Text("原律动")
                Slider(value: $pattern.groove.feel, in: 0...1) { began in if began { beginEdit() } }.frame(width: 80)
                Text("\(Int((g.feel * 100).rounded()))%").font(.mono13).frame(width: 38, alignment: .leading)
            }
            .help("每一步微移的保留程度：0% 完全对齐格子，100% 按提取到的（或你调的）微移演奏")
            Spacer()
            Slider(value: $cellW, in: 12...40).frame(width: 80).help("缩放")
        }
        .controlSize(.small)
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button { togglePlay() } label: { Label(transport.isPlaying ? "停止" : "播放", systemImage: transport.isPlaying ? "stop.fill" : "play.fill") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            Text(bars.map { $0.count == 1 ? "循环第 \($0.lowerBound + 1) 小节" : "循环第 \($0.lowerBound + 1)–\($0.upperBound + 1) 小节" } ?? "循环全部")
                .font(.caption12).foregroundStyle(Theme.textSecondary)
            if bars != nil { Button("全部") { bars = nil }.buttonStyle(.borderless).font(.caption12) }
            Toggle("节拍器", isOn: $metronome).toggleStyle(.checkbox)
            Divider().frame(height: 16)
            Picker("对照", selection: $compare) {
                ForEach(DrumCompare.allCases, id: \.self) { c in Text(c.title).tag(c) }
            }
            .frame(width: 150)
            .disabled(!compareAvailable)
            .help(compareHelp)
            if compare != .off { Slider(value: $compareGain, in: 0...1).frame(width: 70).help("原声音量") }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undoStack.isEmpty)
                .keyboardShortcut("z", modifiers: .command).help("撤销 ⌘Z")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift]).help("重做 ⇧⌘Z")
            Button("导出 MIDI…") { exportMidi() }.buttonStyle(SecondaryButtonStyle(compact: true))
            Button("送入 Playground…") { sendOpen = true }.buttonStyle(PrimaryButtonStyle())
        }
        .buttonStyle(.borderless)
        .padding(.leading, 20).padding(.trailing, 76).padding(.vertical, 10) // clear of the floating 灵感 button
    }

    private var compareAvailable: Bool { pattern.source != nil && model.drumSourceAudio(pattern, "drums") != nil }

    private var compareHelp: String {
        guard let src = pattern.source else { return "手动新建的节奏没有原声" }
        if abs(src.bpm - pattern.bpm) >= 0.01 { return "改了速度，原声对不上了；点「原速」回到 \(String(format: "%g", src.bpm)) BPM" }
        if let m = src.meter, m != g.meter { return "改了拍号，原声对不上了" }
        if model.drumSourceAudio(pattern, "drums") == nil { return "原声文件不在了（片段被删除？）" }
        return "和提取时的原声一起播放，听哪里没对上"
    }

    // MARK: Editing

    private func snapshot() -> DrumSnapshot { DrumSnapshot(groove: pattern.groove, cropBars: pattern.source?.cropBars ?? 0) }

    private func restore(_ s: DrumSnapshot) {
        pattern.groove = s.groove
        pattern.source?.cropBars = s.cropBars
    }

    /// Records the state before a change (once per gesture).
    private func beginEdit() {
        undoStack.append(snapshot())
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// A change inside a gesture that already called `beginEdit`.
    private func apply(_ f: (inout DrumGroove) -> Void) { f(&pattern.groove) }

    private func edit(_ f: (inout DrumGroove) -> Void) { beginEdit(); apply(f) }

    private func editPattern(_ f: (inout DrumPattern) -> Void) { beginEdit(); f(&pattern) }

    private func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot()); restore(s)
    }

    private func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot()); restore(s)
    }

    // MARK: Playback

    private var playRange: ClosedRange<Int> {
        guard let b = bars, b.upperBound < g.bars else { return 0...(g.bars - 1) }
        return b
    }

    private func playGroove(_ r: ClosedRange<Int>) -> DrumGroove {
        var pg = g
        DrumOps.crop(&pg, bars: r.lowerBound..<(r.upperBound + 1))
        return pg
    }

    private var framesPerQ: Double { 44100 * 60 / pattern.bpm }

    private func togglePlay() {
        let e = AudioEngine.shared
        if e.isPlaying { e.pause(); playing = nil; return }
        start()
    }

    private func start() {
        let e = AudioEngine.shared
        let r = playRange
        let tracks = compareTracks(r)
        // Without audio to follow, schedule ~32 bars so chance plays differently on each pass.
        let ps = PlayState(firstBar: r.lowerBound, bars: r.count, passes: tracks.isEmpty ? max(1, 32 / r.count) : 1)
        e.configure(sampleRate: 44100)
        e.setTracks(tracks)
        var m = MetronomeConfig()
        m.enabled = metronome; m.bpm = pattern.bpm; m.barAnchorFrame = 0; m.beatsPerBar = g.meter.quarterBeatsPerBar
        e.setMetronome(m)
        e.setMidiMix(muted: false, solo: false)
        playing = ps
        schedule(ps, cut: true)
        e.play(from: 0)
    }

    private func schedule(_ ps: PlayState, cut: Bool) {
        let e = AudioEngine.shared
        let pg = playGroove(ps.firstBar...(ps.firstBar + ps.bars - 1))
        let fq = framesPerQ
        let notes = DrumOps.hits(pg, passes: ps.passes).map { h in
            let f = Int64(max(0, h.q) * fq)
            return ScheduledNote(startFrame: f, endFrame: f + Int64(0.25 * 44100), pitch: UInt8(clamping: h.note), velocity: UInt8(clamping: h.velocity), drum: true)
        }
        let len = Int64(pg.lengthQ * Double(ps.passes) * fq)
        e.setMidi(notes, enabled: true, cut: cut)
        e.setLength(len)
        e.setLoop(0..<len)
    }

    /// Edits while playing are heard on the next pass without restarting.
    private func reschedule() {
        guard let ps = playing, AudioEngine.shared.isPlaying else { return }
        schedule(ps, cut: false)
    }

    private func restartIfPlaying() {
        guard AudioEngine.shared.isPlaying else { return }
        AudioEngine.shared.pause()
        start()
    }

    private func compareTracks(_ r: ClosedRange<Int>) -> [AudioTrack] {
        let name: String
        switch compare {
        case .off: return []
        case .mix: name = "mix"
        case .drums: name = "drums"
        case .lane:
            guard let piece = g.lanes.first(where: { $0.id == selectedLane })?.piece else { return [] }
            name = piece.rawValue
        }
        guard let url = model.drumSourceAudio(pattern, name) else { return [] }
        let barFrames = g.meter.quarterBeatsPerBar * framesPerQ
        let first = Int64((Double(r.lowerBound + (pattern.source?.cropBars ?? 0)) * barFrames).rounded())
        guard let buf = try? AudioLoader.load(url, startFrame: first, frames: Int64((Double(r.count) * barFrames).rounded())) else { return [] }
        let t = AudioTrack(id: "compare", buffer: buf)
        t.gain = Float(compareGain)
        return [t]
    }

    private var playStep: Int? {
        guard transport.isPlaying, let ps = playing else { return nil }
        let q = Double(transport.positionFrame) / framesPerQ
        let span = ps.bars * g.stepsPerBar
        guard span > 0 else { return nil }
        return ps.firstBar * g.stepsPerBar + Int(floor(q * Double(g.stepsPerBeat))) % span
    }

    private func exportMidi() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = pattern.title + ".mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var p = pattern
        if let r = bars { p.groove = playGroove(r) }
        try? DrumOps.exportMidi(p).write(to: url)
    }
}

// MARK: - Grid

/// Lane headers, bar ruler, step grid and the parameter strip, sharing one horizontal scroll.
/// Click toggles a step, drag paints along the lane, ⌥-drag on a step sets its velocity.
struct DrumGrid: View {
    var groove: DrumGroove
    @Binding var selectedLane: UUID?
    @Binding var selectedStep: Int?
    @Binding var bars: ClosedRange<Int>?
    @Binding var param: StepParam
    var cellW: CGFloat
    var playStep: Int?
    var begin: () -> Void
    var apply: ((inout DrumGroove) -> Void) -> Void
    var preview: (DrumLane) -> Void
    var setLane: (UUID, (inout DrumLane) -> Void) -> Void

    @ViewState private var drag: Drag?

    enum Drag {
        case paint(lane: UUID, on: Bool, visited: Set<Int>)
        case velocity(lane: UUID, index: Int, start: Int)
        case strip
    }

    private let rowH: CGFloat = 30, rulerH: CGFloat = 22, stripH: CGFloat = 76, headerW: CGFloat = 176

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("点格子加减，拖动连画；⌥ 拖动改力度").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    .frame(height: rulerH, alignment: .center)
                ForEach(groove.lanes) { laneHeader($0).frame(height: rowH) }
                Picker("", selection: $param) { ForEach(StepParam.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).padding(.top, 10).padding(.trailing, 8)
                Text(stripHint).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).padding(.top, 4).padding(.trailing, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: headerW)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ruler.frame(width: width, height: rulerH)
                    grid.frame(width: width, height: rowH * CGFloat(groove.lanes.count))
                    strip.frame(width: width, height: stripH).padding(.top, 10)
                }
            }
        }
    }

    private var width: CGFloat { CGFloat(groove.totalSteps) * cellW + 1 }
    private var selectedLaneValue: DrumLane? { groove.lanes.first { $0.id == selectedLane } }

    private var stripHint: String {
        guard let l = selectedLaneValue else { return "先选一条轨道" }
        switch param {
        case .velocity: return "\(l.name)：上下拖动改力度"
        case .nudge: return "\(l.name)：中线以上推后，以下提前（最多半格）"
        case .chance: return "\(l.name)：每次循环按这个概率出现"
        case .repeats: return "\(l.name)：一格里连击 1–4 下"
        }
    }

    private func laneHeader(_ lane: DrumLane) -> some View {
        let selected = lane.id == selectedLane
        return HStack(spacing: 4) {
            Button { selectedLane = lane.id; preview(lane) } label: {
                Text(lane.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("\(GMDrum.name(lane.note))（GM \(lane.note)）" + (lane.piece.map { " · 来自\($0.displayName)" } ?? ""))
            toggle("M", on: lane.muted, tint: Theme.warning) { setLane(lane.id) { $0.muted.toggle() } }.help("静音")
            toggle("S", on: lane.solo, tint: Theme.accent) { setLane(lane.id) { $0.solo.toggle() } }.help("独奏")
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selectionFill : .clear))
        .padding(.trailing, 8)
        .contentShape(Rectangle())
    }

    private func toggle(_ t: String, on: Bool, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 16)
                .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? tint : Theme.chipFill.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }

    // Ruler: bar numbers; click selects a bar, ⇧-click extends the selection (bar tools and loop).
    private var ruler: some View {
        Canvas { ctx, size in
            let barW = CGFloat(groove.stepsPerBar) * cellW
            if let b = bars {
                ctx.fill(Path(CGRect(x: CGFloat(b.lowerBound) * barW, y: 0, width: CGFloat(b.count) * barW, height: size.height)), with: .color(Theme.selectionFill))
            }
            for bar in 0..<groove.bars {
                let x = CGFloat(bar) * barW
                ctx.fill(Path(CGRect(x: x, y: 4, width: 1, height: size.height - 4)), with: .color(Theme.controlBorder))
                ctx.draw(Text("\(bar + 1)").font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textSecondary), at: CGPoint(x: x + 9, y: size.height / 2), anchor: .center)
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { v in
            let bar = max(0, min(groove.bars - 1, Int(v.location.x / (CGFloat(groove.stepsPerBar) * cellW))))
            if NSEvent.modifierFlags.contains(.shift), let b = bars { bars = min(b.lowerBound, bar)...max(b.upperBound, bar) }
            else { bars = bars == bar...bar ? nil : bar...bar }
        })
    }

    private var grid: some View {
        Canvas { ctx, size in
            let spb = groove.stepsPerBeat, spBar = groove.stepsPerBar
            if let b = bars {
                ctx.fill(Path(CGRect(x: CGFloat(b.lowerBound * spBar) * cellW, y: 0, width: CGFloat(b.count * spBar) * cellW, height: size.height)), with: .color(Theme.selectionFill.opacity(0.6)))
            }
            if let p = playStep {
                ctx.fill(Path(CGRect(x: CGFloat(p) * cellW, y: 0, width: cellW, height: size.height)), with: .color(Theme.accent.opacity(0.16)))
            }
            for (r, lane) in groove.lanes.enumerated() {
                let y = CGFloat(r) * rowH
                let byIndex = Dictionary(uniqueKeysWithValues: lane.steps.map { ($0.index, $0) })
                let dim = lane.muted || (groove.lanes.contains { $0.solo } && !lane.solo)
                for i in 0..<groove.totalSteps {
                    let rect = CGRect(x: CGFloat(i) * cellW + 1.5, y: y + 4, width: cellW - 3, height: rowH - 8)
                    let path = Path(roundedRect: rect, cornerRadius: 3)
                    guard let s = byIndex[i] else {
                        let onBeat = (i % spb) == 0
                        ctx.fill(path, with: .color(Theme.chipFill.opacity((i / spb) % 2 == 0 ? (onBeat ? 0.9 : 0.6) : (onBeat ? 0.55 : 0.32))))
                        continue
                    }
                    let a = (0.3 + 0.7 * Double(s.velocity) / 127) * (dim ? 0.35 : 1) * (s.chance < 100 ? 0.65 : 1)
                    ctx.fill(path, with: .color(Theme.accent.opacity(a)))
                    if s.chance < 100 { ctx.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
                    if s.repeats > 1 {
                        for k in 0..<s.repeats {
                            let x = rect.minX + rect.width * (CGFloat(k) + 0.5) / CGFloat(s.repeats)
                            ctx.fill(Path(CGRect(x: x - 0.75, y: rect.maxY - 6, width: 1.5, height: 4)), with: .color(Theme.onAccent))
                        }
                    }
                    if abs(s.nudge) >= 0.08 {
                        let x = rect.midX + CGFloat(s.nudge) * (cellW - 3)
                        ctx.fill(Path(CGRect(x: x - 0.75, y: rect.minY + 2, width: 1.5, height: 6)), with: .color(Theme.onAccent.opacity(0.9)))
                    }
                    if lane.id == selectedLane, i == selectedStep {
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(Theme.textPrimary), lineWidth: 1.5)
                    }
                }
            }
            for i in stride(from: 0, through: groove.totalSteps, by: spBar) {
                ctx.fill(Path(CGRect(x: CGFloat(i) * cellW - 0.5, y: 0, width: 1.5, height: size.height)), with: .color(Theme.controlBorder))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(gridDrag).onEnded { _ in drag = nil })
    }

    private func cell(_ p: CGPoint) -> (row: Int, index: Int)? {
        let r = Int(p.y / rowH), i = Int(p.x / cellW)
        guard r >= 0, r < groove.lanes.count, i >= 0, i < groove.totalSteps else { return nil }
        return (r, i)
    }

    private func gridDrag(_ v: DragGesture.Value) {
        switch drag {
        case nil:
            guard let (r, i) = cell(v.startLocation) else { return }
            let lane = groove.lanes[r]
            selectedLane = lane.id
            if NSEvent.modifierFlags.contains(.option), let s = lane.step(at: i) {
                begin()
                selectedStep = i
                drag = .velocity(lane: lane.id, index: i, start: s.velocity)
            } else {
                let on = lane.step(at: i) == nil
                begin()
                apply { on ? DrumOps.setStep(&$0, lane: lane.id, DrumStep(index: i)) : DrumOps.removeStep(&$0, lane: lane.id, index: i) }
                if on { selectedStep = i; preview(lane) } else if selectedStep == i { selectedStep = nil }
                drag = .paint(lane: lane.id, on: on, visited: [i])
            }
        case .paint(let laneId, let on, var visited):
            guard let r = groove.lanes.firstIndex(where: { $0.id == laneId }) else { return }
            let i = Int(v.location.x / cellW)
            guard i >= 0, i < groove.totalSteps, !visited.contains(i) else { return }
            visited.insert(i)
            let has = groove.lanes[r].step(at: i) != nil
            if on && !has { apply { DrumOps.setStep(&$0, lane: laneId, DrumStep(index: i)) } }
            if !on && has { apply { DrumOps.removeStep(&$0, lane: laneId, index: i) } }
            drag = .paint(lane: laneId, on: on, visited: visited)
        case .velocity(let laneId, let i, let start):
            let vel = max(1, min(127, start + Int((v.startLocation.y - v.location.y) / 1.5)))
            apply { gr in
                guard let li = gr.lanes.firstIndex(where: { $0.id == laneId }), var s = gr.lanes[li].step(at: i) else { return }
                s.velocity = vel; DrumOps.setStep(&gr, lane: laneId, s)
            }
        case .strip: break
        }
    }

    // Parameter strip for the selected lane.
    private var strip: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Theme.chipFill.opacity(0.35)))
            if param == .nudge { ctx.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 0.5)), with: .color(Theme.controlBorder)) }
            for i in stride(from: 0, through: groove.totalSteps, by: groove.stepsPerBar) {
                ctx.fill(Path(CGRect(x: CGFloat(i) * cellW - 0.5, y: 0, width: 1, height: size.height)), with: .color(Theme.controlBorder.opacity(0.6)))
            }
            guard let lane = selectedLaneValue else { return }
            let h = size.height - 6
            for s in lane.steps where s.index < groove.totalSteps {
                let x = CGFloat(s.index) * cellW + 3, w = cellW - 6
                let rect: CGRect
                switch param {
                case .velocity: let bh = h * CGFloat(s.velocity) / 127; rect = CGRect(x: x, y: size.height - 3 - bh, width: w, height: bh)
                case .chance: let bh = h * CGFloat(s.chance) / 100; rect = CGRect(x: x, y: size.height - 3 - bh, width: w, height: bh)
                case .repeats: let bh = h * CGFloat(s.repeats) / 4; rect = CGRect(x: x, y: size.height - 3 - bh, width: w, height: bh)
                case .nudge:
                    let mid = size.height / 2, d = (h / 2) * CGFloat(s.nudge / 0.5)
                    rect = CGRect(x: x, y: d >= 0 ? mid - d : mid, width: w, height: max(1.5, abs(d)))
                }
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(s.index == selectedStep ? Theme.accentPressed : Theme.accent.opacity(0.75)))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            guard let lane = selectedLaneValue else { return }
            if drag == nil { begin(); drag = .strip }
            let i = Int(v.location.x / cellW)
            guard var s = lane.step(at: i) else { return }
            let frac = Double(max(0, min(1, 1 - (v.location.y - 3) / (stripH - 6))))
            switch param {
            case .velocity: s.velocity = max(1, Int((frac * 127).rounded()))
            case .chance: s.chance = Int((frac * 20).rounded()) * 5
            case .repeats: s.repeats = max(1, min(4, Int((frac * 4).rounded())))
            case .nudge: s.nudge = ((frac - 0.5) * 100).rounded() / 100
            }
            selectedStep = i
            apply { DrumOps.setStep(&$0, lane: lane.id, s) }
        }.onEnded { _ in drag = nil })
    }
}

// MARK: - Send to Playground

/// Puts the pattern (or the selected bars) under a Playground section's chords, as a snapshot
/// that loops for the section's length.
struct DrumSendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var pattern: DrumPattern
    var bars: ClosedRange<Int>?
    @ViewState private var projectId: UUID?
    @ViewState private var sectionIndex = 0
    @ViewState private var useSelection = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("送入 Playground").font(.sectionTitle)
            Text("放在乐段的和弦下面，按乐段长度循环。送入的是快照，之后在这里改不影响作品（作品里会提示可以更新）。")
                .font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Picker("作品", selection: $projectId) {
                Text("新建作品").tag(UUID?.none)
                ForEach(model.playgrounds) { Text($0.title).tag(Optional($0.id)) }
            }
            if let p = project {
                Picker("乐段", selection: $sectionIndex) {
                    ForEach(Array(p.sections.enumerated()), id: \.offset) { i, s in
                        Text("\(s.name)（\(s.barCount) 小节）" + (s.drums != nil ? " · 已有鼓，会替换" : "")).tag(i)
                    }
                }
                if p.meter != pattern.groove.meter {
                    Text("作品是 \(p.meter.display)，这个节奏是 \(pattern.groove.meter.display)：鼓会按自己的长度循环，和小节线错开。")
                        .font(.caption12).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                if abs(p.bpm - pattern.bpm) >= 0.5 {
                    Text("会按作品的 \(String(format: "%g", p.bpm)) BPM 演奏（节奏这里是 \(String(format: "%g", pattern.bpm))）。")
                        .font(.caption12).foregroundStyle(Theme.textSecondary)
                }
            }
            if let b = bars {
                Toggle(b.count == 1 ? "只送第 \(b.lowerBound + 1) 小节" : "只送第 \(b.lowerBound + 1)–\(b.upperBound + 1) 小节", isOn: $useSelection)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("送入") { send() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20).frame(width: 440)
        .onAppear { projectId = model.playgrounds.first?.id }
    }

    private var project: PlaygroundProject? { projectId.flatMap { id in model.playgrounds.first { $0.id == id } } }

    private func send() {
        let drums = SectionDrums.from(pattern, bars: useSelection ? bars.map { $0.lowerBound..<($0.upperBound + 1) } : nil)
        var p = project ?? {
            var np = PlaygroundProject(title: "\(pattern.title) 练习", key: KeySignature(tonic: 0, tonicName: "C", mode: .major),
                                       bpm: pattern.bpm, meter: pattern.groove.meter)
            np.sections[0].barCount = max(4, drums.groove.bars)
            return np
        }()
        let si = min(sectionIndex, p.sections.count - 1)
        var d = drums
        d.volume = p.sections[si].drums?.volume ?? 1
        p.sections[si].drums = d
        model.save(p)
        model.reload()
        dismiss()
        model.route = .playground(p.id)
    }
}

import AppKit
import MusicnoteCore
import MusicnotePractice
import SwiftUI

/// 练琴: the whole window is the stage. One row of controls on top, the song's timeline with
/// the A–B loop under it, falling notes below, the keyboard along the bottom edge.
struct PracticePage: View {
    @Environment(AppModel.self) private var model
    let itemId: UUID

    @ViewState private var session: PracticeSessionModel?
    @ViewState private var transport = TransportModel()
    @AppStorage("practicePalette") private var paletteName = "amber"
    @AppStorage("practiceLookahead") private var lookahead = 3.5
    @AppStorage("practiceVisualOffsetMs") private var visualOffsetMs = 0.0

    var body: some View {
        let palette = PracticePalette.named(paletteName)
        Group {
            if let session {
                VStack(spacing: 0) {
                    PracticeTopBar(session: session, palette: palette, transport: transport, paletteName: $paletteName,
                                   lookahead: $lookahead, visualOffsetMs: $visualOffsetMs, onClose: close)
                    PracticeTimelineRow(session: session, palette: palette, positionUs: positionUs,
                                        playing: transport.isPlaying, visualOffset: visualOffsetMs / 1000)
                    PracticeStageView(session: session, palette: palette, lookahead: lookahead, pressed: session.judge.held,
                                      visualOffset: visualOffsetMs / 1000, playing: transport.isPlaying)
                }
                .background(shortcuts(session))
            } else {
                VStack(spacing: 12) {
                    Text("这个片段还不能练").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.text)
                    Text("需要先确认速度并转出 MIDI。").font(.system(size: 14)).foregroundStyle(palette.secondary)
                    Button("返回") { close() }.buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.ground)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .background(PracticeWindowChrome())
        .onAppear {
            transport.sampleRate = PracticeSessionModel.sampleRate
            if session == nil { session = PracticeSessionModel(model: model, itemId: itemId); session?.start() }
            session?.offsetSeconds = visualOffsetMs / 1000
        }
        .onChange(of: visualOffsetMs) { _, ms in session?.offsetSeconds = ms / 1000 }
        .onDisappear { session?.stop(); transport.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in session?.togglePlay() }
    }

    private var positionUs: Int64 { Int64(Double(transport.positionFrame) / PracticeSessionModel.sampleRate * 1_000_000) }

    private func close() {
        session?.stop()
        model.practicing = nil
    }

    /// Keys without modifiers: [ and ] set A and B, − and + change the speed, L turns the loop
    /// on and off, W waiting, ← and → move by a bar. Space is the app's play/pause.
    private func shortcuts(_ s: PracticeSessionModel) -> some View {
        Group {
            Button("设 A 点") { s.setLoopStart() }.keyboardShortcut("[", modifiers: [])
            Button("设 B 点") { s.setLoopEnd() }.keyboardShortcut("]", modifiers: [])
            Button("减速") { s.stepRate(-1) }.keyboardShortcut("-", modifiers: [])
            Button("加速") { s.stepRate(1) }.keyboardShortcut("=", modifiers: [])
            Button("加速") { s.stepRate(1) }.keyboardShortcut("+", modifiers: [.shift])
            Button("循环开关") { s.toggleLoop() }.keyboardShortcut("l", modifiers: [])
            Button("等待开关") { s.toggleWait() }.keyboardShortcut("w", modifiers: [])
            Button("后退一小节") { s.seek(bars: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("前进一小节") { s.seek(bars: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

// MARK: - Top bar

struct PracticeTopBar: View {
    var session: PracticeSessionModel
    var palette: PracticePalette
    var transport: TransportModel
    @Binding var paletteName: String
    @Binding var lookahead: Double
    @Binding var visualOffsetMs: Double
    var onClose: () -> Void
    @ViewState private var showSettings = false
    /// Where the speed slider is in the window (top-left origin), for the debug driver to drag it.
    nonisolated(unsafe) static var debugSpeedFrame = CGRect.zero

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // One row when the window is wide enough (a long title is cut short for it), else two.
            HStack(spacing: 24) { titleGroup.frame(maxWidth: 260, alignment: .leading); Spacer(minLength: 0); transportGroup; Spacer(minLength: 0); backingGroup }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 20) { titleGroup; Spacer(minLength: 0); backingGroup }
                transportGroup
            }
        }
        // The strip under the title bar stays empty: it holds the window's own three buttons
        // and is where the window is dragged from.
        .padding(.leading, 12).padding(.trailing, 20).padding(.top, 34).padding(.bottom, 8)
    }

    private var titleGroup: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(palette.secondary).help("返回片段页").accessibilityLabel("返回")
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(palette.text).lineLimit(1)
                Text(session.subtitle + (session.calibrated ? "" : " · 未校准的转录"))
                    .font(.system(size: 13)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)
        }
    }

    private var transportGroup: some View {
        let us = Int64(Double(transport.positionFrame) / PracticeSessionModel.sampleRate * 1_000_000)
        let rate = session.settings.rate
        return HStack(spacing: 18) {
            Button { session.togglePlay() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.ground).frame(width: 44, height: 44)
                    .background(Circle().fill(palette.text)).contentShape(Circle())
            }
            .buttonStyle(.plain).help("播放 / 暂停（空格）").accessibilityLabel(transport.isPlaying ? "暂停" : "播放")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatTime(us: us, millis: false)).font(.system(size: 24, weight: .medium).monospacedDigit()).foregroundStyle(palette.text)
                Text("/ " + formatTime(us: session.durationUs, millis: false)).font(.system(size: 14).monospacedDigit()).foregroundStyle(palette.secondary)
            }
            .fixedSize()
            Text(session.bars.barNumber(at: us) >= 1 ? "第 \(session.bars.barNumber(at: us)) 小节" : "弱起").font(.system(size: 14).monospacedDigit()).foregroundStyle(palette.secondary)
                .frame(minWidth: 72, alignment: .leading)
            HStack(spacing: 10) {
                Text("速度").font(.system(size: 14)).foregroundStyle(palette.secondary)
                Slider(value: Binding(get: { session.settings.rate }, set: { session.setRate($0, save: false) }),
                       in: PracticeSettings.rateRange) { editing in if !editing { session.persist() } }
                    .frame(width: 132).tint(palette.accent).accessibilityLabel("速度")
                    .background(GeometryReader { g in
                        Color.clear.onAppear { Self.debugSpeedFrame = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, f in Self.debugSpeedFrame = f }
                    })
                    .help("拖动改变速度，播放中立即生效（− 和 + 每次 5%）")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int((rate * 100).rounded()))%").font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(palette.text)
                        .lineLimit(1).fixedSize().frame(width: 52, alignment: .leading)
                    Text("\(String(format: "%.0f", session.bpm * rate)) BPM").font(.system(size: 13).monospacedDigit()).foregroundStyle(palette.secondary)
                }
                .fixedSize()
            }
        }
    }

    private var backingGroup: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(PracticeBacking.allCases, id: \.self) { kind in
                    let on = session.settings.backing == kind
                    let ready = session.available.contains(kind)
                    Button { session.setBacking(kind) } label: {
                        Text(label(kind)).font(.system(size: 14, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? palette.text : palette.secondary.opacity(ready ? 1 : 0.45))
                            .padding(.horizontal, 13).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? palette.selected : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!ready)
                    .help(ready ? hint(kind) : (session.loading ? "正在加载" : missing(kind)))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.surface))
            .accessibilityElement(children: .contain).accessibilityLabel("伴奏")
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 13)).foregroundStyle(palette.secondary)
                Slider(value: Binding(get: { Double(session.settings.backingGain) }, set: { session.setBackingGain(Float($0), save: false) }),
                       in: 0...1) { editing in if !editing { session.persist() } }
                    .frame(width: 92).tint(palette.accent).accessibilityLabel("伴奏音量").help("伴奏音量")
            }
            HStack(spacing: 6) {
                Button { session.setMidi(on: !session.settings.midiOn) } label: {
                    Label("示范音", systemImage: "pianokeys").font(.system(size: 14, weight: session.settings.midiOn ? .semibold : .regular))
                        .foregroundStyle(session.settings.midiOn ? palette.accent : palette.secondary)
                        .frame(height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("用自带音色把 MIDI 弹出来，可以核对校准后的音符")
                if session.settings.midiOn {
                    Slider(value: Binding(get: { Double(session.settings.midiGain) }, set: { session.setMidiGain(Float($0), save: false) }),
                           in: 0...1) { editing in if !editing { session.persist() } }
                        .frame(width: 72).tint(palette.accent).accessibilityLabel("示范音音量").help("示范音音量")
                }
            }
            Button { showSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15))
                    .foregroundStyle(session.keyboard.sources.isEmpty ? palette.secondary : palette.accent)
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("配色、画面、MIDI 键盘和延迟校准").accessibilityLabel("画面和键盘设置")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                PracticeSettingsPanel(session: session, palette: palette, paletteName: $paletteName, lookahead: $lookahead, visualOffsetMs: $visualOffsetMs)
            }
        }
    }

    private func label(_ kind: PracticeBacking) -> String {
        let stem = session.item.stemLabel.isEmpty ? "分轨" : session.item.stemLabel
        switch kind {
        case .original: return "原曲"
        case .stem: return stem
        case .backing: return "去" + stem
        case .off: return "关"
        }
    }

    private func hint(_ kind: PracticeBacking) -> String {
        switch kind {
        case .original: "配着原曲练"
        case .stem: "只听这一轨"
        case .backing: "原曲去掉这一轨，由你来弹"
        case .off: "不放伴奏"
        }
    }

    private func missing(_ kind: PracticeBacking) -> String {
        switch kind {
        case .original: "找不到原曲文件"
        case .stem: "这个片段没有保留分轨"
        case .backing: "还没有合成伴奏：回到片段页的「练琴」标签，点「重新拆轨生成伴奏」"
        case .off: ""
        }
    }
}

// MARK: - Settings panel

/// Colours, how far ahead the notes show, the connected keyboard, and the delay calibration.
private struct PracticeSettingsPanel: View {
    var session: PracticeSessionModel
    var palette: PracticePalette
    @Binding var paletteName: String
    @Binding var lookahead: Double
    @Binding var visualOffsetMs: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("配色") {
                Picker("配色", selection: $paletteName) {
                    Text("琥珀").tag("amber")
                    Text("冷白").tag("cool")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            row("提前看到") {
                Picker("提前看到", selection: $lookahead) {
                    Text("2 秒").tag(2.0)
                    Text("3.5 秒").tag(3.5)
                    Text("5 秒").tag(5.0)
                    Text("7 秒").tag(7.0)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("MIDI 键盘").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                if session.keyboard.sources.isEmpty {
                    Text("没有检测到。电钢琴连上电脑后会自动出现，声音照常从 Logic 出。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("已连接：" + session.keyboard.sources.joined(separator: "、"))
                        .font(.system(size: 12)).foregroundStyle(palette.accent).fixedSize(horizontal: false, vertical: true)
                    Text("按对的键变亮，按错的键变色。声音照常从 Logic 出。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("延迟校准").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                    Spacer()
                    Text(visualOffsetMs == 0 ? "0 毫秒" : String(format: "%+.0f 毫秒", visualOffsetMs))
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(palette.text)
                    Button("归零") { visualOffsetMs = 0 }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
                        .disabled(visualOffsetMs == 0).opacity(visualOffsetMs == 0 ? 0.4 : 1)
                }
                Slider(value: $visualOffsetMs, in: -250...250, step: 5).tint(palette.accent).accessibilityLabel("延迟校准")
                Text("音符碰到线比听到的声音早，或者明明弹在点上却总被判错，就往左调；反过来往右调。用蓝牙耳机时通常要往左调很多。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18).frame(width: 340)
        .background(palette.surface)
        .environment(\.colorScheme, .dark)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
            Spacer()
            content()
        }
    }
}

// MARK: - Timeline and loop

private struct PracticeTimelineRow: View {
    var session: PracticeSessionModel
    var palette: PracticePalette
    var positionUs: Int64
    var playing: Bool
    var visualOffset: Double

    var body: some View {
        HStack(spacing: 18) {
            Button { session.toggleLoop() } label: {
                Label(session.loop.map { "循环 \(session.bars.label($0)) 小节" } ?? "循环", systemImage: "repeat")
                    .font(.system(size: 14, weight: session.loopOn ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(session.loopOn ? palette.accent : palette.secondary)
                    .frame(minWidth: 150, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.loop == nil ? "从当前小节起循环四小节（L）。[ 和 ] 把 A、B 设在当前位置" : "循环开关（L）。拖进度条上的两端改范围，[ 和 ] 设在当前位置")
            PracticeTimeline(session: session, palette: palette, positionUs: positionUs, playing: playing, visualOffset: visualOffset).frame(height: 44)
            Button { session.togglePreroll() } label: {
                Text("预备 1 小节").font(.system(size: 13, weight: session.preroll ? .medium : .regular))
                    .foregroundStyle(session.preroll && session.loopOn ? palette.text : palette.secondary.opacity(session.preroll ? 1 : 0.55))
                    .strikethrough(!session.preroll, color: palette.secondary.opacity(0.55))
                    .frame(height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(session.preroll ? "循环时每一遍从 A 之前一小节开始。点一下关掉" : "循环时直接从 A 开始。点一下打开")
            Button { session.toggleWait() } label: {
                let noKeyboard = session.waitOn && !session.waitActive
                Label(session.waiting ? "等你弹" : noKeyboard ? "等待（没接键盘）" : "等待", systemImage: "hand.raised")
                    .font(.system(size: 13, weight: session.waitOn ? .semibold : .regular))
                    .foregroundStyle(session.waitActive ? palette.accent : palette.secondary.opacity(noKeyboard ? 0.7 : 1))
                    .frame(minWidth: 76, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.waitOn ? (session.waitActive ? "等待模式开着：到了该弹的音会停下，弹对了继续（W）。循环时每一遍都重新等" : "等待模式开着，但没有检测到 MIDI 键盘，所以不会停。接上电钢琴后自动生效")
                                 : "等待模式：到了该弹的音会停下，弹对了继续（W）。需要接上电钢琴")
        }
        .padding(.horizontal, 24).padding(.bottom, 10)
    }
}

/// The whole clip as a rail: the loop as a tinted stretch with a handle at each end, the
/// playhead, bar numbers underneath. Click or drag to move; drag a handle to resize the loop.
struct PracticeTimeline: View {
    var session: PracticeSessionModel
    var palette: PracticePalette
    /// The position as the 30 Hz transport has it, for the accessibility value only; the
    /// playhead itself is drawn every frame from the engine.
    var positionUs: Int64
    var playing: Bool
    var visualOffset: Double

    private enum Grab { case a, b, seek }
    @ViewState private var grab: Grab?
    /// Where the timeline is in the window (top-left origin), for the debug driver to drag it.
    nonisolated(unsafe) static var debugFrame = CGRect.zero

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let duration = max(1, session.durationUs)
            let x: (Int64) -> CGFloat = { CGFloat(Double($0) / Double(duration)) * w }
            ZStack(alignment: .topLeading) {
                Capsule().fill(palette.rail).frame(width: w, height: 4).offset(y: 13)
                if let loop = session.loop {
                    let tint = session.loopOn ? palette.accent : palette.secondary
                    let left = x(loop.lowerBound), right = x(loop.upperBound)
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint.opacity(session.loopOn ? 0.22 : 0.12))
                        .frame(width: max(4, right - left), height: 20).offset(x: left, y: 5)
                    Rectangle().fill(tint).frame(width: 2, height: 20).offset(x: left, y: 5)
                    Rectangle().fill(tint).frame(width: 2, height: 20).offset(x: max(left + 2, right - 2), y: 5)
                }
                // The playhead, drawn every frame from the engine's clock like the stage, so it
                // glides while playing and sits under the mouse while the timeline is dragged.
                let _ = session.redraw
                TimelineView(.animation(paused: !playing)) { timeline in
                    let frame = timeline.date
                    Canvas { ctx, size in
                        _ = frame
                        let px = min(size.width - 2, max(0, x(session.visualUs(offsetSeconds: visualOffset)) - 1))
                        ctx.fill(Path(roundedRect: CGRect(x: px, y: 3, width: 2, height: 24), cornerRadius: 1), with: .color(palette.text))
                    }
                }
                .frame(width: w, height: 30)
                .allowsHitTesting(false)
                ForEach(labels(width: w), id: \.number) { line in
                    Text("\(line.number)").font(.system(size: 11).monospacedDigit()).foregroundStyle(palette.secondary)
                        .fixedSize().offset(x: x(line.us), y: 29)
                }
            }
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .onAppear { Self.debugFrame = geo.frame(in: .global) }
            .onChange(of: geo.frame(in: .global)) { _, f in Self.debugFrame = f }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let us = Int64(Double(min(max(0, v.location.x), w)) / Double(w) * Double(duration))
                    if grab == nil {
                        if let loop = session.loop, abs(v.startLocation.x - x(loop.lowerBound)) <= 8 { grab = .a }
                        else if let loop = session.loop, abs(v.startLocation.x - x(loop.upperBound)) <= 8 { grab = .b }
                        else { grab = .seek }
                    }
                    switch grab {
                    case .a: if let loop = session.loop { session.setLoop(us..<loop.upperBound, save: false) }
                    case .b: if let loop = session.loop { session.setLoop(loop.lowerBound..<us, save: false) }
                    default: session.seek(toUs: us)
                    }
                }
                .onEnded { _ in grab = nil; session.persist() })
            .accessibilityElement()
            .accessibilityLabel("进度")
            .accessibilityValue("第 \(session.bars.barNumber(at: positionUs)) 小节")
            .accessibilityAdjustableAction { direction in session.seek(bars: direction == .increment ? 1 : -1) }
        }
    }

    /// Bar numbers far enough apart to read.
    private func labels(width: CGFloat) -> [PracticeBars.Line] {
        let perBar = CGFloat(session.bars.barUs / Double(max(1, session.durationUs))) * width
        let step = [1, 2, 4, 8, 16, 32, 64].first { CGFloat($0) * perBar >= 56 } ?? 128
        return session.bars.lines.filter { $0.number >= 1 && ($0.number - 1) % step == 0 }
    }
}

// MARK: - Window

/// While practising, the page runs up under the title bar: no toolbar, no title, only the
/// window's own three buttons. Put back as it was on leaving.
private struct PracticeWindowChrome: NSViewRepresentable {
    final class Probe: NSView {
        private weak var changed: NSWindow?
        private var saved: (transparent: Bool, title: NSWindow.TitleVisibility, fullSize: Bool, toolbar: Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restore()
            guard let w = window else { return }
            saved = (w.titlebarAppearsTransparent, w.titleVisibility, w.styleMask.contains(.fullSizeContentView), w.toolbar?.isVisible ?? false)
            changed = w
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.toolbar?.isVisible = false
        }

        func restore() {
            guard let w = changed, let s = saved else { return }
            w.titlebarAppearsTransparent = s.transparent
            w.titleVisibility = s.title
            if !s.fullSize { w.styleMask.remove(.fullSizeContentView) }
            w.toolbar?.isVisible = s.toolbar
            changed = nil; saved = nil
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.restore() }
}

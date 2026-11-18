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
                        .overlay(alignment: .topTrailing) { PracticeChordReadout(session: session, palette: palette).padding(.trailing, 40).padding(.top, 16) }
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
    /// on and off, W waiting, M the metronome, ← and → move by a bar. Space is the app's play/pause.
    private func shortcuts(_ s: PracticeSessionModel) -> some View {
        Group {
            Button("设 A 点") { s.setLoopStart() }.keyboardShortcut("[", modifiers: [])
            Button("设 B 点") { s.setLoopEnd() }.keyboardShortcut("]", modifiers: [])
            Button("减速") { s.stepRate(-1) }.keyboardShortcut("-", modifiers: [])
            Button("加速") { s.stepRate(1) }.keyboardShortcut("=", modifiers: [])
            Button("加速") { s.stepRate(1) }.keyboardShortcut("+", modifiers: [.shift])
            Button("循环开关") { s.toggleLoop() }.keyboardShortcut("l", modifiers: [])
            Button("等待开关") { s.toggleWait() }.keyboardShortcut("w", modifiers: [])
            Button("节拍器开关") { s.setMetronome(on: !s.settings.metronomeOn) }.keyboardShortcut("m", modifiers: [])
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
                        Text(label(kind)).font(.system(size: 14, weight: on ? .semibold : .regular)).lineLimit(1)
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
            HStack(spacing: 6) {
                let on = session.settings.metronomeOn
                Button { session.setMetronome(on: !on) } label: {
                    Label("节拍器", systemImage: "metronome").font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? palette.accent : palette.secondary)
                        .frame(height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("按确认过的拍子打拍，每小节第一拍音高一些，跟着速度条变快变慢（M）")
                .accessibilityAddTraits(on ? .isSelected : [])
                if on {
                    Slider(value: Binding(get: { Double(session.settings.metronomeVolume) }, set: { session.setMetronomeGain(Float($0), save: false) }),
                           in: 0...1) { editing in if !editing { session.persist() } }
                        .frame(width: 72).tint(palette.accent).accessibilityLabel("节拍器音量").help("节拍器音量")
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
        // Never squeezed: the title gives way instead.
        .fixedSize(horizontal: true, vertical: false)
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

// MARK: - Chord readout

/// The chord under the hands, in the stage's top right corner: what the keys held on the connected keyboard spell, big enough
/// to read from the bench. It keeps the last chord, dimmed, after the keys are let go.
private struct PracticeChordReadout: View {
    var session: PracticeSessionModel
    var palette: PracticePalette

    var body: some View {
        let connected = !session.keyboard.sources.isEmpty
        VStack(alignment: .trailing, spacing: 4) {
            if let chord = session.chord, connected {
                let held = session.chordHeld
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(chord.name).font(.system(size: 34, weight: .semibold)).foregroundStyle(held ? palette.text : palette.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let detail = chord.detail {
                        Text(detail).font(.system(size: 15)).foregroundStyle(palette.secondary)
                    }
                }
                if !chord.others.isEmpty {
                    Text("也可以叫 " + chord.others.joined(separator: "、")).font(.system(size: 13)).foregroundStyle(palette.secondary).lineLimit(1)
                }
                Text(chord.notes.joined(separator: "  ")).font(.system(size: 12).monospacedDigit()).foregroundStyle(palette.barLabel).lineLimit(1)
            } else {
                Text("和弦").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.secondary)
                Text(connected ? "按下的和弦会显示在这里" : "接上 MIDI 键盘后，这里显示按下的和弦")
                    .font(.system(size: 12)).foregroundStyle(palette.barLabel)
            }
        }
        .opacity(session.chord != nil && connected && !session.chordHeld ? 0.7 : 1)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minWidth: 150, alignment: .trailing)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.ground.opacity(0.85)))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine).accessibilityLabel("按下的和弦")
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
            PracticeTimeline(session: session, palette: palette, positionUs: positionUs, playing: playing, visualOffset: visualOffset).frame(height: PracticeTimeline.height)
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

/// The whole clip in two strips. The upper one is the loop's: drag across it to draw a loop,
/// drag an end to resize it (past the other end it simply turns round), drag its middle to
/// move it, click an empty place for four bars from there. The lower one is the song: click
/// or drag to move the playhead, with the bar numbers under it.
struct PracticeTimeline: View {
    var session: PracticeSessionModel
    var palette: PracticePalette
    /// The position as the 30 Hz transport has it, for the accessibility value only; the
    /// playhead itself is drawn every frame from the engine.
    var positionUs: Int64
    var playing: Bool
    var visualOffset: Double

    /// What a drag is doing: moving the playhead, an end of the loop with the other end held
    /// where it was, the whole loop by where it was taken hold of, or drawing a new loop.
    private enum Grab: Equatable { case seek, end(fixedUs: Int64), move(offsetUs: Int64, lengthUs: Int64), draw(fromUs: Int64) }
    private enum Spot { case edge, body, empty, rail }
    @ViewState private var grab: Grab?
    /// Where the timeline is in the window (top-left origin), for the debug driver to drag it.
    nonisolated(unsafe) static var debugFrame = CGRect.zero

    static let stripHeight: CGFloat = 20
    /// The waveform's height, and the distance from one of its columns to the next.
    static let waveHeight: CGFloat = 28
    static let columnPitch: CGFloat = 3
    /// The whole timeline: loop strip, waveform, bar numbers.
    static let height: CGFloat = stripHeight + waveHeight + 22
    private static let edgeReach: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let duration = max(1, session.durationUs)
            let x: (Int64) -> CGFloat = { CGFloat(Double($0) / Double(duration)) * w }
            let us: (CGFloat) -> Int64 = { Int64(Double(min(max(0, $0), w)) / Double(w) * Double(duration)) }
            let strip = Self.stripHeight
            ZStack(alignment: .topLeading) {
                // The loop strip: a faint lane, so it reads as a place to drag in.
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.surface).frame(width: w, height: strip)
                if let loop = session.loop {
                    let on = session.loopOn
                    let tint = on ? palette.accent : palette.secondary
                    let left = x(loop.lowerBound), right = max(left + 6, x(loop.upperBound))
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(on ? (grab == nil ? 0.28 : 0.4) : 0.16))
                        .frame(width: right - left, height: strip).offset(x: left)
                    ForEach([left, right - 6], id: \.self) { hx in
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint).frame(width: 6, height: strip).offset(x: hx)
                    }
                    if right - left > 52 {
                        Text(session.bars.label(loop)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(on ? palette.text : palette.secondary).lineLimit(1).fixedSize()
                            .frame(width: right - left, height: strip).offset(x: left)
                    }
                }
                // The song: its waveform cut along the beat grid (a column a beat, or a few beats or
                // part of one as the width allows), lit up to the playhead, over the bar and beat
                // lines. The playhead is drawn every frame from the engine's clock like the stage, so
                // it glides while playing and sits under the mouse while dragged. A plain rail until
                // the audio has loaded.
                let wave = Self.waveHeight
                let bars = session.bars
                let beatWidth = bars.beatUs / Double(duration) * Double(w)
                let unit = Waveform.beatsPerColumn(beatWidth: beatWidth, beatsPerBar: bars.beatsPerBar) * bars.beatUs
                let columns = Waveform.columns(session.waveform, durationUs: duration, originUs: bars.anchorUs, unitUs: unit)
                    .map { (left: x($0.startUs), right: x($0.endUs), value: CGFloat($0.value)) }
                let lines = gridLines(width: w, beatWidth: beatWidth).map { (x: x($0.us), level: $0.level) }
                if columns.isEmpty { Capsule().fill(palette.rail).frame(width: w, height: 4).offset(y: strip + 4 + wave / 2 - 2) }
                let loopSpan = session.loopOn ? session.loop.map { x($0.lowerBound)...x($0.upperBound) } : nil
                let redraw = session.redraw
                TimelineView(.animation(paused: !playing)) { timeline in
                    let frame = timeline.date
                    Canvas { ctx, size in
                        _ = frame; _ = redraw
                        let px = min(size.width - 2, max(0, x(session.visualUs(offsetSeconds: visualOffset)) - 1))
                        // Beat, bar and numbered-bar lines, each kind filled in one go.
                        var grid = [Path](repeating: Path(), count: 3)
                        for l in lines { grid[l.level].addRect(CGRect(x: min(size.width - 1, max(0, l.x - 0.5)), y: 0, width: 1, height: size.height)) }
                        for (k, o) in [0.08, 0.16, 0.3].enumerated() { ctx.fill(grid[k], with: .color(palette.line.opacity(o))) }
                        if !columns.isEmpty {
                            // Four shades: played or not, in the loop or not.
                            var paths = [Path](repeating: Path(), count: 4)
                            let mid = size.height / 2
                            for c in columns {
                                let gap: CGFloat = c.right - c.left >= 3 ? 1 : 0.6
                                let h = max(2, c.value * wave)
                                let cx = (c.left + c.right) / 2
                                let inLoop = loopSpan?.contains(cx) ?? false
                                let k = (cx < px ? 1 : 0) + (inLoop ? 2 : 0)
                                let r = CGRect(x: c.left + gap / 2, y: mid - h / 2, width: max(0.6, c.right - c.left - gap), height: h)
                                paths[k].addRoundedRect(in: r, cornerSize: CGSize(width: min(1, r.width / 2), height: 1))
                            }
                            let shades = [palette.secondary.opacity(0.28), palette.secondary.opacity(0.9), palette.accent.opacity(0.38), palette.accent]
                            for k in 0..<4 { ctx.fill(paths[k], with: .color(shades[k])) }
                        }
                        ctx.fill(Path(roundedRect: CGRect(x: px, y: 0, width: 2, height: size.height), cornerRadius: 1), with: .color(palette.text))
                    }
                }
                .frame(width: w, height: wave + 4).offset(y: strip + 2)
                .allowsHitTesting(false)
                ForEach(labels(width: w), id: \.number) { line in
                    Text("\(line.number)").font(.system(size: 11).monospacedDigit()).foregroundStyle(palette.secondary)
                        .fixedSize().offset(x: x(line.us), y: strip + wave + 7)
                }
            }
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .onAppear { Self.debugFrame = geo.frame(in: .global) }
            .onChange(of: geo.frame(in: .global)) { _, f in Self.debugFrame = f }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard grab == nil else { return }
                switch phase {
                case .active(let p):
                    switch spot(p, x: x) {
                    case .edge: NSCursor.resizeLeftRight.set()
                    case .body: NSCursor.openHand.set()
                    case .empty, .rail: NSCursor.pointingHand.set()
                    }
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let here = us(v.location.x)
                    if grab == nil {
                        let start = us(v.startLocation.x)
                        switch spot(v.startLocation, x: x) {
                        case .rail: grab = .seek
                        case .edge:
                            guard let loop = session.loop else { grab = .seek; break }
                            // Hold the end not taken hold of.
                            let nearA = abs(v.startLocation.x - x(loop.lowerBound)) <= abs(v.startLocation.x - x(loop.upperBound))
                            grab = .end(fixedUs: nearA ? loop.upperBound : loop.lowerBound)
                            NSCursor.resizeLeftRight.set()
                        case .body:
                            guard let loop = session.loop else { grab = .seek; break }
                            grab = .move(offsetUs: start - loop.lowerBound, lengthUs: loop.upperBound - loop.lowerBound)
                            NSCursor.closedHand.set()
                        case .empty: grab = .draw(fromUs: start)
                        }
                    }
                    switch grab {
                    case .end(let fixed)?: session.setLoop(ends: fixed, here, save: false)
                    case .move(let offset, let length)?:
                        let a = min(max(0, here - offset), max(0, session.durationUs - length))
                        session.moveLoop(toUs: a, save: false)
                    case .draw(let from)?:
                        // A click (no drag yet) is handled when the mouse comes up.
                        if abs(v.translation.width) >= 3 { session.setLoop(ends: from, here, save: false) }
                    default: session.seek(toUs: here)
                    }
                }
                .onEnded { v in
                    if case .draw(let from)? = grab, abs(v.translation.width) < 3 { session.setLoop(session.bars.defaultLoop(at: from), save: false) }
                    grab = nil
                    session.persist()
                    NSCursor.arrow.set()
                })
            .accessibilityElement()
            .accessibilityLabel("进度和循环")
            .accessibilityValue("第 \(session.bars.barNumber(at: positionUs)) 小节" + (session.loopOn ? "，循环 \(session.loop.map { session.bars.label($0) } ?? "") 小节" : ""))
            .accessibilityAdjustableAction { direction in session.seek(bars: direction == .increment ? 1 : -1) }
        }
    }

    /// What is under a point: the loop strip's handles, its loop, its empty lane, or the rail below.
    private func spot(_ p: CGPoint, x: (Int64) -> CGFloat) -> Spot {
        guard p.y < Self.stripHeight + 2 else { return .rail }
        guard let loop = session.loop else { return .empty }
        let left = x(loop.lowerBound), right = x(loop.upperBound)
        // A short loop keeps a middle to take hold of: its ends reach in a third of it at most.
        let reach = min(Self.edgeReach, max(4, (right - left) / 3))
        if p.x <= left + reach && p.x >= left - Self.edgeReach || p.x >= right - reach && p.x <= right + Self.edgeReach { return .edge }
        return p.x > left && p.x < right ? .body : .empty
    }

    /// The lines behind the waveform: 2 for a numbered bar, 1 for any other bar when bars are
    /// far enough apart to tell, 0 for a beat when beats are.
    private func gridLines(width: CGFloat, beatWidth: Double) -> [(us: Int64, level: Int)] {
        let bars = session.bars
        let numbered = Set(labels(width: width).map(\.us))
        let barWidth = beatWidth * bars.beatsPerBar
        var out: [(us: Int64, level: Int)] = []
        let barStarts = Set(bars.lines.map(\.us))
        if beatWidth >= Self.minLineGap {
            out += bars.ticks(every: bars.beatUs).filter { !barStarts.contains($0) && !barStarts.contains($0 - 1) && !barStarts.contains($0 + 1) }.map { ($0, 0) }
        }
        out += bars.lines.compactMap { l in numbered.contains(l.us) ? (l.us, 2) : barWidth >= Self.minLineGap ? (l.us, 1) : nil }
        return out
    }

    /// Lines closer than this read as a smear and are left out.
    private static let minLineGap = 6.0

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

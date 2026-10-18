import MusicnoteCore
import SwiftUI

/// Original-speed audio with a metronome on the same clock. BPM and offset update
/// the click schedule live without stopping or stretching the audio.
struct ConfirmStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var source: SourceSession
    var transport: TransportModel

    @ViewState private var bpmText = ""
    @ViewState private var offsetMs: Double = 0
    @ViewState private var detectedOriginUs: Int64 = 0
    @ViewState private var tonic = 0
    @ViewState private var flats = false
    @ViewState private var mode: Mode = .major
    @ViewState private var numerator = 4
    @ViewState private var denominator = 4
    @ViewState private var meterConfirmed = false
    @ViewState private var barAnchorUs: Int64?
    @ViewState private var metronomeOn = true
    @ViewState private var volume: Double = 0.6
    @ViewState private var viewRange: Range<Int64> = 0..<1
    @ViewState private var selection: Range<Int64> = 0..<1
    @ViewState private var ready = false
    @ViewState private var fromSongGrid = false
    @ViewState private var songGridUnsteady = false
    @ViewState private var startsOnBar = false

    private var rate: Double { item.source.sampleRate }
    private var trimStartFrame: Int64 { Int64((Double(item.trimStartUs) * rate / 1_000_000).rounded()) }
    private var trimEndFrame: Int64 { Int64((Double(item.trimEndUs) * rate / 1_000_000).rounded()) }
    private var bpm: Double? { Tempo.parseUserBpm(bpmText) }
    private var originUs: Int64 { detectedOriginUs + Int64(offsetMs * 1000) }
    private var grid: BeatGrid? {
        bpm.map { BeatGrid(bpm: $0, beatOriginUs: originUs, meter: Meter(numerator, denominator), barAnchorUs: barAnchorUs) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detectionSummary
                WaveformSelectionView(peaks: source.peaks, totalFrames: item.source.frames, selection: $selection,
                                      playhead: transport.positionFrame, editable: false, viewRange: $viewRange,
                                      beatFrames: beatFrames, downbeatFrames: downbeatFrames,
                                      onSeek: { AudioEngine.shared.seek($0) }, onCommit: {})
                    .frame(height: 140)
                HStack(spacing: 8) {
                    Button { togglePlay() } label: {
                        Label(transport.isPlaying ? "暂停" : "原速循环播放", systemImage: transport.isPlaying ? "pause.fill" : "play.fill")
                    }.buttonStyle(SecondaryButtonStyle())
                    Toggle("节拍器", isOn: $metronomeOn).toggleStyle(.checkbox)
                    Slider(value: $volume, in: 0...1).frame(width: 100)
                    Text("一直早一点或晚一点，调整拍点偏移；越播越偏，调整 BPM。").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
                HStack(alignment: .top, spacing: 24) {
                    tempoCard
                    keyCard
                    meterCard
                }
                HStack {
                    Button("返回修改选区") {
                        AudioEngine.shared.pause()
                        var i = item; i.state = .draft; model.save(i)
                    }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    if bpm == nil { Text("请输入有效的正数 BPM").font(.caption12).foregroundStyle(Theme.error) }
                    Button("确认并拆轨") { confirm() }.buttonStyle(PrimaryButtonStyle()).disabled(bpm == nil)
                        .help("保存 BPM、调性和节拍起点后，只对选区运行 Logic 模型拆轨")
                }
            }
            .padding(24)
        }
        .onAppear(perform: setup)
        .onChange(of: source.buffer != nil) { _, _ in setupAudio() }
        .onChange(of: bpmText) { _, _ in updateMetronome() }
        .onChange(of: offsetMs) { _, _ in updateMetronome() }
        .onChange(of: metronomeOn) { _, _ in updateMetronome() }
        .onChange(of: volume) { _, _ in updateMetronome() }
        .onChange(of: barAnchorUs) { _, _ in updateMetronome() }
        .onChange(of: numerator) { _, _ in updateMetronome() }
        .onChange(of: denominator) { _, _ in updateMetronome() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in togglePlay() }
    }

    // MARK: Sections

    private var detectionSummary: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "确认速度与调性", subtitle: "以下是对未拆轨混合音频的检测建议，需要你试听确认。")
                if let d = item.detection {
                    HStack(spacing: 16) {
                        if let raw = d.rawBpm {
                            Text("检测 BPM \(String(format: "%.2f", raw)) → 建议 \(String(format: "%.1f", d.roundedBpm ?? raw))").font(.mono13)
                        } else { Text("未能检测 BPM，请手填").foregroundStyle(Theme.warning) }
                        if let c = d.confidence { Text("置信度 \(String(format: "%.2f", c))（0–5.3）").font(.caption12).foregroundStyle(Theme.textSecondary) }
                        if let k = d.rawKey { Text("调性建议 \(k) \(d.rawScale == "minor" ? "小调" : "大调")").font(.control13) }
                        if let s = d.keyStrength { Text("强度 \(String(format: "%.2f", s))").font(.caption12).foregroundStyle(Theme.textSecondary) }
                    }
                    ForEach(d.errors, id: \.self) { Text($0).font(.caption12).foregroundStyle(Theme.warning) }
                    if startsOnBar {
                        Label("选区开头对齐在拍点上：第 1 小节第 1 拍就从选区开头算起。", systemImage: "metronome")
                            .font(.caption12).foregroundStyle(Theme.accent)
                    }
                    if songGridUnsteady {
                        Label("整曲拍点在这段不稳（多半锁到了切分节奏），第 1 小节没有沿用整曲小节线。请边听节拍器边设第 1 拍；分析和声后还会用换和弦点再核对一次。", systemImage: "exclamationmark.triangle")
                            .font(.caption12).foregroundStyle(Theme.warning)
                    }
                    if fromSongGrid && !startsOnBar {
                        Label("速度、拍号和第 1 小节的位置沿用了选区阶段的整曲小节线；如果改了 BPM 或拍点偏移，记得核对小节线。", systemImage: "metronome")
                            .font(.caption12).foregroundStyle(Theme.accent)
                    }
                    Text("检测的是大调/小调与四分音符拍点，不是完整调式、拍号或强拍检测；片段内转调或明显变速时可回去重新切分。")
                        .font(.caption12).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var tempoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("BPM（四分音符）").font(.system(size: 13, weight: .semibold))
                HStack {
                    TextField("BPM", text: $bpmText).font(.mono13).frame(width: 80).textFieldStyle(.roundedBorder)
                    Stepper("", onIncrement: { step(0.5) }, onDecrement: { step(-0.5) }).labelsHidden()
                    Button("×2") { scale(2) }.buttonStyle(SecondaryButtonStyle(compact: true))
                    Button("÷2") { scale(0.5) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
                if let b = bpm { Text("确认值：\(String(format: "%.1f", b))").font(.caption12).foregroundStyle(Theme.textSecondary) }
                Text("拍点偏移 \(Int(offsetMs)) ms").font(.system(size: 13, weight: .semibold))
                HStack {
                    Button("−10") { offsetMs -= 10 }.buttonStyle(SecondaryButtonStyle(compact: true))
                    Slider(value: $offsetMs, in: -halfBeatMs...halfBeatMs).frame(width: 140)
                    Button("+10") { offsetMs += 10 }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
        }
    }

    private var keyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("调性").font(.system(size: 13, weight: .semibold))
                Picker("主音", selection: $tonic) {
                    ForEach(0..<12, id: \.self) { pc in Text(Pitch.name(pc: pc, flats: flats)).tag(pc) }
                }.frame(width: 140)
                Toggle("降号拼写", isOn: $flats).toggleStyle(.checkbox)
                Picker("", selection: $mode) { Text("大调").tag(Mode.major); Text("小调").tag(Mode.minor) }
                    .pickerStyle(.segmented).frame(width: 140)
            }
        }
    }

    private var meterCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("拍号与小节起点").font(.system(size: 13, weight: .semibold))
                HStack {
                    Stepper("\(numerator)", value: $numerator, in: 1...15).frame(width: 70)
                    Text("/")
                    Picker("", selection: $denominator) { ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) } }.frame(width: 64)
                    Toggle("已确认", isOn: $meterConfirmed).toggleStyle(.checkbox)
                }
                Button("把当前拍设为小节起点") { setBarAnchor() }.buttonStyle(SecondaryButtonStyle(compact: true))
                if let a = barAnchorUs {
                    HStack {
                        Text("小节起点 \(formatTime(us: a))").font(.caption12)
                        Button("清除") { barAnchorUs = nil }.buttonStyle(.borderless).font(.caption12)
                    }
                } else {
                    Text("未设小节起点时节拍器不强调强拍；拍点不等于小节第一拍。").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
                if denominator == 8 {
                    Text("内部 BPM 仍按四分音符计；6/8 的附点四分拍速 = BPM ÷ 1.5。").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: Logic

    private var halfBeatMs: Double { (bpm.map { 60_000 / $0 } ?? 500) / 2 }

    private var beatFrames: [Int64] {
        guard let g = grid else { return [] }
        return g.beatTimes(durationUs: item.durationUs).map { trimStartFrame + Int64(Double($0) * rate / 1_000_000) }
    }

    private var downbeatFrames: Set<Int64> {
        guard let g = grid, barAnchorUs != nil else { return [] }
        return Set(g.beatTimes(durationUs: item.durationUs).filter { g.isDownbeat(q: g.q(atUs: $0)) }
            .map { trimStartFrame + Int64(Double($0) * rate / 1_000_000) })
    }

    private func setup() {
        selection = trimStartFrame..<trimEndFrame
        let pad = max(Int64(1), Int64(selection.count) / 20)
        viewRange = max(0, trimStartFrame - pad)..<min(item.source.frames, trimEndFrame + pad)
        if let t = item.timing, item.hasValidTiming {
            bpmText = String(format: "%.1f", t.bpm); detectedOriginUs = t.beatOriginUs; offsetMs = 0
            tonic = t.key.tonic; mode = t.key.mode; flats = t.key.tonicName.contains("♭")
            numerator = t.meter.numerator; denominator = t.meter.denominator; meterConfirmed = t.meterConfirmed; barAnchorUs = t.barAnchorUs
        } else if let d = item.detection {
            if let r = d.roundedBpm { bpmText = String(format: "%.1f", r) }
            detectedOriginUs = fitOrigin(ticks: d.ticksSec, bpm: d.roundedBpm ?? d.rawBpm ?? 120)
            if let k = d.rawKey, let pc = Pitch.parsePitchClass(k) {
                tonic = pc; mode = d.rawScale == "minor" ? .minor : .major
                flats = Pitch.prefersFlats(KeySignature(tonic: pc, tonicName: k, mode: mode))
            }
            applySongGrid(clipBpm: d.roundedBpm)
        }
        ready = true
        setupAudio()
    }

    /// The selection stage's whole-song bar lines carry over: tempo reading (half-time or not),
    /// meter, and bar 1 on the first bar line of the clip (its start when the selection snapped).
    /// The clip's own BPM wins when it agrees with the song's within 4%, since it is local.
    private func applySongGrid(clipBpm: Double?) {
        guard let g = item.songGrid else { return }
        let s = Double(item.trimStartUs) / 1e6, e = Double(item.trimEndUs) / 1e6
        if let r = clipBpm, abs(r - g.bpm) / g.bpm < 0.04 { bpmText = String(format: "%.1f", r) }
        else if let r = Tempo.roundToHalf(g.bpm) { bpmText = String(format: "%.1f", r) }
        numerator = g.beatsPerBar; denominator = 4
        // The selection start is where the user put bar 1. When it sits on a beat of the
        // whole-song grid (snapped to a bar or a beat), bar 1 beat 1 is the clip start — the
        // grid's own downbeat guess never overrides that choice.
        if g.beats(from: s - 0.06, to: s + 0.06).contains(where: { abs($0 - s) <= 0.06 }) {
            barAnchorUs = 0
            detectedOriginUs = 0
            startsOnBar = true
            return
        }
        guard g.steady(from: s, to: e) else { songGridUnsteady = true; return }
        if let a = g.barAnchor(clipStart: s, clipEnd: e) {
            barAnchorUs = Int64(a * 1e6)
            detectedOriginUs = Int64(a * 1e6)
            fromSongGrid = true
        }
    }

    /// Fits the beat phase to detected ticks: circular mean of tick positions modulo the beat.
    private func fitOrigin(ticks: [Double], bpm: Double) -> Int64 {
        guard !ticks.isEmpty, bpm > 0 else { return 0 }
        let beat = 60 / bpm
        var sx = 0.0, sy = 0.0
        for t in ticks { let a = 2 * Double.pi * (t.truncatingRemainder(dividingBy: beat)) / beat; sx += cos(a); sy += sin(a) }
        var phase = atan2(sy, sx) / (2 * .pi) * beat
        if phase < 0 { phase += beat }
        return Int64(phase * 1_000_000)
    }

    private func setupAudio() {
        guard let buf = source.buffer, ready else { return }
        let e = AudioEngine.shared
        e.pause()
        transport.sampleRate = rate
        e.configure(sampleRate: rate)
        e.setMidi([], enabled: false)
        e.setTracks([AudioTrack(id: "source", buffer: buf)])
        e.setLength(item.source.frames)
        e.setLoop(trimStartFrame..<trimEndFrame)
        e.seek(trimStartFrame)
        updateMetronome()
    }

    private func updateMetronome() {
        guard let b = bpm else { AudioEngine.shared.setMetronome(MetronomeConfig()); return }
        var m = MetronomeConfig()
        m.enabled = metronomeOn
        m.bpm = b
        m.volume = Float(volume)
        m.originFrame = trimStartFrame + Int64(Double(originUs) * rate / 1_000_000)
        m.barAnchorFrame = barAnchorUs.map { trimStartFrame + Int64(Double($0) * rate / 1_000_000) }
        m.beatsPerBar = Meter(numerator, denominator).quarterBeatsPerBar
        AudioEngine.shared.setMetronome(m)
    }

    private func togglePlay() {
        let e = AudioEngine.shared
        if e.isPlaying { e.pause() } else {
            let p = transport.positionFrame
            e.play(from: (trimStartFrame..<trimEndFrame).contains(p) ? p : trimStartFrame)
        }
    }

    private func step(_ d: Double) { if let b = bpm { bpmText = String(format: "%.1f", max(0.5, b + d)) } else { bpmText = "120.0" } }
    private func scale(_ f: Double) { if let b = bpm, let r = Tempo.roundToHalf(b * f) { bpmText = String(format: "%.1f", r) } }

    private func setBarAnchor() {
        guard let g = grid else { return }
        let local = Int64(Double(transport.positionFrame - trimStartFrame) / rate * 1_000_000)
        barAnchorUs = g.us(atQ: g.q(atUs: local).rounded())
    }

    private func confirm() {
        guard let b = bpm else { return }
        AudioEngine.shared.pause()
        let name = Pitch.name(pc: tonic, flats: flats)
        let timing = TimingConfirmation(trimRevision: item.trimRevision, bpm: b, beatOriginUs: originUs,
                                        meter: Meter(numerator, denominator), meterConfirmed: meterConfirmed,
                                        barAnchorUs: barAnchorUs, key: KeySignature(tonic: tonic, tonicName: name, mode: mode))
        model.confirmAndSeparate(item.id, timing: timing)
    }
}

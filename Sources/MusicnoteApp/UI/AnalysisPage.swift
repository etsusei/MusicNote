import AVFoundation
import MusicnoteCore
import SwiftUI

/// Loaded audio for the selection/confirmation stages.
@MainActor @Observable
final class SourceSession {
    var buffer: AVAudioPCMBuffer?
    var peaks: WaveformPeaks?
    var error: String?
    var loading = false
    var loadedFor: String?

    func load(_ source: SourceRef) {
        guard loadedFor != source.fingerprint, !loading else { return }
        guard let url = Pipeline.resolve(source) else { error = "原曲文件找不到了"; return }
        loading = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let buf = try AudioLoader.load(url)
                let peaks = WaveformPeaks(buffer: buf)
                await MainActor.run {
                    self.buffer = buf; self.peaks = peaks; self.loading = false; self.loadedFor = source.fingerprint
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.loading = false }
            }
        }
    }
}

struct AnalysisPage: View {
    @Environment(AppModel.self) private var model
    let itemId: UUID
    @ViewState private var source = SourceSession()
    @ViewState private var transport = TransportModel()

    var body: some View {
        let _ = model.dataVersion
        if let item = model.item(itemId) {
            VStack(spacing: 0) {
                AnalysisHeader(item: item)
                if item.state != .ready { Divider().opacity(0.6) }
                Group {
                    switch item.state {
                    case .draft, .detecting:
                        SelectionStage(item: item, source: source, transport: transport)
                    case .awaitingConfirmation:
                        ConfirmStage(item: item, source: source, transport: transport)
                    case .separating, .transcribing, .harmonizing:
                        ProgressStage(item: item)
                    case .awaitingStem:
                        StemStage(item: item, transport: transport)
                    case .editingMidi:
                        BarOneStage(item: item, transport: transport)
                    case .ready:
                        ReadyStage(item: item, transport: transport)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { if item.state.needsSource { source.load(item.source) } }
            .onChange(of: item.state) { _, s in if s.needsSource { source.load(item.source) } }
            .onDisappear { AudioEngine.shared.stopAll(); transport.stop() }
        }
    }
}

extension AnalysisState {
    var needsSource: Bool { self == .draft || self == .detecting || self == .awaitingConfirmation }
    var step: Int {
        switch self {
        case .draft, .detecting: 0
        case .awaitingConfirmation: 1
        case .separating, .awaitingStem: 2
        case .transcribing, .editingMidi: 3
        case .harmonizing, .ready: 4
        }
    }
}

struct AnalysisHeader: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    @ViewState private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let song = model.song(item.songId) {
                Button { model.route = .song(song.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                        Text(song.title).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("回到这首歌")
            }
            TextField("片段标题", text: $title).font(.pageTitle).textFieldStyle(.plain)
                .onSubmit { var i = item; i.title = title; model.save(i) }
                .onAppear { title = item.title }
            HStack(spacing: 10) {
                Text("\(item.source.fileName) · \(formatTime(us: item.trimStartUs))–\(formatTime(us: item.trimEndUs))（\(String(format: "%.3f", item.durationUs.seconds)) 秒）")
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
                if Pipeline.resolve(item.source) == nil {
                    Label("原曲已移动或删除", systemImage: "exclamationmark.triangle").font(.caption12).foregroundStyle(Theme.warning)
                    Button("重新选择原曲…") { model.relinkSource(item.id) }.buttonStyle(.borderless).font(.caption12)
                }
                Spacer()
                if item.state != .ready {
                    StepIndicator(step: item.state.step, harmonic: item.selectedStem.map(\.isHarmonic) ?? true)
                }
            }
            if let job = model.jobs[item.id] {
                HStack(spacing: 8) {
                    ProgressView(value: job.total.map { Double(job.completed) / Double(max(1, $0)) }).frame(width: 160)
                        .progressViewStyle(.linear)
                    Text(job.stage + (job.total.map { "（\(job.completed)/\($0)）" } ?? "")).font(.caption12)
                    Button("取消") { model.cancelJob(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            } else if let failed = model.failedJob(for: item.id) {
                HStack(spacing: 8) {
                    Image(systemName: failed.status == .interrupted ? "pause.circle" : "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    Text((failed.status == .interrupted ? "上次任务被中断：" : "任务失败：") + (failed.errorMessage ?? failed.type.rawValue))
                        .font(.caption12).foregroundStyle(Theme.warning).lineLimit(2)
                    Button("重试") { retry(failed) }.buttonStyle(SecondaryButtonStyle(compact: true))
                    Button("丢弃") { model.discardJob(failed) }.buttonStyle(.borderless).font(.caption12)
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
    }

    private func retry(_ job: Job) {
        model.discardJob(job)
        switch job.type {
        case .detect: model.analyze(item.id)
        case .separate: if let t = item.timing { model.confirmAndSeparate(item.id, timing: t) }
        case .transcribe: if !item.selectedStems.isEmpty { model.transcribe(item.id, stems: item.selectedStems) }
        case .harmony: model.runHarmony(item.id)
        case .skeleton: model.generateSkeleton(item.id)
        }
    }
}

struct StepIndicator: View {
    var step: Int
    var harmonic: Bool
    var body: some View {
        let names = ["选区", "速度调性", "拆轨选轨", "转录", harmonic ? "和声与笔记" : "笔记"]
        HStack(spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                Text(n).font(.system(size: 11, weight: i == step ? .semibold : .regular))
                    .foregroundStyle(i == step ? Theme.accent : (i < step ? Theme.textPrimary : Theme.textSecondary))
                if i < names.count - 1 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.textSecondary) }
            }
        }
    }
}

// MARK: - Selection

struct SelectionStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var source: SourceSession
    var transport: TransportModel
    @ViewState private var selection: Range<Int64> = 0..<1
    @ViewState private var viewRange: Range<Int64> = 0..<1
    @ViewState private var loopOn = false
    @ViewState private var stopAt: Int64?
    @AppStorage("selectionSnap") private var snapMode = "bar" // bar / beat / off
    @AppStorage("selectionClick") private var clickOn = false

    private var rate: Double { item.source.sampleRate }
    private var grid: SongGrid? { item.songGrid }
    private func sec(_ f: Int64) -> Double { Double(f) / rate }
    private func fr(_ t: Double) -> Int64 { Int64((t * rate).rounded()) }

    private var viewSeconds: (Double, Double) { (sec(viewRange.lowerBound), sec(viewRange.upperBound)) }
    private var beatFrames: [Int64] {
        guard let g = grid else { return [] }
        let (a, b) = viewSeconds
        return g.beats(from: a, to: b).map(fr)
    }
    private var downbeatFrames: Set<Int64> {
        guard let g = grid else { return [] }
        let (a, b) = viewSeconds
        return Set(g.downbeats(from: a, to: b).map(fr))
    }
    /// Bar numbers counted from the bar line at the selection start.
    private var barLabels: [(frame: Int64, number: Int)] {
        guard let g = grid else { return [] }
        let s = sec(selection.lowerBound), e = sec(selection.upperBound)
        return g.downbeats(from: s - 0.06, to: e - 0.06).enumerated().map { (fr($0.element), $0.offset + 1) }
    }
    private var snapper: ((Int64) -> Int64)? {
        guard let g = grid, snapMode != "off" else { return nil }
        let bars = snapMode == "bar"
        return { f in fr(g.snap(sec(f), toBars: bars)) }
    }
    /// How far an edge is from the nearest bar line, in ms.
    private func offBar(_ f: Int64) -> Int? {
        guard let g = grid else { return nil }
        return Int(((sec(f) - g.snap(sec(f), toBars: true)) * 1000).rounded())
    }
    private func frame(_ us: Int64) -> Int64 { Int64((Double(us) * rate / 1_000_000).rounded()) }
    private func us(_ f: Int64) -> Int64 { Int64((Double(f) / rate * 1_000_000).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let e = source.error {
                Card { HStack { Text(e).foregroundStyle(Theme.warning); Button("重新选择原曲…") { model.relinkSource(item.id) } } }
            }
            HStack(alignment: .bottom) {
                SectionHeader(title: "圈出想学的片段", subtitle: "拖两侧边界调整起止，拖中间整体平移；默认吸附整曲的小节线（按住 ⌥ 自由拖），第 1 小节就从选区开头算。")
                Spacer()
                if grid != nil {
                    Picker("", selection: $snapMode) { Text("吸附小节").tag("bar"); Text("吸附拍").tag("beat"); Text("不吸附").tag("off") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                        .help("拖动边界时吸附；按住 ⌥ 临时不吸附")
                }
            }
            WaveformSelectionView(peaks: source.peaks, totalFrames: item.source.frames, selection: $selection,
                                  playhead: transport.positionFrame, editable: item.state == .draft, viewRange: $viewRange,
                                  beatFrames: beatFrames, downbeatFrames: downbeatFrames, barLabels: barLabels, snap: snapper,
                                  sampleRate: rate, onSeek: { AudioEngine.shared.seek($0) }, onCommit: commit)
                .frame(height: 250)
                .overlay { if source.loading { ProgressView("正在读取整曲波形…") } }
            HStack {
                ZoomBar(viewRange: $viewRange, totalFrames: item.source.frames, fitRange: selection)
                Spacer()
                Text(formatTime(us: us(transport.positionFrame))).font(.mono13).foregroundStyle(Theme.textSecondary)
            }
            transportRow
            barGridBar
            HStack(spacing: 10) {
                if item.separation == nil {
                    Text("\(item.source.fileName) · \(formatTime(us: Int64(item.source.durationSec * 1_000_000), millis: false))")
                        .font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Button("换一个原曲文件…") { model.replaceSource(item.id) }.buttonStyle(.borderless).font(.caption12)
                        .help("比如把试听片段换成完整版；还没拆轨，换文件不会影响别的东西")
                }
                Spacer()
                if item.state == .detecting {
                    ProgressView().controlSize(.small)
                    Text("正在只分析选区的 BPM 与调性（未拆轨）").font(.caption12)
                } else {
                    Button("分析 BPM 与调性") { commit(); model.analyze(item.id) }
                        .buttonStyle(PrimaryButtonStyle()).disabled(selection.count < Int(rate * 0.5) || source.buffer == nil)
                        .help("锁定当前区间并启动 Essentia。此时不会拆轨。")
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .onAppear { setup(); model.detectSongGrid(item.id) }
        .onChange(of: source.buffer != nil) { _, _ in setup() }
        .onChange(of: clickOn) { _, _ in updateClick() }
        .onChange(of: item.songGrid) { _, _ in updateClick() }
        .onChange(of: loopOn) { _, on in AudioEngine.shared.setLoop(on ? selection : nil) }
        .onChange(of: selection) { _, s in if loopOn { AudioEngine.shared.setLoop(s) } }
        .onChange(of: transport.positionFrame) { _, p in
            if let stop = stopAt, p >= stop, !loopOn { AudioEngine.shared.pause(); stopAt = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in
            if AudioEngine.shared.isPlaying { AudioEngine.shared.pause() } else { playSelection() }
        }
    }

    private func setup() {
        selection = frame(item.trimStartUs)..<max(frame(item.trimStartUs) + 1, frame(item.trimEndUs))
        if viewRange.count <= 1 {
            // Open on the selection when there is one; the overview still shows the whole song.
            let total = max(1, item.source.frames)
            if selection.count > 1, selection.count < Int(total) * 9 / 10 {
                let pad = max(Int64(rate * 2), Int64(selection.count) / 6)
                viewRange = max(0, selection.lowerBound - pad)..<min(total, selection.upperBound + pad)
            } else { viewRange = 0..<total }
        }
        guard let buf = source.buffer else { return }
        transport.sampleRate = rate
        let e = AudioEngine.shared
        e.pause()
        e.configure(sampleRate: rate)
        e.setMidi([], enabled: false)
        e.setMetronome(MetronomeConfig())
        e.setTracks([AudioTrack(id: "source", buffer: buf)])
        e.setLength(item.source.frames)
        e.seek(selection.lowerBound)
        updateClick()
    }

    /// Play / stop, loop and click on the left; the selection's start, end and length on the right.
    private var transportRow: some View {
        HStack(spacing: 10) {
            Button { AudioEngine.shared.isPlaying ? AudioEngine.shared.pause() : playSelection() } label: {
                Label(transport.isPlaying ? "停止" : "播放选区", systemImage: transport.isPlaying ? "stop.fill" : "play.fill")
                    .frame(minWidth: 76)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button { AudioEngine.shared.play(from: transport.positionFrame) } label: { Label("从游标", systemImage: "play").fixedSize() }
                .buttonStyle(SecondaryButtonStyle()).disabled(transport.isPlaying)
            Toggle("循环", isOn: $loopOn).toggleStyle(.checkbox).fixedSize()
            if grid != nil {
                Toggle("节拍器", isOn: $clickOn).toggleStyle(.checkbox).fixedSize().help("按整曲小节线打拍，重拍有重音，用来听小节线对不对")
            }
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                TimeField(label: "起点", us: us(selection.lowerBound)) { v in setRange(frame(v), selection.upperBound) }
                TimeField(label: "终点", us: us(selection.upperBound)) { v in setRange(selection.lowerBound, frame(v)) }
                TimeField(label: "时长", us: us(Int64(selection.count))) { v in setRange(selection.lowerBound, selection.lowerBound + frame(v)) }
            }
            .disabled(item.state != .draft)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderSubtle))
    }

    /// Whole-song bar lines: snapping, half-time, meter, nudging, and whether the edges sit on bar lines.
    @ViewBuilder private var barGridBar: some View {
        if let g = grid {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("小节线").font(.system(size: 13, weight: .semibold))
                    Text(String(format: "整曲 %.1f BPM", g.bpm)).font(.mono13).foregroundStyle(Theme.textSecondary)
                    Toggle("半速", isOn: Binding(get: { g.halfTime }, set: { on in model.updateSongGrid(item.id) { $0.setHalfTime(on) } }))
                        .toggleStyle(.checkbox)
                        .help(String(format: "检测到 %.1f BPM。慢歌常被测成两倍速：勾上后按一半的速度数拍，一小节变长一倍。", g.detectedBpm))
                    Picker("", selection: Binding(get: { g.beatsPerBar }, set: { n in model.updateSongGrid(item.id) { $0.setBeatsPerBar(n) } })) {
                        Text("4/4").tag(4); Text("3/4").tag(3)
                    }.labelsHidden().frame(width: 70)
                    HStack(spacing: 2) {
                        Button { model.updateSongGrid(item.id) { $0.shift(beats: -1) } } label: { Image(systemName: "chevron.left") }
                        Text("挪一拍").font(.caption12)
                        Button { model.updateSongGrid(item.id) { $0.shift(beats: 1) } } label: { Image(systemName: "chevron.right") }
                    }
                    .buttonStyle(.borderless)
                    .help("重拍不对时，把所有小节线整体挪一拍")
                    Spacer()
                    if item.state == .draft {
                        Button("选区对齐到小节线") {
                            let s0 = fr(g.snap(sec(selection.lowerBound), toBars: true))
                            var e0 = fr(g.snap(sec(selection.upperBound), toBars: true))
                            if e0 <= s0 { e0 = fr(g.downbeats(from: sec(s0) + 0.05, to: sec(s0) + 30).first ?? sec(selection.upperBound)) }
                            setRange(s0, e0)
                        }.buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                }
                HStack(spacing: 14) {
                    edgeStatus("起点", selection.lowerBound)
                    edgeStatus("终点", selection.upperBound)
                    let n = barLabels.count
                    if n > 0 { Text("选区内 \(n) 个小节线").font(.caption12).foregroundStyle(Theme.textSecondary) }
                    if !g.steady(from: sec(selection.lowerBound), to: sec(selection.upperBound)) {
                        Label("这段的拍点不稳（可能锁到了切分节奏），小节线只能参考：吸附后务必用节拍器听一下", systemImage: "exclamationmark.triangle")
                            .font(.caption12).foregroundStyle(Theme.warning)
                    } else if g.margin < 0.3 {
                        Label("小节线位置把握不大：打开节拍器听一下重拍，不对就用 ‹ › 挪一拍", systemImage: "ear")
                            .font(.caption12).foregroundStyle(Theme.warning)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderSubtle))
        } else if model.songGridRunning.contains(item.id) {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在分析整曲的拍子和小节线…").font(.caption12) }
        } else if let e = model.songGridError[item.id] {
            HStack(spacing: 8) {
                Text("整曲小节线没检测出来：\(e)").font(.caption12).foregroundStyle(Theme.warning)
                Button("重试") { model.songGridError[item.id] = nil; model.detectSongGrid(item.id) }.buttonStyle(.borderless).font(.caption12)
            }
        }
    }

    private func edgeStatus(_ label: String, _ f: Int64) -> some View {
        let off = offBar(f) ?? 0
        let on = abs(off) <= 30
        return Label(on ? "\(label)在小节线上" : "\(label)离小节线 \(off > 0 ? "+" : "")\(off) ms", systemImage: on ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption12).foregroundStyle(on ? Theme.success : Theme.warning)
    }

    /// Click on the song's bar lines, starting from the downbeat nearest the selection start.
    private func updateClick() {
        guard let g = grid, clickOn else { AudioEngine.shared.setMetronome(MetronomeConfig()); return }
        var m = MetronomeConfig()
        m.enabled = true
        m.bpm = g.bpm
        let anchor = fr(g.snap(sec(selection.lowerBound), toBars: true))
        m.originFrame = anchor
        m.barAnchorFrame = anchor
        m.beatsPerBar = Double(g.beatsPerBar)
        AudioEngine.shared.setMetronome(m)
    }

    private func setRange(_ s: Int64, _ e: Int64) {
        let s2 = max(0, min(s, item.source.frames - 1))
        let e2 = max(s2 + 1, min(e, item.source.frames))
        selection = s2..<e2
        commit()
    }

    private func commit() {
        model.updateSelection(item.id, start: us(selection.lowerBound), end: us(selection.upperBound))
        updateClick()
    }

    private func playSelection() {
        stopAt = loopOn ? nil : selection.upperBound
        AudioEngine.shared.setLoop(loopOn ? selection : nil)
        AudioEngine.shared.play(from: selection.lowerBound)
    }
}

/// Seconds with millisecond display; accepts "1:23.456" or "83.456".
struct TimeField: View {
    var label: String
    var us: Int64
    var onCommit: (Int64) -> Void
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize()
            TextField("", text: $text).font(.mono13).frame(width: 88).textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let v = parse(text) { onCommit(v) } }
        }
        .onAppear { text = formatTime(us: us) }
        .onChange(of: us) { _, v in if !focused { text = formatTime(us: v) } }
    }

    private func parse(_ s: String) -> Int64? {
        let parts = s.split(separator: ":")
        var sec = 0.0
        if parts.count == 2, let m = Double(parts[0]), let x = Double(parts[1]) { sec = m * 60 + x }
        else if let x = Double(s) { sec = x } else { return nil }
        return sec >= 0 ? Int64(sec * 1_000_000) : nil
    }
}

// MARK: - Progress

struct ProgressStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            if let j = model.jobs[item.id] {
                Text(j.stage).font(.sectionTitle)
                if let t = j.total { Text("\(j.completed) / \(t)").font(.mono13).foregroundStyle(Theme.textSecondary) }
                Button("取消") { model.cancelJob(item.id) }.buttonStyle(SecondaryButtonStyle())
            } else {
                Text(item.state.display).font(.sectionTitle)
                Text("任务没有在运行。可在上方重试或丢弃。").font(.caption12).foregroundStyle(Theme.textSecondary)
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var fallback: some View {
        switch item.state {
        case .separating: Button("回到速度调性确认") { var i = item; i.state = .awaitingConfirmation; model.save(i) }.buttonStyle(SecondaryButtonStyle())
        case .transcribing: Button("回到选轨") { var i = item; i.state = .awaitingStem; model.save(i) }.buttonStyle(SecondaryButtonStyle())
        case .harmonizing: Button("重新分析和声") { model.runHarmony(item.id) }.buttonStyle(SecondaryButtonStyle())
        default: EmptyView()
        }
    }
}

// MARK: - Stems

struct StemStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var transport: TransportModel
    @ViewState private var chosen: Set<StemKind> = []
    @ViewState private var listening: StemKind?
    @ViewState private var listeningMix = false
    @ViewState private var loaded = false

    /// Selected stems in a fixed order.
    private var ordered: [StemKind] { StemKind.allCases.filter { chosen.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "试听并选择分轨", subtitle: "钢琴、吉他、其他可以多选：会合并成一轨再转 MIDI，钢琴单薄、和弦在铺底或吉他上时信息更全。人声、鼓、贝斯只能单选，不做和声分析。切换试听保持同一播放位置。")
            if let sep = item.separation {
                VStack(spacing: 0) {
                    ForEach(StemKind.allCases, id: \.self) { kind in
                        if let s = sep.stem(kind) { row(kind, s); Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderSubtle))
                HStack(spacing: 8) {
                    Button { toggle() } label: { Label(transport.isPlaying ? "暂停" : "播放", systemImage: transport.isPlaying ? "pause.fill" : "play.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                    Text(formatTime(us: transport.positionUs)).font(.mono13).foregroundStyle(Theme.textSecondary)
                    Text("共享增益 \(String(format: "%.2f", sep.sharedGainDb)) dB").font(.caption12).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if ordered.count > 1 {
                        Button { listenMix() } label: {
                            Label(listeningMix ? "正在试听合并" : "试听所选合并", systemImage: listeningMix ? "speaker.wave.3.fill" : "speaker.wave.3")
                        }.buttonStyle(SecondaryButtonStyle())
                    }
                    if item.confirmedMidiRevision != nil {
                        Button("不换了，回到原来的结果") { model.cancelReselect(item.id) }.buttonStyle(SecondaryButtonStyle())
                            .help("回到重选分轨之前确认过的 MIDI 与和声")
                    }
                    Button(ordered.isEmpty ? "转为 MIDI" : "转为 MIDI（\(ordered.map(\.displayName).joined(separator: " + "))）") {
                        guard !ordered.isEmpty else { return }
                        AudioEngine.shared.pause(); model.transcribe(item.id, stems: ordered)
                    }
                    .buttonStyle(PrimaryButtonStyle()).disabled(ordered.isEmpty)
                }
                Text("转录完成前六条候选都会保留，可以改选重新转录；之后只保留选中的分轨（多选时还有合并后的那一轨）。")
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .onAppear { chosen = Set(item.selectedStems); load() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in toggle() }
    }

    private func row(_ kind: StemKind, _ s: StemAsset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.isHarmonic ? (chosen.contains(kind) ? "checkmark.square.fill" : "square")
                                              : (chosen.contains(kind) ? "largecircle.fill.circle" : "circle"))
                .foregroundStyle(chosen.contains(kind) ? Theme.accent : Theme.textSecondary)
            Text(kind.displayName).font(.system(size: 14, weight: .medium)).frame(width: 48, alignment: .leading)
            if s.level == .silent { StatusPill(text: "静音", color: Theme.warning) }
            if s.level == .weak { StatusPill(text: "很弱", color: Theme.warning) }
            if !kind.isHarmonic { Text("不做和声分析").font(.caption12).foregroundStyle(Theme.textSecondary) }
            Spacer()
            Text(String(format: "%.1f MB", Double(s.bytes) / 1_000_000)).font(.caption12).foregroundStyle(Theme.textSecondary)
            Button { listen(kind) } label: {
                Label(listening == kind ? "正在试听" : "试听", systemImage: listening == kind ? "speaker.wave.2.fill" : "speaker.wave.2")
            }.buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { pick(kind) }
    }

    private func load() {
        guard let sep = item.separation, !loaded else { return }
        let e = AudioEngine.shared
        e.pause(); e.configure(sampleRate: 44100); e.setMidi([], enabled: false); e.setMetronome(MetronomeConfig()); e.setLoop(nil)
        transport.sampleRate = 44100
        var tracks: [AudioTrack] = []
        for s in sep.stems {
            if let buf = try? AudioLoader.load(model.paths.url(relative: s.relativePath)) {
                let t = AudioTrack(id: s.kind.rawValue, buffer: buf)
                tracks.append(t)
            }
        }
        e.setTracks(tracks)
        e.setLength(sep.frames)
        e.seek(0) // the confirmation page left the cursor at the clip's position in the whole song
        listen(listening ?? ordered.first ?? .piano, start: false)
        loaded = true
    }

    /// Harmony stems toggle (several can go in together); vocals, drums and bass are single choices.
    private func pick(_ kind: StemKind) {
        if kind.isHarmonic {
            chosen = chosen.filter(\.isHarmonic)
            if chosen.contains(kind) { chosen.remove(kind) } else { chosen.insert(kind) }
        } else {
            chosen = [kind]
        }
        if listeningMix { listenMix() }
    }

    /// The selected stems together, as they will be mixed for transcription.
    private func listenMix() {
        listeningMix = true
        listening = nil
        for k in StemKind.allCases { AudioEngine.shared.updateTrack(k.rawValue, muted: !chosen.contains(k), solo: false) }
        if !AudioEngine.shared.isPlaying { AudioEngine.shared.play() }
    }

    private func listen(_ kind: StemKind, start: Bool = true) {
        listeningMix = false
        listening = kind
        for k in StemKind.allCases { AudioEngine.shared.updateTrack(k.rawValue, muted: false, solo: k == kind) }
        if start && !AudioEngine.shared.isPlaying { AudioEngine.shared.play() }
    }

    private func toggle() {
        if AudioEngine.shared.isPlaying { AudioEngine.shared.pause() } else { AudioEngine.shared.play() }
    }
}
